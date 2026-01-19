#if canImport(ApplicationServices)
import ApplicationServices
#endif

public enum AccessibilityPermission {
    /// Returns true if the current process is trusted for Accessibility features (eg CGEvent posting).
    public static func isTrusted() -> Bool {
        #if canImport(ApplicationServices)
        AXIsProcessTrusted()
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
