import SwiftUI
import AVFoundation

// MARK: - Mục audio

/// Một file audio đã dựng: liên kết với chương của sách, hoặc rời rạc
/// trong thư mục output (đổi name pattern, các lần chạy cũ…).
struct AudioItem: Identifiable, Equatable, Hashable {
    var url: URL
    var bookId: String?
    var bookTitle: String = ""          // rỗng = file rời rạc không thuộc sách nào
    var chapterIndex: Int = 0
    var chapterTitle: String = ""
    var fileExt: String = ""
    var fileSize: Int64 = 0
    var createdAt: Date = .distantPast
    var duration: Double = 0            // 0 = chưa đo xong

    var id: String { url.path }
    var isLinked: Bool { bookId != nil }
    var displayName: String {
        chapterTitle.isEmpty ? url.deletingPathExtension().lastPathComponent : chapterTitle
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url.path) }
}

// MARK: - Nguồn dữ liệu

/// Gộp audioPaths của các sách + quét file rời rạc trong thư mục output,
/// đo thời lượng từng file ở nền (không chặn UI).
@MainActor
final class AudioLibraryModel: ObservableObject {
    @Published var items: [AudioItem] = []
    @Published var searchText = ""
    @Published var bookFilter: String?      // bookId; nil = tất cả

    private let store = Store.shared
    private var durationTask: Task<Void, Never>?
    /// Path vừa xóa — giấu khỏi danh sách tới khi Thùng rác xử lý xong,
    /// tránh file lóe lên lại lúc quét lại ngay sau delete.
    private var suppressed = Set<String>()

    static let audioExts: Set<String> = ["m4a", "mp3", "wav", "aac", "flac", "ogg"]

    struct BookChoice: Identifiable, Equatable {
        let id: String      // bookId
        let title: String
    }

    var bookChoices: [BookChoice] {
        var seen = Set<String>()
        var out: [BookChoice] = []
        for it in items where it.isLinked && seen.insert(it.bookId!).inserted {
            out.append(BookChoice(id: it.bookId!, title: it.bookTitle))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var filtered: [AudioItem] {
        var out = items
        if let f = bookFilter { out = out.filter { $0.bookId == f } }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter {
                $0.displayName.localizedCaseInsensitiveContains(q)
                    || $0.bookTitle.localizedCaseInsensitiveContains(q)
                    || $0.url.lastPathComponent.localizedCaseInsensitiveContains(q)
            }
        }
        return out
    }

    var totalFiles: Int { items.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.fileSize } }
    var totalDuration: Double { items.reduce(0) { $0 + $1.duration } }

    /// Quét lại toàn bộ file audio. `clearSuppression` = bỏ qua danh sách
    /// path vừa xóa (dùng cho nút Làm mới — hiển thị đúng sự thật trên đĩa).
    func refresh(books: [Book], outDir: String, clearSuppression: Bool = false) {
        durationTask?.cancel()
        if clearSuppression { suppressed.removeAll() }

        let prevDurations = Dictionary(
            uniqueKeysWithValues: items.filter { $0.duration > 0 }.map { ($0.url.path, $0.duration) })

        var out: [AudioItem] = []
        var knownPaths = Set<String>()

        // 1) File liên kết chương sách qua meta
        for book in books {
            for (idx, path) in store.meta(for: book.id).audioPaths.sorted(by: { $0.key < $1.key }) {
                guard FileManager.default.fileExists(atPath: path),
                      !suppressed.contains(path) else { continue }
                knownPaths.insert(path)
                let ch = book.manifest.chapters.first(where: { $0.index == idx })
                var item = Self.makeItem(
                    url: URL(fileURLWithPath: path), bookId: book.id, bookTitle: book.title,
                    chapterIndex: idx,
                    chapterTitle: ch.map { book.chapterTitle($0) } ?? "Chương \(idx)")
                item.duration = prevDurations[item.url.path] ?? 0
                out.append(item)
            }
        }

        // 2) File audio trong output chưa liên kết chương nào
        let outDirURL = URL(fileURLWithPath: outDir)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: outDirURL.path) {
            for name in names.sorted() {
                let ext = (name as NSString).pathExtension.lowercased()
                guard Self.audioExts.contains(ext) else { continue }
                let url = outDirURL.appendingPathComponent(name)
                guard !knownPaths.contains(url.path), !suppressed.contains(url.path) else { continue }
                var item = Self.makeItem(url: url, bookId: nil, bookTitle: "",
                                         chapterIndex: 0, chapterTitle: "")
                item.duration = prevDurations[item.url.path] ?? 0
                out.append(item)
            }
        }

