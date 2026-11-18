import SwiftUI

/// Chi tiết sách: danh sách chương, chọn chương để dựng audio, phát, sửa tên/bỏ qua.
struct BookDetailView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: Store
    let book: Book
    @State private var selection: Set<Int> = []
    @State private var renamingChapter: Chapter?
    @State private var renameText = ""

    var renderableChapters: [Chapter] {
        book.manifest.chapters.filter {
            book.audioPath(for: $0) == nil && !store.meta(for: book.id).skippedChapters.contains($0.index)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            chapterTable
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let cover = book.coverURL, let img = NSImage(contentsOf: cover) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "book.closed").font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 84, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(book.title).font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    Text(languageLabel)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(languageColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(languageColor)
                }
                HStack(spacing: 10) {
                    if !book.author.isEmpty { Text(book.author) }
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(book.manifest.chapters.count) chương")
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(book.manifest.chapters.reduce(0) { $0 + $1.chars }) ký tự")
                }
                .font(.body).foregroundStyle(.secondary)

                progressRow

                if app.shouldSuggestEnglishVoice {
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.max")
                            .foregroundStyle(DS.warning)
                        Text(app.status(for: "kokoro-en")?.installed == true
                             ? "Sách tiếng Anh: giọng Kokoro (offline) tự nhiên hơn cho sách thuần Anh."
                             : "Sách tiếng Anh: giọng Edge (en-US) tự nhiên hơn cho sách thuần Anh.")
                            .font(.footnote)
                        Button("Chuyển sang giọng Anh") {
                            Task { await app.switchToEnglishVoice() }
                        }
                        .buttonStyle(.link)
                    }
                    .padding(8)
                    .card(cornerRadius: 10)
                }

                HStack(spacing: 12) {
                    Button {
                        app.player.playChapter(book: book,
                                               chapters: book.manifest.chapters,
                                               startAt: book.manifest.chapters.first?.index ?? 1)
                    } label: {
                        Label("Nghe", systemImage: "play.fill")
                    }
                    .buttonStyle(.primary)
                    .disabled(book.manifest.chapters.compactMap { book.audioPath(for: $0) }.isEmpty)
                    if let job = liveListeningJob, let ch = liveListeningChapter {
                        Button {
                            app.startLiveListening(book: book, chapter: ch)
                        } label: {
                            Label("Nghe dần: \(job.chapterTitle)", systemImage: "play.circle.dotted")
                        }
                        .buttonStyle(.soft)
                        .help("Nghe luôn những đoạn đã dựng xong của chương đang render")
                    }
                    Button {
                        selection = Set(renderableChapters.map(\.index))
                        app.enqueueChapters(book, indices: selection.sorted())
                        selection = []
                    } label: {
                        Label(renderableChapters.isEmpty
                              ? "Đã dựng đủ chương"
                              : "Dựng \(renderableChapters.count) chương còn thiếu",
                              systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.soft)
                    .disabled(renderableChapters.isEmpty)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                engineChip
                voiceChip
            }
        }
        .padding(18)
    }

    /// Job đang dựng chapter chưa có audio cuối → có thể "Nghe dần" ngay.
    private var liveListeningJob: RenderJob? {
        app.jobs.first { j in
            j.bookId == book.id && j.state == .rendering
                && book.manifest.chapters.first(where: { $0.index == j.chapterIndex })
                    .flatMap { book.audioPath(for: $0) } == nil
        }
    }

    private var liveListeningChapter: Chapter? {
        liveListeningJob.flatMap { job in
            book.manifest.chapters.first(where: { $0.index == job.chapterIndex })
        }
    }

    private var progressRow: some View {
        let done = book.manifest.chapters.filter { book.audioPath(for: $0) != nil }.count
        let total = book.manifest.chapters.count
        return HStack(spacing: 10) {
            ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                .frame(width: 190)
                .tint(done == total && total > 0 ? DS.success : DS.accent)
            Text("\(done)/\(total) chương có audio")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var languageLabel: String {
        switch book.manifest.language {
        case "en": return "English"
        case "zh": return "中文"
        default: return "Tiếng Việt"
        }
    }

    private var languageColor: Color {
        switch book.manifest.language {
        case "en": return DS.info
        case "zh": return DS.plum
        default: return DS.success
        }
    }

    private var engineChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "cpu")
            if app.engineLoading {
                ProgressView().controlSize(.mini)
                Text("Đang nạp engine…")
            } else if app.engineInfo.isEmpty {
                Text("Chưa nạp engine").foregroundStyle(DS.warning)
            } else {
                Text(app.engineInfo)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .chip()
    }

    private var voiceChip: some View {
        let current: String
        switch app.store.settings.engine {
        case .edge: current = app.store.settings.edgeVoice
        case .kokoro: current = app.store.settings.kokoroVoice
        case .vieneu: current = app.store.settings.defaultVoice
        }
        return Menu {
            ForEach(app.voices) { v in
                Button {
                    switch app.store.settings.engine {
                    case .edge: app.store.settings.edgeVoice = v.id
                    case .kokoro: app.store.settings.kokoroVoice = v.id
                    case .vieneu: app.store.settings.defaultVoice = v.id
                    }
                } label: {
                    if v.id == current {
                        Label(v.label, systemImage: "checkmark")
                    } else { Text(v.label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2")
                Text(current.isEmpty ? "Chọn giọng" : current)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .chip()
        }
        .menuStyle(.borderlessButton)
        // fixedSize ép Menu ôm sát chip — không thì nó giãn chiếm hết chỗ trống
        // quanh đó (vùng bấm tràn ra ngoài icon).
        .fixedSize()
        .task { if app.voices.isEmpty { await app.refreshVoices() } }
    }

    private var chapterTable: some View {
        Table(book.manifest.chapters, selection: $selection) {
            TableColumn("Chương") { ch in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: ch)).foregroundStyle(iconColor(for: ch))
                        .imageScale(.medium)
                    Text(book.chapterTitle(ch))
                        .font(.system(size: 13.5, design: .rounded))
                        .lineLimit(1)
                }
                .padding(.vertical, 4)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Ký tự") { ch in
                Text("\(ch.chars)").monospacedDigit().foregroundStyle(.secondary)
                    .font(.system(size: 12.5, design: .rounded))
                    .padding(.vertical, 4)
            }
            TableColumn("Audio") { ch in
                if let url = book.audioPath(for: ch) {
                    HStack(spacing: 6) {
                        Button {
                            app.player.playChapter(book: book,
                                                   chapters: book.manifest.chapters,
                                                   startAt: ch.index)
                        } label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 16, design: .rounded))
                        }
                        .buttonStyle(.link)
                        .help("Phát chương này")
                        Button {
                            app.revealInFinder([url])
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 14, design: .rounded))
                        }
                        .buttonStyle(.link)
                        .help("Mở file audio trong Finder")
                        Text(URL(fileURLWithPath: url.path).lastPathComponent)
                            .font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 4)
                } else if let job = app.liveJob(for: book, chapter: ch) {
                    Button {
                        app.startLiveListening(book: book, chapter: ch)
                    } label: {
                        Label("Nghe dần", systemImage: "play.circle.dotted")
                            .font(.footnote)
                    }
                    .buttonStyle(.link)
                    .help(job.state == .rendering
                          ? "Nghe luôn phần đã dựng xong" : "Đưa chương lên đầu hàng đợi và nghe dần")
                    .padding(.vertical, 4)
                } else if store.meta(for: book.id).skippedChapters.contains(ch.index) {
                    Text("Bỏ qua").font(.footnote).foregroundStyle(.tertiary)
                }
            }
        }
        .contextMenu(forSelectionType: Int.self) { indices in
            if indices.count == 1,
               let ch = book.manifest.chapters.first(where: { $0.index == indices.first! }) {
                Button("Đổi tên chương…") {
                    renamingChapter = ch
                    renameText = book.chapterTitle(ch)
                }
                Button(store.meta(for: book.id).skippedChapters.contains(ch.index)
                       ? "Bỏ đánh dấu bỏ qua" : "Bỏ qua chương này") {
                    app.toggleSkipChapter(book, ch.index)
                }
                if let url = book.audioPath(for: ch) {
                    Button("Mở file audio trong Finder") {
                        app.revealInFinder([url])
                    }
                    Button("Dựng lại chương này") {
                        app.enqueueChapters(book, indices: [ch.index])
                    }
                } else {
                    Button("Dựng chương này") {
                        app.enqueueChapters(book, indices: [ch.index])
                    }
                }
            } else if indices.count > 1 {
                Button("Dựng \(indices.count) chương đã chọn") {
                    app.enqueueChapters(book, indices: indices.sorted())
                }
            }
        } primaryAction: { indices in
            // double-click: phát chương có audio
            if indices.count == 1,
               let ch = book.manifest.chapters.first(where: { $0.index == indices.first! }),
               book.audioPath(for: ch) != nil {
                app.player.playChapter(book: book, chapters: book.manifest.chapters,
                                      startAt: ch.index)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                app.enqueueChapters(book, indices: selection.sorted())
                selection = []
            } label: {
                Label("Dựng \(selection.count) chương đã chọn", systemImage: "waveform")
            }
            .buttonStyle(.primary)
            .disabled(selection.isEmpty)
            Spacer()
            if let ch = renamingChapter {
                HStack {
                    TextField("Tên chương", text: $renameText)
                        .frame(width: 260)
                    Button("Lưu") {
                        app.renameChapter(book, ch.index, newTitle: renameText)
                        renamingChapter = nil
                    }
                    .buttonStyle(.primaryCompact)
                    Button("Hủy") { renamingChapter = nil }.buttonStyle(.link)
                }
            }
        }
        .padding(14)
    }

    private func icon(for ch: Chapter) -> String {
        if book.audioPath(for: ch) != nil { return "checkmark.circle.fill" }
        if store.meta(for: book.id).skippedChapters.contains(ch.index) { return "minus.circle" }
        return "circle.dotted"
    }

    private func iconColor(for ch: Chapter) -> Color {
        if book.audioPath(for: ch) != nil { return DS.success }
        if store.meta(for: book.id).skippedChapters.contains(ch.index) { return .secondary }
        return .secondary.opacity(0.6)
    }
}
