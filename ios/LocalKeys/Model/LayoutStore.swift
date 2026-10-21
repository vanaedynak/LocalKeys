import Foundation
import Combine

/// Built-in layouts (regenerated on launch, so app updates improve them) + user layouts (persisted).
final class LayoutStore: ObservableObject {
    static let shared = LayoutStore()

    @Published private(set) var custom: [KBLayout] = []
    @Published var currentId: String {
        didSet { UserDefaults.standard.set(currentId, forKey: "currentLayout") }
    }

    let builtins: [KBLayout] = BuiltinLayouts.all

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("layouts.json")
    }()

    private init() {
        currentId = UserDefaults.standard.string(forKey: "currentLayout") ?? "builtin.laptop"
        load()
        if layout(id: currentId) == nil { currentId = "builtin.laptop" }
    }

    var all: [KBLayout] { builtins + custom }

    var current: KBLayout { layout(id: currentId) ?? builtins[0] }

    func layout(id: String) -> KBLayout? { all.first { $0.id == id } }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let list = try? JSONDecoder().decode([KBLayout].self, from: data) {
            custom = list
        }
    }

    private let saveQueue = DispatchQueue(label: "localkeys.save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    /// Encoding + writing happens off the main thread and is coalesced: dragging a key or a
    /// slider in the editor changes the layout many times a second.
    private func save() {
        pendingSave?.cancel()
        let snapshot = custom
        let url = fileURL
        let work = DispatchWorkItem {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("LocalKeys: failed to save layouts: \(error)")
            }
        }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write any pending change now (the app is going to the background).
    func flush() {
        guard let work = pendingSave, !work.isCancelled else { return }
        pendingSave = nil
        work.cancel()
        let snapshot = custom
        let url = fileURL
        saveQueue.sync {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
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
        guard !l.builtIn, let i = custom.firstIndex(where: { $0.id == l.id }) else { return }
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
