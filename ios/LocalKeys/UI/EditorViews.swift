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
        case wheel = "Кнопка колеса"
        case wheelStrip = "Колесо (полоса)"
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
            case .scrollWheel: return .wheelStrip
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
            case .wheelStrip: key.action = .scrollWheel(WheelConfig())
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

                if !key.action.isZone {
                    Section {
                        Toggle("Другое действие при зажатом Fn", isOn: Binding(
                            get: { key.fn != nil },
                            set: { key.fn = $0 ? .key(KC.f(1)) : nil }))
                        if case .key(let fnCode)? = key.fn {
                            NavigationLink {
                                KeyPickerView(selection: Binding(get: { fnCode }, set: { key.fn = .key($0) }), title: "Клавиша с Fn")
                            } label: {
                                HStack { Text("Fn + эта клавиша"); Spacer(); Text(KeyCatalog.name(fnCode)).foregroundColor(.secondary) }
                            }
                        } else if key.fn != nil {
                            Text("Задано особое действие").foregroundColor(.secondary)
                        }
                    } header: {
                        Text("Слой Fn")
                    } footer: {
                        Text("Работает, пока зажата клавиша с действием «Fn (второй слой)», как на компактных клавиатурах.")
                    }
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
        case .scrollWheel(let cfg):
            wheelEditor(cfg)
        }
    }

    private func wheelEditor(_ cfg: WheelConfig) -> some View {
        func update(_ f: (inout WheelConfig) -> Void) {
            var c = cfg
            f(&c)
            key.action = .scrollWheel(c)
        }
        return Group {
            Picker("Что делает", selection: Binding(get: { cfg.mode }, set: { v in update { $0.mode = v } })) {
                ForEach(WheelMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            VStack(alignment: .leading) {
                Text("Шаг деления: \(Int(cfg.notch ?? 26)) pt — одно деление = один шаг")
                Slider(value: Binding(get: { cfg.notch ?? 26 }, set: { v in update { $0.notch = v.rounded() } }), in: 12...60)
            }
            if cfg.mode.isScroll {
                Toggle(isOn: Binding(get: { cfg.smooth == true }, set: { v in update { $0.smooth = v } })) {
                    VStack(alignment: .leading) {
                        Text("Плавная прокрутка")
                        Text("Без щелчков: страница едет вслед за пальцем. Выключено — по строкам, как обычное колесо.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Toggle("Докручивать по инерции после взмаха", isOn: Binding(get: { cfg.spin ?? true }, set: { v in update { $0.spin = v } }))
            }
            Toggle("Обратное направление", isOn: Binding(get: { cfg.invert == true }, set: { v in update { $0.invert = v } }))
            Text(wheelHelp(cfg.mode)).font(.footnote).foregroundColor(.secondary)
        }
    }

    private func wheelHelp(_ m: WheelMode) -> String {
        switch m {
        case .scroll, .hscroll: return "Ведите одним пальцем вдоль колеса. Касание — средняя кнопка мыши. Вертикальное или горизонтальное колесо — по форме элемента."
        case .volume: return "Вверх / вправо — громче. Касание — выключить звук."
        case .zoom: return "Ctrl + колесо: масштаб в браузере, документах, картинках."
        case .tabs: return "Переключение вкладок в браузере и редакторах."
        case .windows: return "Пока палец на колесе, открыт переключатель окон (Alt+Tab); отпустите палец, чтобы выбрать окно."
        case .undo: return "Назад — отменить (Ctrl+Z), вперёд — повторить (Ctrl+Y)."
        case .arrows: return "Шаг — нажатие стрелки: списки, меню, курсор в тексте."
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
            VStack(alignment: .leading) {
                Text("Мёртвая зона: \(Int(((cfg.deadzone ?? 0.28) * 100).rounded()))%")
                Slider(value: Binding(get: { cfg.deadzone ?? 0.28 }, set: { v in update { $0.deadzone = v } }), in: 0.05...0.7)
            }
            if cfg.sprint != nil {
                VStack(alignment: .leading) {
                    Text("Бег включается при отклонении: \(String(format: "%.1f", cfg.sprintAt ?? 1.3))")
                    Slider(value: Binding(get: { cfg.sprintAt ?? 1.3 }, set: { v in update { $0.sprintAt = v } }), in: 1.0...2.2)
                }
                Toggle("Бег не сбрасывается, пока палец на стике", isOn: Binding(get: { cfg.sprintLatch == true }, set: { v in update { $0.sprintLatch = v } }))
                NavigationLink { KeyPickerView(selection: Binding(get: { cfg.sprint ?? KC.lshift }, set: { v in update { $0.sprint = v } }), title: "Клавиша бега") } label: {
                    HStack { Text("Клавиша бега"); Spacer(); Text(KeyCatalog.name(cfg.sprint ?? KC.lshift)).foregroundColor(.secondary) }
                }
            }
            Toggle("Фиксированный центр (иначе центр там, где коснулись)", isOn: Binding(get: { cfg.fixedCenter == true }, set: { v in update { $0.fixedCenter = v } }))
            Button("Стрелки вместо WASD") {
                update { $0.up = KC.up; $0.left = KC.left; $0.down = KC.down; $0.right = KC.right }
            }
        }
    }
}

/// Where a group keeps its place while being scaled.
enum GroupAnchor: String, CaseIterable, Identifiable {
    case bottom, center, top, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottom: return "Снизу"
        case .center: return "Центр"
        case .top: return "Сверху"
        case .bottomLeft: return "Слева снизу"
        case .bottomRight: return "Справа снизу"
        }
    }
    /// Anchor point inside the group's bounding box (0...1).
    var unit: (x: Double, y: Double) {
        switch self {
        case .bottom: return (0.5, 1)
        case .center: return (0.5, 0.5)
        case .top: return (0.5, 0)
        case .bottomLeft: return (0, 1)
        case .bottomRight: return (1, 1)
        }
    }
}

/// Scale / place several elements at once (e.g. all keys smaller, trackpad untouched).
struct GroupInspectorView: View {
    let count: Int
    var onScale: (Double, GroupAnchor) -> Void
    var onCenter: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var anchor: GroupAnchor = .bottom

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Размер")
                        Spacer()
                        Text("\(Int((scale * 100).rounded()))%").monospacedDigit().foregroundColor(.secondary)
                    }
                    Slider(value: $scale, in: 0.4...1.6, step: 0.01)
                    HStack {
                        ForEach([0.7, 0.8, 0.9, 1.0, 1.1], id: \.self) { v in
                            Button("\(Int(v * 100))%") { scale = v }
                                .buttonStyle(.bordered)
                        }
                    }
                    Picker("Неподвижная точка", selection: $anchor) {
                        ForEach(GroupAnchor.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Выбрано элементов: \(count)")
                } footer: {
                    Text("Все выбранные элементы меняют размер вместе, сохраняя расстановку. Остальное (например, тачпад) не меняется. Двигать группу — перетаскиванием любого выбранного элемента.")
                }
                Section {
                    Button("Выровнять по центру экрана") {
                        onCenter()
                        scale = 1
                    }
                    Button("Удалить выбранные", role: .destructive) { onDelete() }
                }
            }
            .navigationTitle("Группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .onChange(of: scale) { onScale($0, anchor) }
            .onChange(of: anchor) { onScale(scale, $0) }
        }
    }
}

struct LayoutPropertiesView: View {
    @Binding var layout: KBLayout
    /// Built-in layout changed by the user: offer the factory version back.
    var onReset: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

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
                if let onReset {
                    Section {
                        Button("Сбросить к стандартной", role: .destructive) { confirmReset = true }
                    } footer: {
                        Text("Вернуть встроенную раскладку «\(layout.name)» к исходному виду. Ваши изменения в ней пропадут.")
                    }
                    .confirmationDialog("Сбросить раскладку к стандартной?", isPresented: $confirmReset, titleVisibility: .visible) {
                        Button("Сбросить", role: .destructive) { onReset() }
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
