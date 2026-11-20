import Foundation

// MARK: - Cài đặt

struct TTSSamplingParams: Codable, Equatable {
    var temperature: Double = 0.8
    var topK: Int = 25
    var topP: Double = 0.95
    var repetitionPenalty: Double = 1.2
    var steps: Int = 16          // nano
    var cfg: Double = 3.0        // nano
    var speed: Double = 1.0      // nano
    var ratePct: Int = 0         // edge

    var asDict: [String: Any] {
        ["temperature": temperature, "top_k": topK, "top_p": topP,
         "repetition_penalty": repetitionPenalty, "steps": steps, "cfg": cfg,
         "speed": speed, "rate_pct": ratePct]
    }
}

struct TextRule: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var find: String
    var replace: String
    var isRegex: Bool = false

    var asDict: [String: Any] { ["find": find, "replace": replace, "regex": isRegex] }
}

enum EngineKind: String, Codable, CaseIterable {
    case vieneu, kokoro, edge

    var label: String {
        switch self {
        case .vieneu: "VieNeu (offline)"
        case .kokoro: "Kokoro (offline, tiếng Anh)"
        case .edge: "Edge-TTS (online)"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var workspacePath: String = ""
    var onboarded: Bool = false

    // Engine mặc định
    var engine: EngineKind = .vieneu
    var mode: String = "v3turbo"          // v3turbo | v3nano
    var defaultVoice: String = ""
    var kokoroVoice: String = "af_heart"
    var edgeVoice: String = "vi-VN-HoaiMyNeural"

    // Tài nguyên (tự dò máy khi autoHardwarePreset = true)
    var autoHardwarePreset: Bool = true
    var threads: Int = 2
    var partChars: Int = 4500
    var silenceSec: Double = 0.6

    // Xuất file
    var outFormat: String = "m4a"         // m4a | mp3 | wav
    var outDirPath: String = ""           // rỗng = <ws>/output
    var namePattern: String = "{book} - {index:02d}. {title}"
    var cleanupParts: Bool = true
    var openFolderWhenDone: Bool = false

    // Nâng cao
    var sampling: TTSSamplingParams = TTSSamplingParams()
    var globalRules: [TextRule] = []
    var hfMirror: String = ""             // rỗng = HF chính thức
    var restartWorkerBetweenChapters: Bool = false
    var restartWorkerRssMb: Double = 0    // 0 = tắt
    var cooldownMinutes: Double = 0       // >0 = nghỉ giữa các chương cho máy nguội

    // Player
    var playbackRate: Float = 1.0

    // Nghe dần — phát từng part worker vừa dựng, không chờ cả chương
    var progressiveListen: Bool = true

    // model_id -> phiên bản điều khoản đã đồng ý (bump ModelLicenseTerms.version
    // để bắt người dùng xác nhận lại sau khi đổi nội dung điều khoản)
    var modelLicenseAccepted: [String: Int] = [:]

    // Phiên bản điều khoản sử dụng app đã đồng ý — 0 = chưa (hỏi ở lần chạy đầu)
    var termsAcceptedVersion: Int = 0

    var outDir: String {
        if !outDirPath.isEmpty { return outDirPath }
        return URL(fileURLWithPath: workspacePath).appendingPathComponent("output").path
    }

    // Decode bỏ qua key thiếu — thêm field mới không làm mất settings cũ
    enum CodingKeys: String, CodingKey {
        case workspacePath, onboarded, engine, mode, defaultVoice, kokoroVoice, edgeVoice
        case autoHardwarePreset, threads, partChars, silenceSec
        case outFormat, outDirPath, namePattern, cleanupParts, openFolderWhenDone
        case sampling, globalRules, hfMirror
        case restartWorkerBetweenChapters, restartWorkerRssMb, cooldownMinutes
        case playbackRate, progressiveListen
        case modelLicenseAccepted, termsAcceptedVersion
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspacePath = try c.decodeIfPresent(String.self, forKey: .workspacePath) ?? ""
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        engine = try c.decodeIfPresent(EngineKind.self, forKey: .engine) ?? .vieneu
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "v3turbo"
        defaultVoice = try c.decodeIfPresent(String.self, forKey: .defaultVoice) ?? ""
        kokoroVoice = try c.decodeIfPresent(String.self, forKey: .kokoroVoice) ?? "af_heart"
        edgeVoice = try c.decodeIfPresent(String.self, forKey: .edgeVoice) ?? "vi-VN-HoaiMyNeural"
        autoHardwarePreset = try c.decodeIfPresent(Bool.self, forKey: .autoHardwarePreset) ?? true
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? 2
        partChars = try c.decodeIfPresent(Int.self, forKey: .partChars) ?? 4500
        silenceSec = try c.decodeIfPresent(Double.self, forKey: .silenceSec) ?? 0.6
        outFormat = try c.decodeIfPresent(String.self, forKey: .outFormat) ?? "m4a"
        outDirPath = try c.decodeIfPresent(String.self, forKey: .outDirPath) ?? ""
        namePattern = try c.decodeIfPresent(String.self, forKey: .namePattern)
            ?? "{book} - {index:02d}. {title}"
        cleanupParts = try c.decodeIfPresent(Bool.self, forKey: .cleanupParts) ?? true
        openFolderWhenDone = try c.decodeIfPresent(Bool.self, forKey: .openFolderWhenDone) ?? false
        sampling = try c.decodeIfPresent(TTSSamplingParams.self, forKey: .sampling)
            ?? TTSSamplingParams()
        globalRules = try c.decodeIfPresent([TextRule].self, forKey: .globalRules) ?? []
        hfMirror = try c.decodeIfPresent(String.self, forKey: .hfMirror) ?? ""
        restartWorkerBetweenChapters = try c.decodeIfPresent(Bool.self,
                                                             forKey: .restartWorkerBetweenChapters) ?? false
        restartWorkerRssMb = try c.decodeIfPresent(Double.self, forKey: .restartWorkerRssMb) ?? 0
        cooldownMinutes = try c.decodeIfPresent(Double.self, forKey: .cooldownMinutes) ?? 0
        playbackRate = try c.decodeIfPresent(Float.self, forKey: .playbackRate) ?? 1.0
        progressiveListen = try c.decodeIfPresent(Bool.self, forKey: .progressiveListen) ?? true
        modelLicenseAccepted = try c.decodeIfPresent([String: Int].self,
                                                     forKey: .modelLicenseAccepted) ?? [:]
        termsAcceptedVersion = try c.decodeIfPresent(Int.self,
                                                     forKey: .termsAcceptedVersion) ?? 0
    }
}

// MARK: - Catalog model

/// Phiên bản nội dung điều khoản chịu trách nhiệm khi tải model — bump số này
/// trong LicenseConsentView mỗi khi thay đổi văn bản điều khoản để người dùng
/// phải xác nhận lại.
enum ModelLicenseTerms {
    static let version = 1
}

/// Phiên bản điều khoản sử dụng ứng dụng (bắt buộc ở lần chạy đầu, chặn trước
/// khi app chạm tới model nào — kể cả model mặc định khi chưa cài model).
/// Bump số này khi đổi văn bản trong TermsConsentView để hỏi lại người dùng.
enum AppTerms {
    static let version = 1
}

/// Model đang chờ người dùng xác nhận điều khoản, kèm hành động sẽ tiếp tục
/// sau khi đồng ý: tải về (model offline) hay dùng model online.
struct LicenseGate: Identifiable, Equatable {
    enum Action { case download, useOnline }
    let model: CatalogModel
    let action: Action

    var id: String { model.id }
}

struct CatalogModel: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var engine: String
    var mode: String?
    var description: String
    var sizeMb: Double?
    var ramGb: Double?
    var sampleRate: Int?
    var quality: String?
    var hardwareTier: String?
    var voiceClone: Bool?
    var speedControl: Bool?
    var noDownload: Bool?
    var licenseUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, engine, mode, description, quality
        case sizeMb = "size_mb"
        case ramGb = "ram_gb"
        case sampleRate = "sample_rate"
        case hardwareTier = "hardware_tier"
        case voiceClone = "voice_clone"
        case speedControl = "speed_control"
        case noDownload = "no_download"
        case licenseUrl = "license_url"
    }

