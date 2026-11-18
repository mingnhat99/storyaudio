import SwiftUI
import UniformTypeIdentifiers

/// Trang Giọng đọc & Model: chọn model/engine (tải / xóa / dùng), chọn giọng,
/// nghe thử, clone giọng từ file audio, xuất/nhập backup — tất cả trong một chỗ.
struct VoicesView: View {
    @EnvironmentObject var app: AppModel
    @State private var searchText = ""
    @State private var langFilter: String = "all"   // all | vi | en

    var filteredVoices: [VoiceItem] {
        var list = app.voices
        if langFilter != "all" {
            // giọng clone luôn hiện; preset lọc theo ngôn ngữ
            list = list.filter { $0.custom || $0.lang == langFilter }
        }
        if !searchText.isEmpty {
            list = list.filter {
                $0.label.localizedCaseInsensitiveContains(searchText)
                    || $0.id.localizedCaseInsensitiveContains(searchText)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Giọng đọc & Model").font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    if app.engineInfo.isEmpty {
                        Text(app.engineLoading ? "Đang nạp engine…" : "Engine chưa nạp — chọn model ở cột bên trái")
                            .foregroundStyle(DS.warning).font(.callout)
                    } else {
                        Text(app.engineInfo).foregroundStyle(.secondary).font(.callout)
                    }
                }
                Spacer()
                if app.voicesLoading { ProgressView().controlSize(.regular) }
                Button {
                    Task {
                        await app.refreshModels()
                        await app.refreshVoices()
                    }
                } label: {
                    Label("Làm mới", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.soft)
            }
            .padding(16)

            if app.store.settings.engine == .vieneu {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                    Text("VieNeu đọc tốt tiếng Việt và lẫn Anh–Việt. Sách thuần tiếng Anh nên dùng engine Kokoro (offline) hoặc giọng Edge (en-US, en-GB…) — chọn model tương ứng trong cột Model bên trái.")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .card(cornerRadius: 12)
            }

            HStack(alignment: .top, spacing: 0) {
                // Cột trái: model TTS (chọn engine + tải/xóa) + công cụ giọng
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(text: "Model TTS")
                        if app.catalog.isEmpty {
                            Text("Đang tải danh sách model…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(app.catalog) { model in
                            ModelRailCard(model: model)
                        }
                        Text("Cửa hàng model lấy từ catalog.json — mở rộng được sau.")
                            .font(.caption2).foregroundStyle(.tertiary)

                        Divider()

                        if app.supportsVoiceClone {
                            CloneVoiceCard()
                            VoiceBackupCard()
                        } else {
                            VoiceCloneUnavailableCard()
                        }
                    }
                    .padding(16)
                }
                .frame(width: 300)

                Divider()
                // Phần chính: danh sách giọng của model đang dùng
                VStack(spacing: 0) {
                    Picker("Ngôn ngữ", selection: $langFilter) {
                        Text("Tất cả").tag("all")
                        Text("Tiếng Việt").tag("vi")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    .frame(width: 300)
                    .padding(.horizontal, 16).padding(.top, 12)

                    List {
                        if !app.voices.filter(\.custom).isEmpty {
                            Section("Giọng đã clone") {
                                ForEach(app.voices.filter(\.custom)) { v in
                                    VoiceRow(voice: v)
                                }
                            }
                        }
                        Section("Giọng có sẵn") {
                            ForEach(filteredVoices.filter { !$0.custom }) { v in
                                VoiceRow(voice: v)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxWidth: .infinity)
                    .searchable(text: $searchText, prompt: "Tìm giọng…")
                }
            }
        }
    }
}

// MARK: - Model TTS (rail trái)

/// Card model dạng compact trong rail trái: trạng thái cài, tải/xóa,
/// và nút "Dùng" đổi engine sang model này ngay tại chỗ.
struct ModelRailCard: View {
    @EnvironmentObject var app: AppModel
    let model: CatalogModel
    @State private var confirmDelete = false

    var status: ModelStatus? { app.status(for: model.id) }
    var progress: DownloadProgress? { app.downloadProgress[model.id] }
    var isCurrent: Bool { app.currentModelId == model.id }

