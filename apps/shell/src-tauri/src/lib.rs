// KRIT shell. Image commands + menu bar tray.
// Native capture (freeze, overlay, crop) lives in the Swift helper; this side
// holds the IPC hooks (TODO) and the Konva annotation editor in the frontend.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::Serialize;
use std::path::PathBuf;
use std::process::Command;
use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    path::BaseDirectory,
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};
use tauri_plugin_clipboard_manager::ClipboardExt;

/// Result of reading an image from disk.
/// Returns base64 PNG to avoid passing raw bytes across the webview IPC.
#[derive(Serialize)]
struct LoadedImage {
    /// data URL ready for <img>/Konva: "data:image/png;base64,...."
    data_url: String,
    name: String,
}

/// Reads an image file from disk and returns it as a data URL.
/// Used by the editor to open a PNG (via dialog or a path from the helper).
#[tauri::command]
fn open_image(path: String) -> Result<LoadedImage, String> {
    let bytes = std::fs::read(&path).map_err(|e| format!("failed to read {path}: {e}"))?;

    // Detect mime by extension; default to png.
    let mime = match std::path::Path::new(&path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/png",
    };

    let name = std::path::Path::new(&path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("image")
        .to_string();

    let data_url = format!("data:{mime};base64,{}", STANDARD.encode(&bytes));
    Ok(LoadedImage { data_url, name })
}

/// Writes PNG bytes (from the canvas as base64) to a file.
/// The path usually comes from the save dialog on the frontend.
#[tauri::command]
fn save_image(path: String, png_base64: String) -> Result<(), String> {
    let bytes = STANDARD
        .decode(png_base64.as_bytes())
        .map_err(|e| format!("invalid base64: {e}"))?;
    std::fs::write(&path, bytes).map_err(|e| format!("failed to save {path}: {e}"))?;
    Ok(())
}

/// Copies a PNG image (base64) to the clipboard as a native image.
/// Decodes the PNG to RGBA because the clipboard expects raw pixels.
#[tauri::command]
fn copy_image_to_clipboard(app: AppHandle, png_base64: String) -> Result<(), String> {
    let bytes = STANDARD
        .decode(png_base64.as_bytes())
        .map_err(|e| format!("invalid base64: {e}"))?;

    let decoded = image::load_from_memory(&bytes)
        .map_err(|e| format!("invalid PNG: {e}"))?
        .to_rgba8();
    let (w, h) = decoded.dimensions();

    let img = Image::new_owned(decoded.into_raw(), w, h);
    app.clipboard()
        .write_image(&img)
        .map_err(|e| format!("clipboard write failed: {e}"))?;
    Ok(())
}

/// Locates the bundled "KRIT Helper.app" executable.
///
/// In a packaged build the helper lives in the app's Resources folder. In
/// development (`tauri dev`) it is resolved relative to the repo so the tray
/// capture flow can be exercised without packaging first.
fn helper_binary(app: &AppHandle) -> Option<PathBuf> {
    let inside_app = "KRIT Helper.app/Contents/MacOS/krit-helper";

    // 1. Bundled resource (production).
    if let Ok(p) = app.path().resolve(inside_app, BaseDirectory::Resource) {
        if p.exists() {
            return Some(p);
        }
    }

    // 2. Dev fallback: built bundle in the helper package.
    //    src-tauri/../../helper/dist/KRIT Helper.app/...
    if let Ok(exe) = std::env::current_exe() {
        // Walk up looking for the `apps` directory, then into helper/dist.
        let mut dir = exe.as_path();
        while let Some(parent) = dir.parent() {
            let candidate = parent
                .join("apps")
                .join("helper")
                .join("dist")
                .join(inside_app);
            if candidate.exists() {
                return Some(candidate);
            }
            dir = parent;
        }
    }

    // 3. Last resort: absolute repo path used during development.
    let repo = PathBuf::from(format!(
        "{}/../../helper/dist/{}",
        env!("CARGO_MANIFEST_DIR"),
        inside_app
    ));
    if repo.exists() {
        return Some(repo);
    }

    None
}

/// Runs the native helper in one-shot mode and loads the result into the editor.
///
/// `mode` is "region" or "screen". The helper shows the overlay, captures once,
/// prints the PNG path to stdout and exits 0; a non-zero exit means cancelled.
/// On success we emit `krit://capture-complete` with the path so the frontend
/// can open it; otherwise `krit://capture-cancelled`.
#[tauri::command]
fn capture(app: AppHandle, mode: String) -> Result<(), String> {
    let helper = helper_binary(&app)
        .ok_or_else(|| "KRIT Helper not found (build it with apps/helper/scripts/make-app.sh)".to_string())?;

    let arg = match mode.as_str() {
        "region" => "capture-region",
        "screen" => "capture-screen",
        other => return Err(format!("unknown capture mode: {other}")),
    };

    // Run off the main thread so the overlay/selection doesn't block the UI.
    std::thread::spawn(move || {
        let output = Command::new(&helper).arg(arg).output();
        match output {
            Ok(out) if out.status.success() => {
                let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if path.is_empty() {
                    let _ = app.emit("krit://capture-cancelled", "empty path");
                } else {
                    focus_editor(&app);
                    let _ = app.emit("krit://capture-complete", path);
                }
            }
            Ok(_) => {
                // Non-zero exit: cancelled (Esc) or denied permission.
                let _ = app.emit("krit://capture-cancelled", "cancelled");
            }
            Err(e) => {
                let _ = app.emit("krit://capture-error", e.to_string());
            }
        }
    });

    Ok(())
}

/// Checks whether Screen Recording permission is granted (no prompt).
/// Delegates to the helper's `check-permission` (CGPreflightScreenCaptureAccess),
/// so the answer reflects the binary that actually captures. Used for onboarding
/// polling. Returns true when granted.
#[tauri::command]
fn check_screen_permission(app: AppHandle) -> Result<bool, String> {
    let helper =
        helper_binary(&app).ok_or_else(|| "KRIT Helper not found".to_string())?;
    let out = Command::new(&helper)
        .arg("check-permission")
        .output()
        .map_err(|e| e.to_string())?;
    Ok(out.status.success())
}

/// Triggers the native Screen Recording permission prompt.
/// Delegates to the helper's `request-permission` (CGRequestScreenCaptureAccess),
/// which shows the system dialog on first run. Returns true when granted.
#[tauri::command]
fn request_screen_permission(app: AppHandle) -> Result<bool, String> {
    let helper =
        helper_binary(&app).ok_or_else(|| "KRIT Helper not found".to_string())?;
    let out = Command::new(&helper)
        .arg("request-permission")
        .output()
        .map_err(|e| e.to_string())?;
    Ok(out.status.success())
}

/// Shows and focuses the editor window. Reused by the tray and helper IPC.
fn focus_editor(app: &AppHandle) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.set_focus();
        let _ = win.unminimize();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            open_image,
            save_image,
            copy_image_to_clipboard,
            capture,
            check_screen_permission,
            request_screen_permission
        ])
        .setup(|app| {
            build_tray(app.handle())?;
            // Warm the permission check on startup so the helper is registered
            // with TCC early — the first capture shouldn't be the first time
            // macOS sees the process. Runs off-thread so setup never blocks.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                if let Some(helper) = helper_binary(&handle) {
                    let _ = Command::new(&helper).arg("check-permission").output();
                }
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running KRIT");
}