    var engineKind: EngineKind {
        switch engine {
        case "edge": .edge
        case "kokoro": .kokoro
        default: .vieneu
        }
    }
}

struct CatalogFile: Codable {
    var version: Int
    var models: [CatalogModel]
}

struct ModelStatus: Codable, Identifiable, Equatable {
    var id: String
    var installed: Bool
    var partial: Bool
    var sizeBytes: Int64
    var missing: [String]

    enum CodingKeys: String, CodingKey {
        case id, installed, partial, missing
        case sizeBytes = "size_bytes"
    }
}

struct DownloadProgress: Identifiable, Equatable {
    var modelId: String
    var file: String?
    var fileIndex: Int?
    var fileCount: Int?
    var doneBytes: Int64?
    var totalBytes: Int64?
    var pct: Double?
    var speedBps: Double?
    var finished: Bool?
    var cancelled: Bool?

    var id: String { modelId }
}

// MARK: - Sách & chương

struct Chapter: Codable, Identifiable, Equatable {
    var index: Int
    var title: String
    var file: String
    var chars: Int
    var paras: Int

    var id: Int { index }
}

struct BookManifest: Codable, Equatable {
    var id: String
    var title: String
    var author: String
    var sourceName: String
    var created: String
    var chapters: [Chapter]
    var cover: String?
    var language: String?   // "vi" | "en" | "zh" — tự dò khi import

