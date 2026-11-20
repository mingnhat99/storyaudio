import SwiftUI

/// Tab Hàng đợi: tiến trình render, queue, log worker.
struct JobsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            jobsHeader

            if let endsAt = app.cooldownEndsAt {
                CooldownBanner(endsAt: endsAt)
            }

            if let job = app.currentJob {
                CurrentJobCard(job: job)
            }

            if app.jobs.isEmpty {
                emptyState
            } else {
                jobsTable
            }

            WorkerLogView()
        }
    }

    private var jobsHeader: some View {
        let queueBusy = app.jobs.contains { $0.state == .queued || $0.state == .rendering }
        let hasFinished = app.jobs.contains { $0.state != .queued && $0.state != .rendering }
        let pauseLabel = app.queuePaused ? "Tiếp tục hàng đợi" : "Tạm dừng hàng đợi"
        let pauseIcon = app.queuePaused ? "play" : "pause"
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hàng đợi dựng audio").font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(DS.ink)
                Text("Render theo từng đoạn — đứt giữa chừng chạy lại sẽ tiếp tục từ đoạn dở")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.togglePauseQueue()
            } label: {
                Label(pauseLabel, systemImage: pauseIcon)
            }
            .buttonStyle(.soft)
            .disabled(!queueBusy)
            Button("Xóa job đã xong") {
                app.removeFinishedJobs()
            }
            .buttonStyle(.soft)
            .disabled(!hasFinished)
        }
        .padding(16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(DS.accent.opacity(0.6))
            Text("Chưa có job dựng audio nào")
                .font(.headline).foregroundStyle(DS.ink)
            Text("Chọn một sách trong sidebar, đánh dấu các chương rồi bấm “Dựng audio”.\nĐang dựng dở mà tắt app thì mở lại sẽ tiếp tục từ đoạn dở.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                app.mainTab = 0
                app.selectedBookId = nil
            } label: {
                Label("Mở Thư viện", systemImage: "books.vertical")
            }
            .buttonStyle(.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var jobsTable: some View {
        Table(app.jobs) {
            TableColumn("Chương") { (j: RenderJob) in
                VStack(alignment: .leading, spacing: 2) {
                    Text(j.chapterTitle).lineLimit(1)
                    Text(j.bookTitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            TableColumn("Trạng thái") { (j: RenderJob) in
                stateCell(j)
            }
            TableColumn("Audio") { (j: RenderJob) in
                Text(j.audioSec > 0 ? formatClock(j.audioSec) : "—")
                    .monospacedDigit()
            }
            TableColumn("Engine") { (j: RenderJob) in
                Text("\(j.engineLabel) · \(j.voice)").lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
            TableColumn("") { (j: RenderJob) in
                jobActions(j)
            }
        }
        .frame(minHeight: 180)
    }

    private func stateCell(_ j: RenderJob) -> some View {
        let color: Color = stateColor(j.state)
        let counter = j.state == .rendering && j.parts > 0
            ? " (\(j.part)/\(j.parts))" : ""
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(j.state.label + counter).monospacedDigit()
        }
    }

    private func jobActions(_ j: RenderJob) -> some View {
        var buttons: [Button<Text>] = []
        if j.state == .rendering || j.state == .queued {
            buttons.append(Button("Hủy") { app.cancelJob(j.id) })
        }
        if j.state == .failed || j.state == .cancelled {
            buttons.append(Button("Chạy lại") { app.retryJob(j.id) })
        }
        if j.state == .done, !j.outPath.isEmpty {
            buttons.append(Button("Mở trong Finder") {
                app.revealInFinder([URL(fileURLWithPath: j.outPath)])
            })
        }
        return HStack(spacing: 4) {
            ForEach(buttons.indices, id: \.self) { i in
                buttons[i].font(.footnote).buttonStyle(.link)
            }
        }
    }

    private func stateColor(_ s: JobState) -> Color {
        switch s {
        case .queued: return .secondary
        case .rendering: return DS.accent
        case .done: return DS.success
        case .failed: return DS.danger
        case .cancelled: return DS.warning
        }
    }
}

/// Banner nghỉ làm mát giữa các chương: đếm ngược thời gian còn nghỉ và
/// nút bỏ nghỉ để chạy ngay chương kế.
struct CooldownBanner: View {
    @EnvironmentObject var app: AppModel
    let endsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = max(endsAt.timeIntervalSince(timeline.date), 0)
            HStack(spacing: 14) {
                Image(systemName: "snowflake")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang nghỉ cho máy nguội — \(formatClock(remaining)) nữa")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    Text("Chương kế tiếp tự chạy khi hết nghỉ. Điều chỉnh trong Cài đặt → Nâng cao.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    app.skipCooldown()
                } label: {
                    Label("Bỏ nghỉ, chạy ngay", systemImage: "play.fill")
                }
                .buttonStyle(.soft)
                .help("Không đợi hết thời gian nghỉ, dựng chương kế ngay")
            }
            .padding(14)
            .card(cornerRadius: 14)
        }
    }
}

struct CurrentJobCard: View {
    @EnvironmentObject var app: AppModel
    let job: RenderJob

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.chapterTitle).font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.ink)
                HStack(spacing: 12) {
                    Text("\(job.bookTitle)")
                    Text("·").foregroundStyle(.tertiary)
                    Text(job.engineLabel + " · " + job.voice)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(job.chars) ký tự")
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    if job.parts > 0 {
                        Text("Đoạn \(job.part)/\(job.parts)").monospacedDigit()
                    }
                    if job.audioSec > 0 {
                        Text("đã có \(formatClock(job.audioSec) + " audio")").monospacedDigit()
                    }
                    if let eta = job.etaSec {
                        Text("còn ~\(formatClock(eta))").monospacedDigit()
                    }
                    if job.rssMb > 0 {
                        Text(String(format: "RAM %.1f GB", job.rssMb / 1024)).monospacedDigit()
                    }
                    if let started = job.startedAt {
                        Text("bắt đầu \(started.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: job.progress)
                    .frame(maxWidth: .infinity)
            }
            Spacer()
            VStack(spacing: 8) {
                Button {
                    if let book = app.books.first(where: { $0.id == job.bookId }),
                       let ch = book.manifest.chapters.first(where: { $0.index == job.chapterIndex }) {
                        app.startLiveListening(book: book, chapter: ch)
                    }
                } label: {
                    Label("Nghe ngay", systemImage: "play.circle.dotted")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.soft)
                .help("Nghe từng đoạn đã dựng xong, không chờ cả chương")
                Button(role: .destructive) {
                    app.cancelJob(job.id)
                } label: {
                    Label("Hủy chương này", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.softDanger)
                .help("Hủy job đang dựng")
            }
            .frame(width: 170)
        }
        .padding(18)
        .card(cornerRadius: 16)
    }
}

