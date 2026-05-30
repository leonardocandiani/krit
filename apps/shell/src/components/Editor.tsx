// KRIT core: Konva annotation canvas.
// Loads an image and draws editable objects on top (arrow, shapes, text,
// blur, crop). Select/move/resize via Transformer.
// Exports at native resolution (the original image's devicePixelRatio).

import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  Stage,
  Layer,
  Image as KonvaImage,
  Rect,
  Ellipse,
  Arrow,
  Line,
  Text as KonvaText,
  Transformer,
} from "react-konva";
import Konva from "konva";
import type { Shape, ShapeType, ToolId } from "../lib/types";

export interface EditorHandle {
  // Exports the final result as PNG at the image's native resolution.
  exportPNG: () => string | null;
  deleteSelected: () => void;
}

interface EditorProps {
  image: HTMLImageElement | null;
  tool: ToolId;
  color: string;
  strokeWidth: number;
  shapes: Shape[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  // commit = new history point (undo/redo)
  onCommit: (next: Shape[]) => void;
  // crop requested a new area -> App crops the base image
  onCrop: (box: { x: number; y: number; width: number; height: number }) => void;
}

let uid = 0;
const nextId = () => `s${Date.now()}_${uid++}`;

function normalizeBox(x1: number, y1: number, x2: number, y2: number) {
  return {
    x: Math.min(x1, x2),
    y: Math.min(y1, y2),
    width: Math.abs(x2 - x1),
    height: Math.abs(y2 - y1),
  };
}

export const Editor = forwardRef<EditorHandle, EditorProps>(function Editor(
  {
    image,
    tool,
    color,
    strokeWidth,
    shapes,
    selectedId,
    onSelect,
    onCommit,
    onCrop,
  },
  ref,
) {
  const stageRef = useRef<Konva.Stage>(null);
  const trRef = useRef<Konva.Transformer>(null);
  const shapeRefs = useRef<Map<string, Konva.Node>>(new Map());
  const containerRef = useRef<HTMLDivElement>(null);

  const [viewport, setViewport] = useState({ width: 800, height: 600 });
  const [draft, setDraft] = useState<Shape | null>(null); // shape being drawn
  const [cropBox, setCropBox] = useState<ReturnType<
    typeof normalizeBox
  > | null>(null);
  const [editingText, setEditingText] = useState<{
    id: string;
    x: number;
    y: number;
    value: string;
    fontSize: number;
    color: string;
  } | null>(null);

  // Scale to fit the image in the viewport (only shrinks, never above 1).
  const scale = useMemo(() => {
    if (!image) return 1;
    const pad = 48;
    const sx = (viewport.width - pad) / image.width;
    const sy = (viewport.height - pad) / image.height;
    return Math.min(1, sx, sy);
  }, [image, viewport]);

  const stageW = image ? image.width * scale : viewport.width;
  const stageH = image ? image.height * scale : viewport.height;

  // Tracks the container size to dimension the stage.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setViewport({ width: el.clientWidth, height: el.clientHeight });
    });
    ro.observe(el);
    setViewport({ width: el.clientWidth, height: el.clientHeight });
    return () => ro.disconnect();
  }, []);

  // Binds the Transformer to the selected node (select mode only).
  useEffect(() => {
    const tr = trRef.current;
    if (!tr) return;
    if (tool !== "select" || !selectedId) {
      tr.nodes([]);
      tr.getLayer()?.batchDraw();
      return;
    }
    const node = shapeRefs.current.get(selectedId);
    tr.nodes(node ? [node] : []);
    tr.getLayer()?.batchDraw();
  }, [selectedId, tool, shapes]);

  useImperativeHandle(ref, () => ({
    exportPNG: () => {
      const stage = stageRef.current;
      if (!stage || !image) return null;
      // Clear selection so the Transformer doesn't show up in the export.
      const tr = trRef.current;
      tr?.nodes([]);
      tr?.getLayer()?.batchDraw();
      // pixelRatio restores native resolution: the stage is scaled by `scale`.
      const url = stage.toDataURL({ pixelRatio: 1 / scale });
      return url;
    },
    deleteSelected: () => {
      if (!selectedId) return;
      onCommit(shapes.filter((s) => s.id !== selectedId));
      onSelect(null);
    },
  }));

  // --- mouse drawing ---
  function pointer(): { x: number; y: number } {
    const stage = stageRef.current;
    const p = stage?.getPointerPosition();
    if (!p) return { x: 0, y: 0 };
    // convert stage coords (scaled) to native image coords
    return { x: p.x / scale, y: p.y / scale };
  }

  function handleMouseDown(e: Konva.KonvaEventObject<MouseEvent>) {
    if (!image) return;
    const clickedEmpty = e.target === e.target.getStage();

    if (tool === "select") {
      if (clickedEmpty) onSelect(null);
      return;
    }

    const { x, y } = pointer();

    if (tool === "crop") {
      setCropBox({ x, y, width: 0, height: 0 });
      return;
    }

    if (tool === "text") {
      const id = nextId();
      setEditingText({ id, x, y, value: "", fontSize: 24, color });
      return;
    }

    const id = nextId();
    const common = { id, x, y, color, strokeWidth };
    let shape: Shape;
    switch (tool) {
      case "rect":
      case "ellipse":
      case "blur":
        shape = { ...common, type: tool as ShapeType, width: 0, height: 0 };
        break;
      case "arrow":
      case "line":
        shape = { ...common, type: tool, points: [0, 0, 0, 0] };
        break;
      default:
        return;
    }
    setDraft(shape);
  }

  function handleMouseMove() {
    if (!image) return;
    const { x, y } = pointer();

    if (cropBox) {
      setCropBox(normalizeBox(cropBox.x, cropBox.y, x, y));
      return;
    }
    if (!draft) return;

    if (draft.type === "arrow" || draft.type === "line") {
      setDraft({ ...draft, points: [0, 0, x - draft.x, y - draft.y] });
    } else {
      const box = normalizeBox(draft.x, draft.y, x, y);
      setDraft({ ...draft, ...box });
    }
  }

  function handleMouseUp() {
    if (cropBox) {
      if (cropBox.width > 4 && cropBox.height > 4) onCrop(cropBox);
      setCropBox(null);
      return;
    }
    if (!draft) return;

    // discard clicks with no drag
    const tiny =
      draft.type === "arrow" || draft.type === "line"
        ? Math.hypot(draft.points![2], draft.points![3]) < 4
        : (draft.width ?? 0) < 4 && (draft.height ?? 0) < 4;

    if (!tiny) {
      onCommit([...shapes, draft]);
      onSelect(draft.id);
    }
    setDraft(null);
  }

  // --- text: commit the overlay textarea ---
  function commitText() {
    if (!editingText) return;
    const value = editingText.value.trim();
    if (value) {
      const shape: Shape = {
        id: editingText.id,
        type: "text",
        x: editingText.x,
        y: editingText.y,
        text: value,
        fontSize: editingText.fontSize,
        color: editingText.color,
        strokeWidth: 0,
      };
      onCommit([...shapes, shape]);
      onSelect(shape.id);
    }
    setEditingText(null);
  }

  // --- transform/drag update for an existing shape ---
  function applyNodeChange(id: string, node: Konva.Node) {
    const next = shapes.map((s) => {
      if (s.id !== id) return s;
      const upd: Shape = { ...s, x: node.x() / scale, y: node.y() / scale };
      const sx = node.scaleX();
      const sy = node.scaleY();
      if (s.type === "rect" || s.type === "ellipse" || s.type === "blur") {
        upd.width = Math.max(2, (s.width ?? 0) * sx);
        upd.height = Math.max(2, (s.height ?? 0) * sy);
      } else if (s.type === "line" || s.type === "arrow") {
        upd.points = (s.points ?? []).map((p, i) =>
          i % 2 === 0 ? p * sx : p * sy,
        );
      } else if (s.type === "text") {
        upd.fontSize = Math.max(8, (s.fontSize ?? 24) * sy);
      }
      upd.rotation = node.rotation();
      // reset the visual scale already absorbed into the model
      node.scaleX(1);
      node.scaleY(1);
      return upd;
    });
    onCommit(next);
  }

  const allShapes = draft ? [...shapes, draft] : shapes;

  return (
    <div ref={containerRef} className="editor-stage-wrap">
      {!image && (
        <div className="editor-empty">
          <div className="editor-empty-inner">
            <p className="mono editor-empty-title">No image</p>
            <p className="editor-empty-hint">
              Drop an image, or press ⇧⌘4 to capture
            </p>
          </div>
        </div>
      )}

      {image && (
        <Stage
          ref={stageRef}
          width={stageW}
          height={stageH}
          scaleX={scale}
          scaleY={scale}
          className="editor-stage"
          style={{ cursor: tool === "select" ? "default" : "crosshair" }}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
        >
          <Layer listening={false}>
            <KonvaImage image={image} width={image.width} height={image.height} />
          </Layer>

          <Layer>
            {allShapes.map((s) => (
              <ShapeNode
                key={s.id}
                shape={s}
                image={image}
                draggable={tool === "select"}
                onSelect={() => tool === "select" && onSelect(s.id)}
                registerRef={(node) => {
                  if (node) shapeRefs.current.set(s.id, node);
                  else shapeRefs.current.delete(s.id);
                }}
                onDragEnd={(node) => applyNodeChange(s.id, node)}
                onTransformEnd={(node) => applyNodeChange(s.id, node)}
              />
            ))}

            {/* crop preview */}
            {cropBox && (
              <Rect
                x={cropBox.x}
                y={cropBox.y}
                width={cropBox.width}
                height={cropBox.height}
                stroke="#FF7847"
                strokeWidth={1.5 / scale}
                dash={[6 / scale, 4 / scale]}
                fill="rgba(255,120,71,0.08)"
              />
            )}

            <Transformer
              ref={trRef}
              rotateEnabled
              anchorSize={8}
              anchorStroke="#57B6FF"
              anchorFill="#07080a"
              borderStroke="#57B6FF"
              borderDash={[4, 3]}
              boundBoxFunc={(oldBox, newBox) =>
                newBox.width < 5 || newBox.height < 5 ? oldBox : newBox
              }
            />
          </Layer>
        </Stage>
      )}

      {/* text editing overlay */}
      {editingText && image && (
        <textarea
          className="editor-text-input"
          autoFocus
          value={editingText.value}
          style={{
            left: editingText.x * scale,
            top: editingText.y * scale,
            fontSize: editingText.fontSize * scale,
            color: editingText.color,
          }}
          onChange={(e) =>
            setEditingText({ ...editingText, value: e.target.value })
          }
          onBlur={commitText}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              commitText();
            }
            if (e.key === "Escape") setEditingText(null);
          }}
        />
      )}
    </div>
  );
});

