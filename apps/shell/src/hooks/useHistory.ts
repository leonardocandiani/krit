// Undo/redo history over immutable snapshots of the shapes array.
// Simple, and enough for an annotation's scale (tens of objects).

import { useCallback, useState } from "react";
import type { Shape } from "../lib/types";

interface HistoryState {
  past: Shape[][];
  present: Shape[];
  future: Shape[][];
}

export function useHistory(initial: Shape[] = []) {
  const [state, setState] = useState<HistoryState>({
    past: [],
    present: initial,
    future: [],
  });

  // Replaces the current state, creating a new history point.
  const commit = useCallback((next: Shape[]) => {
    setState((s) => ({
      past: [...s.past, s.present],
      present: next,
      future: [],
    }));
  }, []);

  // Updates present WITHOUT a new history point (e.g. during a drag).
  const setPresent = useCallback((next: Shape[]) => {
    setState((s) => ({ ...s, present: next }));
  }, []);

  const undo = useCallback(() => {
    setState((s) => {
      if (s.past.length === 0) return s;
      const previous = s.past[s.past.length - 1];
      return {
        past: s.past.slice(0, -1),
        present: previous,
        future: [s.present, ...s.future],
      };
    });
  }, []);

  const redo = useCallback(() => {
    setState((s) => {
      if (s.future.length === 0) return s;
      const next = s.future[0];
      return {
        past: [...s.past, s.present],
        present: next,
        future: s.future.slice(1),
      };
    });
  }, []);

  const reset = useCallback((shapes: Shape[]) => {
    setState({ past: [], present: shapes, future: [] });
  }, []);

  return {
    shapes: state.present,
    canUndo: state.past.length > 0,
    canRedo: state.future.length > 0,
    commit,
    setPresent,
    undo,
    redo,
    reset,
  };
}
