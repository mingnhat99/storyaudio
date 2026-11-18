import SwiftUI
import UniformTypeIdentifiers

/// AppDelegate: kích hoạt cửa sổ và chạy bootstrap/shot từ lifecycle AppKit —
/// không phụ thuộc cửa sổ có "appear" theo SwiftUI hay không (launch context
/// nền đôi khi không order-front window, làm .task không chạy).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.contentView != nil {
            w.makeKeyAndOrderFront(nil)
        }
        guard UIPreview.enabled || SelfShot.requested != nil else { return }
        let app = AppModel.shared
        if UIPreview.enabled && UIPreview.phase == "onboarding" {
            app.previewOnboarding()
        } else {
            Task { @MainActor in
                await app.bootstrap()
                app.applyPreviewNavigation()
            }
        }
        // Launch context nền đôi khi không cho WindowGroup tạo window —
        // route qua hosting view offscreen để vẫn chụp được UI.
        SelfShot.runOffscreenShot()
    }
}

@main
struct StoryAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--smoke-render") {
                SmokeRunnerView()
                    .environmentObject(app)
                    .environmentObject(app.player)
                    .environmentObject(app.store)
            } else {
                RootView()
                    .environmentObject(app)
                    .environmentObject(app.player)
                    .environmentObject(app.store)
                    .frame(minWidth: 1100, minHeight: 700)
                    // Design system pastel: light mode trước, dark mode làm sau
                    .preferredColorScheme(.light)
                    .tint(DS.accent)
                    .fontDesign(.rounded)
            }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1220, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            // File > Nhập sách / Dán text
            CommandGroup(after: .newItem) {
                Button("Nhập sách…") { app.importPanelShown = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Dán text thành sách…") { app.pastePanelShown = true }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            // App > Cài đặt (Cmd+,)
            CommandGroup(replacing: .appSettings) {
                Button("Cài đặt…") {
                    app.mainTab = 3
                    app.selectedBookId = nil
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // Menu Điều khiển phát
            CommandMenu("Điều khiển") {
                Button("Phát / Tạm dừng") { app.player.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Tua lại 15 giây") { app.player.seek(by: -15) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Tua tới 15 giây") { app.player.seek(by: 15) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Button("Chương trước") { app.player.prev() }
                Button("Chương sau") { app.player.next() }
            }
            // Help > Hướng dẫn
            CommandGroup(after: .help) {
                Button("Hướng dẫn sử dụng…") {
                    let readme = URL(fileURLWithPath: app.store.settings.workspacePath)
                        .appendingPathComponent("README-APP.md")
                    if FileManager.default.fileExists(atPath: readme.path) {
                        NSWorkspace.shared.open(readme)
                    }
                }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            switch app.phase {
            case .boot:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(app.bootMessage).foregroundStyle(.secondary)
                    if app.runtimeMissing && app.phase == .boot {
                        Text("Chưa có runtime Python — sẽ chuyển sang cài đặt…")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .onboarding:
                OnboardingView()
            case .ready:
                MainView()
            }
        }
        // Tắt hairline hệ thống dưới unified toolbar (xem WindowChrome).
        .background(TitlebarSeparatorHider())
        // Dialog điều khoản chịu trách nhiệm — phủ lên mọi giai đoạn
        // (onboarding, model manager, rail model) trước khi cho tải model
        // offline hoặc dùng model online lần đầu.
        .overlay {
            if let gate = app.licenseGate {
                LicenseConsentView(gate: gate)
                    .zIndex(10)
            }
        }
        // Điều khoản sử dụng app (lần chạy đầu) — trên cùng: chặn bootstrap
        // trước khi app có thể chạm tới model nào, kể cả model mặc định.
        .overlay {
            if app.termsGate {
                TermsConsentView()
                    .zIndex(20)
            }
        }
        .preferredColorScheme(.light)
        .tint(DS.accent)
        .fontDesign(.rounded)
        .task {
            // SelfShot + bootstrap đã được AppDelegate chủ động trigger —
            // .task ở đây chỉ chạy khi window thật xuất hiện (khi chạy --shot
            // qua hosting view offscreen, AppDelegate lo phần còn lại).
            if UIPreview.enabled && UIPreview.phase == "onboarding" {
                app.previewOnboarding()
            } else {
                await app.bootstrap()
                app.applyPreviewNavigation()
            }
        }
    }
}

// MARK: - Điều hướng sidebar (thay TabView — pattern macOS chuẩn)

enum SidebarSelection: Hashable {
    case book(String)
    case voices
    case jobs
    case audio
    case settings
}

struct MainView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarSearch = ""
    // Độ rộng sidebar tự quản (NavigationSplitView đã bỏ — NSSplitViewController
    // dựng lại divider private sau mỗi relayout, không có API tắt hẳn).
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 270

    private var selection: SidebarSelection? {
        if app.mainTab == 0, let id = app.selectedBookId {
            return .book(id)
        }
        switch app.mainTab {
        case 1: return .voices
        case 2: return .jobs
        case 3: return .settings
        case 4: return .audio
        default: return nil
        }
    }

    private var selectionBinding: Binding<SidebarSelection?> {
        Binding(get: { selection }, set: { sel in
            switch sel {
            case .book(let id):
                app.mainTab = 0
                app.selectedBookId = id
            case .voices:
                app.mainTab = 1; app.selectedBookId = nil
            case .jobs:
                app.mainTab = 2; app.selectedBookId = nil
            case .settings:
                app.mainTab = 3; app.selectedBookId = nil
            case .audio:
                app.mainTab = 4; app.selectedBookId = nil
            case nil:
                app.mainTab = 0; app.selectedBookId = nil
            }
        })
    }

    private var filteredBooks: [Book] {
        guard !sidebarSearch.isEmpty else { return app.books }
        return app.books.filter {
            $0.title.localizedCaseInsensitiveContains(sidebarSearch)
                || $0.author.localizedCaseInsensitiveContains(sidebarSearch)
        }
    }

    private var activeJobs: Int {
        app.jobs.count { $0.state == .rendering || $0.state == .queued }
    }

    private var playerVisible: Bool {
        player.currentBookId != nil || player.justPreviewURL != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Chia cột thủ công thay NavigationSplitView: sidebar + tay kéo
            // trong suốt + detail — không NSSplitView thì không bao giờ có
            // divider hệ thống tự vẽ lại sau resize.
            HStack(spacing: 0) {
                sidebar
                    .frame(width: sidebarWidth)
                SidebarResizeHandle(width: $sidebarWidth)
                detail
            }

            if playerVisible {
                PlayerBar()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: playerVisible)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: app.modelMissingPrompt)
        .overlay(alignment: .topTrailing) {
            if let missing = app.modelMissingPrompt {
                ModelMissingBanner(modelId: missing)
                    .padding()
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let ok = urls.filter { ["epub", "pdf", "txt", "docx", "text"]
                .contains($0.pathExtension.lowercased()) }
            guard !ok.isEmpty else { return false }
            Task { await app.importFiles(ok) }
            return true
        }
        .fileImporter(isPresented: $app.importPanelShown,
                      allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data,
                                            .pdf, .plainText, .text,
                                            UTType(filenameExtension: "docx") ?? .data],
                      allowsMultipleSelection: true,
                      onCompletion: { result in
                          if case .success(let urls) = result {
                              Task { await app.importFiles(urls) }
                          }
                      })
        .sheet(isPresented: $app.pastePanelShown) {
            PasteTextView()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: selectionBinding) {
            Section {
                ForEach(filteredBooks) { book in
                    BookRow(book: book)
                        .tag(SidebarSelection.book(book.id))
                        .contextMenu {
                            Button("Mở thư mục sách") {
                                NSWorkspace.shared.open(book.dir)
                            }
                            Button("Xóa khỏi thư viện…", role: .destructive) {
                                app.deleteBook(book)
                            }
                        }
                }
                if app.books.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "books.vertical")
                            .font(.title2).foregroundStyle(.tertiary)
                        Text("Chưa có sách nào.\nKéo-thả EPUB / PDF / TXT / DOCX vào cửa sổ, hoặc dùng nút Nhập sách ở thanh công cụ.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("Thư viện")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.bodyText)
            }
            if sidebarSearch.isEmpty {
                Section {
                    sidebarTool(.voices, "Giọng đọc & Model", "waveform")
                    sidebarTool(.jobs, "Hàng đợi", "list.bullet.rectangle", badge: activeJobs)
                    sidebarTool(.audio, "Audio đã tạo", "music.note.list")
                    sidebarTool(.settings, "Cài đặt", "gearshape")
                } header: {
                    Text("Công cụ")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.bodyText)
                }
            }
        }
        .listStyle(.sidebar)
        // Ô tìm sách tự vẽ ghim trên cùng thay .searchable — ô tìm kiếm hệ
        // thống của placement .sidebar không có API thêm khoảng cách với
        // toolbar, tự vẽ mới kiểm soát được margin phía trên.
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarSearchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
        }
        // Ẩn material xám của List rồi phủ canvas phẳng — List .sidebar
        // tự vẽ material hệ thống, .hidden đơn thuần không đủ, phải tô
        // canvas đè lên để khớp nền phần detail.
        .scrollContentBackground(.hidden)
        .background(DS.canvas)
        .environment(\.defaultMinListRowHeight, 44)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.importPanelShown = true
                } label: {
                    Label("Nhập sách", systemImage: "plus")
                }
                .help("Nhập EPUB / PDF / TXT / DOCX (⌘O)")
                Button {
                    app.pastePanelShown = true
                } label: {
                    Label("Dán text", systemImage: "doc.on.clipboard")
                }
                .help("Tạo sách từ text dán vào (⇧⌘V)")
            }
        }
    }

    /// Ô tìm sách trong sidebar — bề mặt trắng + viền tóc cho khớp input
    /// chỗ khác trong app, kèm nút xóa trống nhanh.
    private var sidebarSearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.bodyText)
            TextField("Tìm sách…", text: $sidebarSearch)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(DS.ink)
            if !sidebarSearch.isEmpty {
                Button {
                    sidebarSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.bodyText.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Xóa tìm kiếm")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1)
        )
    }

    private func sidebarTool(_ sel: SidebarSelection,
                             _ title: String,
                             _ icon: String,
                             badge: Int = 0) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .imageScale(.medium)
                .foregroundStyle(DS.ink)
            Spacer(minLength: 8)
            if badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(DS.accent, in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .tag(sel)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        ZStack {
            switch selection {
            case .book(let id):
                if let book = app.books.first(where: { $0.id == id }) {
                    BookDetailView(book: book)
                        .navigationTitle(book.title)
                } else {
                    LibraryWelcome()
                }
            case .voices:
                VoicesView().navigationTitle("Giọng đọc & Model")
            case .jobs:
                JobsView().navigationTitle("Hàng đợi")
            case .audio:
                AudioLibraryView().navigationTitle("Audio đã tạo")
            case .settings:
                SettingsView().navigationTitle("Cài đặt")
            case nil:
                LibraryWelcome()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Panel nội dung: card trắng phẳng nổi nhẹ trên nền canvas
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DS.surface)
                .shadow(color: DS.cardShadow, radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
    }
}

// MARK: - Màn chào Thư viện khi chưa chọn sách

struct LibraryWelcome: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var store: Store

    private var resume: PlayerViewModel.ResumableSession? {
        PlayerViewModel.latestResumable(books: app.books, positions: store.positions)
    }

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(DS.accentSoft)
                    .frame(width: 132, height: 132)
                Image(systemName: "headphones")
                    .font(.system(size: 50, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.accent)
            }
            VStack(spacing: 8) {
                Text("Chào mừng đến StoryAudio")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.ink)
                Text("Chuyển sách, file hoặc text thành audio theo chương —\ndựng bằng engine trên máy hoặc giọng đọc trực tuyến.")
                    .font(.callout).foregroundStyle(DS.bodyText)
                    .multilineTextAlignment(.center)
            }
            if let resume {
                ContinueListeningCard(book: resume.book, chapter: resume.chapter,
                                      position: resume.pos)
            }
            HStack(spacing: 12) {
                Button {
                    app.importPanelShown = true
                } label: {
                    Label("Nhập sách", systemImage: "plus")
                }
                .buttonStyle(.primary)
                Button {
                    app.pastePanelShown = true
                } label: {
                    Label("Dán text", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.soft)
            }
            Text("Hoặc kéo-thả file EPUB, PDF, TXT, DOCX thẳng vào cửa sổ")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Thư viện")
    }
}

