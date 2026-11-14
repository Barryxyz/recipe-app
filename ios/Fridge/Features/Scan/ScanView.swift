import PhotosUI
import SwiftUI

/// F1.1: pick a place, take or import 1–2 photos, send them to `scan-ingredients`.
/// Photos stay in memory and are released when this screen closes.
struct ScanView: View {
    /// Close the scan and open the manual add sheet instead.
    var onAddManually: () -> Void = {}
    /// Review saved: items added or updated (F1.3).
    var onSaved: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var camera = CameraController()
    @State private var consent = AIConsent.shared

    private enum Phase: Equatable {
        case capturing
        case sending
        case review(ScanReview)
        case failed(ScanAPI.ScanError)
    }

    @State private var placement: Placement = ScanView.lastPlacement
    @State private var photos: [ScanPhoto] = []
    @State private var phase: Phase = .capturing
    @State private var libraryItems: [PhotosPickerItem] = []
    @State private var processing = false
    @State private var sendTask: Task<Void, Never>?
    @State private var usage: ScanAPI.Usage?
    @State private var stapleIds: Set<Int64> = []

    /// Kept low for cost (one phone photo usually covers about 2 shelves). Server enforces it too.
    static let maxPhotos = 2
    private static let placementKey = "scan.lastPlacement"
    private static var lastPlacement: Placement {
        UserDefaults.standard.string(forKey: placementKey).flatMap(Placement.init(rawValue:)) ?? .fridge
    }

