import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Detects which AI engines this Mac can actually run, so features can gate
/// themselves and Preferences can explain what's available. Pure local probing:
/// no network, no secrets, no API key.
///
/// KRIT's AI is two tiers:
///   • On-device (default, free, offline) — Apple's Vision / Translation work
///     everywhere; the Foundation Models on-device LLM needs Apple Intelligence
///     (Apple Silicon, enabled), so it is absent on Intel.
///   • Cloud (opt-in): runs through the user's OWN Claude subscription using
///     the token the user pastes from `claude setup-token` (see AICredentials),
///     sent as Bearer + the oauth beta header and billed to the subscription.
///     No paid per-token API key, ever.
enum AICapability {

    /// True when Apple's on-device language model is usable right now
    /// (Apple Intelligence-capable Mac with the model downloaded). False on
    /// Intel, when Apple Intelligence is off, or below macOS 26.
    static var onDeviceLanguageModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }

    /// The cloud tier is configured when the user has stored a subscription
    /// token (pasted from `claude setup-token`). The token, not a binary, is how
    /// KRIT reaches the user's Claude subscription. See AICredentials.
    static var cloudConfigured: Bool { AICredentials.hasToken }
}
