import SwiftUI

struct KeyPickerView: View {
    @Binding var selection: UInt16
    var title: String = "Клавиша"
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            ForEach(KeyGroup.allCases) { group in
                let items = KeyCatalog.all.filter { $0.group == group && matches($0) }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { info in
                            Button {
                                selection = info.code
                                dismiss()
                            } label: {
                                HStack {
                                    Text(info.name).foregroundColor(.primary)
                                    Spacer()
                                    if info.code == selection { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Поиск клавиши")
        .navigationTitle(title)
    }

    private func matches(_ k: KeyInfo) -> Bool {
        query.isEmpty || k.name.localizedCaseInsensitiveContains(query)
    }
}

struct KeyInspectorView: View {
    @Binding var key: KeyDef
    let layouts: [KBLayout]
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case key = "Клавиша"
        case combo = "Сочетание"
        case mouse = "Кнопка мыши"
        case wheel = "Колесо мыши"
        case text = "Ввод текста"
        case special = "Действие"
        case layout = "Сменить раскладку"
        case trackpad = "Тачпад"
        case look = "Обзор мышью"
        case stick = "Стик"
        var id: String { rawValue }
    }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch key.action {
            case .key: return .key
            case .combo: return .combo
            case .mouse: return .mouse
            case .wheel: return .wheel
            case .text: return .text
            case .special: return .special
            case .switchLayout: return .layout
            case .trackpad: return .trackpad
            case .mouseLook: return .look
            case .stick: return .stick
            }
        }, set: { k in
            switch k {
            case .key: key.action = .key(KC.space)
            case .combo: key.action = .combo([KC.lctrl, KC.c])
            case .mouse: key.action = .mouse(0)
            case .wheel: key.action = .wheel(1)
            case .text: key.action = .text("")
            case .special: key.action = .special(.langSwitch)
            case .layout: key.action = .switchLayout(layouts.first?.id ?? "")
            case .trackpad: key.action = .trackpad
            case .look: key.action = .mouseLook
            case .stick: key.action = .stick(StickConfig())
            }
        })
    }

