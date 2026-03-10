import Foundation
import Carbon
import AppKit

/// Manages global keyboard shortcuts using the Carbon RegisterEventHotKey API.
/// This is the most reliable approach for global hotkeys on macOS, used by
/// major apps like Raycast and Alfred.
final class HotkeyManager {
    private let logger = DualLogger(category: "Hotkey")

    /// Callback invoked when the global hotkey is pressed.
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// The hotkey signature identifier (ASCII for "CTXD").
    private let signature: OSType = 0x43_54_58_44

    /// Shared instance (Carbon callbacks need a stable reference).
    static let shared = HotkeyManager()

    private init() {}

    deinit {
        unregister()
    }

    /// Register a global hotkey.
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., 49 for Space).
    ///   - modifiers: Carbon modifier flags (e.g., cmdKey | shiftKey).
    func register(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(cmdKey | shiftKey)) {
        unregister() // Remove any previous registration

        // Install the event handler for hot key events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandler
        )

        guard status == noErr else {
            logger.error("Failed to install event handler: \(status)")
            return
        }

        // Register the hotkey
        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            logger.info("Global hotkey registered (keyCode: \(keyCode), modifiers: \(modifiers))")
        } else {
            logger.error("Failed to register hotkey: \(registerStatus)")
        }
    }

    /// Unregister the current global hotkey.
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    /// Called by the Carbon event handler when the hotkey is pressed.
    fileprivate func handleHotKeyEvent() {
        logger.debug("Hotkey pressed")
        DispatchQueue.main.async { [weak self] in
            self?.onHotkey?()
        }
    }
}

/// Carbon event handler callback (C function pointer).
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handleHotKeyEvent()
    return noErr
}
