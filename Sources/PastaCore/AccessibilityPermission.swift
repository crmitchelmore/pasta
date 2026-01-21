#if canImport(ApplicationServices)
import ApplicationServices
#endif

public enum AccessibilityPermission {
    /// Returns true if the current process is trusted for Accessibility features (eg CGEvent posting).
    /// Note: AXIsProcessTrusted() can be cached by the system; changes may not reflect immediately.
    public static func isTrusted() -> Bool {
        #if canImport(ApplicationServices)
        // Use AXIsProcessTrustedWithOptions without prompt to force a fresh check
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #else
        false
        #endif
    }

    /// Best-effort: asks the system to show the Accessibility permission prompt.
    public static func requestPrompt() {
        #if canImport(ApplicationServices)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
    }
}
