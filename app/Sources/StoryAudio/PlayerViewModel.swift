import AppKit
import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Player audio: playlist theo chương, tua tốc độ không méo giọng, nhớ vị trí,
/// bookmark, sleep timer.
@MainActor
final class PlayerViewModel: NSObject, ObservableObject {
    @Published var currentBookId: String?
    @Published var currentChapterIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Float = 1.0 { didSet { applyRate() } }
    @Published var sleepTimerEnd: Date?
    @Published var sleepTimerMinutes: Double?
    @Published var sleepAtChapterEnd = false
    @Published var playlist: [(index: Int, title: String, url: URL)] = []
    @Published var justPreviewURL: URL?
    @Published var playbackError: String?

    /// Hết chương thì tự phát chương tiếp — lưu UserDefaults, mặc định bật.
    @Published var autoAdvance: Bool = {
        if let v = UserDefaults.standard.object(forKey: "playerAutoAdvance") as? Bool {
            return v
        }
        return true
    }() {
        didSet {
            UserDefaults.standard.set(autoAdvance, forKey: "playerAutoAdvance")
        }
    }

    /// Âm lượng riêng của app — lưu UserDefaults, không đụng âm lượng hệ thống.
    @Published var volume: Float = {
        if let v = UserDefaults.standard.object(forKey: "playerVolume") as? Float {
            return min(max(v, 0), 1)
        }
        return 1
    }() {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "playerVolume")
        }
    }

    /// Phiên "nghe dần" — phát từng part worker vừa dựng của chương đang render.
    @Published var live: LiveState?
    private var liveGapPendingPart: Int?      // đang phát khoảng lặng trước part này
    private var liveGapStartOffset: Double = 0
    private var pendingFinalURL: URL?         // render xong — handover tại ranh giới part

    /// Phiên vừa khôi phục từ lần chạy trước — player chưa có item thật,
    /// lần resume đầu tiên mới nạp file tại đúng vị trí đã lưu.
    private var restorePending = false

    private var player: AVPlayer = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private let store = Store.shared
    private var lastSave = Date.distantPast

    override init() {
        super.init()
        player.volume = volume
        let observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = self.liveTimeBase() + time.seconds
                if self.duration <= 0, self.live == nil, let item = self.player.currentItem,
                   item.status == .readyToPlay {
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                }
                self.savePositionThrottled()
                self.checkSleepTimer()
                self.updateNowPlaying()
            }
        }
        timeObserver = observer
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleChapterEnd() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.playbackError = (note.object as? AVPlayerItem)?.error?
                    .localizedDescription ?? "Không phát tiếp được file này"
            }
        }
        // File bị xóa/di chuyển → item chuyển sang failed, surface lên UI
        player.publisher(for: \.currentItem?.status)
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, status == .failed else { return }
                if self.playbackError == nil {
                    self.playbackError = self.player.currentItem?.error?
                        .localizedDescription ?? "Không mở được file audio"
                }
            }
            .store(in: &cancellables)
        // Thoát app giữa 2 lần save throttle (5s) → ghi ngay vị trí cuối
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.savePositionNow() }
        }
    }

    // MARK: - Phát

    /// Bật chơi 1 chương của sách (playlist = các chương có audio của sách đó)
    func playChapter(book: Book, chapters: [Chapter], startAt index: Int) {
        var list: [(Int, String, URL)] = []
        for ch in chapters {
            if let url = book.audioPath(for: ch) {
                list.append((ch.index, book.chapterTitle(ch), url))
            }
        }
        guard !list.isEmpty else { return }
        stopLive()
        playlist = list.map { (index: $0.0, title: $0.1, url: $0.2) }
        currentBookId = book.id
        loadItem(index: index, autoPlay: true, seekTo: nil)
    }

    func playURL(_ url: URL) {          // nghe preview giọng / file lẻ
        stopLive()
        restorePending = false
        justPreviewURL = url
        currentBookId = nil
        currentChapterIndex = nil
        playlist = []
        playbackError = nil
        ensureRemoteCommands()
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        duration = 0
        updateNowPlaying()
    }

    // MARK: - Khôi phục phiên nghe lần trước

    /// Vị trí nghe gần nhất còn phát được — sách còn trong thư viện,
    /// chương có file audio còn trên đĩa.
    struct ResumableSession: Equatable {
        let book: Book
        let chapter: Chapter
        let pos: PlaybackPosition
    }

    static func latestResumable(books: [Book], positions: [String: PlaybackPosition])
        -> ResumableSession? {
        let candidates = positions.values.compactMap { pos -> ResumableSession? in
            guard let book = books.first(where: { $0.id == pos.bookId }),
                  let ch = book.manifest.chapters.first(where: { $0.index == pos.chapterIndex }),
                  book.audioPath(for: ch) != nil, pos.seconds > 1 else { return nil }
            return ResumableSession(book: book, chapter: ch, pos: pos)
        }
        return candidates.sorted { $0.pos.updatedAt > $1.pos.updatedAt }.first
    }

    /// Mở lại app: dựng lại thanh player ở đúng vị trí nghe cuối cùng (đang tạm
    /// dừng), bấm play là nghe tiếp. Chỉ chạy khi player còn trống hoàn toàn —
    /// không đụng phiên đang phát hay preview.
    func restoreLastSession(books: [Book]) {
        guard currentBookId == nil, justPreviewURL == nil, live == nil else { return }
        guard let session = Self.latestResumable(books: books,
                                                 positions: store.positions) else { return }

        var list: [(index: Int, title: String, url: URL)] = []
        for ch in session.book.manifest.chapters {
            if let url = session.book.audioPath(for: ch) {
                list.append((ch.index, session.book.chapterTitle(ch), url))
            }
        }
        guard let entry = list.first(where: { $0.index == session.chapter.index }) else { return }

        playlist = list
        currentBookId = session.book.id
        currentChapterIndex = session.chapter.index
        currentTime = session.pos.seconds
        duration = 0
        isPlaying = false
        restorePending = true
        measureDuration(of: entry.url)
    }

    /// Đo thời lượng file ở nền để thanh tua hiện đúng khi còn chờ play.
    private func measureDuration(of url: URL) {
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            guard let dur = try? await asset.load(.duration) else { return }
            let d = dur.seconds
            guard d.isFinite, d > 0, let self, self.restorePending else { return }
            self.duration = d
        }
    }

    func loadItem(index: Int, autoPlay: Bool, seekTo: Double?) {
        if live != nil { stopLive() }
        guard let entry = playlist.first(where: { $0.index == index }) else { return }
        currentChapterIndex = index
        playbackError = nil
        restorePending = false
        let item = AVPlayerItem(url: entry.url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        duration = 0
        // quay lại vị trí đã nghe của chương này (nếu có và không chỉ định khác)
        let target = seekTo ?? savedPosition(bookId: currentBookId, chapter: index)
        if let t = target, t > 1 {
            player.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            currentTime = t
        } else {
            currentTime = 0
        }
        if autoPlay { resume() } else { pause() }
    }

    func togglePlay() {
        // đang chờ part tiếp theo — pause/resume không tác dụng, sẽ tự phát khi có
        if let st = live {
            switch st.phase {
            case .buffering, .waitingFirst, .waitingQueue: return
            default: break
            }
        }
        isPlaying ? pause() : resume()
    }

    func resume() {
        ensureRemoteCommands()
        // phiên khôi phục từ lần chạy trước — nạp file thật tại vị trí đã lưu rồi phát
        if restorePending, let ch = currentChapterIndex {
            loadItem(index: ch, autoPlay: true, seekTo: currentTime)
            return
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePositionNow()
        updateNowPlaying()
    }

    func seek(by delta: Double) {
        let t = max(0, min(duration, currentTime + delta))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func seek(to t: Double) {
        if let st = live, st.phase == .playing || st.phase == .buffering || st.phase == .finishing {
            // chỉ cho tua trong phạm vi audio đã sẵn sàng
            let clamped = min(max(0, t), max(st.readyDuration - 0.5, 0))
            let (n, off) = LiveTimeline.part(containing: clamped, durations: st.durations,
                                             gap: st.gap, maxPart: st.readyMaxPart)
            let offset = max(0, off)
            if n == st.currentPart, liveGapPendingPart == nil, player.currentItem != nil {
                player.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = LiveTimeline.baseOffset(part: n, durations: st.durations,
                                                      gap: st.gap) + offset
            } else if st.files[n] != nil {
                playLivePart(n, seekTo: offset, autoPlay: isPlaying || st.autoResume)
            }
            return
        }
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func next(autoAdvance: Bool = true) {
        guard let cur = currentChapterIndex,
              let idx = playlist.firstIndex(where: { $0.index == cur }),
              idx + 1 < playlist.count
        else { return }
        let entry = playlist[idx + 1]
        loadItem(index: entry.index, autoPlay: isPlaying || autoAdvance, seekTo: nil)
    }

    func prev() {
        if let st = live, st.phase == .playing || st.phase == .finishing {
            let base = LiveTimeline.baseOffset(part: st.currentPart, durations: st.durations,
                                               gap: st.gap)
            if currentTime - base > 3 {
                seek(to: base)
                return
            }
            if st.currentPart > 1, st.files[st.currentPart - 1] != nil {
                playLivePart(st.currentPart - 1, autoPlay: isPlaying)
                return
            }
            seek(to: 0)
            return
        }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        guard let cur = currentChapterIndex,
              let idx = playlist.firstIndex(where: { $0.index == cur }), idx > 0
        else { return }
        let entry = playlist[idx - 1]
        loadItem(index: entry.index, autoPlay: isPlaying, seekTo: nil)
    }

    private func applyRate() {
        if isPlaying {
            player.rate = rate
        }
        updateNowPlaying()
    }

    private func handleChapterEnd() {
        if sleepAtChapterEnd {
            isPlaying = false
            sleepAtChapterEnd = false
            updateNowPlaying()
            return
        }
        if live != nil {
            liveAdvance()
            return
        }
        if autoAdvance {
            next()
        } else {
            // Tắt tự phát tiếp — dừng ở cuối chương, nạp sẵn chương sau ở
            // trạng thái tạm dừng để bấm play là nghe chương mới.
            isPlaying = false
            updateNowPlaying()
            next(autoAdvance: false)
        }
    }

    // MARK: - Nghe dần (phát part worker vừa dựng)

    /// Base cộng vào item time để ra currentTime theo timeline file cuối.
    private func liveTimeBase() -> Double {
        guard let st = live else { return 0 }
        if liveGapPendingPart != nil { return liveGapStartOffset }
        return LiveTimeline.baseOffset(part: st.currentPart, durations: st.durations, gap: st.gap)
    }

    /// Mở phiên nghe dần cho chương đang được dựng.
    func startLive(book: Book, chapter: Chapter, job: RenderJob, buildDir: URL,
                   queuedBehind: String?) {
        stopLive()
        justPreviewURL = nil
        currentBookId = book.id
        currentChapterIndex = chapter.index
        var st = LiveState(book: book, chapter: chapter, jobId: job.id, buildDir: buildDir,
                           gap: store.settings.silenceSec, chapterChars: chapter.chars)
        st.phase = queuedBehind.map { .waitingQueue($0) } ?? .waitingFirst
        absorbScan(into: &st)
        st.gapURL = LiveAudio.makeGapFile(seconds: st.gap)
        playlist = [(index: chapter.index, title: book.chapterTitle(chapter),
                     url: st.files[1] ?? buildDir)]
        live = st
        duration = st.readyDuration
        currentTime = 0
        maybeStartLive()
    }

    /// Hút kết quả quét build dir + parts.json vào state, đo bù duration thiếu.
    private func absorbScan(into st: inout LiveState) {
        let scan = LiveScanner.scan(buildDir: st.buildDir)
        st.files.merge(scan.files) { cur, _ in cur }
        if let m = scan.manifest {
            st.partsTotal = max(st.partsTotal, m.partsTotal)
            st.charsDone = m.parts.compactMap(\.chars).reduce(0, +)
            st.audioDone = m.parts.compactMap(\.audioSec).reduce(0, +)
            for p in m.parts {
                guard let n = Int((p.file as NSString).deletingPathExtension
                    .dropFirst("part-".count)) else { continue }
                if let d = p.audioSec { st.durations[n] = d }
            }
        }
        // part mp3 (Edge) không có audio_sec trong manifest → đo qua AVAsset
        for (n, url) in st.files where st.durations[n] == nil {
            let asset = AVURLAsset(url: url)
            Task { [weak self] in
                guard let dur = try? await asset.load(.duration) else { return }
                let d = dur.seconds
                guard d.isFinite, d > 0 else { return }
                self?.liveDurationResolved(part: n, seconds: d)
            }
        }
    }

    private func liveDurationResolved(part n: Int, seconds d: Double) {
        guard var st = live, (st.durations[n] ?? 0) < 0.01 else { return }
        st.durations[n] = d
        live = st
        if st.phase != .finishing { duration = st.readyDuration }
    }

    /// Part 1 đã sẵn sàng & tốc độ render đủ nhanh (hoặc chưa đo được) → phát.
    private func maybeStartLive() {
        guard let st = live else { return }
        var isWaiting = false
        if case .waitingFirst = st.phase { isWaiting = true }
        if case .waitingQueue = st.phase { isWaiting = true }
        guard isWaiting else { return }
        guard st.files[1] != nil,
              LiveTimeline.isSafeToStart(rateEMA: st.rateEMA, playbackRate: Double(rate))
        else { return }
        var part = 1
        var offset: Double?
        if let pos = savedPosition(bookId: st.book.id, chapter: st.chapter.index), pos > 1 {
            let (p, o) = LiveTimeline.part(containing: min(pos, st.readyDuration),
                                           durations: st.durations, gap: st.gap,
                                           maxPart: st.readyMaxPart)
            part = p
            offset = o
        }
        playLivePart(part, seekTo: offset, autoPlay: true)
    }

    private func playLivePart(_ n: Int, seekTo offset: Double? = nil, autoPlay: Bool) {
        guard var st = live, let url = st.files[n] else { return }
        st.currentPart = n
        st.phase = .playing
        live = st
        liveGapPendingPart = nil
        playbackError = nil
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        duration = st.readyDuration
        if let o = offset, o > 0.5 {
            player.seek(to: CMTime(seconds: o, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        currentTime = LiveTimeline.baseOffset(part: n, durations: st.durations, gap: st.gap)
            + (offset ?? 0)
        if autoPlay {
            resume()
        } else {
            player.pause()
            isPlaying = false
        }
    }

    /// Hết 1 item (part hoặc khoảng lặng) trong phiên live → quyết định bước tiếp.
    private func liveAdvance() {
        if let pending = liveGapPendingPart {
            liveGapPendingPart = nil
            playLivePart(pending, autoPlay: true)
            return
        }
        guard var st = live else { return }
        let n = st.currentPart
        if let final = pendingFinalURL {
            handoverToFinal(final, afterPart: n)
            return
        }
        if let nextURL = st.files[n + 1] {
            if let gapURL = st.gapURL, (st.durations[n] ?? 0) > 0.01 {
                // chèn khoảng lặng đúng bằng gap của file cuối để timeline khớp
                liveGapPendingPart = n + 1
                liveGapStartOffset = LiveTimeline.baseOffset(part: n, durations: st.durations,
                                                             gap: st.gap)
                    + (st.durations[n] ?? 0)
                let item = AVPlayerItem(url: gapURL)
                item.audioTimePitchAlgorithm = .spectral
                player.replaceCurrentItem(with: item)
                // item cũ phát hết đã tự pause player, replace không tự phát lại —
                // không play thì gap không bao giờ chạy → treo ở ranh giới part
                resume()
            } else {
                playLivePart(n + 1, autoPlay: true)
            }
        } else if st.terminal {
            st.phase = .failed("Job dựng bị hủy/lỗi — đã phát hết phần sẵn có")
            live = st
            isPlaying = false
            savePositionNow()
        } else {
            st.autoResume = isPlaying
            st.phase = .buffering
            live = st
            isPlaying = false
        }
    }

    /// Worker báo tiến độ part — cập nhật state, đánh thức trạng thái chờ.
    func liveProgress(jobId: String, part: Int, parts: Int, chars: Int?,
                      audioSec: Double?, partAudioSec: Double?, partSeconds: Double?) {
        guard var st = live, st.jobId == jobId else { return }
        st.partsTotal = max(st.partsTotal, parts)
        if st.files[part] == nil {   // worker ghi file trước khi emit event
            for ext in ["wav", "mp3"] {
                let u = st.buildDir.appendingPathComponent(
                    String(format: "part-%03d", part) + "." + ext)
                if FileManager.default.fileExists(atPath: u.path) { st.files[part] = u; break }
            }
        }
        if let d = partAudioSec, st.durations[part] == nil { st.durations[part] = d }
        if let c = chars { st.charsDone += c }
        if let a = audioSec { st.audioDone = a }
        if let d = partAudioSec, let w = partSeconds, w > 0.3 {
            let r = d / w     // vận tốc render của part này (giây audio / giây đợi)
            st.rateEMA = st.rateEMA.map { $0 + (r - $0) * 0.5 } ?? r
            st.partSecondsEMA = st.partSecondsEMA.map { $0 + (w - $0) * 0.5 } ?? w
        }
        st.stage = nil
        live = st
        duration = st.readyDuration

        switch st.phase {
        case .waitingFirst, .waitingQueue:
            maybeStartLive()
        case .buffering where st.files[st.currentPart + 1] != nil:
            playLivePart(st.currentPart + 1, autoPlay: st.autoResume)
        default:
            break
        }
    }

    func liveStage(jobId: String, stage: String) {
        guard var st = live, st.jobId == jobId else { return }
        st.stage = stage
        live = st
    }

    /// Job lỗi/hủy — phát nốt các part sẵn có rồi dừng.
    func liveJobFailed(jobId: String, message: String) {
        guard var st = live, st.jobId == jobId else { return }
        st.terminal = true
        var noMoreAudio = st.files[st.currentPart + 1] == nil
        if case .waitingFirst = st.phase { noMoreAudio = true }
        if case .waitingQueue = st.phase { noMoreAudio = true }
        if noMoreAudio {
            st.phase = .failed(message)
            live = st
            isPlaying = false
        } else {
            live = st
        }
    }

    /// Worker trả file hoàn chỉnh — chuyển phiên live sang file đó.
    func liveJobFinished(jobId: String, finalURL: URL) {
        guard let st = live, st.jobId == jobId else { return }
        pendingFinalURL = finalURL
        switch st.phase {
        case .playing:
            var s = st
            s.phase = .finishing
            live = s
        case .buffering, .waitingFirst, .waitingQueue, .failed:
            handoverToFinal(finalURL, afterPart: st.currentPart)
        case .finishing:
            break
        }
    }

    /// Chuyển sang file hoàn chỉnh tại đúng ranh giới part — không lệch vị trí.
    private func handoverToFinal(_ final: URL, afterPart n: Int) {
        guard let st = live else { return }
        let autoPlay: Bool
        switch st.phase {
        case .playing, .finishing, .waitingFirst, .waitingQueue: autoPlay = true
        case .buffering: autoPlay = st.autoResume
        case .failed: autoPlay = false
        }
        let offset: Double
        if n >= 1 {
            offset = LiveTimeline.baseOffset(part: n + 1, durations: st.durations, gap: st.gap)
        } else if let saved = savedPosition(bookId: st.book.id, chapter: st.chapter.index),
                  saved > 1 {
            offset = saved
        } else {
            offset = 0
        }
        savePositionNow()
        live = nil
        liveGapPendingPart = nil
        pendingFinalURL = nil

        var list: [(Int, String, URL)] = []
        for ch in st.book.manifest.chapters {
            if let u = st.book.audioPath(for: ch) {
                list.append((ch.index, st.book.chapterTitle(ch), u))
            }
        }
        if !list.contains(where: { $0.0 == st.chapter.index }) {
            list.append((st.chapter.index, st.book.chapterTitle(st.chapter), final))
        }
        playlist = list.map { (index: $0.0, title: $0.1, url: $0.2) }
        loadItem(index: st.chapter.index, autoPlay: autoPlay, seekTo: offset)

        // đã chuyển sang file cuối → build dir không còn cần (nếu cài đặt cho phép dọn)
        if store.settings.cleanupParts {
            try? FileManager.default.removeItem(at: st.buildDir)
        }
    }

    /// Kết thúc phiên nghe dần (giữ job chạy ngầm, vị trí đã lưu theo timeline file cuối).
    func stopLive() {
        guard let st = live else { return }
        savePositionNow()
        live = nil
        liveGapPendingPart = nil
        pendingFinalURL = nil
        currentBookId = st.book.id
        currentChapterIndex = st.chapter.index
    }

    // MARK: - Vị trí & bookmark

    private func savedPosition(bookId: String?, chapter: Int) -> Double? {
        guard let bookId, let pos = store.positions[bookId],
              pos.chapterIndex == chapter else { return nil }
        return pos.seconds
    }

    private func savePositionThrottled() {
        guard Date().timeIntervalSince(lastSave) > 5 else { return }
        savePositionNow()
    }

    func savePositionNow() {
        guard let bookId = currentBookId, let ch = currentChapterIndex else { return }
        store.positions[bookId] = PlaybackPosition(bookId: bookId, chapterIndex: ch,
                                                   seconds: currentTime, updatedAt: Date())
        store.updateMeta(for: bookId) { $0.lastPlayedChapter = ch }
        lastSave = Date()
    }

    func addBookmark(note: String) {
        guard let bookId = currentBookId, let ch = currentChapterIndex,
              let entry = playlist.first(where: { $0.index == ch }) else { return }
        store.bookmarks.append(Bookmark(bookId: bookId, chapterIndex: ch,
                                        chapterTitle: entry.title,
                                        seconds: currentTime, note: note))
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Double?) {
        sleepTimerMinutes = minutes
        sleepTimerEnd = minutes.map { Date().addingTimeInterval($0 * 60) }
        if minutes == nil { sleepAtChapterEnd = false }
    }

    private func checkSleepTimer() {
        guard let end = sleepTimerEnd, isPlaying else { return }
        if Date() >= end {
            pause()
            sleepTimerEnd = nil
            sleepTimerMinutes = nil
        }
    }

    var sleepTimerRemaining: Int? {
        guard let end = sleepTimerEnd else { return nil }
        return max(0, Int(end.timeIntervalSinceNow / 60 + 0.999))
    }

    // MARK: - Media key & Now Playing (macOS)

    /// Đăng ký lười — app đang idle không chiếm media key của trình phát khác;
    /// lần đầu phát thật mới nhận play/pause/tua từ phím cứng & Control Center.
    private var remoteCommandsReady = false

    private func ensureRemoteCommands() {
        guard !remoteCommandsReady else { return }
        remoteCommandsReady = true
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [NSNumber(value: 15)]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: -15) }
            return .success
        }
        cc.skipForwardCommand.preferredIntervals = [NSNumber(value: 15)]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.seek(by: 15) }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.prev() }
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    var nowPlayingTitle: String {
        if let idx = currentChapterIndex,
           let entry = playlist.first(where: { $0.index == idx }) {
            return entry.title
        }
        return justPreviewURL?.lastPathComponent ?? "Đang phát"
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: "StoryAudio",
            MPMediaItemPropertyPlaybackDuration: max(duration, 0),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
    }
}
