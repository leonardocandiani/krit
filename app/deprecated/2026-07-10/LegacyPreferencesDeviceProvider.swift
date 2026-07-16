// Deprecated on 2026-07-10.
// Reason: synchronous AVFoundation discovery ran from RecordingForm.body and
// could repeat on every SwiftUI state update. PreferencesDeviceModel now loads
// immutable device options off the main actor and refreshes on hardware changes.

import AVFoundation

@MainActor
enum PreferencesDeviceProvider {
    static var microphones: [(String, String)] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .externalUnknown]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        return devices(deviceTypes, mediaType: .audio)
    }

    static var cameras: [(String, String)] {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .externalUnknown]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInWideAngleCamera, .external, .continuityCamera]
        }
        return devices(deviceTypes, mediaType: .video)
    }

    private static func devices(
        _ types: [AVCaptureDevice.DeviceType],
        mediaType: AVMediaType
    ) -> [(String, String)] {
        var options: [(String, String)] = [("System Default", "")]
        options += AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: mediaType,
            position: .unspecified
        )
        .devices
        .sorted {
            $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending
        }
        .map { ($0.localizedName, $0.uniqueID) }
        return options
    }
}