    var body: some View {
        NavigationStack {
            Group {
                if !consent.granted {
                    AIConsentView(action: "Scan your fridge", onContinue: {}, onNotNow: { finish() })
                } else {
                switch phase {
                case .capturing: captureScreen
                case .sending: sendingScreen
                case .review(let r):
                    ScanReviewView(review: r,
                                   onSaved: { n in finish(); onSaved(n) },
                                   onDiscard: { finish() },
                                   onRetake: { phase = .capturing },
                                   onAddManually: { addManually() })
                case .failed(let e): failedScreen(e)
                }
                }
            }
            .toolbar {
                if !isReviewing {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { finish() } }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        // F5.3: the camera starts only after the AI consent.
        .task(id: consent.granted) { if consent.granted { await camera.requestAccessAndStart() } }
        .task {
            usage = try? await ScanAPI.usage()
            stapleIds = (try? await PantryAPI.catalogStapleIds()) ?? []
        }
        .onDisappear {
            sendTask?.cancel()
            camera.stop()
            photos = []   // release image data
        }
    }

    private var isReviewing: Bool { if case .review = phase { true } else { false } }

    // MARK: Capture

    private var captureScreen: some View {
        VStack(spacing: 0) {
            Picker("Scanning", selection: $placement) {
                ForEach(Placement.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onChange(of: placement) { _, new in UserDefaults.standard.set(new.rawValue, forKey: Self.placementKey) }

            ZStack {
                switch camera.access {
                case .granted:
                    CameraPreview(session: camera.session)
                case .denied:
                    permissionHelp
                case .unavailable:
                    ContentUnavailableView("No camera", systemImage: "camera",
                                           description: Text("Use Library to pick photos instead."))
                case .unknown:
                    Color.black
                }
                if processing { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)

            thumbnails
            controls
        }
        .navigationTitle(placement == .staples ? "Scan staples" : "Scan your \(placement.title.lowercased())")
        .onChange(of: libraryItems) { _, items in Task { await importLibrary(items) } }
    }

    private var permissionHelp: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is off").font(.headline)
            Text("Fridge uses the camera to photograph your shelves and list the food on them. Photos aren't stored.")
                .multilineTextAlignment(.center).font(.subheadline)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.borderedProminent)
            Button("Add manually instead") { addManually() }
        }
        .foregroundStyle(.white)
        .padding(30)
    }

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    Button { withAnimation { photos.removeAll { $0.id == photo.id } } } label: {
                        Image(uiImage: photo.thumbnail)
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                                    .padding(2)
                            }
                    }
                    .accessibilityLabel("Remove photo")
                }
                if photos.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Up to 2 photos, about 2 shelves each.").font(.footnote).foregroundStyle(.secondary)
                        if let usage {
                            Text(usage.text).font(.caption).foregroundStyle(usage.left <= 2 ? .orange : .secondary)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .frame(height: 72)
        }
    }

    private var controls: some View {
        let full = photos.count >= Self.maxPhotos
        return HStack {
            PhotosPicker(selection: $libraryItems, maxSelectionCount: max(1, Self.maxPhotos - photos.count),
                         matching: .images, photoLibrary: .shared()) {
                Label("Library", systemImage: "photo.on.rectangle")
            }
            .disabled(full)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Button { shoot() } label: {
                    Circle().strokeBorder(.primary, lineWidth: 4)
                        .background(Circle().fill(full ? Color.gray.opacity(0.3) : Color.white).padding(6))
                        .frame(width: 72, height: 72)
                }
                .disabled(full || camera.access != .granted || camera.isCapturing)
                .accessibilityLabel("Take photo")
                if full { Text("Max \(Self.maxPhotos) photos").font(.caption2).foregroundStyle(.secondary) }
            }

            Button { send() } label: {
                Text("Scan (\(photos.count))").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(photos.isEmpty || processing || (usage?.left ?? 1) <= 0)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding()
    }

    // MARK: Sending, failure

    private var sendingScreen: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Looking for ingredients…").font(.headline)
            Text("This usually takes 8–20 seconds.").foregroundStyle(.secondary)
            Button("Cancel", role: .cancel) {
                sendTask?.cancel()
                sendTask = nil
                phase = .capturing
            }
            .padding(.top)
        }
        .navigationTitle("Scanning")
    }

    private func failedScreen(_ error: ScanAPI.ScanError) -> some View {
        ContentUnavailableView {
            Label(error.errorDescription ?? "Something went wrong",
                  systemImage: error == .offline ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            switch error {
            case .offline: Text("You can add items by hand instead.")
            case .aiDisabled: Text("AI features are temporarily unavailable. You can add items by hand.")
            case .limitReached(let message): Text(message)
            case .subscriptionRequired: Text("Subscribe to scan your shelves. You can still add items by hand.")
            case .failed: Text("Your photos are still here. Try again, or add items by hand.")
            }
        } actions: {
            if error == .subscriptionRequired {
                Button("See plans") { SubscriptionStore.shared.showPaywall = true }.buttonStyle(.borderedProminent)
            }
            if case .failed = error {
                Button("Retry") { send() }.buttonStyle(.borderedProminent)
            } else if error == .offline {
                Button("Retry") { send() }.buttonStyle(.borderedProminent)
            }
            Button("Add manually") { addManually() }
            Button("Back to photos") { phase = .capturing }
        }
    }

    // MARK: Actions

    private func shoot() {
        camera.capture { data in Task { await add([data]) } }
    }

    private func importLibrary(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var datas: [Data] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) { datas.append(data) }
        }
        libraryItems = []
        await add(datas)
    }

    /// Processes off the main thread; keeps at most 4.
    private func add(_ datas: [Data]) async {
        processing = true
        defer { processing = false }
        for data in datas where photos.count < Self.maxPhotos {
            let processed = await Task.detached(priority: .userInitiated) { try? ScanImageProcessor.process(data) }.value
            if let processed { withAnimation { photos.append(processed) } }
        }
    }

    private func send() {
        let toSend = photos
        let where_ = placement
        phase = .sending
        sendTask = Task {
            do {
                let response = try await ScanAPI.scan(placement: where_, photos: toSend)
                guard !Task.isCancelled else { return }   // cancelled: no further UI changes
                usage = response.usage ?? usage
                Events.log(.scanCompleted, ["location": .string(where_.rawValue), "photos": .integer(toSend.count),
                                            "items_detected": .integer(response.items.count)])
                photos = []                                // photos are no longer needed: release them
                phase = .review(ScanReview(scan: response, placement: where_, stapleIds: stapleIds))
            } catch is CancellationError {
                return
            } catch let error as ScanAPI.ScanError {
                guard !Task.isCancelled else { return }
                phase = .failed(error)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(.failed(error.localizedDescription))
            }
        }
    }

    private func addManually() {
        finish()
        onAddManually()
    }

    private func finish() {
        sendTask?.cancel()
        photos = []
        dismiss()
    }
}
