import Foundation
import Combine

/// Built-in layouts (regenerated on launch, so app updates improve them) + user layouts (persisted).
/// A built-in layout can be edited in place: the edited version is kept as an override until reset.
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    @Published private(set) var custom: [KBLayout] = []
    @Published private(set) var overrides: [String: KBLayout] = [:]
    @Published var currentId: String {
        didSet { UserDefaults.standard.set(currentId, forKey: "currentLayout") }
    }

    /// Factory versions of the built-in layouts.
    private let defaults: [KBLayout] = BuiltinLayouts.all

    /// Built-in layouts as the user sees them (with their edits).
    var builtins: [KBLayout] { defaults.map { overrides[$0.id] ?? $0 } }

    func isModified(_ id: String) -> Bool { overrides[id] != nil }

    /// Back to the factory version of a built-in layout.
    func resetBuiltin(_ id: String) {
        guard overrides[id] != nil else { return }
        overrides[id] = nil
        save()
    }

    private static let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let fileURL = LayoutStore.dir.appendingPathComponent("layouts.json")
    private let overridesURL = LayoutStore.dir.appendingPathComponent("builtin-overrides.json")

    private init() {
        currentId = UserDefaults.standard.string(forKey: "currentLayout") ?? "builtin.laptop"
        load()
        if layout(id: currentId) == nil { currentId = "builtin.laptop" }
    }

    var all: [KBLayout] { builtins + custom }

    var current: KBLayout { layout(id: currentId) ?? builtins[0] }

    func layout(id: String) -> KBLayout? { all.first { $0.id == id } }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([KBLayout].self, from: data) {
            custom = list
        }
        if let data = try? Data(contentsOf: overridesURL),
           let dict = try? JSONDecoder().decode([String: KBLayout].self, from: data) {
            overrides = dict.filter { id, _ in defaults.contains { $0.id == id } }
        }
    }

    private static func write(_ custom: [KBLayout], _ overrides: [String: KBLayout], _ url: URL, _ overridesURL: URL) {
        do {
            try JSONEncoder().encode(custom).write(to: url, options: .atomic)
            try JSONEncoder().encode(overrides).write(to: overridesURL, options: .atomic)
        } catch {
            NSLog("LocalKeys: failed to save layouts: \(error)")
        }
    }

    private let saveQueue = DispatchQueue(label: "localkeys.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    /// Encoding + writing happens off the main thread and is coalesced: dragging a key or a
    /// slider in the editor changes the layout many times a second.
    private func save() {
        pendingSave?.cancel()
        let snapshot = custom, ov = overrides
        let url = fileURL, ovURL = overridesURL
        let work = DispatchWorkItem { Self.write(snapshot, ov, url, ovURL) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write any pending change now (the app is going to the background).
    func flush() {
        guard let work = pendingSave, !work.isCancelled else { return }
        pendingSave = nil
        work.cancel()
        let snapshot = custom, ov = overrides
        let url = fileURL, ovURL = overridesURL
        saveQueue.sync { Self.write(snapshot, ov, url, ovURL) }
    }

    /// Creates an editable copy and makes it current.
    @discardableResult
    func duplicate(_ l: KBLayout, name: String? = nil) -> KBLayout {
        var copy = l
        copy.id = "user." + UUID().uuidString
        copy.name = name ?? (l.name + " (моя)")
        copy.builtIn = false
        copy.keys = l.keys.map { var k = $0; k.id = UUID(); return k }
        custom.append(copy)
        save()
        currentId = copy.id
        return copy
    }

    func createEmpty() -> KBLayout {
        let l = KBLayout(id: "user." + UUID().uuidString, name: "Новая раскладка", icon: "square.grid.3x3",
                         cols: 12, rows: 5, keys: [], glide: false, builtIn: false)
        custom.append(l)
        save()
        currentId = l.id
        return l
    }

    func update(_ l: KBLayout) {
        if l.builtIn {
            guard defaults.contains(where: { $0.id == l.id }), overrides[l.id] != l else { return }
            overrides[l.id] = l
            save()
            return
        }
        guard let i = custom.firstIndex(where: { $0.id == l.id }) else { return }
        if custom[i] != l {
            custom[i] = l
            save()
        }
    }

    func delete(id: String) {
        custom.removeAll { $0.id == id }
        save()
        if currentId == id { currentId = "builtin.laptop" }
    }

    func moveCustom(from: IndexSet, to: Int) {
        custom.move(fromOffsets: from, toOffset: to)
        save()
    }

    func next() {
        let list = all
        guard let i = list.firstIndex(where: { $0.id == currentId }) else { return }
        currentId = list[(i + 1) % list.count].id
    }

    func exportJSON(_ l: KBLayout) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(l) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func importJSON(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              var l = try? JSONDecoder().decode(KBLayout.self, from: data) else { return false }
        l.id = "user." + UUID().uuidString
        l.builtIn = false
        custom.append(l)
        save()
        currentId = l.id
        return true
    }
}
