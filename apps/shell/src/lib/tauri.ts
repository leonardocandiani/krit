// Bridge to the Rust backend + browser fallbacks.
// The editor runs both under `tauri dev` and plain `vite dev` (browser),
// so drag&drop can be tested without the native app.

import { invoke } from "@tauri-apps/api/core";
import { save as saveDialog, open as openDialog } from "@tauri-apps/plugin-dialog";

export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * Triggers a native capture via the Swift helper (one-shot).
 * `mode` is "region" or "screen". The result arrives asynchronously through the
 * `krit://capture-complete` event (see App's listener). No-op in the browser.
 */
export async function startCapture(mode: "region" | "screen"): Promise<void> {
  if (!isTauri()) return;
  await invoke("capture", { mode });
}

/** Returns whether Screen Recording permission is granted (no prompt). */
export async function checkScreenPermission(): Promise<boolean> {
  if (!isTauri()) return true; // browser preview: pretend granted
  try {
    return await invoke<boolean>("check_screen_permission");
  } catch {
    return false;
  }
}

/** Triggers the native Screen Recording permission prompt. Returns granted. */
export async function requestScreenPermission(): Promise<boolean> {
  if (!isTauri()) return true;
  try {
    return await invoke<boolean>("request_screen_permission");
  } catch {
    return false;
  }
}

// Converts a data URL "data:image/png;base64,XXXX" to the raw XXXX.
function stripBase64(dataUrl: string): string {
  const i = dataUrl.indexOf(",");
  return i >= 0 ? dataUrl.slice(i + 1) : dataUrl;
}

/** Reads a PNG from disk as a data URL (via Rust command). */
export async function openImage(
  path: string,
): Promise<{ dataUrl: string; name: string }> {
  const res = await invoke<{ data_url: string; name: string }>("open_image", {
    path,
  });
  return { dataUrl: res.data_url, name: res.name };
}

/**
 * Copies a PNG image (data URL) to the clipboard.
 * On Tauri it uses the native command; in the browser it uses the Clipboard API.
 */
export async function copyImage(pngDataUrl: string): Promise<void> {
  if (isTauri()) {
    await invoke("copy_image_to_clipboard", {
      pngBase64: stripBase64(pngDataUrl),
    });
    return;
  }
  // Browser fallback
  const blob = await (await fetch(pngDataUrl)).blob();
  await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
}

/**
 * Saves a PNG image (data URL). On Tauri it opens the native dialog and writes
 * via the Rust command; in the browser it triggers a download.
 */
export async function saveImage(
  pngDataUrl: string,
  suggestedName = "krit.png",
): Promise<boolean> {
  if (isTauri()) {
    const path = await saveDialog({
      defaultPath: suggestedName,
      filters: [{ name: "PNG", extensions: ["png"] }],
    });
    if (!path) return false;
    await invoke("save_image", { path, pngBase64: stripBase64(pngDataUrl) });
    return true;
  }
  // Browser fallback: download
  const a = document.createElement("a");
  a.href = pngDataUrl;
  a.download = suggestedName;
  a.click();
  return true;
}

/**
 * Opens the file picker and returns the contents as a data URL.
 * On Tauri it uses the native dialog + Rust command; in the browser, <input file>.
 */
export async function pickImage(): Promise<{
  dataUrl: string;
  name: string;
} | null> {
  if (isTauri()) {
    const path = await openDialog({
      multiple: false,
      directory: false,
      filters: [{ name: "Image", extensions: ["png", "jpg", "jpeg", "webp"] }],
    });
    if (!path || typeof path !== "string") return null;
    return openImage(path);
  }
  // Browser fallback
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.onchange = () => {
      const file = input.files?.[0];
      if (!file) return resolve(null);
      const reader = new FileReader();
      reader.onload = () =>
        resolve({ dataUrl: reader.result as string, name: file.name });
      reader.readAsDataURL(file);
    };
    input.click();
  });
}
