import AppKit
import Darwin

/// Tự cài app vào Applications khi chạy từ DMG / chỗ khác ngoài Applications
/// (pattern Chrome/Firefox): lần đầu mở app từ file .dmg, hiện một hộp thoại —
/// bấm nút là app tự copy bundle vào Applications rồi tự khởi động lại từ đó,
/// người dùng không phải kéo thả thủ công. Dữ liệu app (settings, thư viện,
/// workspace, venv Python) đều nằm ngoài app bundle nên chuyển chỗ không mất gì.
enum AppInstaller {

    /// Hỏi cài khi: đang chạy từ .app bundle (không phải binary trần khi dev),
    /// chưa nằm trong Applications, chạy từ DMG (/Volumes) hoặc bundle bị
    /// quarantine (file đi từ Internet về) — và không phải chế độ test tự động.
    static var shouldPromptForInstall: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        guard !isDebugRun else { return false }
        guard !insideApplications(bundle.path) else { return false }
        // Nghi override để test hộp thoại không phải mount DMG thật
        if UserDefaults.standard.bool(forKey: "debugAlwaysOfferInstall") { return true }
        return bundle.path.hasPrefix("/Volumes/") || hasQuarantineXattr(bundle.path)
    }

    /// Hộp thoại + thực hiện chuyển chỗ. Gọi đầu applicationDidFinishLaunching —
    /// nếu người dùng chọn chuyển và chuyển thành công, app terminate ngay trong
    /// hàm này (không chạm tới bootstrap); từ chối/lỗi → app chạy tiếp bình thường
    /// và sẽ hỏi lại ở lần mở sau (điều kiện "chưa nằm trong Applications" vẫn đúng).
    @discardableResult
    static func promptIfNeeded() -> Bool {
        guard shouldPromptForInstall else { return false }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Cài đặt StoryAudio vào Applications?"
        alert.informativeText = "StoryAudio đang chạy từ file cài đặt (.dmg). "
            + "Chuyển vào Applications là app tự copy rồi khởi động lại — không cần "
            + "kéo thả, dữ liệu đã có được giữ nguyên."
        alert.addButton(withTitle: "Chuyển vào Applications")
        alert.addButton(withTitle: "Không, cứ chạy từ đây")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        installAndRelaunch()
        return true   // chuyển thành công thì không bao giờ tới đây (app đã terminate)
    }

    // MARK: - Chuyển bundle

    private static func installAndRelaunch() {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let myVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

        // Đích thử lần lượt: /Applications (chuẩn) → ~/Applications (máy bị hạn quyền)
        let dests = [URL(fileURLWithPath: "/Applications/\(source.lastPathComponent)"),
                     URL(fileURLWithPath: NSHomeDirectory() + "/Applications/\(source.lastPathComponent)")]

        for dest in dests {
            if fm.fileExists(atPath: dest.path) {
                // Cùng phiên bản đã nằm ở đích → chỉ mở lại bản đã cài, khỏi copy
                if let v = Bundle(url: dest)?.infoDictionary?["CFBundleShortVersionString"] as? String,
                   v == myVersion {
                    relaunch(to: dest)
                }
                // Bản cũ khác phiên bản → vào Thùng rác (khôi phục được) rồi copy đè
                try? fm.trashItem(at: dest, resultingItemURL: nil)
            }
            // ~/Applications có thể chưa tồn tại trên máy sạch
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: source, to: dest)
                relaunch(to: dest)
            } catch {
                continue   // thiếu quyền / đích hỏng → thử đích kế
            }
        }
        showFailureAlert()
    }

    /// Mở bản vừa cài rồi thoát bản hiện tại. Shell con ngủ 1 giây trước khi
    /// `open` — kịp cho app cũ terminate xong, LaunchServices không nhầm launch
    /// bundle mới thành activate instance đang chạy (cùng bundle id).
    private static func relaunch(to dest: URL) -> Never {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "sleep 1; open '\(dest.path)'"]
        try? sh.run()
        NSApp.terminate(nil)
        exit(0)   // phòng hờ — terminate thường không quay về đây
    }

    private static func showFailureAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Không cài được StoryAudio vào Applications"
        alert.informativeText = "Không đủ quyền ghi vào thư mục Applications. "
            + "App vẫn chạy từ vị trí hiện tại — hoặc kéo thả thủ công từ file .dmg."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Điều kiện hỏi

    private static var isDebugRun: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--shot") || args.contains("--ui-preview")
            || args.contains("--smoke-render")
    }

    private static func insideApplications(_ path: String) -> Bool {
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// Bundle tải từ Internet về mang xattr com.apple.quarantine — dấu hiệu
    /// "file cài đặt" kể cả khi người dùng đã copy app ra Desktop rồi mới mở.
    private static func hasQuarantineXattr(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }
}
