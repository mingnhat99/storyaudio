import SwiftUI

/// Quản lý model: tải / hủy / xóa / kiểm tra — dùng trong onboarding và Cài đặt.
struct ModelManagerView: View {
    @EnvironmentObject var app: AppModel
    var showHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quản lý model TTS").font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(DS.ink)
                        Text("Model chạy offline ngay trên máy — tải một lần, dùng mãi mãi.")
                            .foregroundStyle(.secondary).font(.callout)
                    }
                    Spacer()
                    Button {
                        Task { await app.refreshModels() }
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.soft)
                }
                .padding(20)
            }
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(app.catalog) { model in
                        ModelCard(model: model)
                    }
                    if app.catalog.isEmpty {
                        Text("Đang tải danh sách model…").foregroundStyle(.secondary).padding()
                    }
                    HStack {
                        Text("Cửa hàng model lấy từ catalog.json — mở rộng được sau.")
                            .font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    }.padding(.horizontal, 4)
                }
                .padding(20)
            }
        }
    }
}

struct ModelCard: View {
    @EnvironmentObject var app: AppModel
    let model: CatalogModel
    @State private var confirmDelete = false

    var status: ModelStatus? { app.status(for: model.id) }
    var progress: DownloadProgress? { app.downloadProgress[model.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: status?.installed == true
                  ? "checkmark.seal.fill" : "arrow.down.circle")
                .font(.system(size: 30, design: .rounded))
                .foregroundStyle(status?.installed == true ? DS.success : DS.accent)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.name).font(.headline)
                    if model.voiceClone == true {
                        Label("Clone giọng", systemImage: "person.wave.2.fill")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(DS.accentDeep)
                            .background(DS.accentSoft, in: Capsule())
                    }
                    if model.engineKind == .edge {
                        Label("Online", systemImage: "wifi")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(DS.warning)
                            .background(DS.warning.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    statusView
                }
                Text(model.description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    if let mb = model.sizeMb, mb > 0 {
                        Label("\(Int(mb)) MB", systemImage: "internaldrive")
                    }
                    if let ram = model.ramGb, ram > 0 {
                        Label(String(format: "RAM ~%.1f GB", ram), systemImage: "memorychip")
                    }
                    if let q = model.quality {
                        Label(q, systemImage: "waveform")
                    }
                    if model.speedControl == true {
                        Label("Đổi tốc độ khi dựng", systemImage: "gauge.with.needle")
                    }
                }
                .font(.caption).foregroundStyle(.tertiary)

                if let p = progress, p.finished != true, status?.installed != true {
                    DownloadProgressView(progress: p)
                }
                if let s = status, s.partial, progress == nil {
                    Text("Thiếu \(s.missing.count) file — tải lại để hoàn tất")
                        .font(.caption).foregroundStyle(DS.warning)
                }
                if let s = status, s.installed, s.sizeBytes > 0 {
                    Text("Đã cài — \(formatBytes(s.sizeBytes))")
                        .font(.caption).foregroundStyle(DS.success)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(status?.installed == true ? DS.success.opacity(0.35) : .clear,
                              lineWidth: 1.5)
        )
        .confirmationDialog("Xóa model khỏi máy?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Xóa \(model.name)", role: .destructive) {
                Task { await app.deleteModel(model.id) }
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Giải phóng \(status.map { formatBytes($0.sizeBytes) } ?? "dung lượng"). Sách đã dựng không bị ảnh hưởng; tải lại được bất cứ lúc nào.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if model.noDownload == true {
            Label("Sẵn sàng", systemImage: "checkmark")
                .font(.caption).foregroundStyle(DS.success)
        } else if progress != nil {
            HStack(spacing: 8) {
                if progress?.cancelled != true {
                    Button("Hủy tải") { app.cancelDownload(model.id) }
                        .buttonStyle(.softCompact)
                }
            }
        } else if status?.installed == true {
            HStack(spacing: 8) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Xóa", systemImage: "trash")
                }
                .buttonStyle(.softDangerCompact)
            }
        } else {
            Button {
                app.requestDownload(model)
            } label: {
                Label(status?.partial == true ? "Tải tiếp phần còn thiếu" : "Tải về",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.primary)
        }
    }
}

struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if progress.cancelled == true {
                    Text("Đã hủy — bấm tải lại để tiếp tục từ phần đã xong")
                        .foregroundStyle(DS.warning)
                } else if progress.finished == true {
                    Text("Hoàn tất ✓").foregroundStyle(DS.success)
                } else {
                    Text("Đang tải: \(progress.file ?? "…")")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let pct = progress.pct {
                        Text(String(format: "%.1f%%", pct)).monospacedDigit()
                    }
                    if let speed = progress.speedBps, speed > 0 {
                        Text("\(formatBytes(Int64(speed)))/s").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            if let done = progress.doneBytes, let total = progress.totalBytes, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                Text("\(formatBytes(done)) / \(formatBytes(total))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.top, 2)
    }
}
