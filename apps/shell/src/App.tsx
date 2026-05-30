// KRIT shell: annotation editor composition.
// Wires toolbar, topbar and canvas; manages image, tool, shortcuts,
// drag&drop and export.

import { useCallback, useEffect, useRef, useState } from "react";
import { Toolbar } from "./components/Toolbar";
import { TopBar } from "./components/TopBar";
import { Editor, type EditorHandle } from "./components/Editor";
import { Onboarding, hasOnboarded } from "./components/Onboarding";
import { useHistory } from "./hooks/useHistory";
import { TOOLS, type ToolId, type Shape } from "./lib/types";
import { listen } from "@tauri-apps/api/event";
import { copyImage, saveImage, pickImage, openImage, isTauri } from "./lib/tauri";
import {
  playSound,
  isMuted,
  toggleMuted,
  unlockAudio,
} from "./lib/sounds";

// Key -> tool map (no modifier).
const KEY_TO_TOOL: Record<string, ToolId> = Object.fromEntries(
  TOOLS.map((t) => [t.shortcut.toLowerCase(), t.id]),
);

function loadImageFromDataUrl(dataUrl: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = dataUrl;
  });
}

export default function App() {
  const [image, setImage] = useState<HTMLImageElement | null>(null);
  const [fileName, setFileName] = useState<string | null>(null);
  const [tool, setTool] = useState<ToolId>("select");
  const [color, setColor] = useState("#FF7847");
  const [strokeWidth, setStrokeWidth] = useState(4);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [muted, setMutedState] = useState(isMuted());
  const [onboarding, setOnboarding] = useState(() => !hasOnboarded());

  const { shapes, canUndo, canRedo, commit, undo, redo, reset } =
    useHistory([]);
  const editorRef = useRef<EditorHandle>(null);

  // Ephemeral status message (copy/save feedback).
  const flash = useCallback((msg: string) => {
    setStatus(msg);
    window.setTimeout(() => setStatus(null), 1800);
  }, []);

  // App launch chime. Browsers gate audio behind a user gesture, so the
  // context is unlocked on the first interaction and the launch cue plays then.
  // Skipped during onboarding — that flow owns the launch cue.
  useEffect(() => {
    if (onboarding) return;
    let played = false;
    function onFirstGesture() {
      unlockAudio();
      if (!played) {
        played = true;
        void playSound("launch");
      }
      window.removeEventListener("pointerdown", onFirstGesture);
      window.removeEventListener("keydown", onFirstGesture);
    }
    window.addEventListener("pointerdown", onFirstGesture);
    window.addEventListener("keydown", onFirstGesture);
    return () => {
      window.removeEventListener("pointerdown", onFirstGesture);
      window.removeEventListener("keydown", onFirstGesture);
    };
  }, [onboarding]);

  const onToggleMute = useCallback(() => {
    const next = toggleMuted();
    setMutedState(next);
    if (!next) void playSound("toggle");
  }, []);

  const openFile = useCallback(async () => {
    const res = await pickImage();
    if (!res) return;
    const img = await loadImageFromDataUrl(res.dataUrl);
    setImage(img);
    setFileName(res.name);
    reset([]);
    setSelectedId(null);
  }, [reset]);

  // Loads an image straight from a file path (used by the native capture flow).
  const loadFromPath = useCallback(
    async (path: string) => {
      try {
        const res = await openImage(path);
        const img = await loadImageFromDataUrl(res.dataUrl);
        setImage(img);
        setFileName(res.name);
        reset([]);
        setSelectedId(null);
      } catch (e) {
        void playSound("error");
        flash("Could not open capture");
        console.error(e);
      }
    },
    [reset, flash],
  );

  // Native capture results from the Swift helper (tray "Snap region"/"Snap screen").
  useEffect(() => {
    if (!isTauri()) return;
    const unlisten = [
      listen<string>("krit://capture-complete", (e) => {
        void loadFromPath(e.payload);
      }),
      listen<string>("krit://capture-error", (e) => {
        void playSound("error");
        flash("Capture failed");
        console.error("capture error:", e.payload);
      }),
      // "cancelled" (Esc) is silent on purpose — no toast, no sound.
    ];
    return () => {
      unlisten.forEach((p) => p.then((off) => off()));
    };
  }, [loadFromPath, flash]);

  const doCopy = useCallback(async () => {
    const url = editorRef.current?.exportPNG();
    if (!url) return;
    try {
      await copyImage(url);
      void playSound("copy");
      flash("Copied to clipboard");
    } catch (e) {
      void playSound("error");
      flash("Copy failed");
      console.error(e);
    }
  }, [flash]);

  const doSave = useCallback(async () => {
    const url = editorRef.current?.exportPNG();
    if (!url) return;
    try {
      const name = fileName?.replace(/\.[^.]+$/, "") ?? "krit";
      const ok = await saveImage(url, `${name}-krit.png`);
      if (ok) {
        void playSound("save");
        flash("Saved");
      }
    } catch (e) {
      void playSound("error");
      flash("Save failed");
      console.error(e);
    }
  }, [fileName, flash]);

  // Crops the base image to the area selected by the crop tool.
  const doCrop = useCallback(
    (box: { x: number; y: number; width: number; height: number }) => {
      if (!image) return;
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(box.width);
      canvas.height = Math.round(box.height);
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      ctx.drawImage(
        image,
        box.x,
        box.y,
        box.width,
        box.height,
        0,
        0,
        box.width,
        box.height,
      );
      const url = canvas.toDataURL("image/png");
      loadImageFromDataUrl(url).then((img) => {
        // shapes fall outside the new coord system; clear them to avoid offset.
        setImage(img);
        reset([]);
        setSelectedId(null);
        setTool("select");
        void playSound("pin");
        flash("Cropped");
      });
    },
    [image, reset, flash],
  );

  // --- keyboard shortcuts ---
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const target = e.target as HTMLElement;
      // ignore while typing text
      if (target.tagName === "TEXTAREA" || target.tagName === "INPUT") return;

      const meta = e.metaKey || e.ctrlKey;

      if (meta && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
        return;
      }
      if (meta && e.key.toLowerCase() === "c") {
        e.preventDefault();
        doCopy();
        return;
      }
      if (meta && e.key.toLowerCase() === "s") {
        e.preventDefault();
        doSave();
        return;
      }
      if (meta && e.key.toLowerCase() === "o") {
        e.preventDefault();
        openFile();
        return;
      }
      if (meta) return;

      if (e.key === "Backspace" || e.key === "Delete") {
        e.preventDefault();
        editorRef.current?.deleteSelected();
        return;
      }
      if (e.key === "Escape") {
        setSelectedId(null);
        return;
      }
      const t = KEY_TO_TOOL[e.key.toLowerCase()];
      if (t) {
        setTool(t);
        if (t !== "select") setSelectedId(null);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [undo, redo, doCopy, doSave, openFile]);

  // --- file drag & drop (browser/webview) ---
  useEffect(() => {
    function onDragOver(e: DragEvent) {
      e.preventDefault();
    }
    async function onDrop(e: DragEvent) {
      e.preventDefault();
      const file = e.dataTransfer?.files?.[0];
      if (!file || !file.type.startsWith("image/")) return;
      const reader = new FileReader();
      reader.onload = async () => {
        const img = await loadImageFromDataUrl(reader.result as string);
        setImage(img);
        setFileName(file.name);
        reset([]);
        setSelectedId(null);
      };
      reader.readAsDataURL(file);
    }
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("drop", onDrop);
    return () => {
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("drop", onDrop);
    };
  }, [reset]);

  if (onboarding) {
    return <Onboarding onDone={() => setOnboarding(false)} />;
  }

  return (
    <div className="app">
      <TopBar
        fileName={fileName}
        canUndo={canUndo}
        canRedo={canRedo}
        hasImage={!!image}
        muted={muted}
        onUndo={undo}
        onRedo={redo}
        onOpen={openFile}
        onCopy={doCopy}
        onSave={doSave}
        onToggleMute={onToggleMute}
        status={status}
      />
      <div className="app-body">
        <Toolbar
          tool={tool}
          onTool={(t) => {
            setTool(t);
            if (t !== "select") setSelectedId(null);
          }}
          color={color}
          onColor={setColor}
          strokeWidth={strokeWidth}
          onStrokeWidth={setStrokeWidth}
        />
        <main className="canvas-area">
          <Editor
            ref={editorRef}
            image={image}
            tool={tool}
            color={color}
            strokeWidth={strokeWidth}
            shapes={shapes as Shape[]}
            selectedId={selectedId}
            onSelect={setSelectedId}
            onCommit={commit}
            onCrop={doCrop}
          />
        </main>
      </div>
    </div>
  );
}
