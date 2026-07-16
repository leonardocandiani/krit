import Foundation

enum KritResourceBundleLocator {
    static func candidates(named bundleName: String) -> [URL] {
        var urls: [URL] = []
        var seenPaths: Set<String> = []

        func append(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return }
            urls.append(standardized)
        }

        for host in [Bundle.main] + Bundle.allBundles {
            append(host.resourceURL?.appendingPathComponent(bundleName))
            append(host.bundleURL.appendingPathComponent(bundleName))
            append(host.bundleURL.deletingLastPathComponent().appendingPathComponent(bundleName))
        }

        return urls
    }
}
