#if canImport(ApplicationServices)
import ApplicationServices
#endif

#if canImport(CoreGraphics)
import CoreGraphics
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
    
    /// Returns true if Input Monitoring permission is granted.
    /// Required for NSEvent.addGlobalMonitorForEvents on macOS Catalina+.
    public static func hasInputMonitoring() -> Bool {
        #if canImport(CoreGraphics)
        return CGPreflightListenEventAccess()
        #else
        return false
        #endif
    }
    
    /// Returns true if both Accessibility and Input Monitoring permissions are granted.
    /// This is what's needed for full hotkey functionality.
    public static func hasFullPermissions() -> Bool {
        return isTrusted() && hasInputMonitoring()
    }

    /// Best-effort: asks the system to show the Accessibility permission prompt.
    public static func requestPrompt() {
        #if canImport(ApplicationServices)
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true]
        _ = AXIsProcessTrustedWithOptions(options)
        #endif
    }
    
    /// Request Input Monitoring permission.
    /// Returns true if granted, false otherwise.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        #if canImport(CoreGraphics)
        return CGRequestListenEventAccess()
        #else
        return false
        #endif
    }
}
