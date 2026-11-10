import Foundation
import os
import Supabase

/// F5.2: product events (app.events), sent in batches. Props hold counts and options only:
/// never food names, recipe titles, typed text or photos. Losing an event is fine; events
/// never block or fail the app.
@MainActor
enum Events {
    enum Name: String {
        case scanCompleted = "scan_completed"
        case scanSaved = "scan_saved"
        case manualItemAdded = "manual_item_added"
        case recipesGenerated = "recipes_generated"
        case recipeSaved = "recipe_saved"
        case recipeEdited = "recipe_edited"
        case recipeDeleted = "recipe_deleted"
        case recipeCreated = "recipe_created"
        case cookedThis = "cooked_this"
        case shoppingItemsAdded = "shopping_items_added"
    }

    private struct Row: Encodable {
        let name: String
        let props: [String: AnyJSON]
        let created_at: String
    }

    private static var buffer: [Row] = []
    private static var flushTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.barryxyz.fridge", category: "events")
    private static let batchSize = 10

    static func log(_ name: Name, _ props: [String: AnyJSON] = [:]) {
        #if DEBUG
        logger.debug("event \(name.rawValue, privacy: .public) \(String(describing: props), privacy: .public)")
        print("[event] \(name.rawValue) \(props)")
        #endif
        buffer.append(Row(name: name.rawValue, props: props,
                          created_at: ISO8601DateFormatter().string(from: .now)))
        if buffer.count >= batchSize { flush() } else { scheduleFlush() }
    }

    /// Sends what's buffered (also when the app goes to the background).
    static func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !buffer.isEmpty else { return }
        let rows = buffer
        buffer = []
        Task {
            do {
                try await supabase.schema("app").from("events").insert(rows).execute()
            } catch {
                #if DEBUG
                print("[event] couldn't send \(rows.count) event(s): \(error.localizedDescription)")
                #endif
            }
        }
    }

    private static func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            flush()
        }
    }
}
