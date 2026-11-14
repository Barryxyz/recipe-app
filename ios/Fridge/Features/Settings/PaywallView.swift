import StoreKit
import SwiftUI

/// F0.6: what the subscription includes, both plans (yearly highlighted), Restore purchases,
/// Manage subscription, and the terms. No app name (it isn't final).
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SubscriptionStore.shared
    @State private var selected: String = SubscriptionStore.productIds[1]
    @State private var manage = false
    @State private var trialEligible: [String: Bool] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Color.accentColor)
                        Text("Unlock scanning and recipe ideas").font(.title.bold())
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        feature("camera.viewfinder", "Scan your fridge", "Photograph a shelf and the food is listed for you.")
                        feature("fork.knife", "Recipe ideas", "Recipes from what you have, using what expires first.")
                        feature("chart.bar", "Nutrition for your own recipes", "Estimates for ingredients the food list doesn't know.")
                    }
                    Text("Your pantry, saved recipes, shopping list and reminders stay free.")
                        .font(.footnote).foregroundStyle(.secondary)

                    if let s = store.status, s.active {
                        activeCard(s)
                    } else if !store.loadedProducts {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if store.products.isEmpty {
                        Label("Subscriptions aren't available yet. They'll appear here once the app is on the App Store.",
                              systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach(store.products, id: \.id) { planCard($0) }
                        Button {
                            if let p = store.products.first(where: { $0.id == selected }) { Task { await store.purchase(p) } }
                        } label: {
                            Group { if store.busy { ProgressView() } else { Text(subscribeTitle).font(.headline) } }
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy)
                        Text("Renews automatically until cancelled. Cancel any time in Settings → Apple ID → Subscriptions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Button("Restore purchases") { Task { await store.restore() } }.disabled(store.busy)
                        // App Review: subscription screens link the terms and the privacy policy.
                        HStack(spacing: 16) {
                            Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                            if let privacy = AppConfig.privacyURL { Link("Privacy Policy", destination: privacy) }
                        }
                    }
                    .font(.footnote)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .manageSubscriptionsSheet(isPresented: $manage)
            .task {
                await store.loadProducts()
                await store.refreshStatus()
                for p in store.products {
                    trialEligible[p.id] = await p.subscription?.isEligibleForIntroOffer ?? false
                }
            }
        }
    }

    private var subscribeTitle: String {
        guard let p = store.products.first(where: { $0.id == selected }) else { return "Subscribe" }
        return trialText(p) != nil ? "Start free trial" : "Subscribe"
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func planCard(_ p: Product) -> some View {
        let isYearly = p.subscription?.subscriptionPeriod.unit == .year
        let on = selected == p.id
        return Button { selected = p.id } label: {
            HStack {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title2)
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isYearly ? "Yearly" : "Monthly").font(.headline)
                        if isYearly, let m = store.monthly,
                           let pct = SubscriptionStore.savingsPercent(monthly: m.price, yearly: p.price) {
                            Text("Save \(pct)%").font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    if let trial = trialText(p) { Text(trial).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(p.displayPrice)\(isYearly ? "/year" : "/month")").font(.headline).monospacedDigit()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    /// "1 week free, then …" when the product has a free trial this Apple ID can still use.
    private func trialText(_ p: Product) -> String? {
        guard trialEligible[p.id] == true, let offer = p.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        let unit: String = switch offer.period.unit {
        case .day: n == 1 ? "day" : "days"
        case .week: n == 1 ? "week" : "weeks"
        case .month: n == 1 ? "month" : "months"
        case .year: n == 1 ? "year" : "years"
        @unknown default: "period"
        }
        return "\(n) \(unit) free, then \(p.displayPrice)"
    }

    private func activeCard(_ s: SubscriptionStore.ServerStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("You're subscribed", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            if let d = s.expires_at {
                Text("Renews or ends on \(d.formatted(date: .long, time: .omitted)).").font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Manage subscription") { manage = true }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}