    private var label: Binding<String> {
        Binding(get: { key.label ?? "" }, set: { key.label = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Действие") {
                    Picker("Тип", selection: kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    actionEditor
                }

                Section {
                    TextField("Подпись (пусто — автоматически)", text: label)
                    Picker("Цвет", selection: $key.style) {
                        ForEach(KeyStyle.allCases) { Text($0.title).tag($0) }
                    }
                    if !key.action.isZone {
                        Toggle(isOn: $key.toggle) {
                            VStack(alignment: .leading) {
                                Text("Фиксация")
                                Text("Нажатие включает удержание, повторное — отпускает (например, автобег).")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Вид")
                } footer: {
                    Text("Подсказка: «sf:имя_символа|Текст» показывает значок SF Symbols с подписью.")
                }

                Section("Положение и размер (в клавишах)") {
                    stepper("Ширина", $key.w, 0.5...20)
                    stepper("Высота", $key.h, 0.5...12)
                    stepper("X", $key.x, 0...40)
                    stepper("Y", $key.y, 0...30)
                }

                Section {
                    Button("Удалить элемент", role: .destructive) { onDelete() }
                }
            }
            .navigationTitle("Свойства элемента")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func stepper(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 0.25) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionEditor: some View {
        switch key.action {
        case .key(let code):
            NavigationLink {
                KeyPickerView(selection: Binding(get: { code }, set: { key.action = .key($0) }))
            } label: {
                HStack { Text("Клавиша"); Spacer(); Text(KeyCatalog.name(code)).foregroundColor(.secondary) }
            }
        case .combo(let codes):
            comboEditor(codes)
        case .mouse(let b):
            Picker("Кнопка", selection: Binding(get: { b }, set: { key.action = .mouse($0) })) {
                Text("Левая").tag(UInt8(0))
                Text("Правая").tag(UInt8(1))
                Text("Средняя").tag(UInt8(2))
                Text("Назад (X1)").tag(UInt8(3))
                Text("Вперёд (X2)").tag(UInt8(4))
            }
        case .wheel(let d):
            Picker("Направление", selection: Binding(get: { d > 0 }, set: { key.action = .wheel($0 ? 1 : -1) })) {
                Text("Вверх").tag(true)
                Text("Вниз").tag(false)
            }
            .pickerStyle(.segmented)
        case .text(let s):
            TextField("Текст для ввода", text: Binding(get: { s }, set: { key.action = .text($0) }), axis: .vertical)
        case .special(let sp):
            Picker("Действие", selection: Binding(get: { sp }, set: { key.action = .special($0) })) {
                ForEach(SpecialAction.allCases) { Text($0.title).tag($0) }
            }
        case .switchLayout(let id):
            Picker("Раскладка", selection: Binding(get: { id }, set: { key.action = .switchLayout($0) })) {
                ForEach(layouts) { Text($0.name).tag($0.id) }
            }
        case .trackpad:
            Text("Одним пальцем — курсор, касание — клик, двумя — прокрутка и правый клик.")
                .font(.footnote).foregroundColor(.secondary)
        case .mouseLook:
            Text("Прямое движение мыши без ускорения — для камеры в играх. Работает несколькими пальцами.")
                .font(.footnote).foregroundColor(.secondary)
        case .stick(let cfg):
            stickEditor(cfg)
        }
    }

    private func comboEditor(_ codes: [UInt16]) -> some View {
        let mods: [(String, UInt16)] = [("Ctrl", KC.lctrl), ("Shift", KC.lshift), ("Alt", KC.lalt), ("Win", KC.lwin)]
        let main = codes.last { !KeyCatalog.isModifier($0) } ?? KC.c
        func rebuild(_ newMods: [UInt16], _ newMain: UInt16) {
            key.action = .combo(newMods + [newMain])
        }
        let current = mods.map { $0.1 }.filter { codes.contains($0) }
        return Group {
            ForEach(0..<mods.count, id: \.self) { i in
                let m = mods[i]
                Toggle(m.0, isOn: Binding(get: { codes.contains(m.1) }, set: { on in
                    var list = current.filter { $0 != m.1 }
                    if on { list.append(m.1) }
                    list.sort { a, b in (mods.firstIndex { $0.1 == a } ?? 0) < (mods.firstIndex { $0.1 == b } ?? 0) }
                    rebuild(list, main)
                }))
            }
            NavigationLink {
                KeyPickerView(selection: Binding(get: { main }, set: { rebuild(current, $0) }))
            } label: {
                HStack { Text("Клавиша"); Spacer(); Text(KeyCatalog.name(main)).foregroundColor(.secondary) }
            }
            Text(codes.map { KeyCatalog.name($0) }.joined(separator: " + "))
                .font(.footnote).foregroundColor(.secondary)
        }
    }

    private func stickEditor(_ cfg: StickConfig) -> some View {
        func update(_ f: (inout StickConfig) -> Void) {
            var c = cfg
            f(&c)
            key.action = .stick(c)
        }
        return Group {
            NavigationLink { KeyPickerView(selection: Binding(get: { cfg.up }, set: { v in update { $0.up = v } })) } label: {
                HStack { Text("Вверх"); Spacer(); Text(KeyCatalog.name(cfg.up)).foregroundColor(.secondary) }
            }
            NavigationLink { KeyPickerView(selection: Binding(get: { cfg.left }, set: { v in update { $0.left = v } })) } label: {
                HStack { Text("Влево"); Spacer(); Text(KeyCatalog.name(cfg.left)).foregroundColor(.secondary) }
            }
            NavigationLink { KeyPickerView(selection: Binding(get: { cfg.down }, set: { v in update { $0.down = v } })) } label: {
                HStack { Text("Вниз"); Spacer(); Text(KeyCatalog.name(cfg.down)).foregroundColor(.secondary) }
            }
            NavigationLink { KeyPickerView(selection: Binding(get: { cfg.right }, set: { v in update { $0.right = v } })) } label: {
                HStack { Text("Вправо"); Spacer(); Text(KeyCatalog.name(cfg.right)).foregroundColor(.secondary) }
            }
            Toggle("Бег при сильном отклонении вперёд (Shift)", isOn: Binding(get: { cfg.sprint != nil }, set: { on in update { $0.sprint = on ? KC.lshift : nil } }))
            Button("Стрелки вместо WASD") {
                update { $0.up = KC.up; $0.left = KC.left; $0.down = KC.down; $0.right = KC.right }
            }
        }
    }
}

struct LayoutPropertiesView: View {
    @Binding var layout: KBLayout
    @Environment(\.dismiss) private var dismiss

    private let icons = ["keyboard", "gamecontroller", "l.joystick", "laptopcomputer", "command", "number.square",
                         "square.grid.3x3", "star", "bolt", "paintbrush", "music.note", "film", "flame", "cpu"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Раскладка") {
                    TextField("Название", text: $layout.name)
                    Picker("Значок", selection: $layout.icon) {
                        ForEach(icons, id: \.self) { Label($0, systemImage: $0).labelStyle(.iconOnly).tag($0) }
                    }
                    Toggle(isOn: $layout.glide) {
                        VStack(alignment: .leading) {
                            Text("Скольжение по клавишам")
                            Text("Ведите пальцем с клавиши на клавишу без отрыва — удобно для WASD.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section("Размер поля (в клавишах)") {
                    Stepper(value: $layout.cols, in: 2...40, step: 0.5) { Text("Ширина: \(layout.cols, specifier: "%.1f")") }
                    Stepper(value: $layout.rows, in: 1...30, step: 0.5) { Text("Высота: \(layout.rows, specifier: "%.1f")") }
                    Button("Подогнать под элементы") {
                        let maxX = layout.keys.map { $0.x + $0.w }.max() ?? layout.cols
                        let maxY = layout.keys.map { $0.y + $0.h }.max() ?? layout.rows
                        layout.cols = max(2, maxX)
                        layout.rows = max(1, maxY)
                    }
                }
            }
            .navigationTitle("Параметры раскладки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
    }
}
