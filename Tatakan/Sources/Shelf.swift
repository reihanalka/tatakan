import AppKit
import SwiftUI
import Combine

/// State of one shelf window.
final class Shelf: ObservableObject, Identifiable {
    let id = UUID()
    @Published var items: [ShelfItem] = []
    @Published var name: String = ""
    @Published var colorIndex: Int = 0
    @Published var expanded = false
    @Published var selection: Set<UUID> = []
    @Published var isTargeted = false
    @Published var status: String?          // small toast at the bottom ("Copied", "Zipping…")
    @Published var renaming = false

    static let colors: [Color] = [.secondary, .red, .orange, .yellow, .green, .blue, .purple, .pink]
    static let colorNames = ["None", "Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink"]

    var tint: Color? { colorIndex == 0 ? nil : Shelf.colors[colorIndex] }

    var displayTitle: String {
        if !name.isEmpty { return name }
        if items.isEmpty { return "Shelf" }
        let files = items.filter { $0.kind == .file }.count
        if files == items.count { return files == 1 ? "1 File" : "\(files) Files" }
        return items.count == 1 ? "1 Item" : "\(items.count) Items"
    }

    /// Items an action should work on: the selection in list mode, otherwise everything.
    var targets: [ShelfItem] {
        let sel = items.filter { selection.contains($0.id) }
        return (expanded && !sel.isEmpty) ? sel : items
    }

    func add(_ new: [ShelfItem]) {
        var existing = Set(items.compactMap { $0.kind == .file ? $0.url?.standardizedFileURL.path : nil })
        for item in new {
            if item.kind == .file, let p = item.url?.standardizedFileURL.path {
                if existing.contains(p) { continue }
                existing.insert(p)
            }
            items.append(item)
        }
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// Swap processed items for their results, keeping their position on the shelf.
    func replace(_ old: [ShelfItem], with new: [ShelfItem]) {
        guard !new.isEmpty else { return }
        let oldIDs = Set(old.map(\.id))
        let firstIndex = items.firstIndex { oldIDs.contains($0.id) } ?? items.count
        items.removeAll { oldIDs.contains($0.id) }
        items.insert(contentsOf: new, at: min(firstIndex, items.count))
        selection = Set(new.map(\.id))
    }

    func pruneDeadFiles() {
        items.removeAll { !$0.isAlive }
        selection = selection.filter { id in items.contains { $0.id == id } }
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    private var toastWork: DispatchWorkItem?
    func toast(_ text: String, seconds: Double = 1.6) {
        status = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.status = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    // MARK: Persistence for "Recent shelves"
    struct Snapshot: Codable, Identifiable {
        var id = UUID()
        var name: String
        var colorIndex: Int
        var items: [ShelfItem]
        var closedAt: Date
        var title: String
    }

    var snapshot: Snapshot {
        Snapshot(name: name, colorIndex: colorIndex, items: items, closedAt: Date(), title: displayTitle)
    }
}
