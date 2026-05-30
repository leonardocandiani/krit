// Toolbar (side rail). Active tool in coral, the only accent per viewport.
// Below: color palette and stroke width.

import { TOOLS, PALETTE, STROKE_WIDTHS } from "../lib/types";
import type { ToolId } from "../lib/types";
import { ToolIcon } from "./icons";

interface Props {
  tool: ToolId;
  onTool: (t: ToolId) => void;
  color: string;
  onColor: (c: string) => void;
  strokeWidth: number;
  onStrokeWidth: (w: number) => void;
}

export function Toolbar({
  tool,
  onTool,
  color,
  onColor,
  strokeWidth,
  onStrokeWidth,
}: Props) {
  return (
    <aside className="toolbar">
      <div className="toolbar-tools">
        {TOOLS.map((t) => (
          <button
            key={t.id}
            className={`tool-btn ${tool === t.id ? "is-active" : ""}`}
            title={`${t.label} · ${t.shortcut}`}
            aria-pressed={tool === t.id}
            onClick={() => onTool(t.id)}
          >
            <ToolIcon id={t.id} />
            <span className="tool-key">{t.shortcut}</span>
          </button>
        ))}
      </div>

      <div className="toolbar-divider" />

      <div className="toolbar-section">
        <span className="toolbar-label mono">Color</span>
        <div className="swatches">
          {PALETTE.map((c) => (
            <button
              key={c}
              className={`swatch ${color === c ? "is-active" : ""}`}
              style={{ background: c }}
              title={c}
              aria-label={`Color ${c}`}
              onClick={() => onColor(c)}
            />
          ))}
        </div>
      </div>

      <div className="toolbar-section">
        <span className="toolbar-label mono">Stroke</span>
        <div className="strokes">
          {STROKE_WIDTHS.map((w) => (
            <button
              key={w}
              className={`stroke-btn ${strokeWidth === w ? "is-active" : ""}`}
              title={`${w}px`}
              onClick={() => onStrokeWidth(w)}
            >
              <span className="stroke-dot" style={{ height: w, width: w }} />
            </button>
          ))}
        </div>
      </div>
    </aside>
  );
}
