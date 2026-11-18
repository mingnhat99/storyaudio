import SwiftUI

/// Thanh player dưới cùng + màn hình mở rộng (bookmark, sleep timer).
struct PlayerBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var showFull = false
    @State private var bookmarkNote = ""
    @State private var showBookmarkField = false
    // Kéo thanh tua: hiển thị vị trí đích cục bộ, chỉ tua thật khi thả tay
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showRemaining = false
    @State private var lastVolume: Float = 1

    var sleepActive: Bool { player.sleepTimerEnd != nil || player.sleepAtChapterEnd }

    var chapterPos: (pos: Int, total: Int)? {
        guard let cur = player.currentChapterIndex,
              let idx = player.playlist.firstIndex(where: { $0.index == cur }),
              player.playlist.count > 1 else { return nil }
        return (idx + 1, player.playlist.count)
    }

    var volumeIcon: String {
        if player.volume <= 0.001 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1" }
        if player.volume < 0.67 { return "speaker.wave.2" }
        return "speaker.wave.3"
    }

    var title: String {
        if let idx = player.currentChapterIndex,
           let entry = player.playlist.first(where: { $0.index == idx }) {
            return entry.title
        }
        return player.justPreviewURL?.lastPathComponent ?? "Đang phát"
    }

    /// File đang phát (để mở trong Finder) — không tính phiên nghe dần
    /// vì playlist khi đó trỏ vào part tạm trong build dir.
    var currentFileURL: URL? {
        guard player.live == nil else { return nil }
        if let idx = player.currentChapterIndex,
           let entry = player.playlist.first(where: { $0.index == idx }) {
            return entry.url
        }
        return player.justPreviewURL
    }

    var body: some View {
        HStack(spacing: 14) {
                // Điều khiển
                HStack(spacing: 6) {
                    Button { player.prev() } label: { Image(systemName: "backward.end.fill") }
                        .disabled(player.playlist.isEmpty)
                        .help("Chương trước")
                    // Nút tua ±15s: màu trầm hơn accent — nhường tâm điểm
                    // cho nút play, tránh cả dãy nút cùng một màu gắt.
                    Button { player.seek(by: -15) } label: {
                        Image(systemName: "gobackward.15")
                            .foregroundStyle(DS.bodyText)
                    }
                        .help("Tua lại 15 giây (⌘←)")
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.playCircle)
                    .animation(.snappy(duration: 0.25), value: player.isPlaying)
                    .help("Phát / Tạm dừng (Space)")
                    Button { player.seek(by: 15) } label: {
                        Image(systemName: "goforward.15")
                            .foregroundStyle(DS.bodyText)
                    }
                        .help("Tua tới 15 giây (⌘→)")
                    Button { player.next() } label: { Image(systemName: "forward.end.fill") }
                        .disabled(player.playlist.isEmpty)
                        .help("Chương sau")
                }
                .buttonStyle(.link)
                .font(.system(size: 19, design: .rounded))

                // Tiến trình
                VStack(spacing: 3) {
                    HStack {
                        Text(formatClock(isScrubbing ? scrubValue : player.currentTime)).monospacedDigit()
                            .font(.footnote).foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubValue : player.currentTime },
                                set: { scrubValue = $0 }),
                            in: 0...max(player.duration, 1)
                        ) { editing in
                            if editing {
                                scrubValue = player.currentTime
                                isScrubbing = true
                            } else {
                                player.seek(to: scrubValue)
                                isScrubbing = false
                            }
                        }
                        .controlSize(.regular)
                        .accessibilityLabel("Vị trí đang phát")
                        durationLabel
                    }
                    HStack(spacing: 8) {
                        if let st = player.live {
                            liveChip(st)
                        }
                        if let err = player.playbackError {
                            errorChip(err)
                        }
                        if let pos = chapterPos {
                            Text("\(pos.pos)/\(pos.total)")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(DS.bodyText)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(DS.surfaceSecondary))
                        }
                        Text(title).font(.system(size: 13.5, weight: .medium, design: .rounded))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1).frame(maxWidth: 480)
                    }
                }

                // Âm lượng
                HStack(spacing: 4) {
                    Button {
                        if player.volume > 0.001 {
                            lastVolume = player.volume
                            player.volume = 0
                        } else {
                            player.volume = lastVolume
                        }
                    } label: {
                        Image(systemName: volumeIcon)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.link)
                    .help(player.volume > 0.001 ? "Tắt tiếng" : "Bật tiếng")
                    Slider(value: $player.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 72)
                        .accessibilityLabel("Âm lượng")
                }

                Spacer()

                // Tốc độ
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { r in
                        Button {
                            player.rate = Float(r)
                        } label: {
                            if abs(player.rate - Float(r)) < 0.01 {
                                Label(String(format: "%.2gx", r), systemImage: "checkmark")
                            } else { Text(String(format: "%.2gx", r)) }
                        }
                    }
                } label: {
                    Text(String(format: "%.2gx", player.rate))
                        .monospacedDigit().font(.callout)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .chip()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Tốc độ phát — không méo giọng")

                // Tự phát chương tiếp theo
                Button {
                    player.autoAdvance.toggle()
                } label: {
                    Image(systemName: "infinity")
                        .font(.system(size: 16, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .foregroundStyle(player.autoAdvance ? DS.accentDeep : DS.ink)
                        .background {
                            if player.autoAdvance {
                                Capsule().fill(DS.accentSoft)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.link)
                .animation(.snappy(duration: 0.2), value: player.autoAdvance)
                .help(player.autoAdvance
                      ? "Tự phát chương tiếp theo: đang BẬT — bấm để tắt"
                      : "Tự phát chương tiếp theo: đang TẮT — bấm để bật")
                .accessibilityLabel("Tự phát chương tiếp theo")
                .accessibilityValue(player.autoAdvance ? "Bật" : "Tắt")

                // Sleep timer
                Menu {
                    if sleepActive {
                        Button("Tắt hẹn giờ") {
                            player.setSleepTimer(minutes: nil)
                            player.sleepAtChapterEnd = false
                        }
                    }
                    ForEach([10.0, 15.0, 30.0, 45.0, 60.0, 90.0], id: \.self) { m in
                        let isSelected = player.sleepTimerMinutes == m
                            && player.sleepTimerEnd != nil
                        Button(isSelected ? "✓ \(Int(m)) phút" : "\(Int(m)) phút") {
                            player.setSleepTimer(minutes: m)
                        }
                    }
                    Divider()
                    Button(player.sleepAtChapterEnd ? "✓ Hết chương" : "Hết chương") {
                        player.setSleepTimer(minutes: nil)
                        player.sleepAtChapterEnd = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sleepActive ? "moon.fill" : "moon")
                        if let m = player.sleepTimerRemaining {
                            Text("\(m)p")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .font(.system(size: 16, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .foregroundStyle(sleepActive ? DS.accentDeep : DS.ink)
                    .background {
                        if sleepActive {
                            Capsule().fill(DS.accentSoft)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                // Menu borderless trong HStack mặc định giãn chiếm hết chỗ trống
                // phía sau — vùng bấm tràn sang phải qua cả icon lân cận.
                .fixedSize()
                .help(sleepActive ? "Hẹn giờ ngủ đang bật — bấm để đổi hoặc tắt" : "Hẹn giờ ngủ")

                Button {
                    showBookmarkField = true
                } label: {
                    Image(systemName: "bookmark")
                        .font(.system(size: 16, design: .rounded))
                }
                .buttonStyle(.link)
                .disabled(player.currentBookId == nil)
                .help("Đánh dấu vị trí hiện tại")

                Button {
                    if let url = currentFileURL { app.revealInFinder([url]) }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 16, design: .rounded))
                }
                .buttonStyle(.link)
                .disabled(currentFileURL == nil)
                .help("Mở file đang phát trong Finder")

                Button {
                    showFull = true
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 16, design: .rounded))
                }
                .buttonStyle(.link)
                .help("Danh sách đang nghe & đánh dấu")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .card(cornerRadius: 16)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        .sheet(isPresented: $showFull) {
            PlayerFullView()
                .environmentObject(app)
                .environmentObject(player)
        }
        .alert("Đánh dấu vị trí", isPresented: $showBookmarkField) {
            TextField("Ghi chú (tùy chọn)", text: $bookmarkNote)
            Button("Lưu") {
                player.addBookmark(note: bookmarkNote)
                bookmarkNote = ""
            }
            Button("Hủy", role: .cancel) { bookmarkNote = "" }
        } message: {
            Text("Lưu tại \(formatClock(player.currentTime)) — \(title)")
        }
    }
    // MARK: - Chip trạng thái nghe dần

    /// Tổng thời gian ↔ thời gian còn lại (bấm để đổi). Live mode luôn hiện tổng
    /// với "≥" vì duration còn tăng theo part mới.
    @ViewBuilder
    private var durationLabel: some View {
        if player.duration > 0, player.live == nil {
            Button {
                showRemaining.toggle()
            } label: {
                Text(showRemaining
                     ? "-" + formatClock(max(0, player.duration
                         - (isScrubbing ? scrubValue : player.currentTime)))
                     : formatClock(player.duration))
                    .monospacedDigit().font(.footnote).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showRemaining ? "Bấm xem tổng thời gian" : "Bấm xem thời gian còn lại")
        } else {
            Text(player.duration > 0
                 ? (player.live != nil ? "≥ " : "") + formatClock(player.duration)
                 : "—")
                .monospacedDigit().font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func errorChip(_ msg: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
            Text(msg).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(DS.warning.opacity(0.14), in: Capsule())
        .foregroundStyle(DS.warning)
        .frame(maxWidth: 220, alignment: .leading)
        .help(msg)
    }

    @ViewBuilder
    private func liveChip(_ st: LiveState) -> some View {
        HStack(spacing: 5) {
            switch st.phase {
            case .waitingQueue, .waitingFirst, .buffering:
                ProgressView().controlSize(.mini)
            case .playing:
                Image(systemName: "waveform").imageScale(.small)
            case .finishing:
                Image(systemName: "checkmark.circle").imageScale(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").imageScale(.small)
            }
            Text(liveStatusText(st))
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(liveColor(st).opacity(0.14), in: Capsule())
        .foregroundStyle(liveColor(st))
        .help(liveHelpText(st))
    }

    private func liveStatusText(_ st: LiveState) -> String {
        switch st.phase {
        case .waitingQueue(let t): return "Chờ tới lượt — đang dựng “\(t)”"
        case .waitingFirst: return "Đang dựng đoạn đầu…"
        case .playing:
            return "Đang dựng dần · \(st.readyMaxPart)/\(max(st.partsTotal, st.readyMaxPart)) đoạn"
        case .buffering:
            if st.stage == "concat" || st.stage == "encode" {
                return "Đang ghép & nén file cuối…"
            }
            if let eta = st.nextPartETA {
                return "Đang dựng đoạn tiếp (~\(Int(eta.rounded()))s)"
            }
            return "Đang dựng đoạn tiếp…"
        case .finishing: return "Xong — chuyển file hoàn chỉnh"
        case .failed(let m): return m
        }
    }

    private func liveColor(_ st: LiveState) -> Color {
        switch st.phase {
        case .failed: return DS.warning
        case .buffering: return DS.warning
        default: return DS.accent
        }
    }

    private func liveHelpText(_ st: LiveState) -> String {
        var lines: [String] = []
        if let est = st.estimatedTotal {
            lines.append("Ước tính cả chương: ~\(formatClock(est))")
        }
        if let r = st.rateEMA {
            lines.append(String(format: "Tốc độ dựng: %.2gx tốc độ phát", r))
            if r < Double(player.rate) {
                lines.append("Đang nghe nhanh hơn tốc độ dựng — sẽ chờ ở các đoạn tiếp." +
                             " Giảm tốc độ phát để nghe liền mạch.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct PlayerFullView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var bookId: String? { player.currentBookId ?? store.positions.keys.sorted().first }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack {
                    Text("Đang nghe").font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    Spacer()
                    Button("Đóng") { dismiss() }.buttonStyle(.soft)
                }.padding(14)

            HStack(alignment: .top, spacing: 0) {
                // Playlist chương
                List {
                    Section("Chương") {
                        ForEach(player.playlist, id: \.index) { entry in
                            HStack {
                                Button {
                                    player.loadItem(index: entry.index, autoPlay: true, seekTo: nil)
                                } label: {
                                    Image(systemName: entry.index == player.currentChapterIndex
                                          ? "speaker.wave.2.fill" : "play.circle")
                                }
                                .buttonStyle(.link)
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                if entry.index == player.currentChapterIndex,
                                   let pos = store.positions[player.currentBookId ?? ""],
                                   pos.chapterIndex == entry.index {
                                    Text(formatClock(pos.seconds)).font(.caption)
                                        .foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .listRowBackground(
                                entry.index == player.currentChapterIndex
                                    ? DS.accentSoft.opacity(0.55)
                                    : Color.clear
                            )
                        }
                    }
                }
                .frame(width: 340)

                Divider()

                // Bookmark
                VStack(alignment: .leading, spacing: 0) {
                    Text("Đánh dấu").font(.headline).padding(12)
                    List {
                        ForEach(store.bookmarks.sorted { $0.createdAt > $1.createdAt }) { bm in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(bm.chapterTitle) — \(formatClock(bm.seconds))")
                                        .font(.callout.weight(.medium))
                                    if !bm.note.isEmpty {
                                        Text(bm.note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Nghe") {
                                    if let book = app.books.first(where: { $0.id == bm.bookId }) {
                                        player.playChapter(book: book,
                                                           chapters: book.manifest.chapters,
                                                           startAt: bm.chapterIndex)
                                        player.seek(to: bm.seconds)
                                    }
                                }
                                .buttonStyle(.link)
                                Button {
                                    store.bookmarks.removeAll { $0.id == bm.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.link)
                            }
                        }
                        if store.bookmarks.isEmpty {
                            Text("Chưa có đánh dấu nào").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            }
        }
        .background(TitlebarSeparatorHider())
        .preferredColorScheme(.light)
        .tint(DS.accent)
        .fontDesign(.rounded)
        .frame(width: 860, height: 520)
    }
}

// MARK: - tiện ích format

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatClock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
