import Combine
import Foundation
import PDFKit
import UserNotifications

/// Bộ điều phối trung tâm của app: worker, model, thư viện sách, hàng đợi render,
/// giọng đọc, phục hồi sau crash.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case boot, onboarding, ready }
    enum OnboardingStep { case workspace, runtime, model }

    /// Instance dùng chung cho App và AppDelegate (trigger bootstrap không phụ
    /// thuộc cửa sổ có hiện lên hay không — phục vụ chế độ --shot tự động).
    static let shared = AppModel()

    @Published var phase: Phase = .boot
    @Published var onboardingStep: OnboardingStep = .workspace
    @Published var bootMessage = "Đang khởi động…"
    /// true = đang hiện dialog điều khoản sử dụng app (lần chạy đầu) —
    /// bootstrap dừng lại cho đến khi người dùng đồng ý.
    @Published var termsGate = false

    // Worker & runtime
    @Published var workerRunning = false
    @Published var runtimeMissing = true          // chưa có venv engine
    @Published var runtimeSetupRunning = false
    @Published var runtimeSetupLog: [String] = []
    @Published var workerLog: [String] = []
    @Published var engineInfo: String = ""        // mô tả engine đang nạp
    @Published var engineLoading = false
    @Published var sysinfoNote = ""
    @Published var modelMissingPrompt: String?    // model_id cần tải (hiện màn model)

    // Model
    @Published var catalog: [CatalogModel] = []
    @Published var modelStatuses: [ModelStatus] = []
    @Published var downloadProgress: [String: DownloadProgress] = [:]  // model_id -> tiến trình
    /// Model đang chờ người dùng xác nhận điều khoản chịu trách nhiệm —
    /// non-nil thì dialog điều khoản phủ lên toàn bộ UI. Hành động đi kèm
    /// (tải model offline / dùng model online) chỉ chạy sau khi bấm "Đồng ý".
    @Published var licenseGate: LicenseGate?

    // Thư viện
    @Published var books: [Book] = []
    @Published var selectedBookId: String?

    // Hàng đợi render
    @Published var jobs: [RenderJob] = []
    @Published var currentJobId: String?
    @Published var queuePaused = false
    /// Đang nghỉ làm mát giữa các chương — thời điểm hết nghỉ (nil = không nghỉ).
    /// Job kế tiếp chỉ chạy sau khi hết nghỉ hoặc người dùng bấm "Bỏ nghỉ".
    @Published var cooldownEndsAt: Date?
    private var cooldownTask: Task<Void, Never>?

    // Giọng
    @Published var voices: [VoiceItem] = []
    @Published var voicesLoading = false
    @Published var voiceBusy = false

    // Điều hướng UI
    @Published var mainTab: Int = 0
    @Published var selectedSettingsTab: Int = 0
    @Published var showModelManager = false
    @Published var importPanelShown = false
    @Published var pastePanelShown = false

    let store = Store.shared
    let worker = WorkerManager()
    let player = PlayerViewModel()
    private var sleepActivity: Any?
    private var workerRestarting = false
    private var restartingTask: Task<Void, Never>?

    /// Forward thay đổi settings của Store sang objectWillChange của AppModel.
    /// View chỉ observe `app` (nút "Dùng" giọng/model đọc app.store.settings,
    /// banner engine…) nhờ đó re-render NGAY khi settings đổi, không phải đợi
    /// một @Published khác của AppModel thay đổi mới cập nhật UI.
    private var settingsSub: AnyCancellable?

    init() {
        settingsSub = store.$settings.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var settings: AppSettings { store.settings }

    var workspaceURL: URL {
        URL(fileURLWithPath: store.settings.workspacePath.isEmpty
            ? store.defaultWorkspaceGuess()
            : store.settings.workspacePath)
    }

    var selectedBook: Book? { books.first { $0.id == selectedBookId } }

    var currentJob: RenderJob? { jobs.first { $0.id == currentJobId } }

    // MARK: - Khởi động

    private var bootstrapped = false

    /// Chỉ dùng cho --ui-preview: nhảy thẳng tới một bước onboarding để chụp UI,
    /// không chạy bootstrap thường.
    func previewOnboarding() {
        switch UIPreview.step {
        case "runtime": onboardingStep = .runtime
        case "model": onboardingStep = .model
        case "terms": termsGate = true
        default: onboardingStep = .workspace
        }
        phase = .onboarding
    }

    /// Chỉ dùng cho --ui-preview: điều hướng tới tab/sách chỉ định sau bootstrap.
    func applyPreviewNavigation() {
        guard UIPreview.enabled else { return }
        SelfShot.log("applyPreviewNavigation: tab=\(UIPreview.tab ?? -1) book=\(UIPreview.bookIndex ?? -1) books=\(books.count) phase=\(phase)")
        if let b = UIPreview.bookIndex, books.indices.contains(b) {
            selectedBookId = books[b].id
            mainTab = 0
        } else if let t = UIPreview.tab {
            mainTab = t
            selectedBookId = nil
        }
        if let st = UIPreview.settingsTab { selectedSettingsTab = st }
        if UIPreview.phase == "player" { previewPlayerBar() }
        if UIPreview.step == "license" {
            // giả lập người dùng bấm Tải về model đầu tiên — dialog điều khoản hiện lên
            if let m = catalog.first(where: { $0.noDownload != true }) {
                licenseGate = LicenseGate(model: m, action: .download)
            }
        }
        if UIPreview.step == "license-online" {
            // giả lập lần đầu dùng model online — dialog điều khoản biến thể online
            licenseGate = LicenseGate(model: edgeCatalogModel, action: .useOnline)
        }
    }

    /// Chỉ dùng cho --ui-preview --ui-phase player: giả trạng thái đang phát
    /// để chụp PlayerBar — chỉ set published state, không đụng AVPlayer.
    private func previewPlayerBar() {
        let player = self.player
        player.currentBookId = books.first?.id
        player.playlist = books.first.map { book in
            book.manifest.chapters.prefix(3).map {
                (index: $0.index, title: $0.title, url: URL(fileURLWithPath: "/dev/null"))
            }
        } ?? []
        player.currentChapterIndex = player.playlist.first?.index
        player.currentTime = 254
        player.duration = 1832
        player.isPlaying = true
        switch UIPreview.step {
        case "sleep": player.setSleepTimer(minutes: 23)
        case "sleepchapter": player.sleepAtChapterEnd = true
        case "error": player.playbackError = "Không mở được file audio"
        case "play":
            // Phát thật để selfshot kiểm chứng pipeline audio chạy:
            // ưu tiên chương có audio, không có thì phát file lẻ trong workspace.
            let book = books.first
            let hasAudio = book.map { b in
                b.manifest.chapters.contains { b.audioPath(for: $0) != nil }
            } ?? false
            if hasAudio, let book, let first = book.manifest.chapters
                .first(where: { book.audioPath(for: $0) != nil }) {
                player.playChapter(book: book, chapters: book.manifest.chapters,
                                   startAt: first.index)
            } else {
                let ws = URL(fileURLWithPath: store.settings.workspacePath)
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: ws, includingPropertiesForKeys: nil))?
                    .filter { ["m4a", "mp3", "wav"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
                if let f = files.first {
                    SelfShot.log("play step: dùng file lẻ \(f.lastPathComponent)")
                    player.playURL(f)
                }
            }
        default: break
        }
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        // Điều khoản sử dụng app: bắt buộc xác nhận TRƯỚC khi bootstrap —
        // chưa đồng ý mà app nạp/dùng model (kể cả model mặc định do chưa
        // cài model nào) là dùng model chưa xin phép → rủi ro vi phạm giấy phép.
        guard store.settings.termsAcceptedVersion >= AppTerms.version else {
            termsGate = true
            return
        }
        bootstrapped = true
        worker.onEvent = { [weak self] ev in self?.handleEvent(ev) }
        worker.onLog = { [weak self] line in
            guard let self else { return }
            self.workerLog.append(line)
            if self.workerLog.count > 800 { self.workerLog.removeFirst(self.workerLog.count - 800) }
        }
        worker.onUnexpectedExit = { [weak self] in
            Task { await self?.recoverFromWorkerCrash() }
        }

        guard !store.settings.workspacePath.isEmpty else {
            onboardingStep = .workspace
            phase = .onboarding
            return
        }
        await prepareWorkspaceAndWorker()
    }

    /// Copy tài sản (worker script, catalog, setup script) từ app bundle vào workspace
    /// rồi khởi động worker. Dùng cả trong onboarding lẫn khi mở app.
    func prepareWorkspaceAndWorker() async {
        bootMessage = "Đang chuẩn bị thư mục làm việc…"
        ensureWorkerAssets()

        runtimeMissing = detectVenvPython() == nil
        if runtimeMissing {
            if store.settings.onboarded {
                // đã setup trước đó nhưng venv biến mất → quay lại onboarding runtime
                onboardingStep = .runtime
                phase = .onboarding
                return
            }
            onboardingStep = .runtime
            phase = .onboarding
            return
        }

        bootMessage = "Đang khởi động worker TTS…"
        do {
            try worker.start(workspace: workspaceURL,
                             python: detectVenvPython()!,
                             script: workspaceURL.appendingPathComponent("tts_worker.py"),
                             hfEndpoint: store.settings.hfMirror)
            let hello = try workerData(await worker.send("hello"), command: "hello")
            workerRunning = true
            _ = try workerData(
                await worker.send("init", ["workspace": workspaceURL.path]),
                command: "init")
            await refreshModels()
            scanBooks()
            relinkOrphanAudio()
            // Mở lại app → dựng lại thanh player ở vị trí nghe lần trước
            player.restoreLastSession(books: books)

            if !store.settings.onboarded {
                await applyHardwarePresetIfFresh()
                // chưa có model nào & engine mặc định cần model → onboarding chọn model
                if store.settings.engine == .vieneu,
                   !modelStatuses.contains(where: { $0.installed && $0.id.hasPrefix("vieneu") }) {
                    onboardingStep = .model
                    phase = .onboarding
                    return
                }
                store.settings.onboarded = true
            }
            phase = .ready
            applyPreviewNavigation()   // --ui-preview: điều hướng ngay khi ready,
                                       // không đợi loadEngine (chậm) xong
            await loadEngine()
            await refreshVoices()
        } catch {
            bootMessage = "Lỗi khởi động worker: \(error.localizedDescription)"
            workerRunning = false
            runtimeMissing = true
            onboardingStep = .runtime
            phase = .onboarding
        }
    }

    /// Bundle tài nguyên SPM (tts_worker.py, catalog.json, setup_runtime.sh).
    /// Không đụng trực tiếp `Bundle.module`: accessor SPM gọi fatalError khi
    /// không tìm thấy StoryAudio_StoryAudio.bundle — bản .app đóng gói thiếu
    /// bundle này crash ngay khi chọn thư mục lần đầu và crash luôn các lần
    /// mở sau (trên máy dev có fallback đường dẫn .build nên lỗi không lộ).
    /// Tự dò an toàn: Contents/Resources trong .app, hoặc cạnh binary khi
    /// chạy trần qua swift run — không thấy thì trả nil, caller tự báo lỗi.
    private static let assetsBundle: Bundle? = {
        for dir in [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap({ $0 }) {
            if let b = Bundle(url: dir.appendingPathComponent("StoryAudio_StoryAudio.bundle")) {
                return b
            }
        }
        return nil
    }()

    private func ensureWorkerAssets() {
        let fm = FileManager.default
        try? fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        guard let assets = Self.assetsBundle else {
            workerLog.append("Lỗi đóng gói app: thiếu StoryAudio_StoryAudio.bundle "
                             + "(tts_worker.py, catalog.json, setup_runtime.sh). "
                             + "Hãy tải lại bản cài mới hoặc builds lại bằng make_app.sh.")
            return
        }
        let names = ["tts_worker.py", "catalog.json", "setup_runtime.sh"]
        for name in names {
            guard let bundled = assets.url(forResource: (name as NSString).deletingPathExtension,
                                           withExtension: (name as NSString).pathExtension)
            else { continue }
            let dest = workspaceURL.appendingPathComponent(name)
            let bundledData = (try? Data(contentsOf: bundled)) ?? Data()
            let destData = (try? Data(contentsOf: dest)) ?? Data()
            if bundledData != destData {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: bundled, to: dest)
                // script shell cần quyền chạy
                if name.hasSuffix(".sh") {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                }
            }
        }
    }

    func detectVenvPython() -> URL? {
        for venv in [".venv-engine", ".venv-vieneu"] {
            let p = workspaceURL.appendingPathComponent("\(venv)/bin/python")
            if FileManager.default.fileExists(atPath: p.path) { return p }
        }
        return nil
    }

    private func applyHardwarePresetIfFresh() async {
        guard store.settings.autoHardwarePreset else { return }
        if let data = try? workerData(await worker.send("sysinfo"), command: "sysinfo") {
            let cpu = (data["cpu_count"] as? Int) ?? 8
            let mem = (data["mem_total_gb"] as? Double) ?? 16.0
            let preset = HardwarePreset.detect(cpuCount: cpu, memGb: mem)
            store.settings.threads = preset.threads
            store.settings.partChars = preset.partChars
            if store.settings.engine == .vieneu { store.settings.mode = preset.mode }
            sysinfoNote = preset.note
        }
    }

    func applyHardwarePresetAgain() async {
        if let data = try? workerData(await worker.send("sysinfo"), command: "sysinfo") {
            let cpu = (data["cpu_count"] as? Int) ?? 8
            let mem = (data["mem_total_gb"] as? Double) ?? 16.0
            let preset = HardwarePreset.detect(cpuCount: cpu, memGb: mem)
            store.settings.threads = preset.threads
            store.settings.partChars = preset.partChars
            if store.settings.engine == .vieneu { store.settings.mode = preset.mode }
            sysinfoNote = preset.note
        }
    }

    // MARK: - Onboarding: runtime setup

    func runRuntimeSetup() {
        guard !runtimeSetupRunning else { return }
        runtimeSetupRunning = true
        runtimeSetupLog = []
        let script = workspaceURL.appendingPathComponent("setup_runtime.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, workspaceURL.path]
        p.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: chunk, as: UTF8.self)
            DispatchQueue.main.async {
                for line in text.split(separator: "\n") {
                    self?.runtimeSetupLog.append(String(line))
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.runtimeSetupRunning = false
                if proc.terminationStatus == 0 {
                    self?.runtimeMissing = false
                    Task { await self?.prepareWorkspaceAndWorker() }
                } else {
                    self?.runtimeSetupLog.append("— Cài đặt thất bại (code \(proc.terminationStatus)). Kiểm tra mạng rồi thử lại —")
                }
            }
        }
        do {
            try p.run()
        } catch {
            runtimeSetupRunning = false
            runtimeSetupLog.append("Không chạy được script: \(error.localizedDescription)")
        }
    }

    // MARK: - Onboarding: chọn workspace

    func chooseWorkspace(_ url: URL) {
        store.settings.workspacePath = url.path
        Task { await prepareWorkspaceAndWorker() }
    }

    func finishOnboarding() {
        store.settings.onboarded = true
        phase = .ready
        Task {
            await loadEngine()
            await refreshVoices()
        }
    }

    // MARK: - Model

    func refreshModels() async {
        guard workerRunning else { return }
        if let data = try? workerData(await worker.send("model_catalog"), command: "catalog") {
            let decoder = JSONDecoder()
            if let raw = try? JSONSerialization.data(withJSONObject: data["models"] ?? []),
               let models = try? decoder.decode([CatalogModel].self, from: raw) {
                catalog = models
            }
        }
        if let data = try? workerData(await worker.send("model_status"), command: "status"),
           let raw = try? JSONSerialization.data(withJSONObject: data["models"] ?? []),
           let statuses = try? JSONDecoder().decode([ModelStatus].self, from: raw) {
            modelStatuses = statuses
        }
    }

    func status(for modelId: String) -> ModelStatus? {
        modelStatuses.first { $0.id == modelId }
    }

    /// Model này đã đồng ý điều khoản ở phiên bản hiện tại chưa.
    func hasAcceptedLicense(modelId: String) -> Bool {
        (store.settings.modelLicenseAccepted[modelId] ?? 0) >= ModelLicenseTerms.version
    }

    /// Engine online (edge) đang chọn nhưng chưa từng xác nhận điều khoản —
    /// mọi đường dẫn tới nó (nạp engine, render) đều phải chặn chờ dialog.
    var onlineConsentPending: Bool {
        store.settings.engine == .edge && !hasAcceptedLicense(modelId: "edge-tts")
    }

    /// Model edge-tts từ catalog; catalog chưa kịp tải thì dựng bản tối thiểu
    /// để dialog điều khoản vẫn hiện được.
    private var edgeCatalogModel: CatalogModel {
        catalog.first { $0.engineKind == .edge }
            ?? CatalogModel(id: "edge-tts", name: "Edge-TTS (online)", engine: "edge",
                            mode: nil, description: "", sizeMb: 0, ramGb: 0.2,
                            sampleRate: 24000, quality: nil, hardwareTier: nil,
                            voiceClone: false, speedControl: true, noDownload: true,
                            licenseUrl: "https://pypi.org/project/edge-tts/")
    }

    /// Nút "Tải về" gọi vào đây: đã đồng ý điều khoản thì tải ngay,
    /// chưa thì hiện dialog xác nhận chịu trách nhiệm — không đồng ý thì không tải.
    func requestDownload(_ model: CatalogModel) {
        guard workerRunning else { return }
        if hasAcceptedLicense(modelId: model.id) {
            Task { await downloadModel(model.id) }
        } else {
            licenseGate = LicenseGate(model: model, action: .download)
        }
    }

    /// Người dùng tick đồng ý trong dialog — ghi nhận theo phiên bản điều
    /// khoản hiện tại rồi tiếp tục hành động đang chờ (tải / dùng model online).
    func acceptLicense(_ gate: LicenseGate) {
        store.settings.modelLicenseAccepted[gate.model.id] = ModelLicenseTerms.version
        licenseGate = nil
        switch gate.action {
        case .download:
            Task { await downloadModel(gate.model.id) }
        case .useOnline:
            if store.settings.engine == gate.model.engineKind {
                // engine đã được chuyển trước đó (guard loadEngine chặn lại)
                // → chỉ cần nạp lại và chạy tiếp hàng đợi đang chờ
                Task {
                    await loadEngine()
                    await refreshVoices()
                    dispatchNextJob()
                }
            } else {
                Task { await useModel(gate.model) }
            }
        }
    }

    /// Người dùng từ chối — đóng dialog, không tải / không dùng model nào cả.
    func declineLicense() {
        licenseGate = nil
    }

    /// Người dùng đồng ý điều khoản sử dụng app — ghi nhận theo phiên bản
    /// hiện tại rồi bootstrap tiếp như bình thường.
    func acceptAppTerms() {
        store.settings.termsAcceptedVersion = AppTerms.version
        termsGate = false
        Task { await bootstrap() }
    }

    /// Người dùng không đồng ý điều khoản app → thoát hẳn, không dùng model nào.
    func declineAppTerms() {
        exit(0)
    }

    func downloadModel(_ modelId: String) async {
        guard workerRunning else { return }
        // Cửa chặn cuối: kể cả caller mới quên qua requestDownload thì
        // model vẫn không thể tải khi chưa có xác nhận chịu trách nhiệm.
        guard hasAcceptedLicense(modelId: modelId) else {
            if let m = catalog.first(where: { $0.id == modelId }) {
                licenseGate = LicenseGate(model: m, action: .download)
            }
            return
        }
        downloadProgress[modelId] = DownloadProgress(modelId: modelId, file: nil,
                                                     fileIndex: nil, fileCount: nil,
                                                     doneBytes: 0, totalBytes: nil,
                                                     pct: 0, speedBps: nil,
                                                     finished: false, cancelled: false)
        do {
            _ = try workerData(await worker.send("model_download", ["model_id": modelId]),
                               command: "download")
        } catch {
            // lỗi/hủy thể hiện qua progress event; đảm bảo trạng thái cuối đúng
        }
        downloadProgress[modelId] = nil
        await refreshModels()
        if status(for: modelId)?.installed == true,
           let m = catalog.first(where: { $0.id == modelId }),
           store.settings.engine == m.engineKind,      // model vừa tải đúng engine đang chọn
           m.engineKind != .vieneu || store.settings.mode == (m.mode ?? "") {
            modelMissingPrompt = nil
        }
    }

    func cancelDownload(_ modelId: String) {
        worker.fireAndForget("model_download_cancel", ["model_id": modelId])
    }

    func deleteModel(_ modelId: String) async {
        // phải dỡ engine trước khi xóa model
        if !engineInfo.isEmpty {
            _ = try? await worker.send("engine_unload")
            engineInfo = ""
        }
        _ = try? await worker.send("model_delete", ["model_id": modelId])
        await refreshModels()
    }

    /// Chuyển engine/mode sang model đã cài — dùng từ rail Model trong trang
    /// Giọng đọc & Model (tương tự engine picker trong Cài đặt).
    func useModel(_ model: CatalogModel) async {
        guard model.noDownload == true || status(for: model.id)?.installed == true else { return }
        // model online lần đầu dùng cũng phải xác nhận điều khoản —
        // chặn TRƯỚC khi đổi settings.engine để từ chối thì không đổi gì cả
        if model.noDownload == true, !hasAcceptedLicense(modelId: model.id) {
            licenseGate = LicenseGate(model: model, action: .useOnline)
            return
        }
        store.settings.engine = model.engineKind
        if model.engineKind == .vieneu, let mode = model.mode {
            store.settings.mode = mode
        }
        // chờ lần nạp engine trước kết thúc rồi mới nạp lại — click nhanh
        // liên tiếp không bị guard engineLoading bỏ qua làm lệch engine thật
        while engineLoading {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await loadEngine()
        await refreshVoices()
    }

    // MARK: - Engine & giọng

    /// Model catalog ứng với engine/mode đang chọn trong Cài đặt
    var currentModelId: String {
        switch store.settings.engine {
        case .edge: return "edge-tts"
        case .kokoro: return "kokoro-en"
        case .vieneu: return store.settings.mode == "v3nano" ? "vieneu-nano" : "vieneu-turbo"
        }
    }

    /// Model hiện tại có hỗ trợ clone giọng không (cờ voice_clone trong catalog;
    /// catalog chưa tải thì mặc định VieNeu hỗ trợ, Edge không)
    var supportsVoiceClone: Bool {
        if let m = catalog.first(where: { $0.id == currentModelId }) {
            return m.voiceClone == true
        }
        return store.settings.engine == .vieneu
    }

    func loadEngine() async {
        guard workerRunning, !engineLoading else { return }
        // engine online chưa qua điều khoản → không nạp, hiện dialog.
        // Catch-all cho mọi lối chuyển sang edge: picker Cài đặt, gợi ý giọng
        // Anh, khôi phục session… (nút "Dùng" đã chặn trước ở useModel).
        if onlineConsentPending {
            licenseGate = LicenseGate(model: edgeCatalogModel, action: .useOnline)
            return
        }
        engineLoading = true
        defer { engineLoading = false }
        let engine = store.settings.engine.rawValue
        var args: [String: Any] = ["engine": engine, "threads": store.settings.threads]
        if store.settings.engine == .vieneu { args["mode"] = store.settings.mode }
        do {
            let data = try workerData(await worker.send("engine_load", args), command: "engine_load")
            let sr = (data["sample_rate"] as? Int) ?? 0
            let mode = (data["mode"] as? String) ?? ""
            engineInfo = store.settings.engine == .edge
                ? "Edge-TTS (online) — \(sr)Hz"
                : (store.settings.engine == .kokoro
                    ? "Kokoro (offline, tiếng Anh) — \(sr)Hz"
                    : "VieNeu \(mode == "v3nano" ? "Nano" : "Turbo") — \(sr)Hz")
        } catch {
            engineInfo = ""
            if case WorkerError.modelMissing(let id) = error {
                modelMissingPrompt = id
            } else {
                engineInfo = "Lỗi nạp engine: \(error.localizedDescription)"
            }
        }
    }

    func refreshVoices() async {
        guard workerRunning, !voicesLoading else { return }
        voicesLoading = true
        defer { voicesLoading = false }
        guard let data = try? workerData(await worker.send("list_voices"), command: "list_voices"),
              let raw = try? JSONSerialization.data(withJSONObject: data["voices"] ?? [])
        else { return }
        struct RawVoice: Codable {
            let id: String; let label: String; let custom: Bool; let engine: String
            let lang: String?; let locale: String?
        }
        guard let raws = try? JSONDecoder().decode([RawVoice].self, from: raw) else { return }
        voices = raws.map {
            VoiceItem(id: $0.id, label: $0.label, custom: $0.custom, engine: $0.engine,
                      lang: $0.lang ?? "vi", locale: $0.locale ?? "")
        }

        // giọng mặc định không còn tồn tại (đổi engine / xóa giọng) → tự chọn giọng hợp lệ
        let current = store.settings.engine == .edge
            ? store.settings.edgeVoice
            : (store.settings.engine == .kokoro
                ? store.settings.kokoroVoice : store.settings.defaultVoice)
        if !voices.contains(where: { $0.id == current }) {
            switch store.settings.engine {
            case .edge:
                if let fallback = voices.first(where: { $0.id.contains("vi-VN") })
                    ?? voices.first {
                    store.settings.edgeVoice = fallback.id
                }
            case .kokoro:
                if let fallback = voices.first(where: { $0.id == "af_heart" })
                    ?? voices.first {
                    store.settings.kokoroVoice = fallback.id
                }
            case .vieneu:
                if let fallback = voices.first(where: { !$0.custom })
                    ?? voices.first {
                    store.settings.defaultVoice = fallback.id
                }
            }
        }
    }

    func cloneVoice(name: String, refURL: URL, denoise: Bool) async throws {
        voiceBusy = true
        defer { voiceBusy = false }
        _ = try workerData(await worker.send("clone_voice", [
            "name": name, "ref_path": refURL.path, "denoise": denoise
        ]), command: "clone_voice")
        await refreshVoices()
    }

    func deleteVoice(_ voice: VoiceItem) async {
        voiceBusy = true
        defer { voiceBusy = false }
        _ = try? workerData(await worker.send("delete_voice", ["name": voice.id]),
                            command: "delete_voice")
        await refreshVoices()
    }

    func exportVoices(to url: URL) async {
        _ = try? workerData(await worker.send("export_voices", ["path": url.path]),
                            command: "export_voices")
    }

    func importVoices(from url: URL) async {
        voiceBusy = true
        defer { voiceBusy = false }
        _ = try? workerData(await worker.send("import_voices", ["path": url.path]),
                            command: "import_voices")
        await refreshVoices()
    }

    /// Trả về path file audio preview để player phát
    func previewVoice(_ voice: VoiceItem) async -> URL? {
        voiceBusy = true
        defer { voiceBusy = false }
        let text = store.settings.engine == .kokoro
            ? "The old lighthouse keeper had seen many storms, but never one quite like this."
            : "Thử giọng đọc. Sương giăng phủ kín miền Bắc, Quỷ Cốc Tử nhìn về phương xa."
        var params = store.settings.sampling.asDict
        switch store.settings.engine {
        case .vieneu where store.settings.mode != "v3nano":
            params.removeValue(forKey: "speed")
            params.removeValue(forKey: "steps")
            params.removeValue(forKey: "cfg")
        case .kokoro:
            // Kokoro chỉ nhận speed — bỏ các tham số LLM của VieNeu
            params.removeValue(forKey: "steps")
            params.removeValue(forKey: "cfg")
        default:
            break
        }
        guard let data = try? workerData(await worker.send("preview", [
            "voice": voice.id, "text": text, "params": params
        ]), command: "preview") else { return nil }
        guard let path = data["path"] as? String else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Import sách

    func scanBooks() {
        let fm = FileManager.default
        let booksDir = workspaceURL.appendingPathComponent("books")
        guard let ids = try? fm.contentsOfDirectory(atPath: booksDir.path) else {
            books = []
            return
        }
        var out: [Book] = []
        for id in ids.sorted() {
            let dir = booksDir.appendingPathComponent(id, isDirectory: true)
            let manifestURL = dir.appendingPathComponent("book.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(BookManifest.self, from: data)
            else { continue }
            out.append(Book(manifest: manifest, meta: store.meta(for: id), dir: dir))
        }
        books = out
    }

    func importFiles(_ urls: [URL]) async {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let bookId = "b\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))"
            do {
                switch ext {
                case "pdf":
                    try await importPDF(url: url, bookId: bookId)
                case "epub", "txt", "text", "docx":
                    // copy nguồn vào workspace để tái parse độc lập vị trí gốc
                    let dest = workspaceURL.appendingPathComponent("books/\(bookId)/source.\(ext)")
                    try FileManager.default.createDirectory(
                        at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: url, to: dest)
                    let resp = try await worker.send("parse_book", [
                        "path": dest.path, "book_id": bookId
                    ])
                    _ = try workerData(resp, command: "parse_book")
                default:
                    continue
                }
            } catch {
                workerLog.append("Import \(url.lastPathComponent) lỗi: \(error.localizedDescription)")
            }
        }
        scanBooks()
        if selectedBookId == nil { selectedBookId = books.last?.id }
    }

    private func importPDF(url: URL, bookId: String) async throws {
        guard let doc = PDFDocument(url: url) else {
            throw WorkerError.commandFailed("Không đọc được PDF")
        }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let t = doc.page(at: i)?.string, !t.isEmpty {
                parts.append(t.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let text = parts.joined(separator: "\n\n")
        guard !text.isEmpty else {
            throw WorkerError.commandFailed("PDF không có lớp text (có thể là scan ảnh)")
        }
        let resp = try await worker.send("import_text", [
            "text": text, "title": url.deletingPathExtension().lastPathComponent,
            "book_id": bookId
        ])
        _ = try workerData(resp, command: "import_text")
    }

    func importPastedText(title: String, text: String) async {
        let bookId = "t\(Int(Date().timeIntervalSince1970))"
        _ = try? await worker.send("import_text", [
            "text": text, "title": title.isEmpty ? "Text dán vào" : title, "book_id": bookId
        ])
        scanBooks()
        selectedBookId = bookId
    }

    func deleteBook(_ book: Book) {
        try? FileManager.default.removeItem(at: book.dir)
        store.bookMetas[book.id] = nil
        if selectedBookId == book.id { selectedBookId = nil }
        scanBooks()
    }

    // MARK: - Quản lý audio đã tạo

    /// Mở Finder và chọn sẵn các file audio (mở đúng file, không chỉ thư mục).
    func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Đưa các file audio vào Thùng rác và xóa liên kết trong meta sách.
    func deleteAudioFiles(_ items: [AudioItem]) {
        let urls = items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty {
            NSWorkspace.shared.recycle(urls) { _, _ in }
        }
        var touchedBooks = Set<String>()
        for it in items {
            guard let bookId = it.bookId else { continue }
            touchedBooks.insert(bookId)
            store.updateMeta(for: bookId) { meta in
                meta.audioPaths = meta.audioPaths.filter { $0.value != it.url.path }
            }
        }
        if !touchedBooks.isEmpty { scanBooks() }
    }

    // MARK: - Hàng đợi render

    func enqueueChapters(_ book: Book, indices: [Int]) {
        guard !indices.isEmpty else { return }
        let engineLabel: String
        switch store.settings.engine {
        case .edge: engineLabel = "Edge"
        case .kokoro: engineLabel = "Kokoro"
        case .vieneu: engineLabel = store.settings.mode == "v3nano" ? "Nano" : "Turbo"
        }
        let voice = currentVoiceId()
        for idx in indices {
            guard let ch = book.manifest.chapters.first(where: { $0.index == idx }),
                  store.meta(for: book.id).skippedChapters.contains(idx) == false
            else { continue }
            jobs.append(RenderJob(
                id: "j\(Int(Date().timeIntervalSince1970))-\(idx)-\(Int.random(in: 100...999))",
                bookId: book.id, bookTitle: book.title, chapterIndex: idx,
                chapterTitle: book.chapterTitle(ch), chars: ch.chars,
                engineLabel: engineLabel, voice: voice))
        }
        beginSleepPrevention()
        Task { await loadEngineIfNeededForQueue() }
        dispatchNextJob()
    }

    private func currentVoiceId() -> String {
        switch store.settings.engine {
        case .edge: return store.settings.edgeVoice
        case .kokoro: return store.settings.kokoroVoice
        case .vieneu: return store.settings.defaultVoice
        }
    }

    private func loadEngineIfNeededForQueue() async {
        // engine theo cài đặt — nếu model chưa có thì nhắc tải
        if engineInfo.isEmpty || engineInfoHasPrefixMismatch() {
            await loadEngine()
        }
        if modelMissingPrompt != nil { return }
    }

    private func engineInfoHasPrefixMismatch() -> Bool {
        if store.settings.engine == .edge { return !engineInfo.contains("Edge")
        }
        if store.settings.engine == .kokoro { return !engineInfo.contains("Kokoro") }
        if store.settings.mode == "v3nano" { return !engineInfo.contains("Nano") }
        return !engineInfo.contains("Turbo")
    }

    private func dispatchNextJob() {
        // đang nghỉ làm mát — job kế tiếp tự chạy khi hết nghỉ (skipCooldown)
        guard cooldownTask == nil else { return }
        guard !queuePaused, currentJobId == nil,
              let idx = jobs.firstIndex(where: { $0.state == .queued })
        else { return }
        // render bằng engine online cũng là "dùng" — chặn chờ xác nhận điều
        // khoản, job giữ nguyên trạng thái queued trong hàng đợi
        if onlineConsentPending {
            licenseGate = LicenseGate(model: edgeCatalogModel, action: .useOnline)
            return
        }
        jobs[idx].state = .rendering
        jobs[idx].startedAt = Date()
        currentJobId = jobs[idx].id
        Task { await runJob(jobs[idx]) }
    }

    /// Tên file audio kỳ vọng của chương (theo namePattern, đã làm sạch ký
    /// tự không hợp lệ — không kèm đuôi file). Dùng chung cho đường dẫn
    /// render và cho việc gắn lại audio mồ côi ở relinkOrphanAudio().
    private func audioBaseName(book: Book, chapter: Chapter) -> String {
        let title = book.chapterTitle(chapter)
        var name = store.settings.namePattern
            .replacingOccurrences(of: "{book}", with: book.title)
            .replacingOccurrences(of: "{title}", with: title)
        if let r = name.range(of: #"\{index:?(\d*)d?\}"#, options: .regularExpression) {
            let m = name[r]
            var pad = 0
            if let pr = m.range(of: #"\d+"#, options: .regularExpression) {
                pad = Int(m[pr]) ?? 0
            }
            name.replaceSubrange(r, with: String(format: "%0\(max(pad, 0))d", chapter.index))
        }
        let invalid = CharacterSet(charactersIn: "/:?*<>\"|\\")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private func jobOutPath(book: Book, chapter: Chapter) -> URL {
        let outDir = URL(fileURLWithPath: store.settings.outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return outDir.appendingPathComponent(audioBaseName(book: book, chapter: chapter))
    }

    private func runJob(_ job: RenderJob) async {
        guard let book = books.first(where: { $0.id == job.bookId }),
              let ch = book.manifest.chapters.first(where: { $0.index == job.chapterIndex })
        else {
            markJob(job.id, state: .failed, error: "Không tìm thấy sách/chương")
            return
        }
        var params = store.settings.sampling.asDict
        switch store.settings.engine {
        case .vieneu where store.settings.mode != "v3nano":
            params.removeValue(forKey: "speed")
            params.removeValue(forKey: "steps")
            params.removeValue(forKey: "cfg")
        case .kokoro:
            // Kokoro chỉ nhận speed — bỏ các tham số LLM của VieNeu
            params.removeValue(forKey: "steps")
            params.removeValue(forKey: "cfg")
        default:
            break
        }
        var rules = store.settings.globalRules.map { $0.asDict }
        rules += store.meta(for: book.id).rules.map { $0.asDict }

        let outURL = jobOutPath(book: book, chapter: ch)
        let slug = "\(book.id)-c\(ch.index)"
        let progressive = store.settings.progressiveListen
        let jobDict: [String: Any] = [
            "job_id": job.id,
            "engine": store.settings.engine.rawValue,
            "mode": store.settings.mode,
            "book_id": book.id,
            "chapter_file": ch.file,
            "title": book.chapterTitle(ch),
            "artist": "StoryAudio — \(currentVoiceId())",
            "voice": currentVoiceId(),
            "params": params,
            "part_chars": store.settings.partChars,
            // part đầu nhỏ dần để nghe dần chờ ít (700→1200→2000 rồi về partChars)
            "part_ramp": progressive ? [700, 1200, 2000] : [],
            "silence_s": store.settings.silenceSec,
            "slug": slug,
            "build_dir": workspaceURL.appendingPathComponent("build/\(slug)").path,
            "out_path": outURL.path,   // chưa có đuôi — worker tự nối đuôi theo format
            "format": store.settings.outFormat,
            "rules": rules,
            "rate_pct": store.settings.sampling.ratePct,
            // bật nghe dần → app tự dọn build dir sau khi phiên nghe kết thúc
            "cleanup_parts": progressive ? false : store.settings.cleanupParts,
        ]
        do {
            let resp = try await worker.send("render", ["job": jobDict])
            if resp["ok"] as? Bool == true, let data = resp["data"] as? [String: Any] {
                let file = data["file"] as? String ?? outURL.path
                markJob(job.id, state: .done, outPath: file,
                        audioSec: (data["duration_sec"] as? Double) ?? 0)
                store.updateMeta(for: book.id) { $0.audioPaths[ch.index] = file }
                scanBooks()
                // không có phiên nghe dần nào đang mở ở chương này → dọn thay worker
                if progressive && store.settings.cleanupParts,
                   player.live?.jobId != job.id {
                    try? FileManager.default.removeItem(
                        at: workspaceURL.appendingPathComponent("build/\(slug)"))
                }
                player.liveJobFinished(jobId: job.id, finalURL: URL(fileURLWithPath: file))
                notifyIfNeededAfterJob()
            } else {
                let err = resp["error"] as? String ?? "lỗi"
                if err == "cancelled" {
                    markJob(job.id, state: .cancelled)
                } else if err.hasPrefix("model_missing:") {
                    modelMissingPrompt = String(err.dropFirst("model_missing:".count))
                    markJob(job.id, state: .queued, error: nil)  // chờ tải model xong chạy lại
                } else {
                    markJob(job.id, state: .failed, error: err)
                }
            }
        } catch {
            // worker chết giữa chừng → recoverFromWorkerCrash sẽ chạy lại job (parts resume)
            if workerRestarting { return }
            markJob(job.id, state: .failed, error: error.localizedDescription)
        }
        currentJobId = nil
        if settings.restartWorkerBetweenChapters && jobs.contains(where: { $0.state == .queued }) {
            await restartWorkerKeepState()
        }
        beginCooldownOrDispatch()
        updateSleepPrevention()
    }

    /// Sau khi xong một chương: bật nghỉ làm mát và còn job chờ thì đếm ngược
    /// cho máy nguội bớt rồi mới dựng chương kế, không thì chạy luôn.
    private func beginCooldownOrDispatch() {
        let restSec = settings.cooldownMinutes * 60
        guard restSec > 0, !queuePaused,
              jobs.contains(where: { $0.state == .queued })
        else {
            dispatchNextJob()
            return
        }
        cooldownEndsAt = Date().addingTimeInterval(restSec)
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(restSec * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.cooldownTask = nil
            self.cooldownEndsAt = nil
            self.dispatchNextJob()
        }
    }

    /// Bỏ dở thời gian nghỉ làm mát — chạy ngay chương kế tiếp trong hàng đợi.
    func skipCooldown() {
        cooldownTask?.cancel()
        cooldownTask = nil
        cooldownEndsAt = nil
        dispatchNextJob()
    }

    private func markJob(_ id: String, state: JobState, error: String? = nil,
                         outPath: String? = nil, audioSec: Double? = nil) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = state
        jobs[idx].error = error
        jobs[idx].finishedAt = state == .queued ? nil : Date()
        if let p = outPath { jobs[idx].outPath = p }
        if let s = audioSec { jobs[idx].audioSec = s }
        if state == .failed || state == .cancelled {
            // phiên nghe dần của job này phát nốt part sẵn có rồi dừng
            player.liveJobFailed(jobId: id, message: error ?? "Job đã bị hủy")
        }
    }

    func cancelJob(_ id: String) {
        worker.fireAndForget("cancel", ["job_id": id])
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            if jobs[idx].state == .queued {
                jobs[idx].state = .cancelled
                jobs[idx].finishedAt = Date()
            }
            // đang render: trạng thái cuối do phản hồi render quyết định (cancelled)
        }
        // đang nghỉ làm mát mà hết job chờ → bỏ nghỉ luôn, khỏi đợi vô ích
        if cooldownTask != nil, !jobs.contains(where: { $0.state == .queued }) {
            skipCooldown()
        }
    }

    func retryJob(_ id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = .queued
        jobs[idx].error = nil
        jobs[idx].part = 0
        jobs[idx].parts = 0
        jobs[idx].finishedAt = nil
        dispatchNextJob()
    }

    func removeFinishedJobs() {
        jobs.removeAll { $0.state == .done || $0.state == .failed || $0.state == .cancelled }
    }

    private func notifyIfNeededAfterJob() {
        let running = jobs.contains { $0.state == .rendering || $0.state == .queued }
        if !running {
            let done = jobs.filter { $0.state == .done }.count
            let failed = jobs.filter { $0.state == .failed }
            let content = failed.isEmpty
                ? "Đã dựng xong \(done) chương audio."
                : "Xong \(done) chương, \(failed.count) chương lỗi."
            notify(title: "StoryAudio", body: content)
            if store.settings.openFolderWhenDone {
                NSWorkspace.shared.open(URL(fileURLWithPath: store.settings.outDir))
            }
        }
    }

    private func notify(title: String, body: String) {
        // UNUserNotificationCenter chỉ hoạt động trong app bundle có bundle id
        // (chạy binary trần / smoke test sẽ crash) — bỏ qua an toàn
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                            trigger: nil)
            center.add(req)
        }
    }

    /// Gắn lại audio "mồ côi" trong output/ về đúng chương của sách.
    ///
    /// Kịch bản bị mất map: app tắt giữa chừng khi đang dựng — worker (process
    /// con) mồ côi vẫn kịp hoàn thành file cuối vào output/, nhưng lệnh ghi
    /// `audioPaths` chỉ chạy khi app nhận được phản hồi render, nên map mất
    /// theo process cũ. Ở lần khởi động sau, đối chiếu tên file với tên kỳ
    /// vọng theo namePattern của các chương chưa có map để gắn lại — không
    /// phải dựng lại chương đã xong.
    private func relinkOrphanAudio() {
        let outDirURL = URL(fileURLWithPath: settings.outDir)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outDirURL.path)
        else { return }

        var mapped = Set<String>()
        for book in books { mapped.formUnion(store.meta(for: book.id).audioPaths.values) }
        let orphans = names.filter {
            AudioLibraryModel.audioExts.contains(($0 as NSString).pathExtension.lowercased())
        }
        guard !orphans.isEmpty else { return }

        // Tên kỳ vọng (không đuôi) của các chương chưa có map. Trùng tên —
        // pattern không chứa {index} mà chương trùng tiêu đề — không đoán được.
        var expected: [String: (bookId: String, chapterIndex: Int)] = [:]
        for book in books {
            for ch in book.manifest.chapters
            where store.meta(for: book.id).audioPaths[ch.index] == nil {
                let base = audioBaseName(book: book, chapter: ch)
                if expected[base] == nil { expected[base] = (book.id, ch.index) }
            }
        }
        guard !expected.isEmpty else { return }

        var relinked = 0
        for name in orphans {
            let url = outDirURL.appendingPathComponent(name)
            guard !mapped.contains(url.path),
                  let hit = expected[url.deletingPathExtension().lastPathComponent]
            else { continue }
            store.updateMeta(for: hit.bookId) { $0.audioPaths[hit.chapterIndex] = url.path }
            mapped.insert(url.path)
            relinked += 1
        }
        if relinked > 0 {
            workerLog.append("Đã gắn lại \(relinked) file audio mồ côi vào chương tương ứng.")
            scanBooks()
        }
    }

    // MARK: - Nghe dần

    /// Job có thể nghe dần cho chương này (đang dựng hoặc đang chờ tới lượt).
    func liveJob(for book: Book, chapter: Chapter) -> RenderJob? {
        guard store.settings.progressiveListen else { return nil }
        return jobs.first {
            $0.bookId == book.id && $0.chapterIndex == chapter.index
                && ($0.state == .rendering || $0.state == .queued)
        }
    }

    /// Bắt đầu nghe dần chương đang dựng — job còn xếp hàng thì được đẩy lên đầu.
    func startLiveListening(book: Book, chapter: Chapter) {
        guard let idx = jobs.firstIndex(where: {
            $0.bookId == book.id && $0.chapterIndex == chapter.index
                && ($0.state == .rendering || $0.state == .queued)
        }) else { return }
        let job: RenderJob
        var queuedBehind: String?
        if jobs[idx].state == .queued, currentJobId != jobs[idx].id,
           let curId = currentJobId,
           let cur = jobs.first(where: { $0.id == curId }), cur.state == .rendering {
            // người dùng muốn nghe chương này → dựng nó trước
            jobs.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
            queuedBehind = cur.chapterTitle
            job = jobs[0]
        } else {
            job = jobs[idx]
        }
        let buildDir = workspaceURL.appendingPathComponent("build/\(book.id)-c\(chapter.index)")
        player.startLive(book: book, chapter: chapter, job: job, buildDir: buildDir,
                         queuedBehind: queuedBehind)
    }

    // MARK: - Sự kiện worker

    private func handleEvent(_ ev: [String: Any]) {
        switch ev["event"] as? String {
        case "render_progress":
            guard let jobId = ev["job_id"] as? String,
                  let idx = jobs.firstIndex(where: { $0.id == jobId }) else { return }
            jobs[idx].part = (ev["part"] as? Int) ?? jobs[idx].part
            jobs[idx].parts = (ev["parts"] as? Int) ?? jobs[idx].parts
            jobs[idx].audioSec = (ev["audio_sec"] as? Double) ?? jobs[idx].audioSec
            jobs[idx].partSeconds = (ev["part_seconds"] as? Double) ?? jobs[idx].partSeconds
            jobs[idx].rssMb = (ev["rss_mb"] as? Double) ?? jobs[idx].rssMb
            if player.live?.jobId == jobId {
                player.liveProgress(jobId: jobId,
                                    part: (ev["part"] as? Int) ?? 0,
                                    parts: (ev["parts"] as? Int) ?? 0,
                                    chars: ev["chars"] as? Int,
                                    audioSec: ev["audio_sec"] as? Double,
                                    partAudioSec: ev["part_audio_sec"] as? Double,
                                    partSeconds: ev["part_seconds"] as? Double)
            }
            if let rss = ev["rss_mb"] as? Double,
               store.settings.restartWorkerRssMb > 0,
               rss > store.settings.restartWorkerRssMb {
                worker.fireAndForget("cancel", ["job_id": jobId])
                // hủy giữa chương rồi chạy lại với worker mới (parts đã xong vẫn còn)
                markJob(jobId, state: .queued)
                currentJobId = nil
                Task { await restartWorkerKeepState() ; dispatchNextJob() }
            }
        case "download_progress":
            guard let modelId = ev["model_id"] as? String else { return }
            let done = (ev["done_bytes"] as? Int64) ?? downloadProgress[modelId]?.doneBytes
            let total = (ev["total_bytes"] as? Int64) ?? downloadProgress[modelId]?.totalBytes
            downloadProgress[modelId] = DownloadProgress(
                modelId: modelId,
                file: ev["file"] as? String,
                fileIndex: ev["file_index"] as? Int,
                fileCount: ev["file_count"] as? Int,
                doneBytes: done,
                totalBytes: total,
                pct: ev["pct"] as? Double,
                speedBps: ev["speed_bps"] as? Double,
                finished: ev["finished"] as? Bool,
                cancelled: ev["cancelled"] as? Bool)
        case "render_stage":
            // worker đang ghép / nén file cuối — không có part mới trong giai đoạn này
            if let jobId = ev["job_id"] as? String {
                player.liveStage(jobId: jobId, stage: ev["stage"] as? String ?? "")
            }
        case "render_error":
            if let jobId = ev["job_id"] as? String,
               let err = ev["error"] as? String {
                markJob(jobId, state: .failed, error: err)
                currentJobId = nil
            }
        default:
            break
        }
    }

    // MARK: - Phục hồi & restart worker

    private func restartWorkerKeepState() async {
        worker.stop()
        try? worker.start(workspace: workspaceURL,
                          python: detectVenvPython()!,
                          script: workspaceURL.appendingPathComponent("tts_worker.py"),
                          hfEndpoint: store.settings.hfMirror)
        _ = try? await worker.send("init", ["workspace": workspaceURL.path])
        await loadEngine()
    }

    /// Nút "Khởi động lại worker ngay" trong Cài đặt (áp cả mirror HF mới)
    func restartWorkerKeepStatePublic() async {
        guard let python = detectVenvPython() else { return }
        workerRestarting = true
        defer { workerRestarting = false }
        worker.stop()
        do {
            try worker.start(workspace: workspaceURL, python: python,
                             script: workspaceURL.appendingPathComponent("tts_worker.py"),
                             hfEndpoint: store.settings.hfMirror)
            _ = try workerData(await worker.send("init", ["workspace": workspaceURL.path]),
                               command: "init")
            workerRunning = true
            await loadEngine()
            await refreshVoices()
        } catch {
            workerLog.append("Khởi động lại worker lỗi: \(error.localizedDescription)")
        }
    }

    private func recoverFromWorkerCrash() async {
        guard !workerRestarting else { return }
        workerRestarting = true
        defer { workerRestarting = false }
        let heldJobId = currentJobId
        for attempt in 1...3 {
            try? await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
            guard let python = detectVenvPython() else { return }
            do {
                try worker.start(workspace: workspaceURL, python: python,
                                 script: workspaceURL.appendingPathComponent("tts_worker.py"),
                                 hfEndpoint: store.settings.hfMirror)
                _ = try workerData(await worker.send("init", ["workspace": workspaceURL.path]),
                                   command: "init")
                workerRunning = true
                await loadEngine()
                if let id = heldJobId, currentJobId == id,
                   let idx = jobs.firstIndex(where: { $0.id == id }),
                   jobs[idx].state == .rendering {
                    Task { await runJob(jobs[idx]) }   // parts đã xong sẽ tự bỏ qua
                } else {
                    dispatchNextJob()
                }
                return
            } catch {
                continue
            }
        }
        if let id = heldJobId {
            markJob(id, state: .failed, error: "Worker bị đứt và không khôi phục được")
            currentJobId = nil
            dispatchNextJob()
        }
    }

    // MARK: - Chống ngủ máy

    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled,
            reason: "Đang dựng audio sách")
    }

    private func updateSleepPrevention() {
        let active = jobs.contains { $0.state == .rendering || $0.state == .queued }
        if !active, let act = sleepActivity as? NSObject {
            ProcessInfo.processInfo.endActivity(act)
            sleepActivity = nil
        }
    }

    func togglePauseQueue() {
        queuePaused.toggle()
        if !queuePaused { dispatchNextJob() }
    }

    // MARK: - Quy tắc text theo sách

    func rules(for bookId: String) -> [TextRule] {
        store.meta(for: bookId).rules
    }

    func updateRules(for bookId: String, _ rules: [TextRule]) {
        store.updateMeta(for: bookId) { $0.rules = rules }
    }

    func toggleSkipChapter(_ book: Book, _ index: Int) {
        store.updateMeta(for: book.id) {
            if $0.skippedChapters.contains(index) {
                $0.skippedChapters.remove(index)
            } else {
                $0.skippedChapters.insert(index)
            }
        }
        scanBooks()
    }

    func renameChapter(_ book: Book, _ index: Int, newTitle: String) {
        store.updateMeta(for: book.id) { $0.chapterTitles[index] = newTitle }
        scanBooks()
    }

    // MARK: - Tiếng Anh

    /// Sách tiếng Anh mà đang dùng engine VieNeu → gợi ý chuyển sang giọng Anh
    var shouldSuggestEnglishVoice: Bool {
        guard let book = selectedBook else { return false }
        return book.manifest.language == "en" && store.settings.engine == .vieneu
    }

    /// Ưu tiên Kokoro (offline, chất lượng cao) nếu đã tải model; chưa có thì Edge online.
    func switchToEnglishVoice() async {
        if status(for: "kokoro-en")?.installed == true {
            store.settings.engine = .kokoro
            store.settings.kokoroVoice = "af_heart"
        } else {
            store.settings.engine = .edge
            if !store.settings.edgeVoice.hasPrefix("en-") {
                store.settings.edgeVoice = "en-US-AriaNeural"
            }
        }
        await loadEngine()
        await refreshVoices()
    }

    // MARK: - Gỡ cài đặt

    struct UninstallOptions {
        var appData = true          // ~/Library/Application Support/StoryAudio + cài đặt
        var appToTrash = true       // đưa StoryAudio.app vào Thùng rác
        var booksAndOutput = false  // books/ output/ build/ trong thư mục làm việc
        var models = false          // models/ (tải lại được qua Model Manager)
        var venvEngine = false      // .venv-engine (venv app tạo trên máy mới)
        var workerFiles = false     // tts_worker.py / catalog.json / setup_runtime.sh
    }

    func performUninstall(_ opts: UninstallOptions) {
        let fm = FileManager.default
        worker.stop()
        sleep(1)   // cho worker kịp thoát

        if opts.booksAndOutput {
            for d in ["books", "output", "build"] {
                try? fm.removeItem(at: workspaceURL.appendingPathComponent(d))
            }
        }
        if opts.models {
            try? fm.removeItem(at: workspaceURL.appendingPathComponent("models"))
        }
        if opts.venvEngine {
            try? fm.removeItem(at: workspaceURL.appendingPathComponent(".venv-engine"))
        }
        if opts.workerFiles {
            for f in ["tts_worker.py", "catalog.json", "setup_runtime.sh"] {
                try? fm.removeItem(at: workspaceURL.appendingPathComponent(f))
            }
        }
        if opts.appData {
            try? fm.removeItem(at: store.supportDir)
            let domain = Bundle.main.bundleIdentifier ?? "com.storyaudio.app"
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }

        if opts.appToTrash, Bundle.main.bundleURL.pathExtension == "app" {
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
        }
    }
}
