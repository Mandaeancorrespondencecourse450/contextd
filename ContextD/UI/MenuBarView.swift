import SwiftUI

/// Menu bar dropdown view with capture status, controls, and navigation.
struct MenuBarView: View {
    @ObservedObject var captureEngine: CaptureEngine
    @ObservedObject var permissionManager: PermissionManager

    var onOpenEnrichment: () -> Void
    var onOpenDebug: () -> Void

    var body: some View {
        // Status
        let statusText = captureEngine.isRunning
            ? "Capturing (\(captureEngine.captureCount))"
            : "Paused"
        Text(statusText)
            .font(.caption)

        if let lastTime = captureEngine.lastCaptureTime {
            Text("Last: \(lastTime.relativeString)")
                .font(.caption)
        }

        if let error = captureEngine.lastError {
            Text("Error: \(error)")
                .font(.caption)
        }

        Divider()

        // Controls
        Button(captureEngine.isRunning ? "Pause Capture" : "Resume Capture") {
            if captureEngine.isRunning {
                captureEngine.stop()
            } else {
                captureEngine.start()
            }
        }

        Button("Enrich Prompt...") {
            onOpenEnrichment()
        }
        .keyboardShortcut(" ", modifiers: [.command, .shift])

        Divider()

        // Permissions warning
        if !permissionManager.allPermissionsGranted {
            Text("Missing permissions")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        // SettingsLink is the correct macOS 14+ way to open the Settings scene
        SettingsLink {
            Text("Settings...")
        }
        .keyboardShortcut(",")

        Button("Database Debug...") {
            onOpenDebug()
        }
        .keyboardShortcut("d", modifiers: [.command, .option])

        Divider()

        Button("Quit ContextD") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
