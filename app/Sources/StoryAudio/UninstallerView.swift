import SwiftUI

/// Màn hình gỡ cài đặt: chọn thành phần cần xóa rồi thực hiện và thoát app.
struct UninstallerView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var opts = AppModel.UninstallOptions()
    @State private var confirm1 = false
    @State private var confirm2 = false

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 26, design: .rounded))
                        .foregroundStyle(DS.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gỡ cài đặt StoryAudio")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.ink)
                        Text("Chọn những gì muốn xóa — file gốc của bạn (epub, audio đã xuất ngoài output/, ref-*.wav, .venv-vieneu, audiobook.py…) không bao giờ bị đụng đến.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(16)

                ScrollView {
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(text: "Luôn nên xóa")
                            Toggle("Dữ liệu app (thư viện, vị trí nghe, bookmark, cài đặt)", isOn: $opts.appData)
                            if runningFromAppBundle {
                                Toggle("Đưa StoryAudio.app vào Thùng rác (khôi phục được)", isOn: $opts.appToTrash)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(cornerRadius: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(text: "Tùy chọn — đọc kỹ trước khi bật")
                            Toggle("Sách đã import + audio trong output/ + file đoạn tạm build/", isOn: $opts.booksAndOutput)
                            Toggle("Model TTS trong models/ (~610MB — tải lại được qua Model Manager)", isOn: $opts.models)
                            Toggle("Venv .venv-engine + Python .python (runtime app tự cài trên máy mới)", isOn: $opts.venvEngine)
                            Toggle("File worker app copy vào thư mục làm việc (tts_worker.py, catalog.json, setup_runtime.sh)", isOn: $opts.workerFiles)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(cornerRadius: 14)

                        VStack(alignment: .leading, spacing: 10) {
                            if opts.models {
                                Label("Model xong có thể tải lại — nhưng mất ~600MB+ và thời gian tải.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(DS.warning)
                            }
                            if opts.booksAndOutput {
                                Label("Audio đã dựng trong output/ sẽ mất vĩnh viễn nếu không copy đi nơi khác.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(DS.warning)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(cornerRadius: 14)
                    }
                    .padding(16)
                }

                Divider()
                HStack {
                    Text("Chạy từ terminal: ./uninstall.sh (--all / --data-only)")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Hủy") { dismiss() }.buttonStyle(.soft).keyboardShortcut(.cancelAction)
                    if !confirm1 {
                        Button("Gỡ cài đặt…", role: .destructive) { confirm1 = true }
                            .buttonStyle(.softDanger)
                    } else if !confirm2 {
                        Text("Chắc chắn?").foregroundStyle(.secondary)
                        Button("Xóa ngay", role: .destructive) {
                            confirm2 = true
                            app.performUninstall(opts)
                        }
                        .buttonStyle(.danger)
                    } else {
                        ProgressView("Đang gỡ cài đặt…")
                    }
                }
                .padding(14)
            }
        }
        .background(TitlebarSeparatorHider())
        .preferredColorScheme(.light)
        .tint(DS.accent)
        .fontDesign(.rounded)
        .frame(width: 640, height: 520)
        .interactiveDismissDisabled(confirm2)
    }

    private var runningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
