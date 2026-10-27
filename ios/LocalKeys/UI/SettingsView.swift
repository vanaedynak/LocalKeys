import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject private var s = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Клавиатура") {
                    Picker("Подписи клавиш", selection: $s.legendMode) {
                        Text("Как на компьютере").tag("auto")
                        Text("English").tag("en")
                        Text("Русский").tag("ru")
                        Text("Українська").tag("ua")
                    }
                    Toggle("Двуязычные подписи", isOn: $s.bilingual)
                    if s.bilingual {
                        Picker("Второй язык при английской раскладке", selection: $s.secondLang) {
                            Text("Русский").tag("ru")
                            Text("Українська").tag("ua")
                            Text("Нет").tag("none")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Размер второго языка")
                                Spacer()
                                Text("\(Int((s.altScale * 100).rounded()))% от основной").monospacedDigit().foregroundColor(.secondary)
                            }
                            Slider(value: $s.altScale, in: 0.4...1.0, step: 0.02)
                        }
                        Toggle(isOn: $s.altShifted) {
                            VStack(alignment: .leading) {
                                Text("Символы второго языка с Shift")
                                Text("На цифрах и знаках справа вверху: например «\"» и «№» на 2 и 3, «,» на «/».")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        LegendPreview(altScale: s.altScale, altShifted: s.altShifted, secondLang: s.secondLang,
                                      legendMode: s.legendMode, themeId: s.themeId)
                            .frame(height: 76)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    }
                    Picker("Кнопка 🌐 переключает язык", selection: $s.langCombo) {
                        Text("Win + Пробел").tag("winSpace")
                        Text("Alt + Shift").tag("altShift")
                        Text("Ctrl + Shift").tag("ctrlShift")
                    }
                    Toggle(isOn: $s.stickyModifiers) {
                        VStack(alignment: .leading) {
                            Text("Залипающие модификаторы")
                            Text("Короткое нажатие Shift/Ctrl/Alt/Win действует на следующую клавишу, двойное — фиксирует.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Toggle("Звук нажатия", isOn: $s.keySound)
                }

                Section("Тачпад и мышь") {
                    slider("Скорость курсора", value: $s.pointerSpeed, range: 0.3...3)
                    slider("Ускорение", value: $s.pointerAccel, range: 0...2)
                    slider("Скорость прокрутки", value: $s.scrollSpeed, range: 0.3...3)
                    Toggle("Естественная прокрутка", isOn: $s.naturalScroll)
                    Toggle("Инерция прокрутки", isOn: $s.scrollMomentum)
                    Toggle("Касание = клик", isOn: $s.tapToClick)
                    slider("Чувствительность обзора (игры)", value: $s.lookSpeed, range: 0.2...5)
                    Toggle("Инвертировать обзор по вертикали", isOn: $s.invertLookY)
                }

                Section {
                    Toggle("Ручка наклоном iPad", isOn: $s.stickTilt)
                    slider("Наклон для полного отклонения", value: $s.tiltRange, range: 10...45, format: "%.0f°")
                    slider("Мёртвая зона наклона", value: $s.tiltDeadzone, range: 0...0.2, format: "%.2f")
                } header: {
                    Text("Джойстик (DCS и другие игры)")
                } footer: {
                    Text("Раскладка «DCS / джойстик» — это настоящий джойстик для Windows: на ПК нужен бесплатный драйвер vJoy. Двойное касание по ручке — центр наклона.")
                }

                Section("Внешний вид") {
                    Picker("Тема", selection: $s.themeId) {
                        ForEach(KTheme.all, id: \.id) { t in Text(t.name).tag(t.id) }
                    }
                    slider("Расстояние между клавишами", value: $s.keyGap, range: 0...14, format: "%.0f pt")
                    Toggle("Показывать верхнюю панель", isOn: $s.showTopBar)
                }

                Section("Это устройство") {
                    TextField("Имя iPad", text: $s.deviceName)
                    Text("Имя показывается на компьютере при подключении.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section {
                    Button("Как пользоваться и советы") { showHelp = true }
                } footer: {
                    Text("LocalKeys \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .sheet(isPresented: $showHelp) { HelpView() }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue)).foregroundColor(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}

struct ConnectionView: View {
    @ObservedObject private var conn = ConnectionManager.shared
    @ObservedObject private var s = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: conn.phase == .connected ? (conn.transport == .usb ? "cable.connector" : "wifi") : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 28))
                            .foregroundColor(conn.phase == .connected ? .green : .orange)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conn.phase == .connected ? "Подключено к \(conn.pcName)" : "Не подключено").font(.headline)
                            Text(conn.statusDetail).font(.subheadline).foregroundColor(.secondary)
                            if let rtt = conn.rttMs, conn.phase == .connected {
                                Text("Задержка: ~\(max(rtt / 2, 1)) мс (туда-обратно \(rtt) мс)").font(.caption).foregroundColor(.secondary)
                            }
                            if conn.pcState?.elevated == false {
                                Text("Агент на ПК запущен без прав администратора — ввод не дойдёт до окон и игр, запущенных от администратора.")
                                    .font(.caption).foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if conn.localNetworkDenied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            Label("Разрешите LocalKeys доступ к локальной сети (Настройки → LocalKeys → Локальная сеть), иначе Wi-Fi не работает. USB работает и без этого.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section {
                    Toggle("USB-кабель", isOn: $s.usbEnabled)
                    HStack {
                        Text("Канал USB")
                        Spacer()
                        Text(conn.usbLinked ? "активен" : (conn.usbListening ? "ожидает кабель" : "выключен"))
                            .foregroundColor(conn.usbLinked ? .green : .secondary)
                    }
                    Toggle("Wi-Fi / локальная сеть", isOn: $s.wifiEnabled)
                    HStack {
                        Text("Канал Wi-Fi")
                        Spacer()
                        Text(conn.wifiLinked ? (conn.transport == .usb ? "в резерве" : "активен") : "нет связи")
                            .foregroundColor(conn.wifiLinked ? .green : .secondary)
                    }
                } header: {
                    Text("Каналы")
                } footer: {
                    Text("Оба канала работают одновременно: когда кабель подключён, ввод идёт по USB (стабильнее, iPad заряжается), при отключении кабеля — мгновенно по Wi-Fi.")
                }

                Section {
                    if conn.discovered.isEmpty {
                        Text("Компьютеры не найдены").foregroundColor(.secondary)
                    }
                    ForEach(conn.discovered) { pc in
                        Button {
                            s.preferredPC = (s.preferredPC == pc.name) ? "" : pc.name
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(pc.name)
                                if pc.source == "scan" { Text("(сканирование)").font(.caption).foregroundColor(.secondary) }
                                Spacer()
                                if s.preferredPC == pc.name { Image(systemName: "star.fill").foregroundColor(.yellow) }
                                if conn.pcName == pc.name && conn.wifiLinked { Image(systemName: "checkmark").foregroundColor(.green) }
                            }
                        }
                    }
                    Button {
                        conn.scanNetwork()
                    } label: {
                        HStack {
                            Text(conn.scanning ? "Сканирование сети…" : "Найти ПК сканированием сети")
                            if conn.scanning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(conn.scanning)
                } header: {
                    Text("Компьютеры в сети")
                } footer: {
                    Text("Звезда — предпочитаемый ПК, если их несколько. Обычно ничего выбирать не нужно: LocalKeys находит компьютер сам.")
                }

                Section {
                    TextField("IP-адрес, например 192.168.1.10", text: $s.manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Адрес вручную (необязательно)")
                } footer: {
                    Text("Только если автопоиск не работает в вашей сети. Адрес показан в окне LocalKeys на ПК.")
                }

                Section {
                    Button("Переподключиться") { conn.reconnectWifi() }
                    Button("Отпустить все клавиши на ПК") { InputController.shared.releaseAll() }
                    Button("Сбросить сопряжение", role: .destructive) { confirmForget = true }
                }
            }
            .navigationTitle("Подключение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .confirmationDialog("Забыть все сопряжённые компьютеры?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) {
                    s.forgetAllPairings()
                    conn.reconnectWifi()
                }
            }
        }
    }
}

/// Live keycaps in the settings, drawn exactly like the keyboard, so the legend size can be tuned by eye.
struct LegendPreview: UIViewRepresentable {
    var altScale: Double
    var altShifted: Bool
    var secondLang: String
    var legendMode: String
    var themeId: String

    private static let codes: [UInt16] = [0x29, 0x03, 0x04, 0x10, 0x1A, 0x27, 0x33, 0x35]

    func makeUIView(context: Context) -> PreviewRow { PreviewRow(count: Self.codes.count) }

    func updateUIView(_ v: PreviewRow, context: Context) {
        let theme = KTheme.byId(themeId)
        let resolved = Legends.resolve(settings: .shared, pc: ConnectionManager.shared.pcState)
        for (i, code) in Self.codes.enumerated() {
            let cap = v.caps[i]
            cap.theme = theme
            cap.style = .normal
            let l = Legends.format(code, resolved, shift: false, altShifted: altShifted) ?? KeyLegend(main: KeyCatalog.cap(code))
            cap.setLegend(main: l.main, top: l.top, alt: l.alt, altTop: l.altTop, altScale: CGFloat(altScale))
            cap.applyColors()
        }
        v.backgroundColor = theme.bg
    }

    final class PreviewRow: UIView {
        let caps: [KeyCapView]

        init(count: Int) {
            caps = (0..<count).map { _ in KeyCapView() }
            super.init(frame: .zero)
            layer.cornerRadius = 10
            caps.forEach { addSubview($0) }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let gap: CGFloat = 5
            let side = min(bounds.height - gap * 2, (bounds.width - gap * CGFloat(caps.count + 1)) / CGFloat(caps.count))
            let total = side * CGFloat(caps.count) + gap * CGFloat(caps.count - 1)
            var x = (bounds.width - total) / 2
            for c in caps {
                c.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
                x += side + gap
            }
        }
    }
}
