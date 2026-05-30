// Top bar: wordmark + actions. The whole area is draggable (Tauri overlay
// titlebar) except the buttons. Actions: undo/redo, open, copy, save.

import {
  KritMark,
  IconUndo,
  IconRedo,
  IconOpen,
  IconCopy,
  IconSave,
  IconSoundOn,
  IconSoundOff,
} from "./icons";

interface Props {
  fileName: string | null;
  canUndo: boolean;
  canRedo: boolean;
  hasImage: boolean;
  muted: boolean;
  onUndo: () => void;
  onRedo: () => void;
  onOpen: () => void;
  onCopy: () => void;
  onSave: () => void;
  onToggleMute: () => void;
  status: string | null;
}

export function TopBar({
  fileName,
  canUndo,
  canRedo,
  hasImage,
  muted,
  onUndo,
  onRedo,
  onOpen,
  onCopy,
  onSave,
  onToggleMute,
  status,
}: Props) {
  return (
    <header className="topbar" data-tauri-drag-region>
      <div className="topbar-brand" data-tauri-drag-region>
        <span className="brand-mark">
          <KritMark size={16} />
        </span>
        <span className="brand-word mono">KRIT</span>
        {fileName && <span className="topbar-file">{fileName}</span>}
        {status && <span className="topbar-status mono">{status}</span>}
      </div>

      <div className="topbar-actions">
        <button
          className="tb-btn"
          title="Undo (⌘Z)"
          disabled={!canUndo}
          onClick={onUndo}
        >
          <IconUndo />
        </button>
        <button
          className="tb-btn"
          title="Redo (⇧⌘Z)"
          disabled={!canRedo}
          onClick={onRedo}
        >
          <IconRedo />
        </button>

        <button
          className="tb-btn"
          title={muted ? "Sound off" : "Sound on"}
          aria-pressed={muted}
          aria-label={muted ? "Unmute sounds" : "Mute sounds"}
          onClick={onToggleMute}
        >
          {muted ? <IconSoundOff /> : <IconSoundOn />}
        </button>

        <span className="tb-sep" />

        <button className="tb-btn" title="Open image (⌘O)" onClick={onOpen}>
          <IconOpen />
          <span>Open</span>
        </button>
        <button
          className="tb-btn"
          title="Copy (⌘C)"
          disabled={!hasImage}
          onClick={onCopy}
        >
          <IconCopy />
          <span>Copy</span>
        </button>
        <button
          className="tb-btn tb-btn-primary"
          title="Save (⌘S)"
          disabled={!hasImage}
          onClick={onSave}
        >
          <IconSave />
          <span>Save</span>
        </button>
      </div>
    </header>
  );
}
