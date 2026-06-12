import AppKit

// MainActor.assumeIsolated is valid at the top-level entry point,
// the OS always launches the main thread first.
MainActor.assumeIsolated {
    let app = NSApplication.shared

    // Dev affordance: render a sample of every annotation element to a PNG and exit.
    // Lets us eyeball rendering quality headlessly, with no screen or TCC permission.
    if let i = CommandLine.arguments.firstIndex(of: "--render-sample"),
       i + 1 < CommandLine.arguments.count {
        app.setActivationPolicy(.accessory)
        SampleRenderer.run(to: CommandLine.arguments[i + 1])
    }
    if let i = CommandLine.arguments.firstIndex(of: "--backgrounds-lab"),
       i + 1 < CommandLine.arguments.count {
        let input = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
        SampleRenderer.backgroundsLab(input: input, to: CommandLine.arguments[i + 1])
    }
    if let i = CommandLine.arguments.firstIndex(of: "--arrow-lab"),
       i + 1 < CommandLine.arguments.count {
        app.setActivationPolicy(.accessory)
        SampleRenderer.arrowLab(to: CommandLine.arguments[i + 1])
    }
    if let i = CommandLine.arguments.firstIndex(of: "--gradient-gallery"),
       i + 1 < CommandLine.arguments.count {
        let input = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
        app.setActivationPolicy(.accessory)
        SampleRenderer.gradientGallery(input: input, to: CommandLine.arguments[i + 1])
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render-gradients"),
       i + 1 < CommandLine.arguments.count {
        app.setActivationPolicy(.accessory)
        SampleRenderer.renderGradients(toDirectory: CommandLine.arguments[i + 1])
    }
    if let i = CommandLine.arguments.firstIndex(of: "--wallpaper-lab"),
       i + 1 < CommandLine.arguments.count {
        let input = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil
        app.setActivationPolicy(.accessory)
        SampleRenderer.wallpaperLab(input: input, to: CommandLine.arguments[i + 1])
    }

    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
