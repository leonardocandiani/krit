import AppKit
import AVFoundation
import ScreenCaptureKit

/// Live state of a single privacy permission. `notDetermined` only applies to the
/// permissions macOS can prompt for on demand (camera, microphone); Screen
/// Recording and Accessibility resolve to a simple granted/denied.
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
}

enum PermissionsManager {

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            Settings.didConfirmScreenRecordingPermission = true
            return true
        }

        Settings.didRequestScreenRecordingPermission = true
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            Settings.didConfirmScreenRecordingPermission = true
        }
        return granted
    }

    static var hasScreenRecordingPermission: Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            Settings.didConfirmScreenRecordingPermission = true
        }
        return granted
    }

    @MainActor
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Screen Recording (status form for the Permissions tab)

    /// Screen Recording has no `notDetermined`: the CG preflight is a plain yes/no.
    static var screenRecordingStatus: PermissionStatus {
        hasScreenRecordingPermission ? .granted : .denied
    }

    // MARK: - Accessibility

    /// True once the user has trusted KRIT for Accessibility (needed for global
    /// gesture/event injection). Like Screen Recording, this is a plain yes/no.
    static var accessibilityStatus: PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    @MainActor
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Camera

    static var cameraStatus: PermissionStatus {
        status(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    @MainActor
    static func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Microphone

    static var microphoneStatus: PermissionStatus {
        status(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    @MainActor
    static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func status(for auth: AVAuthorizationStatus) -> PermissionStatus {
        switch auth {
        case .authorized:    return .granted
        case .notDetermined: return .notDetermined
        default:             return .denied   // .denied, .restricted
        }
    }

    /// Show an alert directing the user to System Settings if permission was denied.
    @MainActor
    static func showPermissionDeniedAlert() {
        if requestScreenRecordingPermission() { return }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        if Settings.didRequestScreenRecordingPermission || Settings.didConfirmScreenRecordingPermission {
            alert.informativeText = "If you already enabled KRIT in System Settings, quit and reopen KRIT so macOS applies the Screen & System Audio Recording permission."
            alert.addButton(withTitle: "Quit KRIT")
        } else {
            alert.informativeText = "KRIT needs Screen Recording permission to capture your screen.\n\nPlease enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
            alert.addButton(withTitle: "Open System Settings")
        }
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if Settings.didRequestScreenRecordingPermission || Settings.didConfirmScreenRecordingPermission {
                NSApp.terminate(nil)
            } else {
                openScreenRecordingSettings()
            }
        }
    }
}
