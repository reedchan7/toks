import SwiftUI

final class SetupState: ObservableObject {
    @Published var installing = false
    @Published var error: String?
}

// First-launch window shown when the collector's launchd agent is not
// registered. One click runs the bundled installer; no terminal needed.
struct SetupView: View {
    @ObservedObject var state: SetupState
    let onInstall: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to Toks")
                .font(.title2.bold())
            Text("Toks lives in your menu bar and shows live TTFT and tok/s for your coding agents.\n\nA one-time install registers a small background collector that reads the session logs those agents already write.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let error = state.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button(state.installing ? "Installing…" : "Install", action: onInstall)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.installing)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
