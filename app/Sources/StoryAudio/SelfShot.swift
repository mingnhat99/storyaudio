import SwiftUI
import AppKit
import CoreGraphics

/// Hook điều hướng UI cho kiểm thử tự động (debug):
/// StoryAudio --ui-preview [--ui-phase onboarding --ui-step workspace|runtime|model|terms]
///                     [--ui-tab 0-3] [--ui-settings-tab 0-3] [--ui-book <index>]
///                     [--ui-step license|license-online|terms — hiện dialog điều khoản]
/// Kết hợp với --shot để chụp từng màn hình mà không cần tương tác chuột.
enum UIPreview {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-preview") }
    static var phase: String? { value("ui-phase") }
    static var step: String? { value("ui-step") }
    static var tab: Int? { value("ui-tab").flatMap(Int.init) }
    static var settingsTab: Int? { value("ui-settings-tab").flatMap(Int.init) }
    static var bookIndex: Int? { value("ui-book").flatMap(Int.init) }

    private static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--\(flag)"), args.count > idx + 1 else { return nil }
        return args[idx + 1]
    }
}

/// Chế độ tự chụp màn hình (debug): StoryAudio --shot /tmp/ui.png
/// App chụp CHÍNH window của mình bằng cacheDisplay in-process —
/// không cần quyền Screen Recording, chụp được cả window chưa hiện trên màn hình.
/// Chụp xong thì exit(0) để dùng trong loop kiểm thử UI tự động.
enum SelfShot {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--shot"), args.count > idx + 1 else { return nil }
        return args[idx + 1]
    }

    private static var shotDelay: Double? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "--shot-delay"), args.count > idx + 1,
              let d = Double(args[idx + 1]) else { return nil }
        return d
    }

    private static var fired = false

    /// Đợi UI sẵn sàng rồi chụp: ưu tiên window thật, fallback sang hosting view
    /// offscreen. Gọi từ AppDelegate — không phụ thuộc RootView.task.
    static func runOffscreenShot() {
        guard let path = requested, !fired else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(1_500_000_000))
            SelfShot.ensureFallbackWindow()
            try? await Task.sleep(nanoseconds: UInt64((shotDelay ?? 4) * 1_000_000_000))
            // Chờ bootstrap xong (phase thoát .boot) — worker lạnh nạp lâu,
            // không chờ sẽ chụp nhầm màn loading. Tối đa 25s.
            for _ in 0..<50 where AppModel.shared.phase == .boot {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            SelfShot.capture(to: path)
            exit(0)
        }
    }

    /// Ghi log chẩn đoán ra file (stdout/stderr bị buffer hoặc mất khi launch qua `open`).
    static func log(_ line: String) {
        fputs("SELFSHOT: \(line)\n", stderr)
        let url = URL(fileURLWithPath: "/tmp/selfshot-debug.log")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + stamped).write(to: url, atomically: true, encoding: .utf8)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first {
            $0.contentView != nil && !$0.isMiniaturized && $0.frame.width > 200
        }
    }

    /// Window offscreen chứa RootView — fallback khi launch context không cho
    /// SwiftUI WindowGroup tạo window (background session). cacheDisplay vẫn
    /// render được full UI từ view chưa hiện trên màn hình.
    private static var fallbackWindow: NSWindow?

    @MainActor
    private static func ensureFallbackWindow() {
        guard fallbackWindow == nil else { return }
        let app = AppModel.shared
        let hosting = NSHostingView(
            rootView: RootView()
                .environmentObject(app)
                .environmentObject(app.player)
                .environmentObject(app.store)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.light)
                .tint(DS.accent)
                .fontDesign(.rounded))
        hosting.frame = NSRect(x: 0, y: 0, width: 1220, height: 780)
        let w = NSWindow(contentRect: hosting.frame,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.contentView = hosting
        fallbackWindow = w
    }

    @MainActor
    private static func capture(to path: String) {
        let p = AppModel.shared.player
        log("shot state: time=" + String(format: "%.1f", p.currentTime)
            + " dur=\(p.duration) playing=\(p.isPlaying) idx=\(p.currentChapterIndex ?? -1) err=\(p.playbackError ?? "-")")
        for w in NSApp.windows {
            log("window '\(w.title)' visible=\(w.isVisible) frame=\(w.frame) type=\(type(of: w))")
        }
        guard let view = mainWindow?.contentView ?? fallbackWindow?.contentView else {
            log("không tìm thấy window nội dung — không chụp được")
            return
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            log("không tạo được bitmap rep")
            return
        }
        view.cacheDisplay(in: bounds, to: rep)
        guard let cg = rep.cgImage else {
            log("không chuyển được CGImage")
            return
        }
        let out = NSBitmapImageRep(cgImage: cg)
        guard let data = out.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        log("đã ghi \(path) (\(cg.width)x\(cg.height))")
    }
}