/// Builds the menu bar tray with the KRIT symbol and the action menu.
fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let capture_region =
        MenuItem::with_id(app, "capture_region", "Snap region", true, Some("Shift+Cmd+4"))?;
    let capture_screen =
        MenuItem::with_id(app, "capture_screen", "Snap screen", true, Some("Shift+Cmd+3"))?;
    let open_editor = MenuItem::with_id(app, "open_editor", "Open editor", true, None::<&str>)?;
    let prefs = MenuItem::with_id(app, "preferences", "Preferences", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit KRIT", true, Some("Cmd+Q"))?;

    let menu = Menu::with_items(
        app,
        &[
            &capture_region,
            &capture_screen,
            &sep1,
            &open_editor,
            &prefs,
            &sep2,
            &quit,
        ],
    )?;

    // Template icon (white with alpha). macOS recolors it to match the menu bar.
    let icon = Image::from_bytes(include_bytes!("../icons/tray.png"))?;

    TrayIconBuilder::with_id("krit-tray")
        .icon(icon)
        .icon_as_template(true)
        .tooltip("KRIT")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "capture_region" => {
                if let Err(e) = capture(app.clone(), "region".into()) {
                    eprintln!("[krit] capture region failed: {e}");
                }
            }
            "capture_screen" => {
                if let Err(e) = capture(app.clone(), "screen".into()) {
                    eprintln!("[krit] capture screen failed: {e}");
                }
            }
            "open_editor" => focus_editor(app),
            "preferences" => {
                // TODO: open a preferences window/route.
                let _ = app.emit("krit://open-preferences", ());
                focus_editor(app);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;

    Ok(())
}