    /// Thông số rút gọn một dòng: dung lượng · RAM · chất lượng
    private var specsCaption: String {
        var parts: [String] = []
        if let mb = model.sizeMb, mb > 0 { parts.append("\(Int(mb)) MB") }
        if let ram = model.ramGb, ram > 0 { parts.append(String(format: "RAM ~%.1f GB", ram)) }
        if let q = model.quality { parts.append(q) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: status?.installed == true
                      ? "checkmark.seal.fill" : "arrow.down.circle")
                    .font(.system(size: 16, design: .rounded))
                    .foregroundStyle(status?.installed == true ? DS.success : DS.accent)
                Text(model.name)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if model.voiceClone == true || model.engineKind == .edge {
                HStack(spacing: 6) {
                    if model.voiceClone == true {
                        Label("Clone giọng", systemImage: "person.wave.2.fill")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(DS.accentDeep)
                            .background(DS.accentSoft, in: Capsule())
                    }
                    if model.engineKind == .edge {
                        Label("Online", systemImage: "wifi")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(DS.warning)
                            .background(DS.warning.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }

            if !specsCaption.isEmpty {
                Text(specsCaption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }

            if let p = progress, p.finished != true, status?.installed != true {
                DownloadProgressView(progress: p)
            } else if let s = status, s.partial {
                Text("Thiếu \(s.missing.count) file — tải lại để hoàn tất")
                    .font(.caption2).foregroundStyle(DS.warning)
            } else if let s = status, s.installed, s.sizeBytes > 0 {
                Text("Đã cài — \(formatBytes(s.sizeBytes))")
                    .font(.caption2).foregroundStyle(DS.success)
            }

            actionRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isCurrent ? DS.success.opacity(0.45)
                                        : (status?.installed == true ? DS.success.opacity(0.2) : .clear),
                              lineWidth: 1.5)
        )
        .help(model.description)
        .confirmationDialog("Xóa model khỏi máy?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Xóa \(model.name)", role: .destructive) {
                Task { await app.deleteModel(model.id) }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Giải phóng \(status.map { formatBytes($0.sizeBytes) } ?? "dung lượng"). Sách đã dựng không bị ảnh hưởng; tải lại được bất cứ lúc nào.")
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if progress != nil, progress?.cancelled != true {
                Button("Hủy tải") { app.cancelDownload(model.id) }
                    .buttonStyle(.softCompact)
            } else if model.noDownload == true || status?.installed == true {
                // pattern giống nút "Dùng" của VoiceRow: model hiện tại khoá lại
                Button(isCurrent ? "Đang dùng" : "Dùng") {
                    Task { await app.useModel(model) }
                }
                .buttonStyle(.softCompact)
                .disabled(isCurrent)
            } else {
                Button {
                    app.requestDownload(model)
                } label: {
                    Label(status?.partial == true ? "Tải tiếp phần còn thiếu" : "Tải về",
                          systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.primaryCompact)
            }
            Spacer(minLength: 0)
            if model.noDownload != true, status?.installed == true, progress == nil {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, design: .rounded))
                }
                .buttonStyle(.softDangerCompact)
                .help("Xóa model khỏi máy")
            }
        }
    }
}

struct VoiceRow: View {
    @EnvironmentObject var app: AppModel
    let voice: VoiceItem
    @State private var previewing = false
    @State private var hovered = false

    var isSelected: Bool {
        switch app.store.settings.engine {
        case .edge: return app.store.settings.edgeVoice == voice.id
        case .kokoro: return app.store.settings.kokoroVoice == voice.id
        case .vieneu: return app.store.settings.defaultVoice == voice.id
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    previewing = true
                    if let url = await app.previewVoice(voice) {
                        app.player.playURL(url)
                    }
                    previewing = false
                }
            } label: {
                if previewing || (app.voiceBusy && previewing) {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 18, design: .rounded))
                }
            }
            .buttonStyle(.link)
            .help("Nghe thử câu mẫu")

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.label)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .lineLimit(1)
                if voice.custom {
                    Text("Đã clone · lưu trong engine").font(.caption).foregroundStyle(.tint)
                } else if !voice.locale.isEmpty && voice.locale.hasPrefix("en-") {
                    Text("English · \(voice.locale)").font(.caption).foregroundStyle(DS.info)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, design: .rounded))
                    .foregroundStyle(DS.success)
                    .help("Đang chọn làm giọng mặc định")
            }
            Button(isSelected ? "Đang dùng" : "Dùng") {
                switch app.store.settings.engine {
                case .edge: app.store.settings.edgeVoice = voice.id
                case .kokoro: app.store.settings.kokoroVoice = voice.id
                case .vieneu: app.store.settings.defaultVoice = voice.id
                }
            }
            .buttonStyle(.softCompact)
            .disabled(isSelected)

            if voice.custom {
                Button(role: .destructive) {
                    Task { await app.deleteVoice(voice) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, design: .rounded))
                }
                .buttonStyle(.link)
                .help("Xóa giọng clone")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovered ? AnyShapeStyle(DS.accentSoft.opacity(0.6)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovered = $0 }
    }
}

// MARK: - Clone giọng

