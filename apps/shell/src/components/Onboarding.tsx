// First-run onboarding. Three steps: intro, Screen Recording permission, and
// shortcuts. The permission step drives the real TCC flow via the Swift helper
// (request + poll), since KRIT cannot capture a pixel without it.

import { useCallback, useEffect, useRef, useState } from "react";
import { KritMark } from "./icons";
import {
  checkScreenPermission,
  requestScreenPermission,
  isTauri,
} from "../lib/tauri";
import { playSound, unlockAudio, audioReady } from "../lib/sounds";

const ONBOARDED_KEY = "krit.onboarded";

export function hasOnboarded(): boolean {
  try {
    return localStorage.getItem(ONBOARDED_KEY) === "1";
  } catch {
    return false;
  }
}

function markOnboarded() {
  try {
    localStorage.setItem(ONBOARDED_KEY, "1");
  } catch {
    // ignore (private mode)
  }
}

type Step = "intro" | "permission" | "ready";
type PermState = "unknown" | "checking" | "waiting" | "granted" | "denied";

export function Onboarding({ onDone }: { onDone: () => void }) {
  const [step, setStep] = useState<Step>("intro");
  const [perm, setPerm] = useState<PermState>("unknown");
  const pollRef = useRef<number | null>(null);
  // Bumped each time the launch cue fires; used as a key to restart the intro
  // animation so it stays in sync with the sound.
  const [launchSeq, setLaunchSeq] = useState(0);

  // Launch cue: sound + intro animation, fired together. We try on mount
  // (Tauri's webview usually allows autoplay). If the audio was still gated,
  // the first gesture re-fires both so they stay synced — the bumped key
  // restarts the CSS timeline from zero.
  useEffect(() => {
    const fire = () => {
      unlockAudio();
      void playSound("launch");
      setLaunchSeq((s) => s + 1);
    };
    fire();

    let reinforced = false;
    const onGesture = () => {
      if (!reinforced && !audioReady()) {
        reinforced = true;
        fire();
      }
      cleanup();
    };
    function cleanup() {
      window.removeEventListener("pointerdown", onGesture);
      window.removeEventListener("keydown", onGesture);
    }
    window.addEventListener("pointerdown", onGesture);
    window.addEventListener("keydown", onGesture);
    return cleanup;
  }, []);

  const stopPolling = useCallback(() => {
    if (pollRef.current !== null) {
      window.clearInterval(pollRef.current);
      pollRef.current = null;
    }
  }, []);

  useEffect(() => stopPolling, [stopPolling]);

  const goReady = useCallback(() => {
    void playSound("capture");
    setStep("ready");
  }, []);

  // Enters the permission step: check first; if already granted, skip ahead.
  const enterPermission = useCallback(async () => {
    void playSound("toggle");
    setStep("permission");
    setPerm("checking");
    const granted = await checkScreenPermission();
    if (granted) {
      setPerm("granted");
      void playSound("save");
    } else {
      setPerm("unknown");
    }
  }, []);

  // Polls the helper until the user flips the toggle in System Settings.
  const startPolling = useCallback(() => {
    stopPolling();
    pollRef.current = window.setInterval(async () => {
      const granted = await checkScreenPermission();
      if (granted) {
        stopPolling();
        setPerm("granted");
        void playSound("save");
      }
    }, 1200);
  }, [stopPolling]);

  const requestPermission = useCallback(async () => {
    setPerm("waiting");
    const granted = await requestScreenPermission();
    if (granted) {
      setPerm("granted");
      void playSound("save");
      return;
    }
    // The system dialog is async; macOS often needs a relaunch after the first
    // grant. Poll so the UI reflects the change the moment it lands.
    setPerm("denied");
    startPolling();
  }, [startPolling]);

  const finish = useCallback(() => {
    stopPolling();
    markOnboarded();
    void playSound("copy");
    onDone();
  }, [onDone, stopPolling]);

  return (
    <div className="ob" role="dialog" aria-label="Welcome to KRIT" data-tauri-drag-region>
      {/* invisible title bar so the frameless window can be dragged */}
      <div className="ob-dragbar" data-tauri-drag-region aria-hidden />
      <div className="ob-grain" aria-hidden />
      <div className="ob-stage">
        {step === "intro" && (
          <Intro key={launchSeq} launching={launchSeq > 0} onNext={enterPermission} />
        )}
        {step === "permission" && (
          <Permission
            state={perm}
            tauri={isTauri()}
            onRequest={requestPermission}
            onContinue={goReady}
            onSkip={finish}
          />
        )}
        {step === "ready" && <Ready onFinish={finish} />}
      </div>
      <Dots step={step} />
    </div>
  );
}

