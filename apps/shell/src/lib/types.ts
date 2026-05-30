// Types for the KRIT annotation editor.

export type ToolId =
  | "select"
  | "arrow"
  | "rect"
  | "ellipse"
  | "line"
  | "text"
  | "blur"
  | "crop";

export interface Tool {
  id: ToolId;
  label: string;
  shortcut: string; // single key (no modifier)
}

// Markup tools in toolbar order.
export const TOOLS: Tool[] = [
  { id: "select", label: "Select", shortcut: "V" },
  { id: "arrow", label: "Arrow", shortcut: "A" },
  { id: "rect", label: "Rectangle", shortcut: "R" },
  { id: "ellipse", label: "Ellipse", shortcut: "E" },
  { id: "line", label: "Line", shortcut: "L" },
  { id: "text", label: "Text", shortcut: "T" },
  { id: "blur", label: "Blur", shortcut: "B" },
  { id: "crop", label: "Crop", shortcut: "C" },
];

export type ShapeType = "arrow" | "rect" | "ellipse" | "line" | "text" | "blur";

// Serializable model for each drawn object. Konva handles rendering;
// this is the source of truth that feeds the history (undo/redo).
export interface Shape {
  id: string;
  type: ShapeType;
  x: number;
  y: number;
  // rect/ellipse/blur use width/height; line/arrow use points; text uses text
  width?: number;
  height?: number;
  points?: number[]; // [x1, y1, x2, y2] relative to x/y
  text?: string;
  fontSize?: number;
  color: string;
  strokeWidth: number;
  rotation?: number;
}

// Brand palette. Coral is the default (action accent); the rest cover the
// common cases for annotating over screenshots.
export const PALETTE: string[] = [
  "#FF7847", // signal coral (default)
  "#F4F5F6", // text-hi (white)
  "#57B6FF", // ice (blue)
  "#FF6363", // red
  "#3DD68C", // green
  "#FFD166", // yellow
  "#07080a", // void (black)
];

export const STROKE_WIDTHS: number[] = [2, 4, 6, 10];
