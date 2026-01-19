import Foundation

#if canImport(AppKit)
import AppKit
#endif

#if canImport(HotKey)
import HotKey
#endif

#if canImport(AppKit) && canImport(HotKey)
public protocol HotKeyProtocol: AnyObject {
    var keyDownHandler: (() -> Void)? { get set }
}

extension HotKey: HotKeyProtocol {}

public protocol HotKeyProviding {
    func makeHotKey(key: Key, modifiers: NSEvent.ModifierFlags) -> HotKeyProtocol
}

public struct SystemHotKeyProvider: HotKeyProviding {
    public init() {}

    public func makeHotKey(key: Key, modifiers: NSEvent.ModifierFlags) -> HotKeyProtocol {
        HotKey(key: key, modifiers: modifiers)
    }
}

public final class HotkeyManager {
    private let hotKey: HotKeyProtocol

    public init(provider: HotKeyProviding = SystemHotKeyProvider(), onTrigger: @escaping () -> Void) {
        hotKey = provider.makeHotKey(key: .c, modifiers: [.control, .command])
        hotKey.keyDownHandler = onTrigger
    }
}
#else
public final class HotkeyManager {
    public init(onTrigger: @escaping () -> Void) {
        _ = onTrigger
    }
}
#endif
