import KritKit

// MainActor.assumeIsolated is valid at the top-level entry point,
// the OS always launches the main thread first. Everything else lives in
// KritKit (library targets get Xcode previews; executable targets do not).
MainActor.assumeIsolated {
    KritMain.run()
}
