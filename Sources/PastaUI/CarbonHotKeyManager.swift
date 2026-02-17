#if os(macOS)
import Carbon
import Foundation
import os.log

/// Manages a global hotkey using the Carbon `RegisterEventHotKey` API.
/// Fires a callback when the registered key combination is pressed.
@MainActor
public final class CarbonHotKeyManager {
    public var onHotKey: (() -> Void)?

    private let log = Logger(subsystem: "com.pasta.clipboard", category: "CarbonHotKeyManager")
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Unique Carbon hotkey signature for Pasta.
    private let hotKeySignature: UInt32 = 0x5041_5300 // "PAS\0"
    private let hotKeyID: UInt32 = 1

    public init() {}

    public func register(_ hotKey: PastaHotKey) {
        unregister()
        installEventHandler()
        registerHotKey(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - Carbon Event Handler

    private func installEventHandler() {
        guard eventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<CarbonHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handleCarbonEvent(event)
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandler
        )

        if status != noErr {
            log.error("Failed to install Carbon event handler: \(status)")
        }
    }

    private func registerHotKey(keyCode: UInt16, modifiers: PastaHotKey.ModifierSet) {
        let hotKeyIDSpec = EventHotKeyID(signature: hotKeySignature, id: hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers.carbonFlags,
            hotKeyIDSpec,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            log.error("Failed to register hotkey (keyCode=\(keyCode)): \(status)")
        } else {
            log.info("Registered hotkey: keyCode=\(keyCode), modifiers=\(modifiers.rawValue)")
        }
    }

    private nonisolated func handleCarbonEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return OSStatus(eventNotHandledErr) }
        guard hotKeyID.signature == hotKeySignature, hotKeyID.id == self.hotKeyID else {
            return OSStatus(eventNotHandledErr)
        }

        DispatchQueue.main.async { [weak self] in
            self?.onHotKey?()
        }

        return noErr
    }
}

#endif
