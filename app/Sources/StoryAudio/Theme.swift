import SwiftUI

// MARK: - Design System "Morning Lavender" (pastel · hiện đại · tối giản, light mode)
//
// Một accent lavender duy nhất, nền canvas phẳng, bề mặt trắng + viền tóc,
// bóng gần như không có, trạng thái bằng màu nhạt.
// Thay thế hoàn toàn design system "Pastel Glass" cũ (gradient + blob + glass).

enum DS {
    // Nền & bề mặt
    static let canvas = Color(hex: 0xF6F5FB)          // nền cửa sổ — lavender rất nhạt
    static let surface = Color.white                  // card, panel
    static let surfaceSecondary = Color(hex: 0xF4F2F9) // vùng phụ nằm trong card

    // Accent lavender — nút chính, selected, focus
    static let accent = Color(hex: 0x8B7CF6)
    static let accentSoft = Color(hex: 0xEDE9FD)      // nền chip / selected / hero
    static let accentDeep = Color(hex: 0x6F5BD8)      // chữ accent đậm trên nền soft

    // Chữ
    static let ink = Color(hex: 0x1D1B2E)             // tiêu đề
    static let bodyText = Color(hex: 0x6E6A85)        // thân — đủ contrast trên nền nhạt

    // Viền & bóng — tối đa tinh gọn
    static let hairline = Color(hex: 0x1D1B2E).opacity(0.08)
    static let cardShadow = Color.black.opacity(0.05)

    // Màu ngữ nghĩa (pastel đậm vừa)
    static let success = Color(hex: 0x4CAF87)
    static let warning = Color(hex: 0xD9975B)
    static let danger = Color(hex: 0xE06B6B)
    static let info = Color(hex: 0x6FA8DC)
    static let plum = Color(hex: 0x9B8CE8)
}

extension Color {
    /// Color(hex: 0xRRGGBB)
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Nền app

/// Nền cửa sổ: canvas phẳng — không blob, không gradient nhiều màu.
struct AppBackground: View {
    var body: some View {
        DS.canvas.ignoresSafeArea()
    }
}

// MARK: - Nút

/// Nút chính: nền accent phẳng, chữ trắng, bo 11pt — thay `.borderedProminent`.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.accent),
                          textColor: .white)
    }
}

/// Bản nhỏ của nút chính cho chỗ hẹp (banner, footnote).
struct PrimaryCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.accent),
                          textColor: .white,
                          font: .system(size: 12.5, weight: .semibold, design: .rounded),
                          paddingH: 13, paddingV: 5)
    }
}

/// Nút phụ: nền trắng, viền tóc, chữ ink — thay `.bordered`.
struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.surface),
                          textColor: DS.ink,
                          font: .system(size: 13.5, weight: .medium, design: .rounded),
                          bordered: true)
    }
}

/// Nút phụ bản nhỏ (form, toolbar log, action trong row) — cùng metric với primaryCompact.
struct SoftCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.surface),
                          textColor: DS.ink,
                          font: .system(size: 12.5, weight: .medium, design: .rounded),
                          paddingH: 13, paddingV: 5,
                          bordered: true)
    }
}

/// Nút phá hủy chính: nền danger phẳng, chữ trắng — cùng metric với primary.
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.danger),
                          textColor: .white)
    }
}

/// Nút phá hủy phụ: nền trắng, viền danger nhạt, chữ danger — cùng metric với soft.
struct SoftDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.surface),
                          textColor: DS.danger,
                          font: .system(size: 13.5, weight: .medium, design: .rounded),
                          bordered: true,
                          borderColor: DS.danger.opacity(0.35))
    }
}

/// Bản nhỏ của softDanger cho chỗ hẹp (Xóa model trong card).
struct SoftDangerCompactButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RoundedButtonBody(configuration: configuration,
                          fill: AnyShapeStyle(DS.surface),
                          textColor: DS.danger,
                          font: .system(size: 12.5, weight: .medium, design: .rounded),
                          paddingH: 13, paddingV: 5,
                          bordered: true,
                          borderColor: DS.danger.opacity(0.35))
    }
}

/// Thân nút dùng chung — hover nhấc bóng rất nhẹ, bấm hơi co.
private struct RoundedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: AnyShapeStyle
    let textColor: Color
    var font: Font = .system(size: 13.5, weight: .semibold, design: .rounded)
    var paddingH: CGFloat = 16
    var paddingV: CGFloat = 8
    var cornerRadius: CGFloat = 11
    var bordered = false
    var borderColor: Color?
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(textColor)
            .padding(.horizontal, paddingH).padding(.vertical, paddingV)
            .frame(minWidth: 34)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(bordered ? (borderColor ?? DS.hairline) : Color.clear, lineWidth: 1)
            )
            .shadow(color: isEnabled && hover ? Color.black.opacity(0.10) : .clear,
                    radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.snappy(duration: 0.18), value: hover)
            .onHover { hover = $0 }
    }
}

/// Nút phát tròn accent phẳng (thanh player) — icon trắng.
struct PlayCircleButtonStyle: ButtonStyle {
    var diameter: CGFloat = 38
    func makeBody(configuration: Configuration) -> some View {
        PlayCircleBody(configuration: configuration, diameter: diameter)
    }
}

private struct PlayCircleBody: View {
    let configuration: ButtonStyleConfiguration
    let diameter: CGFloat
    @State private var hover = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: diameter * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(DS.accent))
            .shadow(color: isEnabled && hover ? DS.accent.opacity(0.30) : .clear,
                    radius: 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .animation(.snappy(duration: 0.18), value: hover)
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == PrimaryCompactButtonStyle {
    static var primaryCompact: PrimaryCompactButtonStyle { .init() }
}

extension ButtonStyle where Self == SoftButtonStyle {
    static var soft: SoftButtonStyle { .init() }
}

extension ButtonStyle where Self == SoftCompactButtonStyle {
    static var softCompact: SoftCompactButtonStyle { .init() }
}

extension ButtonStyle where Self == DangerButtonStyle {
    static var danger: DangerButtonStyle { .init() }
}

extension ButtonStyle where Self == SoftDangerButtonStyle {
    static var softDanger: SoftDangerButtonStyle { .init() }
}

extension ButtonStyle where Self == SoftDangerCompactButtonStyle {
    static var softDangerCompact: SoftDangerCompactButtonStyle { .init() }
}

extension ButtonStyle where Self == PlayCircleButtonStyle {
    static var playCircle: PlayCircleButtonStyle { .init() }
}

// MARK: - Bề mặt

/// Card trắng phẳng: viền tóc + bóng rất nhẹ — thay toàn bộ glass cũ.
struct CardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 1)
            )
            .shadow(color: DS.cardShadow, radius: 10, y: 3)
    }
}

/// Chip pill nền tint 12% — không viền, không bóng.
struct ChipModifier: ViewModifier {
    var tint: Color = DS.accent

    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous).fill(tint.opacity(0.12))
            )
    }
}

extension View {
    /// Bề mặt card chuẩn của app.
    func card(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardModifier(cornerRadius: cornerRadius))
    }

    /// Chip pill (engine, giọng, tốc độ, step indicator).
    func chip(tint: Color = DS.accent) -> some View {
        modifier(ChipModifier(tint: tint))
    }
}

// MARK: - Tiện ích chung

/// Tiêu đề section: caption semibold uppercase — kiểu minimal.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(DS.bodyText.opacity(0.85))
            .kerning(0.6)
    }
}
