import AppKit
import AudioToolbox
import os

/// Central, low-latency sound effects for KRIT. System sounds are registered
/// once and reused for the process lifetime (AudioServices is the lowest-latency
/// path for short UI cues). All playback is gated by the global `playSounds`
/// preference. The capture cue has two styles (Big Sur / Classic) chosen in
/// Preferences; everything else maps one event to one bundled sound.
///
/// Self-contained: it resolves its own resource bundle instead of borrowing
/// another type's probe, so a change elsewhere can never silence the cues. The
/// ID cache is lock-protected and the whole API is `nonisolated`, so any thread
/// (audio callbacks, recording stream queue, main actor) can call `play`.
enum SoundManager {

    enum Effect {
        case capture          // resolves to the user's chosen capture style
        case captureBigSur
        case captureClassic
        case copy
        case save
        case pin
        case toggle
        case ocr
        case recordStart
        case recordPause
        case recordStop
        case error

        var resourceName: String {
            switch self {
            case .capture:        return Settings.captureSoundStyle.resourceName
            case .captureBigSur:  return "capture-bigsur"
            case .captureClassic: return "capture-classic"
            case .copy:           return "copy"
            case .save:           return "save"
            case .pin:            return "pin"
            case .toggle:         return "toggle"
            case .ocr:            return "ocr"
            case .recordStart:    return "record-start"
            case .recordPause:    return "record-pause"
            case .recordStop:     return "record-stop"
            case .error:          return "error"
            }
        }
    }

    private static let log = Logger(subsystem: "com.krit.app", category: "sound")
    private static let lock = NSLock()
    private static var registered: [String: NSSound] = [:]

    /// Plays an effect honoring the global preference. Errors degrade to silence
    /// (or the system beep for `.error`), never to a crash. Safe from any thread.
    ///
    /// NSSound (canal de mídia) em vez de AudioServices: AudioServices toca no
    /// canal de ALERTAS do macOS, então com "Alert volume" baixo nos Ajustes os
    /// cues sumiam mesmo com tudo certo no app.
    static func play(_ effect: Effect) {
        guard Settings.playSounds else { return }
        guard let sound = sound(for: effect.resourceName) else {
            if case .error = effect { NSSound.beep() }
            return
        }
        if sound.isPlaying { sound.stop() }
        sound.play()
    }

    /// Pre-registers the sounds used on the hot path so the first capture has no
    /// disk-load hitch. Call once at launch.
    static func warmUp() {
        _ = sound(for: Effect.captureBigSur.resourceName)
        _ = sound(for: Effect.captureClassic.resourceName)
    }

    /// Probe do harness de teste: caminho resolvido do efeito (nil = não acha).
    static func uiTestResolvedPath(_ effect: Effect) -> String? {
        resourceURL(for: effect.resourceName)?.path
    }

    private static func sound(for name: String) -> NSSound? {
        lock.lock()
        defer { lock.unlock() }

        if let cached = registered[name] { return cached }
        guard let url = resourceURL(for: name) else {
            log.error("sound resource missing: \(name).caf")
            return nil
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            log.error("NSSound init failed for \(name)")
            return nil
        }
        registered[name] = sound
        return sound
    }

    /// Resolves `<name>.caf` from KRIT's resource bundle without leaning on any
    /// other type. Tries the `.app` and `swift build` layouts, then the SPM dev
    /// bundle. Falls back to a direct file URL inside the bundle, because the
    /// processed `Krit_Krit.bundle` is a flat directory (no Info.plist), which can
    /// make `Bundle.url(forResource:)` return nil even though the file is there.
    private static func resourceURL(for name: String) -> URL? {
        for bundleURL in soundBundleURLs {
            // Preferred: let Bundle resolve (honors localization/subdirs).
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: name, withExtension: "caf") {
                return url
            }
            // Flat-layout fallback: the file sits directly in the .bundle dir.
            let direct = bundleURL.appendingPathComponent("\(name).caf")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
        }
        return nil
    }

    /// Candidate locations for `Krit_Krit.bundle`, ordered by likelihood in
    /// production. Resolved once; logs the resolved (or missing) path a single
    /// time so a silenced build is diagnosable from Console.
    private static let soundBundleURLs: [URL] = {
        let bundleName = "Krit_Krit.bundle"
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {            // .app: Contents/Resources/
            urls.append(resources.appendingPathComponent(bundleName))
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent(bundleName)) // swift build: next to binary
        urls.append(Bundle.module.bundleURL)                    // SPM dev: synthesized module bundle

        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let resolved = existing.first {
            log.info("sound bundle resolved at \(resolved.path, privacy: .public)")
        } else {
            log.error("sound bundle not found; checked: \(urls.map(\.path).joined(separator: ", "), privacy: .public)")
        }
        return existing.isEmpty ? urls : existing
    }()
}

/// Capture cue styles offered in Preferences.
enum CaptureSoundStyle: String, CaseIterable {
    case bigSur
    case classic

    var resourceName: String {
        switch self {
        case .bigSur:  return "capture-bigsur"
        case .classic: return "capture-classic"
        }
    }

    var displayName: String {
        switch self {
        case .bigSur:  return "Modern (Big Sur)"
        case .classic: return "Classic"
        }
    }
}
