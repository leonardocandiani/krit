import AVFoundation
import Foundation

/// Plays the helper's native sound effects (`.caf`) via AVAudioPlayer.
///
/// The shutter (`capture`) is the most latency-sensitive sound, so its player is
/// preloaded and reused. Audio failures never interrupt a capture.
///
/// Respects the same mute flag shared with the shell (`krit.soundMuted` in
/// UserDefaults). In CLI one-shot mode the process is short-lived, but preloading
/// still avoids I/O cost on the first trigger.
@MainActor
final class KritSounds {

    static let shared = KritSounds()

    private var players: [String: AVAudioPlayer] = [:]

    private init() {}

    /// Plays a sound by name (without extension). Looks for the `.caf` in the bundle and in
    /// the Resources directory next to the executable (covers the helper bundle and
    /// the `swift run` case).
    func play(_ name: String) {
        guard !UserDefaults.standard.bool(forKey: "krit.soundMuted") else { return }
        guard let url = soundURL(for: name) else { return }

        let player = players[name] ?? (try? AVAudioPlayer(contentsOf: url))
        guard let player else { return }
        players[name] = player
        player.currentTime = 0
        player.play()
    }

    private func soundURL(for name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "caf") {
            return url
        }
        // Fallback: Resources/sounds next to the binary (helper bundle).
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("../Resources/\(name).caf"),
            exeDir.appendingPathComponent("../Resources/sounds/\(name).caf"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
