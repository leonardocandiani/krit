// Tool icons. Custom line icons, currentColor stroke, 18x18, 1.6 width.
// Matches the dry KRIT aesthetic.

import type React from "react";
import type { ToolId } from "../lib/types";

interface IconProps {
  size?: number;
}

const base = (size: number) => ({
  width: size,
  height: size,
  viewBox: "0 0 24 24",
  fill: "none" as const,
  stroke: "currentColor",
  strokeWidth: 1.6,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
});

function Select({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M5 4 L13.5 19 L15.5 12.5 L21 10.5 Z" />
    </svg>
  );
}

function Arrow({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M5 19 L19 5" />
      <path d="M11 5 H19 V13" />
    </svg>
  );
}

function Rect({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <rect x="4" y="6" width="16" height="12" rx="1.5" />
    </svg>
  );
}

function Ellipse({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <ellipse cx="12" cy="12" rx="8" ry="6" />
    </svg>
  );
}

function Line({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M5 19 L19 5" />
    </svg>
  );
}

function TextIcon({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M5 6 H19" />
      <path d="M12 6 V19" />
    </svg>
  );
}

function Blur({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <circle cx="8.5" cy="8.5" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="13" cy="9" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="17" cy="8.5" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="9" cy="13" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="14.5" cy="13.5" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="8" cy="17" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="13.5" cy="17" r="0.6" fill="currentColor" stroke="none" />
      <circle cx="17" cy="16" r="0.6" fill="currentColor" stroke="none" />
    </svg>
  );
}

function Crop({ size = 18 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M7 3 V17 H21" />
      <path d="M3 7 H17 V21" />
    </svg>
  );
}

const MAP: Record<ToolId, (p: IconProps) => React.JSX.Element> = {
  select: Select,
  arrow: Arrow,
  rect: Rect,
  ellipse: Ellipse,
  line: Line,
  text: TextIcon,
  blur: Blur,
  crop: Crop,
};

export function ToolIcon({ id, size }: { id: ToolId; size?: number }) {
  const Cmp = MAP[id];
  return <Cmp size={size} />;
}

// Top bar utility icons.
export function IconCopy({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <rect x="8" y="8" width="12" height="12" rx="2" />
      <path d="M4 16 V5 A1 1 0 0 1 5 4 H15" />
    </svg>
  );
}

export function IconSave({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M5 4 H16 L20 8 V19 A1 1 0 0 1 19 20 H5 A1 1 0 0 1 4 19 V5 A1 1 0 0 1 5 4 Z" />
      <path d="M8 4 V9 H15" />
      <path d="M8 20 V14 H16 V20" />
    </svg>
  );
}

export function IconOpen({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M3 7 A1 1 0 0 1 4 6 H9 L11 8 H20 A1 1 0 0 1 21 9 V18 A1 1 0 0 1 20 19 H4 A1 1 0 0 1 3 18 Z" />
    </svg>
  );
}

export function IconUndo({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M9 7 L4 11 L9 15" />
      <path d="M4 11 H14 A5 5 0 0 1 14 21 H11" />
    </svg>
  );
}

export function IconRedo({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M15 7 L20 11 L15 15" />
      <path d="M20 11 H10 A5 5 0 0 0 10 21 H13" />
    </svg>
  );
}

export function IconTrash({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M4 7 H20" />
      <path d="M9 7 V5 A1 1 0 0 1 10 4 H14 A1 1 0 0 1 15 5 V7" />
      <path d="M6 7 L7 20 A1 1 0 0 0 8 21 H16 A1 1 0 0 0 17 20 L18 7" />
    </svg>
  );
}

export function IconSoundOn({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M4 9 V15 H8 L13 19 V5 L8 9 Z" fill="currentColor" stroke="none" />
      <path d="M16.5 8.5 a4 4 0 0 1 0 7" />
      <path d="M18.8 6 a7 7 0 0 1 0 12" />
    </svg>
  );
}

export function IconSoundOff({ size = 16 }: IconProps) {
  return (
    <svg {...base(size)}>
      <path d="M4 9 V15 H8 L13 19 V5 L8 9 Z" fill="currentColor" stroke="none" />
      <path d="M16 9 L21 15" />
      <path d="M21 9 L16 15" />
    </svg>
  );
}

// Brand symbol "The Notch": two diagonal crop brackets.
export function KritMark({ size = 18 }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
    >
      <path
        d="M6 9 V6 H9"
        stroke="currentColor"
        strokeWidth="2.25"
        strokeLinecap="butt"
        strokeLinejoin="miter"
      />
      <path
        d="M18 15 V18 H15"
        stroke="currentColor"
        strokeWidth="2.25"
        strokeLinecap="butt"
        strokeLinejoin="miter"
      />
    </svg>
  );
}
