import Observation
import SwiftUI

/// F5.3: permission to send data to the third-party AI (App Review guideline 5.1.2). Asked
/// once, before the first scan or the first recipe ideas, and can be withdrawn in Settings.
/// Without it, scans and recipe ideas don't start and nutrition for unknown ingredients isn't
/// estimated (`recompute-macros` gets `estimate: false`).
@MainActor @Observable
final class AIConsent {
    static let shared = AIConsent()
    private static let key = "aiConsentGranted"

    var granted: Bool {
        didSet { UserDefaults.standard.set(granted, forKey: Self.key) }
    }

    private init() { granted = UserDefaults.standard.bool(forKey: Self.key) }
}

/// Shown in place of the camera or the recipe ideas until the user agrees.
struct AIConsentView: View {
    /// "Scan your fridge" / "Get recipe ideas": what the user was about to do.
    let action: String
    var onContinue: () -> Void
    var onNotNow: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.accentColor)
                Text("Before you \(action.lowercased())").font(.title2.bold())
                Text("This uses AI from **Anthropic**, a third-party service. To work, the app sends it:")
                VStack(alignment: .leading, spacing: 12) {
                    row("camera", "Photos you scan", "to identify the food. Photos aren't stored.")
                    row("list.bullet", "Your pantry list and food preferences, including allergies",
                        "to suggest recipes.")
                    row("fork.knife", "Names of ingredients in your own recipes", "to estimate nutrition when the food list doesn't know them.")
                }
                Text("Nothing that identifies you is sent. Anthropic doesn't use this data to train its AI.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let url = AppConfig.privacyURL {
                    Link("Privacy policy", destination: url).font(.footnote)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { AIConsent.shared.granted = true; onContinue() } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button("Not now", action: onNotNow).controlSize(.large)
                Text("You can change this in Settings.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .background(.bar)
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
