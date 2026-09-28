import SwiftUI

// Экран один: кнопка записи + список встреч. Всё в брендовой палитре
// (Brand.swift общий с мак-аппкой).

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var rec = Recorder()
    @AppStorage("macHost") private var macHost = ""
    @State private var showSettings = false
    @State private var states: [String: UploadState] = [:]
    @State private var micDenied = false

    var body: some View {
        ZStack {
            Color.brandCharcoal.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                recordBlock
                list
            }
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showSettings) { SettingsView(host: $macHost) }
        .alert("Нет доступа к микрофону", isPresented: $micDenied) {
            Button("Открыть настройки") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разреши Terminus микрофон — иначе записывать нечего.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 30)
            Text("TERMINUS")
                .font(.system(size: 17, weight: .heavy))
                .kerning(2)
                .foregroundStyle(Color.brandCream)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.brandCream.opacity(0.6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var recordBlock: some View {
        VStack(spacing: 14) {
            // Индикатор уровня — единственное доказательство, что микрофон
            // реально слышит; без него «пишет» видно только по таймеру.
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    Capsule()
                        .fill(Color.brandCream.opacity(rec.isRecording ? 0.85 : 0.15))
                        .frame(width: 3, height: barHeight(i))
                }
            }
            .frame(height: 34)
            .animation(.linear(duration: 0.12), value: rec.level)

            Text(rec.isRecording ? timeText(rec.elapsed) : "Готов к записи")
                .font(.system(size: rec.isRecording ? 34 : 15,
                              weight: rec.isRecording ? .bold : .regular,
                              design: rec.isRecording ? .monospaced : .default))
                .foregroundStyle(rec.isRecording ? Color.brandCream : Color.brandCream.opacity(0.55))
                .contentTransition(.numericText())

            Button(action: toggle) {
                Text(rec.isRecording ? "Остановить" : "Начать запись")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandProminentButtonStyle(outlined: rec.isRecording))
            .padding(.horizontal, 40)

            if let err = rec.lastError {
                Text(err).font(.caption)
                    .foregroundStyle(Color.brandOrange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.vertical, 18)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard rec.isRecording else { return 4 }
        // симметричная «волна» от центра, амплитуда — от живого уровня
        let center = abs(Double(i) - 11.5) / 11.5
        let amp = rec.level * (1 - center * 0.75)
        return 4 + CGFloat(amp) * 30
    }

    private var list: some View {
        Group {
            if store.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("Записей пока нет")
                        .font(.callout)
                        .foregroundStyle(Color.brandCream.opacity(0.4))
                    Spacer()
                }
            } else {
                List {
                    ForEach(store.sessions) { s in
                        row(s)
                            .listRowBackground(Color.brandCream.opacity(0.05))
                            .swipeActions {
                                Button(role: .destructive) { store.delete(s) } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ s: RecSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title)
                    .font(.callout)
                    .foregroundStyle(Color.brandCream)
                    .lineLimit(1)
                Text("\(dateText(s.started)) · \(s.durationText)")
                    .font(.caption2)
                    .foregroundStyle(Color.brandCream.opacity(0.45))
            }
            Spacer()
            statusView(s)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusView(_ s: RecSession) -> some View {
        switch states[s.id] ?? (s.uploaded ? .done : .idle) {
        case .idle:
            Button("На Мак") { send(s) }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.brandOrange)
        case .sending(let p):
            ProgressView(value: p).frame(width: 54).tint(Color.brandCream)
        case .done:
            Label("на Маке", systemImage: "checkmark")
                .font(.caption2)
                .foregroundStyle(Color.brandCream.opacity(0.5))
        case .failed(let msg):
            Button { send(s) } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("повторить").font(.caption.weight(.semibold))
                    Text(msg).font(.system(size: 9)).lineLimit(2)
                }
                .foregroundStyle(Color.brandOrange)
                .frame(maxWidth: 130, alignment: .trailing)
            }
        }
    }

    // MARK: - Действия

    private func toggle() {
        if rec.isRecording {
            guard let s = rec.stop() else { store.reload(); return }
            store.write(meta: s)
            store.reload()
            if !macHost.isEmpty { send(s) }      // Мак задан — отправляем сразу
        } else {
            rec.requestPermission { granted in
                guard granted else { micDenied = true; return }
                _ = rec.start(into: SessionStore.root)
            }
        }
    }

    private func send(_ s: RecSession) {
        guard !macHost.isEmpty else { showSettings = true; return }
        states[s.id] = .sending(0.05)
        Task {
            do {
                try await Uploader.upload(s, host: macHost) { p in
                    Task { @MainActor in states[s.id] = .sending(p) }
                }
                await MainActor.run {
                    states[s.id] = .done
                    store.markUploaded(s)
                }
            } catch {
                await MainActor.run { states[s.id] = .failed(error.localizedDescription) }
            }
        }
    }

    private func timeText(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }
}

struct SettingsView: View {
    @Binding var host: String
    @AppStorage("ownerName") private var ownerName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Мак с расшифровкой") {
                    TextField("mac.local или 192.168.1.5", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Запись уезжает на Мак, там её расшифровывает Terminus. "
                         + "Нужен один Wi-Fi и запущенный приёмник (ingest_server.py).")
                        .font(.caption)
                        .foregroundStyle(Color.brandCream.opacity(0.5))
                }
                Section("Ваше имя") {
                    TextField("как в библиотеке голосов", text: $ownerName)
                        .autocorrectionDisabled()
                    Text("По нему Мак узнаёт вас среди спикеров и подписывает "
                         + "реплики «Я». Пусто — все будут «Собеседник N».")
                        .font(.caption)
                        .foregroundStyle(Color.brandCream.opacity(0.5))
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .environment(\.colorScheme, .dark)
        .tint(Color.brandCream)
    }
}
