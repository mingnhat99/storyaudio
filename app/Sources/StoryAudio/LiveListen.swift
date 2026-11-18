import AVFoundation
import Foundation

// MARK: - Toán timeline bản nghe dần (thuần, tách khỏi player để dễ kiểm chứng)

/// Timeline file cuối = part1 + gap + part2 + gap + … (worker ghép như vậy),
/// nên bản nghe dần phát part + chèn đúng gap sẽ trùng khớp tuyệt đối vị trí
/// trong file cuối → handover / nhớ vị trí / bookmark không lệch giây nào.
enum LiveTimeline {

    /// Vị trí tuyệt đối (timeline file cuối) của ĐẦU part n.
    static func baseOffset(part n: Int, durations: [Int: Double], gap: Double) -> Double {
        guard n > 1 else { return 0 }
        var t = 0.0
        for i in 1..<n { t += (durations[i] ?? 0) + gap }
        return t
    }

    /// Part nào chứa vị trí pos (timeline file cuối) + offset bên trong part đó.
    /// Vị trí nằm trong khoảng lặng giữa 2 part → đầu part sau (không trả offset âm).
    static func part(containing pos: Double, durations: [Int: Double], gap: Double,
                     maxPart: Int) -> (part: Int, offset: Double) {
        var base = 0.0
        for i in 1...max(1, maxPart) {
            let d = durations[i] ?? 0
            if pos < base + d { return (i, max(0, pos - base)) }
            base += d + gap
        }
        return (max(1, maxPart), 0)
    }

    /// Hệ số an toàn: render phải nhanh hơn tốc độ phát ít nhất 15% để bắt đầu
    /// (che dao động vận tốc của nano đo được 0.9–2.0x realtime).
    static let safetyFactor = 1.15

    /// Đủ điều kiện phát tiếp không giật: r̂ ≥ 1.15 × tốc độ phát.
    /// Chưa đo được vận tốc (Edge / part có sẵn từ lần trước) → cho phát,
    /// underrun handler lo phần còn lại.
    static func isSafeToStart(rateEMA: Double?, playbackRate: Double) -> Bool {
        guard let r = rateEMA else { return true }
        return r >= safetyFactor * Double(playbackRate)
    }

    /// Ước lượng chờ trước khi part tiếp theo xong: giây render trung bình ×
    /// tỷ lệ ký tự của part tiếp so với trung bình.
    static func nextPartETA(avgPartSeconds: Double?, avgChars: Double, nextChars: Int?) -> Double? {
        guard let avg = avgPartSeconds, avg > 0, avgChars > 0 else { return nil }
        let ratio = ((nextChars.map(Double.init) ?? avgChars) / avgChars)
        return avg * min(max(ratio, 0.2), 5)
    }
}

// MARK: - Manifest part worker ghi dần trong build dir

struct PartsManifest: Codable {
    struct Part: Codable {
        let file: String
        let chars: Int?
        let audioSec: Double?

        enum CodingKeys: String, CodingKey { case file, chars; case audioSec = "audio_sec" }
    }

    let version: Int
    let partsTotal: Int
    let gapS: Double
    let parts: [Part]

    enum CodingKeys: String, CodingKey {
        case version, parts
        case partsTotal = "parts_total"
        case gapS = "gap_s"
    }
}

/// Quét build dir lấy các part đã có + manifest.
enum LiveScanner {
    static func scan(buildDir: URL) -> (files: [Int: URL], manifest: PartsManifest?) {
        var files: [Int: URL] = [:]
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: buildDir.path) {
            for name in names {
                guard name.hasPrefix("part-"),
                      name.hasSuffix(".wav") || name.hasSuffix(".mp3"),
                      let n = Int((name as NSString).deletingPathExtension
                          .dropFirst("part-".count))
                else { continue }
                files[n] = buildDir.appendingPathComponent(name)
            }
        }
        let manifest: PartsManifest? = {
            guard let data = try? Data(contentsOf: buildDir.appendingPathComponent("parts.json"))
            else { return nil }
            return try? JSONDecoder().decode(PartsManifest.self, from: data)
        }()
        return (files, manifest)
    }
}

// MARK: - Tiện ích audio cho nghe dần

enum LiveAudio {
    /// File khoảng lặng đúng `seconds` giây — chèn giữa các part cho khớp
    /// timeline file cuối. 24 kHz mono float, zero-init = im lặng.
    static func makeGapFile(seconds: Double) -> URL? {
        guard seconds > 0.05 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storyaudio-live-gap-\(Int(seconds * 1000)).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let sr = 24000.0
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                      channels: 1, interleaved: false),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings)
        else { return nil }
        let frames = AVAudioFrameCount((sr * seconds).rounded())
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        do { try file.write(from: buf) } catch { return nil }
        return url
    }
}

// MARK: - Trạng thái phiên nghe dần

struct LiveState: Equatable {
    enum Phase: Equatable {
        case waitingQueue(String)   // chờ tới lượt dựng (tên chương đang dựng trước)
        case waitingFirst           // chưa có part nào để phát
        case playing
        case buffering              // đã nghe hết part sẵn có, chờ part tiếp
        case finishing              // render xong — hết part hiện tại sẽ chuyển file cuối
        case failed(String)
    }

    let book: Book
    let chapter: Chapter
    let jobId: String
    let buildDir: URL
    let gap: Double
    let chapterChars: Int

    var phase: Phase = .waitingFirst
    var currentPart = 0
    var partsTotal = 0
    var durations: [Int: Double] = [:]     // part → giây audio
    var files: [Int: URL] = [:]
    var charsDone = 0
    var audioDone = 0.0
    var rateEMA: Double?                   // giây audio / giây render (EMA)
    var partSecondsEMA: Double?            // giây render trung bình 1 part
    var stage: String?                     // "concat" | "encode" từ render_stage
    var autoResume = true                  // buffering xong phát tiếp tự động
    var terminal = false                   // job hủy/lỗi — phát nốt part sẵn có rồi dừng
    var gapURL: URL?

    var readyMaxPart: Int { files.keys.max() ?? 0 }

    /// Tổng timeline đã sẵn sàng nghe (bao gồm cả gap sau part cuối).
    var readyDuration: Double {
        var t = 0.0
        for i in 1...max(readyMaxPart, 1) { t += (durations[i] ?? 0) + gap }
        return t
    }

    /// Ước tính tổng thời lượng cả chương theo tỷ lệ ký tự đã có audio.
    var estimatedTotal: Double? {
        guard charsDone > 0, chapterChars > 0 else { return nil }
        return audioDone / Double(charsDone) * Double(chapterChars)
    }

    var nextPartETA: Double? {
        guard partsTotal > 0, charsDone > 0 else { return nil }
        let done = min(readyMaxPart, partsTotal)
        guard done > 0 else { return nil }
        let avgChars = Double(charsDone) / Double(done)
        return LiveTimeline.nextPartETA(avgPartSeconds: partSecondsEMA, avgChars: avgChars,
                                        nextChars: nil)
    }

    /// Đang nghe nhanh hơn tốc độ render → sẽ còn giật thêm.
    var listeningFasterThanRender: Bool {
        guard let r = rateEMA else { return false }
        return r < 1.0
    }
}
