import SwiftUI

enum SheetKind: String, Identifiable {
    case settings, connection, layouts, text, inspector, help, group
    var id: String { rawValue }
}

struct MainView: View {
    // Deliberately not observing ConnectionManager here: its ping/latency updates would
    // re-render the whole screen (and re-apply the keyboard) twice a second.
    @ObservedObject private var store = LayoutStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var sheet: SheetKind?
    @State private var editing = false
    @State private var selectedId: UUID?
    @State private var editLayout: KBLayout?
    @State private var group: Set<UUID> = []
    @State private var multiSelect = false
    /// Group positions when the group panel opened: scaling is always computed from these.
    @State private var groupSnapshot: [KeyDef] = []

    private var theme: KTheme { KTheme.byId(settings.themeId) }

    var body: some View {
        let layout = editing ? (editLayout ?? store.current) : store.current
        VStack(spacing: 0) {
            if editing {
                EditorBar(theme: theme,
                          layoutName: layout.name,
                          hasSelection: selectedId != nil || !group.isEmpty,
                          groupCount: group.count,
                          multiSelect: multiSelect,
                          onAdd: addElement,
                          onInspect: { if group.isEmpty { sheet = .inspector } else { openGroupPanel() } },
                          onDuplicate: duplicateSelected,
                          onDelete: deleteSelected,
                          onSelect: selectMany,
                          onToggleMulti: {
                              multiSelect.toggle()
                              if multiSelect, let id = selectedId { group.insert(id); selectedId = nil }
                          },
                          onDone: finishEditing)
            } else if settings.showTopBar {
                TopBar(theme: theme, onOpen: { sheet = $0 }, onEdit: startEditing)
            }
            KeyboardContainer(layout: layout,
                              theme: theme,
                              gap: settings.keyGap,
                              editing: editing,
                              selectedId: selectedId,
                              vpos: settings.vpos(layout.id),
                              scale: settings.scale(layout.id),
                              group: editing ? group : [],
                              multiSelect: editing && multiSelect,
                              onSelect: { selectedId = $0 },
                              onEdited: { l in
                                  editLayout = l
                                  store.update(l)
                              },
                              onSpecial: handleSpecial,
                              onSwitchLayout: { store.currentId = $0 },
                              onEditTap: { id in
                                  selectedId = id
                                  sheet = .inspector
                              },
                              onFilled: { l in
                                  // The layout now covers the whole screen at its current size.
                                  settings.placements[l.id] = nil
                                  commit(l)
                              },
                              onGroup: { group = $0 },
                              onGroupTap: openGroupPanel)
                .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
        }
        .background(Color(uiColor: theme.bg).ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if !settings.showTopBar && !editing {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { settings.showTopBar = true }
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(uiColor: theme.textDim).opacity(0.6))
                        .padding(6)
                }
            }
        }
        .overlay { PairingOverlayHost(theme: theme) }
        .sheet(item: $sheet) { kind in
            sheetView(kind)
                .preferredColorScheme(theme.isLight ? .light : .dark)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .preferredColorScheme(theme.isLight ? .light : .dark)
        .onAppear {
            if !settings.onboardingDone { sheet = .help }
            let env = ProcessInfo.processInfo.environment
            if env["LK_SHEET"] == "settings" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sheet = .settings }
            }
            if let e = env["LK_EDIT"], !e.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    startEditing()
                    if env["LK_GROUP"] == "keys" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selectMany(.keys) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sheetView(_ kind: SheetKind) -> some View {
        switch kind {
        case .settings: SettingsView()
        case .connection: ConnectionView()
        case .layouts: LayoutsView(onEdit: { sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { startEditing() } })
        case .text: TextPanelView()
        case .help: HelpView()
        case .inspector:
            if let id = selectedId, editLayout?.keys.contains(where: { $0.id == id }) == true {
                KeyInspectorView(key: keyBinding(id), layouts: store.all, onDelete: {
                    deleteSelected()
                    sheet = nil
                })
            } else {
                let l = editLayout ?? store.current
                LayoutPropertiesView(layout: layoutBinding(),
                                     onReset: l.builtIn && store.isModified(l.id) ? { resetBuiltin(l.id) } : nil)
            }
        case .group:
            GroupInspectorView(count: group.count,
                               onScale: scaleGroup,
                               onCenter: centerGroup,
                               onDelete: {
                                   deleteSelected()
                                   sheet = nil
                               })
        }
    }

    // MARK: editing

    private func startEditing() {
        // Built-in layouts are edited in place (kept as the user's version until reset).
        editLayout = store.current
        selectedId = nil
        group = []
        multiSelect = false
        editing = true
    }

    private func finishEditing() {
        if let l = editLayout { store.update(l) }
        editing = false
        selectedId = nil
        group = []
        multiSelect = false
        editLayout = nil
    }

    private func resetBuiltin(_ id: String) {
        store.resetBuiltin(id)
        settings.placements[id] = nil
        sheet = nil
        editing = false
        selectedId = nil
        group = []
        multiSelect = false
        editLayout = nil
    }

    // MARK: group

    private func selectMany(_ which: EditorBar.Selection) {
        guard let l = editLayout else { return }
        selectedId = nil
        switch which {
        case .keys:
            // Everything typed with: no trackpad / look zones / stick / wheels and no mouse buttons.
            group = Set(l.keys.filter { k in
                if k.action.isZone { return false }
                if case .mouse = k.action { return false }
                return true
            }.map { $0.id })
        case .all:
            group = Set(l.keys.map { $0.id })
        case .none:
            group = []
            multiSelect = false
        }
    }

    private func openGroupPanel() {
        guard let l = editLayout, !group.isEmpty else { return }
        groupSnapshot = l.keys.filter { group.contains($0.id) }
        sheet = .group
    }

    private func scaleGroup(_ factor: Double, _ anchor: GroupAnchor) {
        guard var l = editLayout, !groupSnapshot.isEmpty,
              let minX = groupSnapshot.map({ $0.x }).min(), let maxX = groupSnapshot.map({ $0.x + $0.w }).max(),
              let minY = groupSnapshot.map({ $0.y }).min(), let maxY = groupSnapshot.map({ $0.y + $0.h }).max() else { return }
        let ax = minX + (maxX - minX) * anchor.unit.x
        let ay = minY + (maxY - minY) * anchor.unit.y
        var scaled = groupSnapshot.map { k -> KeyDef in
            var n = k
            n.x = ax + (k.x - ax) * factor
            n.y = ay + (k.y - ay) * factor
            n.w = k.w * factor
            n.h = k.h * factor
            return n
        }
        // Keep the block on the canvas.
        let nMinX = scaled.map { $0.x }.min() ?? 0, nMaxX = scaled.map { $0.x + $0.w }.max() ?? 0
        let nMinY = scaled.map { $0.y }.min() ?? 0, nMaxY = scaled.map { $0.y + $0.h }.max() ?? 0
        let sx = nMinX < 0 ? -nMinX : min(0, l.cols - nMaxX)
        let sy = nMinY < 0 ? -nMinY : min(0, l.rows - nMaxY)
        func r(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        for i in scaled.indices {
            scaled[i].x = r(scaled[i].x + sx)
            scaled[i].y = r(scaled[i].y + sy)
            scaled[i].w = r(scaled[i].w)
            scaled[i].h = r(scaled[i].h)
        }
        let byId = Dictionary(uniqueKeysWithValues: scaled.map { ($0.id, $0) })
        for i in l.keys.indices { if let n = byId[l.keys[i].id] { l.keys[i] = n } }
        commit(l)
    }

    /// Centres the group horizontally; the current positions become the new base for scaling.
    private func centerGroup() {
        guard var l = editLayout else { return }
        let members = l.keys.filter { group.contains($0.id) }
        guard let minX = members.map({ $0.x }).min(), let maxX = members.map({ $0.x + $0.w }).max() else { return }
        let dx = ((l.cols - (maxX - minX)) / 2 - minX)
        for i in l.keys.indices where group.contains(l.keys[i].id) {
            l.keys[i].x = ((l.keys[i].x + dx) * 100).rounded() / 100
        }
        commit(l)
        groupSnapshot = l.keys.filter { group.contains($0.id) }
    }

    private func commit(_ l: KBLayout) {
        editLayout = l
        store.update(l)
    }

    private func keyBinding(_ id: UUID) -> Binding<KeyDef> {
        Binding<KeyDef>(
            get: {
                editLayout?.keys.first { $0.id == id } ?? KeyDef(x: 0, y: 0, w: 1, h: 1, action: .key(KC.space))
            },
            set: { newValue in
                guard var l = editLayout, let i = l.keys.firstIndex(where: { $0.id == id }) else { return }
                l.keys[i] = newValue
                commit(l)
            })
    }

    private func layoutBinding() -> Binding<KBLayout> {
        Binding<KBLayout>(
            get: { editLayout ?? store.current },
            set: { commit($0) })
    }

    private func addElement(_ action: KeyAction) {
        guard var l = editLayout else { return }
        var w = 1.0, h = 1.0
        switch action {
        case .trackpad, .mouseLook: w = 5; h = 3
        case .stick: w = 3.5; h = 3.5
        case .scrollWheel: w = 1.2; h = 3
        case .flightStick: w = 5; h = 5
        case .axis: w = 1.6; h = 5
        case .joyButton: w = 2; h = 1.4
        default: break
        }
        w = min(w, l.cols)
        h = min(h, l.rows)
        let k = KeyDef(x: max(0, (l.cols - w) / 2).rounded(), y: max(0, (l.rows - h) / 2).rounded(), w: w, h: h, action: action)
        l.keys.append(k)
        commit(l)
        selectedId = k.id
        if case .key = action { sheet = .inspector }
    }

    private func duplicateSelected() {
        if !group.isEmpty {
            guard var l = editLayout else { return }
            var copies: [KeyDef] = []
            for k in l.keys where group.contains(k.id) {
                var c = k
                c.id = UUID()
                c.x = min(k.x + 0.5, max(0, l.cols - k.w))
                c.y = min(k.y + 0.5, max(0, l.rows - k.h))
                copies.append(c)
            }
            l.keys += copies
            commit(l)
            group = Set(copies.map { $0.id })
            return
        }
        guard var l = editLayout, let id = selectedId, let k = l.keys.first(where: { $0.id == id }) else { return }
        var c = k
        c.id = UUID()
        c.x = min(k.x + 0.5, max(0, l.cols - k.w))
        c.y = min(k.y + 0.5, max(0, l.rows - k.h))
        l.keys.append(c)
        commit(l)
        selectedId = c.id
    }

    private func deleteSelected() {
        if !group.isEmpty, var l = editLayout {
            l.keys.removeAll { group.contains($0.id) }
            commit(l)
            group = []
            return
        }
        guard var l = editLayout, let id = selectedId else { return }
        l.keys.removeAll { $0.id == id }
        commit(l)
        selectedId = nil
    }

    private func handleSpecial(_ s: SpecialAction) {
        switch s {
        case .textPanel: sheet = .text
        case .nextLayout: store.next()
        default: break
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject private var store = LayoutStore.shared
    @ObservedObject private var settings = AppSettings.shared
    let theme: KTheme
    var onOpen: (SheetKind) -> Void
    var onEdit: () -> Void
    @State private var showPlacement = false

    var body: some View {
        HStack(spacing: 10) {
            Button { onOpen(.connection) } label: { ConnectionPill(theme: theme) }
                .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.all) { l in
                        let selected = l.id == store.currentId
                        Button {
                            store.currentId = l.id
                        } label: {
                            Label(l.name, systemImage: l.icon)
                                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .foregroundColor(selected ? .white : Color(uiColor: theme.textDim))
                                .background(
                                    Capsule().fill(selected ? Color(uiColor: theme.keyAccent) : Color(uiColor: theme.key).opacity(0.6))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            LangMenu(theme: theme)

            barButton("arrow.up.and.down.square") { showPlacement.toggle() }
                .popover(isPresented: $showPlacement, arrowEdge: .top) {
                    PlacementView(layoutId: store.currentId, layoutName: store.current.name)
                }
            barButton("character.cursor.ibeam") { onOpen(.text) }
            barButton("slider.horizontal.3") { onEdit() }
            barButton("square.stack.3d.up") { onOpen(.layouts) }
            barButton("gearshape") { onOpen(.settings) }
            barButton("chevron.up") {
                withAnimation(.easeOut(duration: 0.2)) { settings.showTopBar = false }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(Color(uiColor: theme.bar))
    }

    private func barButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(Color(uiColor: theme.textDim))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Separate views with their own observer: latency updates redraw only these, not the whole bar.
struct ConnectionPill: View {
    @ObservedObject private var conn = ConnectionManager.shared
    let theme: KTheme

    private var statusColor: Color {
        switch conn.phase {
        case .connected: return .green
        case .pairing, .connecting: return .orange
        case .denied: return .red
        default: return Color(uiColor: theme.textDim)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: conn.transport == .usb ? "cable.connector" : (conn.phase == .connected ? "wifi" : "antenna.radiowaves.left.and.right"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(conn.phase == .connected ? conn.pcName : (conn.phase == .pairing ? "Сопряжение…" : (conn.pcUnresponsive ? "ПК не отвечает" : "Поиск ПК…")))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if conn.phase == .connected, let rtt = conn.rttMs {
                    Text("\(conn.transport == .usb ? "USB" : "Wi-Fi") · \(max(rtt / 2, 1)) мс")
                        .font(.system(size: 10))
                        .foregroundColor(Color(uiColor: theme.textDim))
                }
            }
        }
        .foregroundColor(Color(uiColor: theme.text))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 200, alignment: .leading)
        .background(Capsule().fill(Color(uiColor: theme.key).opacity(0.6)))
    }
}

struct LangMenu: View {
    @ObservedObject private var conn = ConnectionManager.shared
    let theme: KTheme

    var body: some View {
        Menu {
            if let list = conn.pcState?.layouts, !list.isEmpty {
                ForEach(list) { info in
                    Button {
                        conn.sendCommand("setLayout", info.id)
                    } label: {
                        if info.id == conn.pcState?.layoutId {
                            Label(info.name, systemImage: "checkmark")
                        } else {
                            Text(info.name)
                        }
                    }
                }
            } else {
                Text("Нет подключения к ПК")
            }
        } label: {
            Text(conn.pcState?.lang ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(Color(uiColor: theme.text))
                .frame(minWidth: 34)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(uiColor: theme.key).opacity(0.6)))
        }
    }
}

// MARK: - Editor bar

struct EditorBar: View {
    enum Selection { case keys, all, none }

    let theme: KTheme
    let layoutName: String
    let hasSelection: Bool
    var groupCount: Int = 0
    var multiSelect = false
    var onAdd: (KeyAction) -> Void
    var onInspect: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onSelect: (Selection) -> Void = { _ in }
    var onToggleMulti: () -> Void = {}
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").foregroundColor(Color(uiColor: theme.accent))
            Text(layoutName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button { onAdd(.key(KC.space)) } label: { Label("Клавиша", systemImage: "square") }
                Button { onAdd(.trackpad) } label: { Label("Тачпад", systemImage: "hand.point.up.left") }
                Button { onAdd(.scrollWheel(WheelConfig())) } label: { Label("Колесо прокрутки", systemImage: "arrow.up.arrow.down") }
                Button { onAdd(.scrollWheel(WheelConfig(mode: .volume))) } label: { Label("Колесо громкости", systemImage: "speaker.wave.2") }
                Button { onAdd(.mouseLook) } label: { Label("Обзор мышью (игры)", systemImage: "scope") }
                Button { onAdd(.stick(StickConfig())) } label: { Label("Стик WASD", systemImage: "l.joystick") }
                Button { onAdd(.mouse(0)) } label: { Label("Кнопка мыши", systemImage: "computermouse") }
                Section("Джойстик (DCS и другие игры)") {
                    Button { onAdd(.flightStick(FlightStickConfig())) } label: { Label("Ручка", systemImage: "airplane") }
                    Button { onAdd(.axis(AxisConfig())) } label: { Label("РУД (ось)", systemImage: "slider.vertical.3") }
                    Button { onAdd(.axis(AxisConfig(axis: .rz, spring: true))) } label: { Label("Педали (ось с возвратом)", systemImage: "slider.horizontal.3") }
                    Button { onAdd(.joyButton(1)) } label: { Label("Кнопка джойстика", systemImage: "circle.circle") }
                }
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            Menu {
                Button { onSelect(.keys) } label: { Label("Все клавиши (без тачпада)", systemImage: "keyboard") }
                Button { onSelect(.all) } label: { Label("Все элементы", systemImage: "square.grid.3x3.fill") }
                Button(action: onToggleMulti) {
                    Label(multiSelect ? "Выключить выбор касанием" : "Выбирать касанием", systemImage: "hand.tap")
                }
                if groupCount > 0 {
                    Button(role: .destructive) { onSelect(.none) } label: { Label("Снять выделение", systemImage: "xmark") }
                }
            } label: {
                Label(groupCount > 0 ? "Выбрано: \(groupCount)" : "Выделить",
                      systemImage: multiSelect ? "checkmark.circle.fill" : "checkmark.circle")
            }
            Button(action: onInspect) {
                Label(groupCount > 0 ? "Размер" : (hasSelection ? "Свойства" : "Раскладка"),
                      systemImage: groupCount > 0 ? "arrow.up.left.and.arrow.down.right" : "info.circle")
            }
            Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                .disabled(!hasSelection)
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .disabled(!hasSelection)
            Button(action: onDone) {
                Text("Готово").bold()
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color(uiColor: theme.keyAccent)))
                    .foregroundColor(.white)
            }
        }
        .font(.system(size: 14))
        .foregroundColor(Color(uiColor: theme.text))
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(Color(uiColor: theme.bar))
        .overlay(alignment: .bottom) {
            Text(multiSelect ? "Касание — добавить или убрать из выделения, перетаскивание выделенного — двигать всю группу."
                             : "Касание — свойства элемента, перетаскивание — переместить, угол — размер.")
                .font(.system(size: 10))
                .foregroundColor(Color(uiColor: theme.textDim))
                .offset(y: 14)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Pairing overlay

/// Observes the connection on its own so only this small view updates on network events.
struct PairingOverlayHost: View {
    @ObservedObject private var conn = ConnectionManager.shared
    let theme: KTheme

    var body: some View {
        if conn.phase == .pairing, let code = conn.pairingCode {
            PairingOverlay(code: code, theme: theme)
        }
    }
}

struct PairingOverlay: View {
    let code: String
    let theme: KTheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundColor(Color(uiColor: theme.accent))
                Text("Подтвердите подключение на компьютере")
                    .font(.title3.bold())
                Text("В окне LocalKeys на ПК должен быть тот же код:")
                    .foregroundColor(.secondary)
                Text(code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code)
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(uiColor: theme.accent))
                Text("Это нужно один раз. По USB-кабелю сопряжение происходит автоматически.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(32)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(uiColor: theme.bar)))
            .padding(40)
        }
    }
}

// MARK: - Placement (height / size of the keyboard, per layout)

struct PlacementView: View {
    @ObservedObject private var s = AppSettings.shared
    let layoutId: String
    let layoutName: String

    var body: some View {
        let vpos = s.vpos(layoutId)
        let scale = s.scale(layoutId)
        VStack(alignment: .leading, spacing: 16) {
            Text("Положение: \(layoutName)").font(.headline)

            HStack(spacing: 10) {
                VStack(spacing: 8) {
                    nudge("chevron.up") { s.setPlacement(layoutId, vpos: vpos - 0.05) }
                    nudge("chevron.down") { s.setPlacement(layoutId, vpos: vpos + 0.05) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Высота на экране").font(.subheadline)
                    HStack {
                        preset("Вверху", 0)
                        preset("По центру", 0.5)
                        preset("Внизу", 1)
                    }
                    Slider(value: Binding(get: { vpos }, set: { s.setPlacement(layoutId, vpos: $0) }), in: 0...1)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Размер клавиатуры").font(.subheadline)
                    Spacer()
                    Text("\(Int((scale * 100).rounded()))%").monospacedDigit().foregroundColor(.secondary)
                }
                Slider(value: Binding(get: { scale }, set: { s.setPlacement(layoutId, scale: $0) }), in: 0.5...1)
            }

            Button("Сбросить") { s.placements[layoutId] = nil }
                .font(.subheadline)
            Text("Настраивается отдельно для каждой раскладки и запоминается.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func nudge(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 52, height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func preset(_ title: String, _ value: Double) -> some View {
        Button(title) { withAnimation(.easeOut(duration: 0.15)) { s.setPlacement(layoutId, vpos: value) } }
            .buttonStyle(.bordered)
            .font(.caption)
    }
}
