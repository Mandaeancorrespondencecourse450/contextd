import Foundation
import AppKit

/// Manages checking and requesting macOS permissions required by ContextD.
/// Required permissions: Screen Recording (ScreenCaptureKit) and Accessibility (AXUIElement).
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = DualLogger(category: "Permissions")

    @Published var screenRecordingGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    var allPermissionsGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    private init() {
        refreshStatus()
    }

    /// Re-check all permission statuses.
    func refreshStatus() {
        screenRecordingGranted = checkScreenRecording()
        accessibilityGranted = checkAccessibility()
        logger.info("Permissions — Screen Recording: \(self.screenRecordingGranted), Accessibility: \(self.accessibilityGranted)")
    }

    // MARK: - Screen Recording

    /// Check if Screen Recording permission is granted (does not prompt).
    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission. Shows the system prompt on first call only.
    /// After denial, user must manually enable in System Settings.
    func requestScreenRecording() {
        let granted = CGRequestScreenCaptureAccess()
        screenRecordingGranted = granted
        if !granted {
            logger.warning("Screen Recording permission not granted. User must enable manually.")
        }
    }

    // MARK: - Accessibility

    /// Check if Accessibility permission is granted (does not prompt).
    func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    /// Request Accessibility permission. Shows the system dialog directing user to System Settings.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(options)
        accessibilityGranted = granted
        if !granted {
            logger.warning("Accessibility permission not granted. User must enable manually.")
        }
    }

    // MARK: - Open System Settings

    /// Open System Settings to the Screen Recording privacy pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings to the Accessibility privacy pane.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
