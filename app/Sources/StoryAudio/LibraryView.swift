import SwiftUI
import UniformTypeIdentifiers

/// Dòng sách trong sidebar + màn chào Thư viện + sheet dán text.
/// (Điều hướng chính nằm ở MainView — App.swift.)

struct BookRow: View {
    let book: Book

    private var doneCount: Int {
        book.manifest.chapters.filter { book.audioPath(for: $0) != nil }.count
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let cover = book.coverURL,
                   let nsImage = NSImage(contentsOf: cover) {
                    Image(nsImage: nsImage).resizable().scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 46, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).lineLimit(2)
                    .font(.system(size: 13.5, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.ink)
                HStack(spacing: 5) {
                    Image(systemName: doneCount == book.manifest.chapters.count && !book.manifest.chapters.isEmpty
                          ? "checkmark.circle.fill" : "waveform")
                        .font(.caption)
                        .foregroundStyle(doneCount > 0 ? AnyShapeStyle(DS.success) : AnyShapeStyle(Color.secondary))
                    Text(doneCount > 0
                         ? "\(doneCount)/\(book.manifest.chapters.count) chương có audio"
                         : "\(book.manifest.chapters.count) chương")
                        .monospacedDigit()
                }
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Dán text

struct PasteTextView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HStack {
                    Text("Dán text thành sách")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                    Spacer()
                    Button("Đóng") { dismiss() }.buttonStyle(.soft)
                }.padding(12)
                Form {
                    TextField("Tên sách", text: $title)
                    VStack(alignment: .leading) {
                        TextEditor(text: $text)
                            .font(.system(.body))
                            .frame(minHeight: 260)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(DS.surfaceSecondary,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(DS.hairline, lineWidth: 1)
                            )
                        Text("Tự động dò chia chương theo dòng tiêu đề (Hồi thứ…, Chương…, Chapter…, 第N章…)")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(12)
                Divider()
                HStack {
                    Spacer()
                    Button("Tạo sách") {
                        guard !text.isEmpty else { return }
                        Task {
                            await app.importPastedText(title: title, text: text)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.primary)
                    .disabled(text.isEmpty)
                }
                .padding(12)
            }
        }
        .background(TitlebarSeparatorHider())
        .preferredColorScheme(.light)
        .tint(DS.accent)
        .fontDesign(.rounded)
        .frame(width: 560, height: 500)
    }
}