        items = out
        if bookFilter != nil, !out.contains(where: { $0.bookId == bookFilter }) {
            bookFilter = nil
        }
        loadDurations()
    }

    private static func makeItem(url: URL, bookId: String?, bookTitle: String,
                                 chapterIndex: Int, chapterTitle: String) -> AudioItem {
        var size: Int64 = 0
        var created = Date.distantPast
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            created = (attrs[.creationDate] as? Date)
                ?? (attrs[.modificationDate] as? Date)
                ?? .distantPast
        }
        return AudioItem(url: url, bookId: bookId, bookTitle: bookTitle,
                         chapterIndex: chapterIndex, chapterTitle: chapterTitle,
                         fileExt: url.pathExtension.lowercased(),
                         fileSize: size, createdAt: created)
    }

    // MARK: Đo thời lượng (nền, giới hạn 6 file song song)

    private func loadDurations() {
        let pending = items.filter { $0.duration <= 0 }
        guard !pending.isEmpty else { return }
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            await withTaskGroup(of: (String, Double)?.self) { group in
                var iter = pending.makeIterator()
                for _ in 0..<6 {
                    guard let it = iter.next() else { break }
                    group.addTask { await Self.measureDuration(it.url) }
                }
                for await result in group {
                    if Task.isCancelled { break }
                    guard let self, let (path, d) = result else { continue }
                    self.setDuration(path: path, seconds: d)
                    if let next = iter.next() {
                        group.addTask { await Self.measureDuration(next.url) }
                    }
                }
            }
        }
    }

    private static func measureDuration(_ url: URL) async -> (String, Double)? {
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration) else { return nil }
        let d = dur.seconds
        guard d.isFinite, d > 0 else { return nil }
        return (url.path, d)
    }

    private func setDuration(path: String, seconds: Double) {
        guard let idx = items.firstIndex(where: { $0.url.path == path }) else { return }
        items[idx].duration = seconds
    }

    func applySort(_ order: [KeyPathComparator<AudioItem>]) {
        guard !order.isEmpty else { return }
        items.sort(using: order)
    }

    func suppress(paths: [String]) {
        suppressed.formUnion(paths)
        items.removeAll { suppressed.contains($0.url.path) }
    }

    deinit { durationTask?.cancel() }
}

// MARK: - Màn "Audio đã tạo"

