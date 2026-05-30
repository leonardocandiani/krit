import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys via Carbon (`RegisterEventHotKey`).
///
/// Carbon hotkeys do not require Accessibility permission (unlike a CGEvent tap).
/// The trade-off is the older C API, which is wrapped here.
///
/// Hotkeys:
///   - Cmd+Shift+4 -> region capture
///   - Cmd+Shift+3 -> full-screen capture (display under cursor)
///
/// Esc is NOT registered as a global hotkey (too intrusive); it is handled
/// locally by SelectionView while the overlay is active.
@MainActor
final class HotkeyManager {

    enum Action {
        case region
        case fullScreen
    }

    /// Internal Carbon hotkey IDs.
    private enum HotkeyID: UInt32 {
        case region = 1
        case fullScreen = 2
    }

    private var handlerRef: EventHandlerRef?
    private var registeredRefs: [EventHotKeyRef?] = []
    private let onTrigger: (Action) -> Void

    init(onTrigger: @escaping (Action) -> Void) {
        self.onTrigger = onTrigger
    }

    func register() {
        installHandler()
        registerHotkey(keyCode: UInt32(kVK_ANSI_4),
                       modifiers: UInt32(cmdKey | shiftKey),
                       id: .region)
        registerHotkey(keyCode: UInt32(kVK_ANSI_3),
                       modifiers: UInt32(cmdKey | shiftKey),
                       id: .fullScreen)
    }

    deinit {
        for ref in registeredRefs where ref != nil {
            UnregisterEventHotKey(ref)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    // MARK: - Private

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // `self` is passed as userData to the C callback (which cannot capture Swift context).
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let eventRef, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id

                // Dispatch to main thread (AppKit requirement).
                DispatchQueue.main.async {
                    manager.handle(idRaw: id)
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
    }

    private func registerHotkey(keyCode: UInt32, modifiers: UInt32, id: HotkeyID) {
        let signature = fourCharCode("KRIT")
        let hotKeyID = EventHotKeyID(signature: signature, id: id.rawValue)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            registeredRefs.append(ref)
        } else {
            FileHandle.standardError.write(
                Data("KRIT: failed to register hotkey id=\(id.rawValue) status=\(status)\n".utf8)
            )
        }
    }

    private func handle(idRaw: UInt32) {
        guard let id = HotkeyID(rawValue: idRaw) else { return }
        switch id {
        case .region: onTrigger(.region)
        case .fullScreen: onTrigger(.fullScreen)
        }
    }
}

/// Converts a 4-character string to an OSType (FourCharCode) for use as a hotkey signature.
private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) + FourCharCode(char)
    }
    return result
}
