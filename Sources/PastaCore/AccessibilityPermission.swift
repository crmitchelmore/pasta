#if canImport(ApplicationServices)
import ApplicationServices
#endif

public enum AccessibilityPermission {
    /// Returns true if the current process is trusted for Accessibility features (eg CGEvent posting).
    /// Note: AXIsProcessTrusted() can be cached by the system; changes may not reflect immediately.
    public static func isTrusted() -> Bool {
        #if canImport(ApplicationServices)
        // Use simple AXIsProcessTrusted() - AXIsProcessTrustedWithOptions can have issues
        return AXIsProcessTrusted()
        #else
        false
        #endif
    }

    /// Best-effort: asks the system to show the Accessibility permission prompt.
    public static func requestPrompt() {
        #if canImport(ApplicationServices)
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
    }
}