/// Tab quản lý audio: liệt kê mọi file đã dựng (kèm file rời rạc trong output),
/// tìm kiếm/lọc theo sách, phát, mở trong Finder, xóa vào Thùng rác.
struct AudioLibraryView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = AudioLibraryModel()
    @State private var sortOrder: [KeyPathComparator<AudioItem>] = []
    @State private var selection = Set<AudioItem.ID>()
    @State private var pendingDelete: [AudioItem]?

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .task { refresh() }
        .confirmationDialog(
            "Chuyển \(pendingDelete?.count ?? 0) file audio vào Thùng rác?",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Chuyển vào Thùng rác", role: .destructive) {
                deletePending()
            }
            Button("Hủy", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Chương tương ứng sẽ chuyển về trạng thái chưa dựng. File vẫn lấy lại được từ Thùng rác.")
        }
    }

    private func refresh(clearSuppression: Bool = false) {
        model.refresh(books: app.books, outDir: app.settings.outDir,
                      clearSuppression: clearSuppression)
        model.applySort(sortOrder)
    }

    private func deletePending() {
        guard let items = pendingDelete else { return }
        app.deleteAudioFiles(items)
        model.suppress(paths: items.map(\.url.path))
        pendingDelete = nil
        selection = []
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audio đã tạo")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.ink)
                Text("\(model.totalFiles) file · \(formatBytes(model.totalBytes))"
                     + " · ~\(formatClock(model.totalDuration)) nghe")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            searchField
            bookFilterMenu
            Button {
                refresh(clearSuppression: true)
            } label: {
                Label("Làm mới", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.soft)
            .help("Quét lại thư mục output")
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: app.settings.outDir))
            } label: {
                Label("Thư mục", systemImage: "folder")
            }
            .buttonStyle(.soft)
            .help(app.settings.outDir)
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
            TextField("Tìm file, chương, sách…", text: $model.searchText)
                .textFieldStyle(.plain)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.link)
                .help("Xóa bộ lọc")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(DS.surfaceSecondary))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.hairline))
        // Nở theo chỗ trống của header (tối đa 380pt) nhưng không đè lên
        // khối tiêu đề khi cửa sổ hẹp — tối thiểu giữ 230pt như cũ.
        .frame(minWidth: 230, maxWidth: 380)
    }

    private var bookFilterMenu: some View {
        let current = model.bookChoices.first { $0.id == model.bookFilter }
        return Menu {
            Button("Tất cả sách") { model.bookFilter = nil }
            ForEach(model.bookChoices) { b in
                Button(b.title) { model.bookFilter = b.id }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical")
                Text(current?.title ?? "Tất cả sách").lineLimit(1)
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .chip()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Lọc theo sách")
    }

    // MARK: Bảng

    private var table: some View {
        Table(model.filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Chương") { (item: AudioItem) in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: item.isLinked ? "checkmark.circle.fill" : "doc")
                            .foregroundStyle(item.isLinked ? DS.success : .secondary)
                            .imageScale(.small)
                        Text(item.displayName).lineLimit(1)
                    }
                    Text(item.isLinked
                         ? item.bookTitle
                         : "Rời rạc · \(item.fileExt.uppercased())")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 4)
            }
            .width(min: 240, ideal: 430)
            TableColumn("Thời lượng", value: \.duration) { (item: AudioItem) in
                Text(item.duration > 0 ? formatClock(item.duration) : "…")
                    .monospacedDigit()
                    .foregroundStyle(item.duration > 0 ? .primary : .tertiary)
            }
            .width(min: 80, ideal: 90)
            TableColumn("Dung lượng", value: \.fileSize) { (item: AudioItem) in
                Text(formatBytes(item.fileSize)).monospacedDigit()
            }
            .width(min: 80, ideal: 95)
            TableColumn("Ngày tạo", value: \.createdAt) { (item: AudioItem) in
                Text(item.createdAt == .distantPast
                     ? "—" : item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 130)
            TableColumn("") { (item: AudioItem) in
                rowActions(item)
            }
            .width(min: 110, ideal: 120)
        }
        .overlay {
            if model.filtered.isEmpty {
                Text("Không có file khớp bộ lọc")
                    .foregroundStyle(.tertiary)
            }
        }
        .onChange(of: sortOrder) { _, order in
            model.applySort(order)
        }
        .contextMenu(forSelectionType: AudioItem.self) { items in
            if items.count == 1, let item = items.first {
                Button("Phát") { play(item) }
                Button("Mở trong Finder") {
                    app.revealInFinder([item.url])
                }
                Divider()
                Button("Chuyển vào Thùng rác…", role: .destructive) {
                    pendingDelete = [item]
                }
            } else if items.count > 1 {
                Button("Mở \(items.count) file trong Finder") {
                    app.revealInFinder(items.map(\.url))
                }
                Divider()
                Button("Chuyển \(items.count) file vào Thùng rác…", role: .destructive) {
                    pendingDelete = Array(items)
                }
            }
        } primaryAction: { items in
            if items.count == 1, let item = items.first { play(item) }
        }
    }

    private func rowActions(_ item: AudioItem) -> some View {
        HStack(spacing: 2) {
            Button {
                play(item)
            } label: {
                Image(systemName: "play.circle").font(.system(size: 15, design: .rounded))
            }
            .buttonStyle(.link)
            .help("Phát")
            Button {
                app.revealInFinder([item.url])
            } label: {
                Image(systemName: "folder").font(.system(size: 15, design: .rounded))
            }
            .buttonStyle(.link)
            .help("Mở trong Finder")
            Button(role: .destructive) {
                pendingDelete = [item]
            } label: {
                Image(systemName: "trash").font(.system(size: 15, design: .rounded))
            }
            .buttonStyle(.link)
            .help("Chuyển vào Thùng rác")
        }
    }

    // MARK: Hành động

    private func play(_ item: AudioItem) {
        if let bookId = item.bookId,
           let book = app.books.first(where: { $0.id == bookId }),
           book.manifest.chapters.contains(where: { $0.index == item.chapterIndex }) {
            app.player.playChapter(book: book, chapters: book.manifest.chapters,
                                   startAt: item.chapterIndex)
        } else {
            app.player.playURL(item.url)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(DS.accent.opacity(0.6))
            Text("Chưa có file audio nào")
                .font(.headline).foregroundStyle(DS.ink)
            Text("Chọn một sách trong Thư viện rồi bấm “Dựng audio”.\nFile hoàn thành sẽ xuất hiện ở đây để phát, mở trong Finder hoặc dọn dẹp.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                app.mainTab = 0
                app.selectedBookId = nil
            } label: {
                Label("Mở Thư viện", systemImage: "books.vertical")
            }
            .buttonStyle(.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