/// Model hiện tại không hỗ trợ clone (Edge/Kokoro) → ẩn tính năng, chỉ giải thích.
struct VoiceCloneUnavailableCard: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Không hỗ trợ clone giọng", systemImage: "info.circle")
                .font(.headline)
            Text(app.store.settings.engine == .kokoro
                 ? "Kokoro chỉ dùng được bộ giọng tiếng Anh có sẵn (~28 giọng). Muốn clone giọng từ file ghi âm, chọn model VieNeu (Nano/Turbo trong cột Model bên trái) rồi bấm \"Dùng\"."
                 : (app.store.settings.engine == .edge
                    ? "Edge-TTS chỉ có giọng Microsoft có sẵn. Muốn clone giọng từ file ghi âm, chọn model VieNeu (Nano/Turbo trong cột Model bên trái) rồi bấm \"Dùng\"."
                    : "Model đang chọn không hỗ trợ clone giọng. Chọn model VieNeu trong cột Model bên trái."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

struct CloneVoiceCard: View {
    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var refURL: URL?
    @State private var denoise = true
    @State private var dragging = false
    @State private var message: String?
    @State private var hasError = false
    @State private var filePickerShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clone giọng từ file audio", systemImage: "person.wave.2.fill")
                .font(.headline)
            Text("Chọn một đoạn ghi âm sạch 5–30 giây (wav/m4a/mp3). App sẽ khử ồn, học đặc trưng giọng và lưu lại dùng mãi.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Tên giọng:")
                TextField("vd: Giọng tôi", text: $name)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dragging ? AnyShapeStyle(DS.accentSoft)
                                   : AnyShapeStyle(DS.surfaceSecondary))
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(dragging ? DS.accent.opacity(0.5) : DS.hairline, lineWidth: 1.5)
                if let url = refURL {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform.circle.check").font(.title2)
                        Text(url.lastPathComponent).font(.caption).lineLimit(1)
                            .truncationMode(.middle)
                        Button("Đổi file khác") { filePickerShown = true }
                            .buttonStyle(.link).font(.caption)
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down").font(.title2)
                        Text("Kéo-thả file audio vào đây").font(.callout)
                        Button("hoặc chọn file…") { filePickerShown = true }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }
            .frame(height: 104)
            .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    DispatchQueue.main.async {
                        if let url { refURL = url; message = nil }
                    }
                }
                return true
            }
            .fileImporter(isPresented: $filePickerShown,
                          allowedContentTypes: [.audio, .wav, .mp3],
                          onCompletion: { r in
                              if case .success(let url) = r { refURL = url; message = nil }
                          })

            Toggle("Khử ồn file tham chiếu (nên bật)", isOn: $denoise)
                .controlSize(.regular)

            Button {
                Task {
                    message = "Đang enroll giọng… (vài giây)"
                    hasError = false
                    do {
                        try await app.cloneVoice(name: name, refURL: refURL!, denoise: denoise)
                        message = "Đã clone giọng '\(name)' — thấy trong danh sách bên trái."
                        name = ""
                        refURL = nil
                    } catch {
                        message = error.localizedDescription
                        hasError = true
                    }
                }
            } label: {
                Label("Clone giọng", systemImage: "wand.and.stars")
            }
            .buttonStyle(.primary)
            .disabled(name.isEmpty || refURL == nil || app.voiceBusy)

            if let m = message {
                Text(m).font(.footnote).foregroundStyle(hasError ? DS.danger : DS.success)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
    }
}

// MARK: - Backup giọng

struct VoiceBackupCard: View {
    @EnvironmentObject var app: AppModel
    @State private var exportPicker = false
    @State private var importPicker = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sao lưu giọng clone", systemImage: "externaldrive.badge.timemachine")
                .font(.headline)
            Text("Xuất giọng đã clone ra file JSON để chuyển máy / dự phòng (file backup tạo trước đây bằng nút này nhập lại được bình thường).")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Xuất backup…") { exportPicker = true }
                    .buttonStyle(.soft)
                Button("Nhập backup…") { importPicker = true }
                    .buttonStyle(.soft)
            }
            if let n = note {
                Text(n).font(.footnote).foregroundStyle(DS.success)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(cornerRadius: 16)
        .fileExporter(isPresented: $exportPicker,
                      document: JSONBackupDocument(),
                      contentType: .json,
                      defaultFilename: "storyaudio-voices-backup.json") { result in
            if case .success(let url) = result {
                Task {
                    await app.exportVoices(to: url)
                    note = "Đã xuất: \(url.lastPathComponent)"
                }
            }
        }
        .fileImporter(isPresented: $importPicker, allowedContentTypes: [.json]) { r in
            if case .success(let url) = r {
                Task {
                    await app.importVoices(from: url)
                    note = "Đã nhập giọng từ \(url.lastPathComponent)"
                }
            }
        }
    }
}

struct JSONBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data("{}".utf8))
    }
}
