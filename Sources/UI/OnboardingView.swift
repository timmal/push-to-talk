import SwiftUI

struct OnboardingView: View {
    @State private var perms = PermissionsManager.shared.current()
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HoldSpeak needs a few permissions")
                .font(.title2).bold()
            row("Microphone", ok: perms.microphone) {
                Task {
                    _ = await PermissionsManager.shared.requestMicrophone()
                    refresh()
                }
            }
            row("Accessibility (global hotkey and text insertion)", ok: perms.accessibility) {
                PermissionsManager.shared.openAccessibilitySettings()
            }
            row("Input Monitoring", ok: perms.inputMonitoring) {
                PermissionsManager.shared.openInputMonitoringSettings()
            }
            row("Documents folder (reuse existing WhisperKit models)",
                ok: perms.documentsAccess,
                optional: true) {
                if PermissionsManager.shared.requestDocumentsAccess() {
                    refresh()
                } else {
                    PermissionsManager.shared.openDocumentsSettings()
                }
            }
            Text("The Documents permission is optional — without it, HoldSpeak still works and just downloads models into its own folder on first use.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Button("Re-check") { refresh() }
                Spacer()
                Button("Done") { onDone() }
                    .disabled(!perms.allGranted)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }

    private func row(_ title: String, ok: Bool, optional: Bool = false, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? .green : .secondary)
            Text(title)
            if optional {
                Text("Optional")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Button("Open…", action: action)
                .opacity(ok ? 0 : 1)
                .disabled(ok)
        }
        .frame(height: 28)
    }

    private func refresh() {
        perms = PermissionsManager.shared.current()
    }
}