// MARK: - Card tiếp tục nghe dở

/// Tóm tắt vị trí nghe lần cuối + nút phát tiếp ngay tại vị trí đó.
struct ContinueListeningCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerViewModel
    let book: Book
    let chapter: Chapter
    let position: PlaybackPosition

    var body: some View {
        Button {
            // playChapter tự quay về vị trí đã lưu của chương này
            player.playChapter(book: book, chapters: book.manifest.chapters,
                               startAt: chapter.index)
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let cover = book.coverURL, let nsImage = NSImage(contentsOf: cover) {
                        Image(nsImage: nsImage).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Rectangle().fill(DS.accentSoft)
                            Image(systemName: "book.closed")
                                .foregroundStyle(DS.accent)
                        }
                    }
                }
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Tiếp tục nghe")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.accentDeep)
                    Text("\(book.title) · \(book.chapterTitle(chapter))")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                    Text("Dừng ở \(formatClock(position.seconds)) · "
                         + position.updatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "play.fill")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(DS.accent)
                    .padding(10)
                    .background(Circle().fill(DS.accentSoft))
            }
            .padding(12)
            .frame(maxWidth: 460)
            .card(cornerRadius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Nghe tiếp \(book.chapterTitle(chapter)) từ \(formatClock(position.seconds))")
    }
}

struct ModelMissingBanner: View {
    @EnvironmentObject var app: AppModel
    let modelId: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
            Text("Model chưa tải: \(modelId)")
                .font(.callout)
            Button("Tải model") {
                app.modelMissingPrompt = nil
                app.mainTab = 1
                app.selectedBookId = nil
            }
            .buttonStyle(.primaryCompact)
            Button("Để sau") { app.modelMissingPrompt = nil }
                .buttonStyle(.link)
        }
        .padding(12)
        .card(cornerRadius: 14)
    }
}