function Intro({
  launching,
  onNext,
}: {
  launching: boolean;
  onNext: () => void;
}) {
  // `ob-launch` runs the cinematic timeline keyed to the 6s launch sound:
  // punch (0s) -> breathe -> build -> wordmark hit (~3.8s) -> tagline -> CTA.
  return (
    <section className={`ob-panel ob-intro${launching ? " ob-launch" : ""}`}>
      <div className="ob-mark">
        <KritMark size={72} />
      </div>
      <h1 className="ob-wordmark">KRIT</h1>
      <p className="ob-tagline">Capture. Annotate. One shortcut.</p>
      <p className="ob-sub">
        A native screenshot and markup tool for macOS. Open source, no account,
        no upload.
      </p>
      <button className="ob-cta ob-intro-cta" onClick={onNext} autoFocus>
        Get started
      </button>
    </section>
  );
}

function Permission({
  state,
  tauri,
  onRequest,
  onContinue,
  onSkip,
}: {
  state: PermState;
  tauri: boolean;
  onRequest: () => void;
  onContinue: () => void;
  onSkip: () => void;
}) {
  const granted = state === "granted";
  return (
    <section className="ob-panel">
      <div className="ob-icon-ring" data-granted={granted}>
        {granted ? <Check /> : <Aperture />}
      </div>
      <h2 className="ob-h2">Screen Recording</h2>
      <p className="ob-sub">
        macOS gates the screen behind a permission. KRIT needs it to capture.
        Nothing you capture leaves your machine.
      </p>

      {!tauri && (
        <p className="ob-note">Browser preview — permission is mocked here.</p>
      )}

      {granted ? (
        <>
          <p className="ob-status ob-status-ok">Access granted</p>
          <button className="ob-cta" onClick={onContinue} autoFocus>
            Continue
          </button>
        </>
      ) : (
        <>
          {state === "waiting" && (
            <p className="ob-status">Waiting for the system dialog…</p>
          )}
          {state === "denied" && (
            <p className="ob-status ob-status-warn">
              Turn KRIT on in System Settings › Privacy &amp; Security › Screen
              Recording, then quit and reopen KRIT — macOS only applies it after
              a restart.
            </p>
          )}
          <button className="ob-cta" onClick={onRequest} autoFocus>
            {state === "denied" ? "Check again" : "Grant access"}
          </button>
          <button className="ob-skip" onClick={onSkip}>
            Skip for now
          </button>
        </>
      )}
    </section>
  );
}

function Ready({ onFinish }: { onFinish: () => void }) {
  return (
    <section className="ob-panel">
      <div className="ob-icon-ring" data-granted="true">
        <KritMark size={40} />
      </div>
      <h2 className="ob-h2">You're set</h2>
      <p className="ob-sub">Two shortcuts do the work. KRIT lives in the menu bar.</p>

      <div className="ob-keys">
        <div className="ob-key-row">
          <span className="ob-key-combo">
            <kbd>⇧</kbd>
            <kbd>⌘</kbd>
            <kbd>4</kbd>
          </span>
          <span className="ob-key-label">Snap a region</span>
        </div>
        <div className="ob-key-row">
          <span className="ob-key-combo">
            <kbd>⇧</kbd>
            <kbd>⌘</kbd>
            <kbd>3</kbd>
          </span>
          <span className="ob-key-label">Snap the screen</span>
        </div>
      </div>

      <button className="ob-cta" onClick={onFinish} autoFocus>
        Open KRIT
      </button>
    </section>
  );
}

function Dots({ step }: { step: Step }) {
  const order: Step[] = ["intro", "permission", "ready"];
  return (
    <div className="ob-dots" aria-hidden>
      {order.map((s) => (
        <span key={s} className="ob-dot" data-on={s === step} />
      ))}
    </div>
  );
}

function Aperture() {
  return (
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
      <circle
        cx="12"
        cy="12"
        r="8.5"
        stroke="currentColor"
        strokeWidth="1.4"
      />
      <path
        d="M12 3.5 L15 9 M20.5 12 L14 12.6 M16 20 L12.5 14.5 M3.5 12 L10 11.4 M8 20 L11.5 14.5 M12 3.5 L9 9"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

function Check() {
  return (
    <svg width="28" height="28" viewBox="0 0 24 24" fill="none">
      <path
        d="M5 12.5 L10 17.5 L19 7"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
