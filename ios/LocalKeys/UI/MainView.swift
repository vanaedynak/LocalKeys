import SwiftUI

enum SheetKind: String, Identifiable {
    case settings, connection, layouts, text, inspector, help
    var id: String { rawValue }
}

struct MainView: View {
    @ObservedObject private var conn = ConnectionManager.shared
    @ObservedObject private var store = LayoutStore.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var sheet: SheetKind?
    @State private var editing = false
    @State private var selectedId: UUID?
    @State private var editLayout: KBLayout?

    private var theme: KTheme { KTheme.byId(settings.themeId) }

    var body: some View {
        let layout = editing ? (editLayout ?? store.current) : store.current
        VStack(spacing: 0) {
            if editing {
                EditorBar(theme: theme,
                          layoutName: layout.name,
                          hasSelection: selectedId != nil,
                          onAdd: addElement,
                          onInspect: { sheet = .inspector },
                          onDuplicate: duplicateSelected,
                          onDelete: deleteSelected,
                          onDone: finishEditing)
            } else if settings.showTopBar {
                TopBar(theme: theme, onOpen: { sheet = $0 }, onEdit: startEditing)
            }
            KeyboardContainer(layout: layout,
                              theme: theme,
                              gap: settings.keyGap,
                              editing: editing,
                              selectedId: selectedId,
                              settingsVersion: 0,
                              onSelect: { selectedId = $0 },
                              onEdited: { l in
                                  editLayout = l
                                  store.update(l)
                              },
                              onSpecial: handleSpecial,
                              onSwitchLayout: { store.currentId = $0 })
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
        .overlay {
            if conn.phase == .pairing, let code = conn.pairingCode {
                PairingOverlay(code: code, theme: theme)
            }
        }
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
                LayoutPropertiesView(layout: layoutBinding())
            }
        }
    }

    // MARK: editing

    private func startEditing() {
        var l = store.current
        if l.builtIn { l = store.duplicate(l) }
        editLayout = l
        selectedId = nil
        editing = true
    }

    private func finishEditing() {
        if let l = editLayout { store.update(l) }
        editing = false
        selectedId = nil
        editLayout = nil
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
    @ObservedObject private var conn = ConnectionManager.shared
    @ObservedObject private var store = LayoutStore.shared
    @ObservedObject private var settings = AppSettings.shared
    let theme: KTheme
    var onOpen: (SheetKind) -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { onOpen(.connection) } label: { connectionPill }
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

            langMenu

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

    private var statusColor: Color {
        switch conn.phase {
        case .connected: return .green
        case .pairing, .connecting: return .orange
        case .denied: return .red
        default: return Color(uiColor: theme.textDim)
        }
    }

    private var connectionPill: some View {
        HStack(spacing: 7) {
            Image(systemName: conn.transport == .usb ? "cable.connector" : (conn.phase == .connected ? "wifi" : "antenna.radiowaves.left.and.right"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(conn.phase == .connected ? conn.pcName : (conn.phase == .pairing ? "Сопряжение…" : "Поиск ПК…"))
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

    private var langMenu: some View {
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

// MARK: - Editor bar

struct EditorBar: View {
    let theme: KTheme
    let layoutName: String
    let hasSelection: Bool
    var onAdd: (KeyAction) -> Void
    var onInspect: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").foregroundColor(Color(uiColor: theme.accent))
            Text(layoutName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                Button { onAdd(.key(KC.space)) } label: { Label("Клавиша", systemImage: "square") }
                Button { onAdd(.trackpad) } label: { Label("Тачпад", systemImage: "hand.point.up.left") }
                Button { onAdd(.mouseLook) } label: { Label("Обзор мышью (игры)", systemImage: "scope") }
                Button { onAdd(.stick(StickConfig())) } label: { Label("Стик WASD", systemImage: "l.joystick") }
                Button { onAdd(.mouse(0)) } label: { Label("Кнопка мыши", systemImage: "computermouse") }
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            Button(action: onInspect) {
                Label(hasSelection ? "Свойства" : "Раскладка", systemImage: "info.circle")
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
            Text("Перетаскивайте элементы, угол — изменить размер. Сетка 0.25 клавиши.")
                .font(.system(size: 10))
                .foregroundColor(Color(uiColor: theme.textDim))
                .offset(y: 14)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Pairing overlay

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