// Renders a single shape based on its type.
function ShapeNode({
  shape: s,
  image,
  draggable,
  onSelect,
  registerRef,
  onDragEnd,
  onTransformEnd,
}: {
  shape: Shape;
  image: HTMLImageElement;
  draggable: boolean;
  onSelect: () => void;
  registerRef: (node: Konva.Node | null) => void;
  onDragEnd: (node: Konva.Node) => void;
  onTransformEnd: (node: Konva.Node) => void;
}) {
  const blurRef = useRef<Konva.Image>(null);

  // Region pixelate: takes the matching slice of the base image, filters + caches it.
  // Skip while dimensions are still 0 (during the initial draft drag) — Konva
  // can't cache a zero-size node.
  useEffect(() => {
    if (s.type !== "blur") return;
    const node = blurRef.current;
    if (!node || !(s.width ?? 0) || !(s.height ?? 0)) return;
    node.cache();
    node.getLayer()?.batchDraw();
  }, [s.type, s.x, s.y, s.width, s.height]);

  const common = {
    ref: (n: Konva.Node | null) => registerRef(n),
    draggable,
    onClick: onSelect,
    onTap: onSelect,
    rotation: s.rotation ?? 0,
    onDragEnd: (e: Konva.KonvaEventObject<DragEvent>) => onDragEnd(e.target),
    onTransformEnd: (e: Konva.KonvaEventObject<Event>) =>
      onTransformEnd(e.target),
  };

  switch (s.type) {
    case "rect":
      return (
        <Rect
          {...common}
          x={s.x}
          y={s.y}
          width={s.width}
          height={s.height}
          stroke={s.color}
          strokeWidth={s.strokeWidth}
          cornerRadius={4}
        />
      );
    case "ellipse":
      return (
        <Ellipse
          {...common}
          x={s.x + (s.width ?? 0) / 2}
          y={s.y + (s.height ?? 0) / 2}
          radiusX={(s.width ?? 0) / 2}
          radiusY={(s.height ?? 0) / 2}
          stroke={s.color}
          strokeWidth={s.strokeWidth}
        />
      );
    case "arrow":
      return (
        <Arrow
          {...common}
          x={s.x}
          y={s.y}
          points={s.points ?? [0, 0, 0, 0]}
          stroke={s.color}
          fill={s.color}
          strokeWidth={s.strokeWidth}
          pointerLength={Math.max(8, s.strokeWidth * 2.5)}
          pointerWidth={Math.max(8, s.strokeWidth * 2.5)}
        />
      );
    case "line":
      return (
        <Line
          {...common}
          x={s.x}
          y={s.y}
          points={s.points ?? [0, 0, 0, 0]}
          stroke={s.color}
          strokeWidth={s.strokeWidth}
          lineCap="round"
        />
      );
    case "text":
      return (
        <KonvaText
          {...common}
          x={s.x}
          y={s.y}
          text={s.text}
          fontSize={s.fontSize}
          fill={s.color}
          fontFamily="Inter, sans-serif"
          fontStyle="600"
        />
      );
    case "blur":
      return (
        <KonvaImage
          {...common}
          ref={(n: Konva.Image | null) => {
            blurRef.current = n;
            registerRef(n);
          }}
          image={image}
          x={s.x}
          y={s.y}
          width={s.width}
          height={s.height}
          crop={{
            x: s.x,
            y: s.y,
            width: s.width ?? 0,
            height: s.height ?? 0,
          }}
          filters={[Konva.Filters.Pixelate]}
          pixelSize={Math.max(6, Math.round((s.width ?? 40) / 12))}
        />
      );
    default:
      return null;
  }
}
