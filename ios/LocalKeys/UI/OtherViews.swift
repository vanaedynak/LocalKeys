import SwiftUI
import UIKit

struct LayoutsView: View {
    @ObservedObject private var store = LayoutStore.shared
    @Environment(\.dismiss) private var dismiss
    var onEdit: () -> Void
    @State private var renaming: KBLayout?
    @State private var newName = ""
    @State private var importFailed = false
    @State private var copied = false
    @State private var resetting: KBLayout?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.builtins) { l in row(l) }
                } header: {
                    Text("Встроенные")
                } footer: {
                    Text("Встроенные раскладки меняются прямо на месте. Вернуть исходный вид — «Сбросить к стандартной» в меню раскладки.")
                }
                Section {
                    ForEach(store.custom) { l in row(l) }
                        .onDelete { idx in idx.map { store.custom[$0].id }.forEach { store.delete(id: $0) } }
                        .onMove { store.moveCustom(from: $0, to: $1) }
                    Button {
                        _ = store.createEmpty()
                        onEdit()
                    } label: { Label("Новая пустая раскладка", systemImage: "plus") }
                    Button {
                        if let text = UIPasteboard.general.string, store.importJSON(text) {
                            importFailed = false
                        } else {
                            importFailed = true
                        }
                    } label: { Label("Импорт из буфера обмена", systemImage: "doc.on.clipboard") }
                } header: {
                    Text("Мои раскладки")
                } footer: {
                    Text("Свои раскладки — копии и новые. Раскладками можно делиться через буфер обмена (JSON).")
                }
            }
            .navigationTitle("Раскладки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Название", text: $newName)
                Button("Сохранить") {
                    if var l = renaming {
                        l.name = newName
                        store.update(l)
                    }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
            .alert("В буфере нет раскладки LocalKeys", isPresented: $importFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert("JSON раскладки скопирован", isPresented: $copied) {
                Button("OK", role: .cancel) {}
            }
            .confirmationDialog("Сбросить «\(resetting?.name ?? "")» к стандартной?",
                                isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }),
                                titleVisibility: .visible) {
                Button("Сбросить", role: .destructive) {
                    if let l = resetting {
                        store.resetBuiltin(l.id)
                        AppSettings.shared.placements[l.id] = nil
                    }
                    resetting = nil
                }
            }
        }
    }

    private func row(_ l: KBLayout) -> some View {
        HStack {
            Button {
                store.currentId = l.id
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: l.icon).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(l.name).foregroundColor(.primary)
                        Text(l.builtIn && store.isModified(l.id) ? "\(l.keys.count) элементов · изменена" : "\(l.keys.count) элементов")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if l.id == store.currentId { Image(systemName: "checkmark").foregroundColor(.accentColor) }
                }
            }
            Menu {
                Button { store.currentId = l.id; onEdit() } label: { Label("Изменить", systemImage: "slider.horizontal.3") }
                Button { store.duplicate(l) } label: { Label("Дублировать", systemImage: "plus.square.on.square") }
                if !l.builtIn {
                    Button { newName = l.name; renaming = l } label: { Label("Переименовать", systemImage: "pencil") }
                }
                Button {
                    UIPasteboard.general.string = store.exportJSON(l)
                    copied = true
                } label: { Label("Скопировать JSON", systemImage: "doc.on.doc") }
                if !l.builtIn {
                    Button(role: .destructive) { store.delete(id: l.id) } label: { Label("Удалить", systemImage: "trash") }
                } else if store.isModified(l.id) {
                    Button(role: .destructive) { resetting = l } label: { Label("Сбросить к стандартной", systemImage: "arrow.counterclockwise") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20)).padding(.leading, 8)
            }
        }
    }
}

/// Type with the iOS keyboard (dictation, swipe typing, autocorrect) and send to the PC as text.
struct TextPanelView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    @AppStorage("textPanelClose") private var closeAfterSend = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $text)
                    .focused($focused)
                    .font(.system(size: 20))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemBackground)))
                HStack {
                    Toggle("Закрывать после отправки", isOn: $closeAfterSend).fixedSize()
                    Spacer()
                    Button("Очистить") { text = "" }
                    Button {
                        send(enter: true)
                    } label: { Label("Отправить + Enter", systemImage: "return") }
                        .buttonStyle(.bordered)
                    Button {
                        send(enter: false)
                    } label: { Label("Отправить", systemImage: "paperplane.fill") }
                        .buttonStyle(.borderedProminent)
                }
                .disabled(false)
            }
            .padding()
            .navigationTitle("Ввод текста")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            }
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { focused = true } }
        }
    }

    private func send(enter: Bool) {
        guard !text.isEmpty || enter else { return }
        InputController.shared.text(text + (enter ? "\n" : ""))
        text = ""
        if closeAfterSend { dismiss() }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    step("1", "Установите LocalKeys на Windows",
                         "Скачайте LocalKeys-Setup.exe из раздела Releases на GitHub и установите. Программа запускается вместе с Windows и работает в фоне (значок в трее).")
                    step("2", "Подключите iPad",
                         "Wi-Fi: iPad и компьютер в одной сети — LocalKeys найдёт ПК сам. Подтвердите код в окне на компьютере (один раз).\n\nUSB-C: подключите кабель и нажмите «Доверять» на iPad. Нужна служба Apple Mobile Device — она ставится вместе с бесплатным приложением Apple Devices из Microsoft Store (или iTunes). По кабелю сопряжение автоматическое.")
                    step("3", "Пользуйтесь",
                         "Раскладки переключаются в верхней панели. Можно нажимать сколько угодно клавиш одновременно — как на настоящей клавиатуре. Язык ввода — кнопка 🌐 или меню языка вверху.")

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Советы").font(.title3.bold())
                        tip("hand.raised", "Отключите системные жесты iPad: Настройки → Экран «Домой» и многозадачность → Жесты. Иначе жесты 4–5 пальцами могут свернуть приложение во время игры.")
                        tip("lock", "Для игр включите «Гид-доступ» (Настройки → Универсальный доступ): он полностью блокирует системные жесты и выход из приложения.")
                        tip("bolt", "USB-кабель даёт самую стабильную задержку. Wi-Fi остаётся в резерве и подхватывает ввод, если кабель отключить.")
                        tip("gamecontroller", "Игры: раскладки «Игры» и «Игры: стик» поддерживают скольжение пальца по клавишам и зону обзора мышью. Клавишу можно сделать «фиксируемой» (автобег) в редакторе.")
                        tip("character.cursor.ibeam", "Кнопка ввода текста открывает клавиатуру iPad: диктовка, свайп-набор и автокоррекция, затем текст отправляется на ПК.")
                        tip("exclamationmark.triangle", "Ограничения Windows: Ctrl+Alt+Del, экран входа и окна UAC не принимают программный ввод. Игры с агрессивным античитом могут игнорировать эмулированный ввод.")
                    }
                }
                .padding(28)
            }
            .navigationTitle("Как пользоваться")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Понятно") {
                        s.onboardingDone = true
                        dismiss()
                    }
                }
            }
        }
    }

    private func step(_ n: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(n)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(body).foregroundColor(.secondary)
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundColor(.accentColor)
            Text(text).font(.subheadline)
        }
    }
}