    enum CodingKeys: String, CodingKey {
        case id, title, author, chapters, cover, created, language
        case sourceName = "source_name"
    }
}

// Siêu dữ liệu app đè lên manifest (trạng thái render, ghi chú, quy tắc riêng của sách)
struct BookMeta: Codable, Equatable {
    var skippedChapters: Set<Int> = []
    var chapterTitles: [Int: String] = [:]     // đổi tên chương
    var audioPaths: [Int: String] = [:]        // index -> file audio đã dựng
    var rules: [TextRule] = []
    var lastPlayedChapter: Int?
}

struct Book: Identifiable, Equatable {
    var manifest: BookManifest
    var meta: BookMeta
    var dir: URL

    var id: String { manifest.id }
    var title: String { manifest.title }
    var author: String { manifest.author }
    var coverURL: URL? {
        manifest.cover.map { dir.appendingPathComponent($0) }
    }
    func chapterTitle(_ c: Chapter) -> String { meta.chapterTitles[c.index] ?? c.title }

    func audioPath(for c: Chapter) -> URL? {
        if let p = meta.audioPaths[c.index], FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }
}

// MARK: - Render job

enum JobState: String, Codable {
    case queued, rendering, done, failed, cancelled

    var label: String {
        switch self {
        case .queued: "Đang chờ"
        case .rendering: "Đang dựng"
        case .done: "Xong"
        case .failed: "Lỗi"
        case .cancelled: "Đã hủy"
        }
    }
}

struct RenderJob: Identifiable, Equatable {
    var id: String
    var bookId: String
    var bookTitle: String
    var chapterIndex: Int
    var chapterTitle: String
    var chars: Int
    var state: JobState = .queued
    var part: Int = 0
    var parts: Int = 0
    var audioSec: Double = 0
    var partSeconds: Double = 0        // thời gian render đoạn gần nhất
    var outPath: String = ""
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
    var rssMb: Double = 0
    var engineLabel: String = ""
    var voice: String = ""

    var progress: Double {
        parts > 0 ? Double(part) / Double(parts) : 0
    }

    /// Ước lượng còn lại (giây) dựa trên tốc độ các đoạn đã xong
    var etaSec: Double? {
        guard part > 0, partSeconds > 0 else { return nil }
        let remaining = max(parts - part, 0)
        return Double(remaining) * partSeconds
    }
}

// MARK: - Giọng

struct VoiceItem: Identifiable, Equatable, Hashable {
    var id: String          // voice id gửi cho worker
    var label: String
    var custom: Bool
    var engine: String
    var lang: String        // "vi" | "en" (edge); vieneu = "vi"
    var locale: String      // vd vi-VN, en-US (edge)

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: VoiceItem, r: VoiceItem) -> Bool { l.id == r.id }
}

// MARK: - Player

struct PlaybackPosition: Codable, Equatable {
    var bookId: String
    var chapterIndex: Int
    var seconds: Double
    var updatedAt: Date
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var bookId: String
    var chapterIndex: Int
    var chapterTitle: String
    var seconds: Double
    var note: String = ""
    var createdAt: Date = Date()
}

// MARK: - Misc

struct HardwarePreset: Equatable {
    var mode: String
    var threads: Int
    var partChars: Int
    var note: String

    /// Dò cấu hình máy → preset (đúng bảng đo trong HUONG-DAN-AUDIOBOOK.md)
    static func detect(cpuCount: Int, memGb: Double) -> HardwarePreset {
        if memGb <= 8 || cpuCount <= 4 {
            return .init(mode: "v3nano", threads: 1, partChars: 2500,
                         note: "Máy yếu — nano, 1 thread, RAM đỉnh ~1.4GB")
        }
        if memGb >= 16 && cpuCount >= 8 {
            return .init(mode: "v3turbo", threads: 2, partChars: 4500,
                         note: "Máy trung bình trở lên — turbo, 2 thread, RAM đỉnh ~4.4GB")
        }
        return .init(mode: "v3turbo", threads: 2, partChars: 4500,
                     note: "Cấu hình mặc định — turbo, 2 thread")
    }
}
