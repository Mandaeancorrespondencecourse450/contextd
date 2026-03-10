import SwiftUI

/// First-run onboarding view that guides users through granting
/// Screen Recording and Accessibility permissions.
struct OnboardingView: View {
    @ObservedObject var permissionManager: PermissionManager
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("Welcome to ContextD")
                    .font(.title.bold())

                Text("ContextD needs a few permissions to capture your screen activity and enrich your AI prompts with context.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Divider()

            // Permissions
            VStack(spacing: 16) {
                PermissionRow(
                    icon: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    description: "Capture screenshots to extract text from your screen.",
                    isGranted: permissionManager.screenRecordingGranted,
                    onRequest: { permissionManager.requestScreenRecording() },
                    onOpenSettings: { permissionManager.openScreenRecordingSettings() }
                )

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Read focused window titles and app information.",
                    isGranted: permissionManager.accessibilityGranted,
                    onRequest: { permissionManager.requestAccessibility() },
                    onOpenSettings: { permissionManager.openAccessibilitySettings() }
                )
            }

            Divider()

            // Actions
            HStack(spacing: 12) {
                Button("Refresh Status") {
                    permissionManager.refreshStatus()
                }
                .buttonStyle(.bordered)

                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!permissionManager.allPermissionsGranted)
            }

            if !permissionManager.allPermissionsGranted {
                Text("Grant both permissions above to continue. You may need to restart the app after granting permissions.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(width: 520)
    }
}

/// A single permission row showing status and action buttons.
private struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline)

                    Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(isGranted ? .green : .red)
                        .font(.caption)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isGranted {
                Button("Grant") { onRequest() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Settings") { onOpenSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 8)
    }
}
