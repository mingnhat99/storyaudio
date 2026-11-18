import SwiftUI
import AppKit

// MARK: - Window chrome
//
// Hai chi tiết hệ thống macOS không có API SwiftUI tắt trực tiếp:
// hairline dưới unified toolbar và divider của split view — xử lý
// qua probe AppKit nhỏ đặt ở `.background`.

/// Tắt hairline hệ thống dưới unified toolbar — macOS tự vẽ separator
/// giữa toolbar và content khi bên dưới là list/scroll cuộn được.
/// SwiftUI không có modifier tương ứng, set qua NSWindow.titlebarSeparatorStyle.
struct TitlebarSeparatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.apply()
    }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            window?.titlebarSeparatorStyle = .none
        }
    }
}

/// Tay kéo đổi độ rộng sidebar — trong suốt hoàn toàn. App không dùng
/// NavigationSplitView nên không còn divider hệ thống; tay kéo này thay
/// thế chỗ bấm-kéo của divider đó (cursor đổi kiểu khi hover).
struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        // translation là tích lũy từ đầu cử chỉ — neo width
                        // lúc bắt đầu kéo rồi cộng dồn, tránh đếm kép.
                        if dragStart == nil { dragStart = width }
                        width = min(380, max(230, dragStart! + value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
