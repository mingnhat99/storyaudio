import Foundation

/// Lưu trữ cài đặt + thư viện + vị trí nghe + bookmark.
/// Library/app-support: ~/Library/Application Support/StoryAudio/
final class Store: ObservableObject {
    static let shared = Store()

    @Published var settings: AppSettings {
        didSet { saveSettings() }
    }
    @Published var bookMetas: [String: BookMeta] {       // bookId -> meta
        didSet { saveLibrary() }
    }
    @Published var positions: [String: PlaybackPosition] {  // bookId -> vị trí
        didSet { savePositions() }
    }
    @Published var bookmarks: [Bookmark] {
        didSet { saveBookmarks() }
    }

    let supportDir: URL
    private let defaults = UserDefaults.standard

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        supportDir = base.appendingPathComponent("StoryAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir,
                                                 withIntermediateDirectories: true)

        if let data = defaults.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        if let data = try? Data(contentsOf: supportDir.appendingPathComponent("library.json")),
           let m = try? JSONDecoder().decode([String: BookMeta].self, from: data) {
            bookMetas = m
        } else {
            bookMetas = [:]
        }
        if let data = try? Data(contentsOf: supportDir.appendingPathComponent("positions.json")),
           let p = try? JSONDecoder().decode([String: PlaybackPosition].self, from: data) {
            positions = p
        } else {
            positions = [:]
        }
        if let data = try? Data(contentsOf: supportDir.appendingPathComponent("bookmarks.json")),
           let b = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = b
        } else {
            bookmarks = []
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "settings")
        }
    }

    private func saveLibrary() {
        // bookMetas chứa Set/[Int:String] — encode qua các key tuần tự
        struct EncodableMeta: Codable {
            var skipped: [Int]
            var titles: [String: String]
            var audio: [String: String]
            var rules: [TextRule]
            var lastPlayedChapter: Int?
        }
        var out: [String: EncodableMeta] = [:]
        for (k, m) in bookMetas {
            out[k] = EncodableMeta(
                skipped: Array(m.skippedChapters),
                titles: Dictionary(uniqueKeysWithValues: m.chapterTitles.map { (String($0.key), $0.value) }),
                audio: Dictionary(uniqueKeysWithValues: m.audioPaths.map { (String($0.key), $0.value) }),
                rules: m.rules,
                lastPlayedChapter: m.lastPlayedChapter)
        }
        if let data = try? JSONEncoder().encode(out) {
            try? data.write(to: supportDir.appendingPathComponent("library.json"), options: .atomic)
        }
    }

    private func savePositions() {
        if let data = try? JSONEncoder().encode(positions) {
            try? data.write(to: supportDir.appendingPathComponent("positions.json"), options: .atomic)
        }
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: supportDir.appendingPathComponent("bookmarks.json"), options: .atomic)
        }
    }

    // MARK: - Truy cập tiện dụng

    func meta(for bookId: String) -> BookMeta {
        bookMetas[bookId] ?? BookMeta()
    }

    func updateMeta(for bookId: String, _ change: (inout BookMeta) -> Void) {
        var m = meta(for: bookId)
        change(&m)
        bookMetas[bookId] = m
    }

    /// Đề xuất workspace mặc định: ~/Documents/StoryAudio.
    /// Người dùng từng chọn workspace khác (vd bản CLI cũ) thì tự chọn lại trong onboarding —
    /// app nhớ lựa chọn qua UserDefaults.
    func defaultWorkspaceGuess() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("StoryAudio").path
    }
}
