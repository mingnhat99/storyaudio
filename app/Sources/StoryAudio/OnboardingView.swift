import SwiftUI

/// Onboarding 3 bước: chọn thư mục → cài runtime → tải model
struct OnboardingView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(DS.accentSoft).frame(width: 56, height: 56)
                        Image(systemName: "headphones")
                            .font(.system(size: 24, design: .rounded))
                            .foregroundStyle(DS.accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("StoryAudio").font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.ink)
                        Text("Chuyển sách và văn bản thành audio — chạy ngay trên máy bạn")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    stepIndicator
                }
                .padding(28)
                Group {
                    switch app.onboardingStep {
                    case .workspace: WorkspaceStep()
                    case .runtime: RuntimeStep()
                    case .model: ModelStep()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.light)
        .tint(DS.accent)
        .fontDesign(.rounded)
        .frame(width: 880, height: 620)
    }

    private var stepIndex: Int {
        switch app.onboardingStep {
        case .workspace: return 1
        case .runtime: return 2
        case .model: return 3
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach([("Thư mục", 1), ("Runtime", 2), ("Model", 3)], id: \.1) { label, n in
                HStack(spacing: 4) {
                    Image(systemName: stepIndex >= n ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(stepIndex >= n ? DS.accent : .secondary)
                    Text(label).font(.callout).foregroundStyle(stepIndex >= n ? DS.ink : .secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .chip()
    }
}

// MARK: - Bước 1: workspace

struct WorkspaceStep: View {
    @EnvironmentObject var app: AppModel
    @State private var showPicker = false
    private let store = Store.shared

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 54, design: .rounded)).foregroundStyle(.tint)
            Text("Chọn thư mục làm việc").font(.title2.bold())
            Text("App sẽ lưu model TTS, sách đã import và file audio vào thư mục này.\nNếu bạn đã có thư mục làm việc cũ (chứa `models/` — vd dùng với script CLI), chọn luôn thư mục đó — app sẽ nhận diện model sẵn có và không tải lại.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Đề xuất cho máy này").font(.caption).foregroundStyle(.tertiary)
                    Text(store.defaultWorkspaceGuess())
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
                .card(cornerRadius: 12)
                Button("Dùng thư mục đề xuất") {
                    app.chooseWorkspace(URL(fileURLWithPath: store.defaultWorkspaceGuess()))
                }
                .buttonStyle(.soft)
            }

            Button("Chọn thư mục khác…") { showPicker = true }
                .buttonStyle(.primary)
            Spacer()
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder],
                      onCompletion: { result in
                          if case .success(let url) = result {
                              app.chooseWorkspace(url)
                          }
                      })
    }
}

// MARK: - Bước 2: runtime Python

struct RuntimeStep: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 48, design: .rounded)).foregroundStyle(.tint)
            Text("Cài runtime TTS").font(.title2.bold())
            Text("App cần môi trường Python với thư viện VieNeu-TTS (~2GB dung lượng tải lần đầu).\nSẽ tạo venv `.venv-engine` trong thư mục làm việc và cài từ PyPI. Máy chưa có Python ≥ 3.10 thì app tự tải Python chuẩn (~25MB thêm).")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)

            if app.runtimeSetupRunning {
                ProgressView("Đang cài đặt… có thể mất vài phút")
                ScrollView {
                    Text(app.runtimeSetupLog.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 680, maxHeight: 220)
                .padding(8)
                .card(cornerRadius: 12)
            } else {
                Button("Bắt đầu cài đặt") { app.runRuntimeSetup() }
                    .buttonStyle(.primary)
            }
            if !app.runtimeSetupRunning && !app.runtimeSetupLog.isEmpty {
                ScrollView {
                    Text(app.runtimeSetupLog.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 680, maxHeight: 200)
                .padding(8)
                .card(cornerRadius: 12)
            }
            if app.runtimeSetupLog.contains(where: { $0.contains("thất bại") }) {
                Text("Nếu máy đã có venv (vd `.venv-vieneu`) mà vẫn thấy màn này — macOS đang chặn quyền truy cập thư mục. Bấm “Chọn lại thư mục” rồi chọn thư mục làm việc để cấp quyền.")
                    .font(.caption).foregroundStyle(DS.warning)
                    .frame(maxWidth: 560)
                Button("Chọn lại thư mục") {
                    app.onboardingStep = .workspace
                }
                .buttonStyle(.soft)
            }
        }
        .padding(24)
    }
}

// MARK: - Bước 3: chọn & tải model

struct ModelStep: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ModelManagerView(showHeader: false)
            Divider()
            HStack {
                Text("Bạn có thể tải thêm / xóa model bất cứ lúc nào trong trang Giọng đọc & Model.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dùng Edge-TTS (không cần tải)") {
                    Store.shared.settings.engine = .edge
                    app.finishOnboarding()
                }
                .buttonStyle(.soft)
                Button("Hoàn tất") { app.finishOnboarding() }
                    .buttonStyle(.primary)
                    .disabled(!app.modelStatuses.contains {
                        $0.installed && ($0.id == "vieneu-nano" || $0.id == "vieneu-turbo"
                                         || $0.id == "kokoro-en")
                    })
            }
            .padding(16)
        }
    }
}