struct WorkerLogView: View {
    @EnvironmentObject var app: AppModel
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
                HStack {
                    Label("Log worker", systemImage: "doc.text.magnifyingglass")
                        .font(.footnote)
                    Spacer()
                    Toggle("Tự cuộn", isOn: $autoScroll).controlSize(.small)
                    Button("Sao chép") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.workerLog.joined(separator: "\n"),
                                                       forType: .string)
                    }
                    .buttonStyle(.softCompact)
                    Text("pid \(app.worker.pid)").monospacedDigit()
                        .font(.caption).foregroundStyle(.tertiary)
                }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(wrappedLog)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 10)
                        .id("logend")
                }
                .frame(height: 130)
                .clipped()
                .onChange(of: app.workerLog.count) { _, _ in
                    if autoScroll { proxy.scrollTo("logend", anchor: .bottom) }
                }
            }
        }
        // Panel footer nằm trong card trắng: góc trên bo để khớp góc dưới
        // đã được clip bởi card, góc dưới phẳng vì sát mép card.
        .background(
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 14, bottomLeading: 0,
                                                      bottomTrailing: 0, topTrailing: 14),
                                   style: .continuous)
                .fill(DS.surfaceSecondary)
        )
    }

    /// Text không tự gãy giữa một "từ" — dòng log chứa đường dẫn dài không
    /// wrap được sẽ tràn ngang khỏi panel. Chèn zero-width space sau các ký
    /// tự ngắt tự nhiên (/ · . · _ · -) để luôn có điểm gãy dòng.
    private var wrappedLog: String {
        app.workerLog.map { line in
            line.count > 60
                ? line.replacingOccurrences(of: "/", with: "/\u{200B}")
                    .replacingOccurrences(of: ".", with: ".\u{200B}")
                    .replacingOccurrences(of: "_", with: "_\u{200B}")
                    .replacingOccurrences(of: "-", with: "-\u{200B}")
                : line
        }.joined(separator: "\n")
    }
}
