import SwiftUI

/// Chế độ kiểm thử tự động (không GUI): StoryAudio --smoke-render <file-sách>
/// Chạy nguyên luồng app: bootstrap → import → render chương nhỏ nhất → exit 0/1.
struct SmokeRunnerView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack {
            ProgressView()
            Text("Đang chạy smoke test — xem log terminal").padding()
        }
        .task { await runSmoke() }
    }

    private func runSmoke() async {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--smoke-render"), args.count > idx + 1 else {
            print("SMOKE: thiếu đường dẫn file sách")
            exit(2)
        }
        let bookPath = args[idx + 1]
        print("SMOKE: bootstrap…")
        print("SMOKE: settings engine=\(app.store.settings.engine.rawValue) mode=\(app.store.settings.mode)")
        // smoke test không có người dùng bấm đồng ý — tự xác nhận điều khoản
        app.store.settings.termsAcceptedVersion = AppTerms.version
        await app.bootstrap()
        for _ in 0..<60 {
            if app.phase == .ready { break }
            if app.phase == .onboarding {
                print("SMOKE: app vào onboarding — seed settings trước (defaults write)")
                exit(3)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard app.phase == .ready else {
            print("SMOKE: bootstrap không đến ready sau 30s")
            exit(4)
        }
        print("SMOKE: ready ✓ engine=\(app.engineInfo) books=\(app.books.count) voices=\(app.voices.count)")

        print("SMOKE: import \(bookPath)")
        let idsBefore = Set(app.books.map(\.id))
        await app.importFiles([URL(fileURLWithPath: bookPath)])
        // sách vừa import (books sắp theo id — không phải cứ last là sách mới)
        guard let book = app.books.first(where: { !idsBefore.contains($0.id) })
            ?? app.books.last else {
            print("SMOKE: import thất bại")
            exit(5)
        }
        print("SMOKE: sách '\(book.title)' — \(book.manifest.chapters.count) chương")

        guard let smallest = book.manifest.chapters.min(by: { $0.chars < $1.chars }) else {
            exit(6)
        }
        print("SMOKE: render chương nhỏ nhất #\(smallest.index) '\(smallest.title)' (\(smallest.chars) ký tự)")
        let t0 = Date()
        app.enqueueChapters(book, indices: [smallest.index])

        while Date().timeIntervalSince(t0) < 60 * 12 {
            if let job = app.jobs.first(where: { $0.chapterIndex == smallest.index }) {
                switch job.state {
                case .done:
                    let dt = Date().timeIntervalSince(t0)
                    print("SMOKE: XONG ✓ file=\(job.outPath) audio=\(job.audioSec)s sau \(Int(dt))s")
                    print("SMOKE_RESULT: OK")
                    exit(0)
                case .failed:
                    print("SMOKE: THẤT BẠI: \(job.error ?? "?")")
                    print("SMOKE: --- worker log (30 dòng cuối) ---")
                    for l in app.workerLog.suffix(30) { print("  | \(l)") }
                    print("SMOKE_RESULT: FAIL")
                    exit(1)
                case .cancelled:
                    print("SMOKE: BỊ HỦY: \(job.error ?? "?")")
                    exit(1)
                default:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("SMOKE: timeout 12 phút")
        exit(1)
    }
}
