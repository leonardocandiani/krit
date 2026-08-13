import AppKit

/// One logical dragging item with a stable file-promise representation.
/// `NSFilePromiseProvider.delegate` is weak, so `userInfo` owns the delegate until
/// AppKit finishes the promise handshake. Fully materialized files use `NSURL`
/// directly so a destination never has to choose between competing transports.
final class RetainedFilePromiseProvider: NSFilePromiseProvider {
    static func make(
        fileType: String,
        delegate: NSFilePromiseProviderDelegate
    ) -> RetainedFilePromiseProvider {
        return RetainedFilePromiseProvider(
            fileType: fileType,
            delegate: delegate
        )
    }

    private init(
        fileType: String,
        delegate: NSFilePromiseProviderDelegate
    ) {
        super.init()
        self.fileType = fileType
        self.delegate = delegate
        userInfo = delegate
    }
}
