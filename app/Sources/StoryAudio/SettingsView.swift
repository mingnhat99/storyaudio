import SwiftUI

/// Tab Cài đặt: engine, xuất file, quy tắc text, nâng cao.
/// (Model TTS đã chuyển sang trang "Giọng đọc & Model" ở sidebar.)
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var store = Store.shared
    @State private var showUninstaller = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Phần", selection: $app.selectedSettingsTab) {
                Label("Engine & Xuất", systemImage: "slider.horizontal.3").tag(0)
                Label("Quy tắc text", systemImage: "text.badge.replace").tag(1)
                Label("Nâng cao", systemImage: "wrench.and.screwdriver").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            .frame(maxWidth: 680)

            switch app.selectedSettingsTab {
            case 0:
                Form {
                    engineSection
                    outputSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .controlSize(.large)
            case 1:
                RulesSettingsView()
            default:
                Form { advancedSection }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .controlSize(.large)
            }
        }
        .sheet(isPresented: $showUninstaller) {
            UninstallerView().environmentObject(app)
        }
    }

    // MARK: Engine

    @ViewBuilder
    private var engineSection: some View {
        Section("Engine TTS") {
            Picker("Engine", selection: Binding(
                get: { store.settings.engine },
                set: { newValue in
                    store.settings.engine = newValue
                    Task { await app.loadEngine(); await app.refreshVoices() }
                })) {
                ForEach(availableEngines, id: \.self) { e in
                    Text(e.label).tag(e)
                }
            }
            if store.settings.engine == .vieneu {
                Picker("Model", selection: Binding(
                    get: { store.settings.mode },
                    set: { newValue in
                        store.settings.mode = newValue
                        Task { await app.loadEngine(); await app.refreshVoices() }
                    })) {
                    Text("VieNeu v3-Turbo (48kHz, tốt nhất)").tag("v3turbo")
                    if app.status(for: "vieneu-nano")?.installed == true ||
                        store.settings.mode == "v3nano" {
                        Text("VieNeu v3-Nano (nhẹ máy)").tag("v3nano")
                    }
                }
            }
            if !app.sysinfoNote.isEmpty {
                Text(app.sysinfoNote).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Tự dò cấu hình máy khi khởi động", isOn: Binding(
                get: { store.settings.autoHardwarePreset },
                set: { store.settings.autoHardwarePreset = $0 }))
            Stepper("Số thread CPU: \(store.settings.threads)",
                    value: Binding(get: { store.settings.threads },
                                   set: { store.settings.threads = $0 }), in: 0...8)
            if store.settings.threads == 0 {
                Text("0 = engine tự chọn số thread theo máy")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Ký tự mỗi đoạn: \(store.settings.partChars)",
                    value: Binding(get: { store.settings.partChars },
                                   set: { store.settings.partChars = $0 }),
                    in: 1000...12000, step: 500)
            HStack {
                Slider(value: Binding(get: { store.settings.silenceSec },
                                      set: { store.settings.silenceSec = $0 }),
                       in: 0...2, step: 0.1)
                Text(String(format: "Nghỉ giữa đoạn: %.1fs", store.settings.silenceSec))
                    .monospacedDigit().frame(width: 150, alignment: .leading)
            }
            Button("Áp dụng lại preset tự dò theo máy") {
                Task { await app.applyHardwarePresetAgain() }
            }
            .buttonStyle(.soft)
            if (store.settings.engine == .vieneu && store.settings.mode == "v3nano")
                || store.settings.engine == .kokoro {
                HStack {
                    Slider(value: Binding(get: { store.settings.sampling.speed },
                                          set: { store.settings.sampling.speed = $0 }),
                           in: 0.7...1.5, step: 0.05)
                    Text(String(format: "Tốc độ đọc khi dựng: %.2fx", store.settings.sampling.speed))
                        .monospacedDigit().frame(width: 220, alignment: .leading)
                }
            }
            if store.settings.engine == .edge {
                HStack {
                    Slider(value: Binding(get: { Double(store.settings.sampling.ratePct) },
                                          set: { store.settings.sampling.ratePct = Int($0) }),
                           in: -50...100, step: 5)
                    Text("Tốc độ Edge: \(store.settings.sampling.ratePct > 0 ? "+" : "")\(store.settings.sampling.ratePct)%")
                        .monospacedDigit().frame(width: 180, alignment: .leading)
                }
            }
        }

        Section("Giọng mặc định") {
            switch store.settings.engine {
            case .vieneu:
                Picker("Giọng VieNeu", selection: Binding(
                    get: { store.settings.defaultVoice },
                    set: { store.settings.defaultVoice = $0 })) {
                    Text("— chọn giọng trong tab Giọng đọc —").tag("")
                    ForEach(app.voices.filter { !$0.custom || $0.engine == "vieneu" }) { v in
                        Text(v.label).tag(v.id)
                    }
                }
            case .kokoro:
                Picker("Giọng Kokoro (Anh)", selection: Binding(
                    get: { store.settings.kokoroVoice },
                    set: { store.settings.kokoroVoice = $0 })) {
                    ForEach(app.voices.filter { $0.engine == "kokoro" }) { v in
                        Text(v.label).tag(v.id)
                    }
                }
            case .edge:
                Picker("Giọng Edge", selection: Binding(
                    get: { store.settings.edgeVoice },
                    set: { store.settings.edgeVoice = $0 })) {
                    ForEach(app.voices.filter { $0.engine == "edge" }) { v in
                        Text(v.label).tag(v.id)
                    }
                }
            }
        }
    }

    private var availableEngines: [EngineKind] {
        var out: [EngineKind] = [.vieneu, .kokoro, .edge]
        // chỉ hiện engine có model đã cài
        let hasVieneu = app.modelStatuses.contains {
            $0.installed && $0.id.hasPrefix("vieneu")
        }
        if !hasVieneu && store.settings.engine != .vieneu {
            out.removeAll { $0 == .vieneu }
        }
        if app.status(for: "kokoro-en")?.installed != true && store.settings.engine != .kokoro {
            out.removeAll { $0 == .kokoro }
        }
        return out
    }

    // MARK: Xuất file

    @ViewBuilder
    private var outputSection: some View {
        Section("Xuất file audio") {
            Picker("Định dạng", selection: Binding(
                get: { store.settings.outFormat },
                set: { store.settings.outFormat = $0 })) {
                Text("M4A (AAC — nhỏ, tốt)").tag("m4a")
                Text("MP3 (tương thích rộng)").tag("mp3")
                Text("WAV (không nén)").tag("wav")
            }
            outDirRow
            TextField("Mẫu tên file", text: Binding(
                get: { store.settings.namePattern },
                set: { store.settings.namePattern = $0 }))
            Text("Biến: {book} {index} {index:02d} {title}")
                .font(.caption).foregroundStyle(.tertiary)
            Toggle("Tự xóa file đoạn trung gian sau khi xong (tiết kiệm đĩa)",
                   isOn: Binding(get: { store.settings.cleanupParts },
                                 set: { store.settings.cleanupParts = $0 }))
            Toggle("Nghe dần trong khi dựng (phát từng đoạn đã xong)",
                   isOn: Binding(get: { store.settings.progressiveListen },
                                 set: { store.settings.progressiveListen = $0 }))
            Text("Đoạn đầu nhỏ dần để bật nghe nhanh (~30–60s tùy máy); nghe xong đoạn nào " +
                 "worker dựng tiếp đoạn đó. Nghe nhanh hơn tốc độ dựng sẽ tự chờ ở đoạn tiếp.")
                .font(.caption).foregroundStyle(.tertiary)
            Toggle("Mở thư mục audio khi hoàn tất hàng đợi",
                   isOn: Binding(get: { store.settings.openFolderWhenDone },
                                 set: { store.settings.openFolderWhenDone = $0 }))
        }
    }

    /// Hàng chọn thư mục lưu audio: path đang dùng + chọn bằng panel / mở / về mặc định.
    private var outDirRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.accentDeep)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                Text("Thư mục lưu audio")
                Text(store.settings.outDir)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy đường dẫn") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.settings.outDir, forType: .string)
                        }
                        Button("Mở trong Finder") { openOutFolder() }
                    }
                Text(outDirStatusText)
                    .font(.caption2)
                    .foregroundStyle(outDirWritable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DS.warning))
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Chọn thư mục…") { chooseOutFolder() }
                    .buttonStyle(.softCompact)
                Button("Mở") { openOutFolder() }
                    .buttonStyle(.softCompact)
                    .disabled(!outDirWritable)
                if !store.settings.outDirPath.isEmpty {
                    Button("Về mặc định") { store.settings.outDirPath = "" }
                        .buttonStyle(.softCompact)
                }
            }
        }
        .help(store.settings.outDir)
    }

    private var outDirStatusText: String {
        if !outDirWritable {
            return "Không ghi được vào thư mục này — audio sẽ lỗi khi dựng."
        }
        return store.settings.outDirPath.isEmpty
            ? "Mặc định: thư mục “output” trong thư mục làm việc"
            : "Thư mục tùy chọn — file dựng sau này lưu vào đây."
    }

    /// Thư mục (hoặc tổ tiên gần nhất đang tồn tại) có ghi được không —
    /// output/ chưa tạo lần nào thì kiểm tra thư mục cha.
    private var outDirWritable: Bool {
        var dir = URL(fileURLWithPath: store.settings.outDir)
        let fm = FileManager.default
        if store.settings.outDirPath.isEmpty && store.settings.workspacePath.isEmpty {
            return true   // chưa onboard — không cần cảnh báo
        }
        while !fm.fileExists(atPath: dir.path) && dir.path != "/" {
            dir.deleteLastPathComponent()
        }
        return fm.isWritableFile(atPath: dir.path)
    }

    private func chooseOutFolder() {
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục lưu audio"
        panel.message = "File audio dựng xong sẽ được lưu vào thư mục này."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.settings.outDir)
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.outDirPath = url.path
        }
    }

    private func openOutFolder() {
        let url = URL(fileURLWithPath: store.settings.outDir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: Nâng cao

    @ViewBuilder
    private var advancedSection: some View {
        Section("Tham số sinh audio (VieNeu)") {
            HStack {
                Slider(value: Binding(get: { store.settings.sampling.temperature },
                                      set: { store.settings.sampling.temperature = $0 }),
                       in: 0.1...1.5, step: 0.05)
                Text(String(format: "Temperature: %.2f", store.settings.sampling.temperature))
                    .monospacedDigit().frame(width: 170, alignment: .leading)
            }
            HStack {
                Slider(value: Binding(get: { Double(store.settings.sampling.topK) },
                                      set: { store.settings.sampling.topK = Int($0) }),
                       in: 5...100, step: 5)
                Text("Top-K: \(store.settings.sampling.topK)")
                    .monospacedDigit().frame(width: 170, alignment: .leading)
            }
            HStack {
                Slider(value: Binding(get: { store.settings.sampling.repetitionPenalty },
                                      set: { store.settings.sampling.repetitionPenalty = $0 }),
                       in: 1.0...1.6, step: 0.05)
                Text(String(format: "Phạt lặp: %.2f", store.settings.sampling.repetitionPenalty))
                    .monospacedDigit().frame(width: 170, alignment: .leading)
            }
            if store.settings.mode == "v3nano" {
                Stepper("Số bước nano: \(store.settings.sampling.steps)",
                        value: Binding(get: { store.settings.sampling.steps },
                                       set: { store.settings.sampling.steps = $0 }),
                        in: 8...32)
            }
        }
        Section("Worker & mạng") {
            Toggle("Khởi động lại worker sau mỗi chương (giải phóng RAM)",
                   isOn: Binding(get: { store.settings.restartWorkerBetweenChapters },
                                 set: { store.settings.restartWorkerBetweenChapters = $0 }))
            HStack {
                TextField("Mirror Hugging Face", text: Binding(
                    get: { store.settings.hfMirror },
                    set: { store.settings.hfMirror = $0 }))
                Text("rỗng = HF chính thức").font(.caption).foregroundStyle(.tertiary)
            }
            Text("Mirror có hiệu lực sau khi khởi động lại worker. Ví dụ: https://hf-mirror.com")
                .font(.caption).foregroundStyle(.tertiary)
            Button("Khởi động lại worker ngay") {
                Task { await app.restartWorkerKeepStatePublic() }
            }
            .buttonStyle(.soft)
        }
        Section("Dữ liệu") {
            LabeledContent("Thư mục làm việc") {
                Text(store.settings.workspacePath).font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Vị trí lưu app data") {
                Text(store.supportDir.path).font(.system(.caption, design: .monospaced))
            }
            HStack {
                Button(role: .destructive) {
                    showUninstaller = true
                } label: {
                    Label("Gỡ cài đặt StoryAudio…", systemImage: "trash")
                }
                .buttonStyle(.softDanger)
                Spacer()
                Text("hoặc chạy ./uninstall.sh từ terminal").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Quy tắc text

struct RulesSettingsView: View {
    @ObservedObject private var store = Store.shared
    @State private var find = ""
    @State private var replace = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quy tắc tìm–thay thế").font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    Text("Áp dụng cho mọi sách trước khi dựng audio — hữu ích để sửa tên riêng, từ cứng, chữ Hán–Việt.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(16)
            Form {
                Section("Thêm quy tắc") {
                    TextField("Tìm", text: $find)
                    TextField("Thay bằng", text: $replace)
                    Button("Thêm quy tắc") {
                        guard !find.isEmpty else { return }
                        store.settings.globalRules.append(
                            TextRule(find: find, replace: replace))
                        find = ""
                        replace = ""
                    }
                    .buttonStyle(.primary)
                    .disabled(find.isEmpty)
                }
                if store.settings.globalRules.isEmpty {
                    Section {
                        Text("Chưa có quy tắc nào.").foregroundStyle(.secondary)
                    }
                } else {
                    Section("Danh sách (áp dụng theo thứ tự)") {
                        ForEach($store.settings.globalRules) { $rule in
                            HStack {
                                TextField("Tìm", text: $rule.find)
                                Image(systemName: "arrow.right")
                                TextField("Thay", text: $rule.replace)
                                Toggle("Regex", isOn: $rule.isRegex)
                                    .controlSize(.regular)
                                Button {
                                    store.settings.globalRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 15, design: .rounded))
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .onMove { from, to in
                            store.settings.globalRules.move(fromOffsets: from, toOffset: to)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .controlSize(.large)
        }
    }
}
