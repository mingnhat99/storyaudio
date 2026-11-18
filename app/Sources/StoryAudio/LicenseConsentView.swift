import SwiftUI

// MARK: - Khung dialog điều khoản dùng chung

/// Khung xác nhận điều khoản: header icon + tiêu đề, danh sách điều khoản cuộn
/// được, checkbox bắt buộc tick trước khi bấm đồng ý. Nội dung và hành vi 2 nút
/// do view con quyết định (TermsConsentView, LicenseConsentView).
struct ConsentCard: View {
    let icon: String
    let title: String
    let subtitle: String?
    let terms: [String]
    var licenseUrl: String?
    let checkboxText: String
    let footnote: String
    let declineLabel: String
    let declineIsDanger: Bool
    let acceptLabel: String
    let acceptIcon: String
    let onDecline: () -> Void
    let onAccept: () -> Void
    @State private var agreed = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.20).ignoresSafeArea()
            card
                .frame(maxWidth: 560)
                .padding(40)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .animation(.snappy(duration: 0.2), value: agreed)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.warning)
                    .frame(width: 44, height: 44)
                    .background(DS.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(DS.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout).foregroundStyle(DS.bodyText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)

            Divider()

            // Điều khoản
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(terms.enumerated()), id: \.offset) { i, text in
                        term("\(i + 1).", text)
                    }
                    if let url = licenseUrl, let link = URL(string: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                                .font(.system(size: 12, weight: .medium))
                            Button("Xem giấy phép & trang gốc của model") {
                                NSWorkspace.shared.open(link)
                            }
                            .buttonStyle(.link)
                        }
                        .font(.callout)
                        .foregroundStyle(DS.accentDeep)
                        .padding(.top, 2)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 300)
            .background(DS.surfaceSecondary.opacity(0.5))

            Divider()

            // Xác nhận + nút
            VStack(alignment: .leading, spacing: 14) {
                agreeToggle
                HStack {
                    Text(footnote)
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Group {
                        if declineIsDanger {
                            Button(action: onDecline) { Text(declineLabel) }
                                .buttonStyle(.softDanger)
                        } else {
                            Button(action: onDecline) { Text(declineLabel) }
                                .buttonStyle(.soft)
                        }
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(action: onAccept) {
                        Label(acceptLabel, systemImage: acceptIcon)
                    }
                    .buttonStyle(.primary)
                    .disabled(!agreed)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .card(cornerRadius: 18)
        .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
    }

    private func term(_ num: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(num)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DS.accentDeep)
                .monospacedDigit()
                .padding(.top, 1.5)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.bodyText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Checkbox tự vẽ theo DS — không dùng Toggle hệ thống để khớp pastel look.
    private var agreeToggle: some View {
        Button {
            agreed.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: agreed ? "checkmark" : "")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(agreed ? DS.accent : DS.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(agreed ? DS.accent : DS.hairline.opacity(2), lineWidth: 1.2)
                    )
                Text(checkboxText)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DS.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Đồng ý với điều khoản")
        .accessibilityAddTraits(agreed ? .isSelected : [])
    }
}

// MARK: - Điều khoản sử dụng app (lần chạy đầu)

/// Dialog điều khoản sử dụng ứng dụng — hiện ở lần chạy đầu, chặn bootstrap
/// cho đến khi đồng ý. Lý do: lúc đầu chưa có model nào, app có thể fallback
/// về model mặc định (online) — chưa xác nhận điều khoản mà app tự dùng model
/// là vi phạm giấy phép của nhà cung cấp. Không đồng ý → thoát app.
struct TermsConsentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ConsentCard(
            icon: "doc.text.magnifyingglass",
            title: "Điều khoản sử dụng StoryAudio",
            subtitle: "Xác nhận một lần trước khi dùng ứng dụng",
            terms: [
                "StoryAudio là công cụ chuyển sách, file và text thành audio. Các model TTS (offline lẫn online) do các nhà cung cấp độc lập phân phối dưới giấy phép riêng của họ — StoryAudio không liên kết và không đại diện cho bất kỳ nhà cung cấp model nào.",
                "Một số giấy phép có thể hạn chế hoặc không cho phép cài đặt model vào ứng dụng, phân phối lại, hoặc sử dụng cho mục đích nhất định. Bạn chịu trách nhiệm đọc, hiểu và tuân thủ giấy phép của từng model (xem link giấy phép kèm mỗi model trước khi tải).",
                "Khi chưa cài model nào, ứng dụng có thể dùng model mặc định (Edge-TTS, online) hoặc nhắc bạn tải model — mọi việc dùng model, kể cả model mặc định, đều nằm trong điều khoản này.",
                "StoryAudio chỉ tải về và chạy model. Ứng dụng không chịu bất kỳ trách nhiệm pháp lý nào liên quan đến nhà cung cấp model, nội dung do model tạo ra, hoặc mục đích sử dụng của bạn. Mọi hệ quả pháp lý phát sinh (nếu có) do bạn tự chịu trách nhiệm.",
                "Việc đồng ý các điều khoản này là điều kiện để sử dụng ứng dụng. Nếu bạn không đồng ý, ứng dụng sẽ thoát và không dùng model nào."
            ],
            licenseUrl: nil,
            checkboxText: "Tôi đã đọc, hiểu và đồng ý với các điều khoản sử dụng, và tự chịu hoàn toàn trách nhiệm về việc dùng các model trong ứng dụng.",
            footnote: "Không đồng ý sẽ thoát ứng dụng.",
            declineLabel: "Thoát ứng dụng",
            declineIsDanger: true,
            acceptLabel: "Tôi đồng ý",
            acceptIcon: "checkmark.circle.fill",
            onDecline: { app.declineAppTerms() },
            onAccept: { app.acceptAppTerms() })
    }
}

// MARK: - Điều khoản từng model (tải offline / dùng online lần đầu)

/// Dialog điều khoản chịu trách nhiệm trước khi tải model offline hoặc dùng
/// model online lần đầu — không thể đóng bằng Esc: phải bấm từ chối (không
/// tải / không dùng) hoặc tick xác nhận rồi bấm đồng ý.
struct LicenseConsentView: View {
    @EnvironmentObject var app: AppModel
    let gate: LicenseGate

    private var isOnline: Bool { gate.action == .useOnline }

    var body: some View {
        ConsentCard(
            icon: isOnline ? "antenna.radiowaves.left.and.right" : "checkmark.shield",
            title: isOnline
                ? "Xác nhận trách nhiệm trước khi dùng model online"
                : "Xác nhận trách nhiệm trước khi tải",
            subtitle: "Model: \(gate.model.name)",
            terms: terms,
            licenseUrl: gate.model.licenseUrl,
            checkboxText: isOnline
                ? "Tôi đã đọc, hiểu và đồng ý với các điều khoản trên, và tự chịu hoàn toàn trách nhiệm về việc sử dụng model online này."
                : "Tôi đã đọc, hiểu và đồng ý với các điều khoản trên, và tự chịu hoàn toàn trách nhiệm về việc tải và sử dụng model này.",
            footnote: isOnline
                ? "Không đồng ý sẽ không dùng model online này."
                : "Không đồng ý sẽ không tải model.",
            declineLabel: "Tôi không đồng ý",
            declineIsDanger: false,
            acceptLabel: isOnline ? "Đồng ý & dùng model" : "Đồng ý & tải về",
            acceptIcon: isOnline ? "antenna.radiowaves.left.and.right" : "arrow.down.circle.fill",
            onDecline: { app.declineLicense() },
            onAccept: { app.acceptLicense(gate) })
    }

    /// Điều khoản cho từng loại hành động: tải model offline vs dùng model online.
    private var terms: [String] {
        if isOnline {
            return [
                "Model online chạy qua dịch vụ trực tuyến của nhà cung cấp độc lập (không phân phối kèm ứng dụng). StoryAudio không liên kết và không đại diện cho nhà cung cấp dịch vụ.",
                "Việc sử dụng dịch vụ trực tuyến chịu ràng buộc bởi điều khoản của nhà cung cấp — có thể hạn chế việc truy cập qua ứng dụng bên thứ ba hoặc một số mục đích sử dụng nhất định. Bạn chịu trách nhiệm đọc, hiểu và tuân thủ các điều khoản đó.",
                "StoryAudio chỉ là công cụ kết nối và chạy model. Ứng dụng không chịu bất kỳ trách nhiệm pháp lý nào liên quan đến nhà cung cấp, nội dung do model tạo ra, hoặc mục đích sử dụng của bạn.",
                "Việc sử dụng model online là hoàn toàn tự nguyện, bao gồm cả việc gửi text tới dịch vụ trực tuyến để dựng audio. Mọi hệ quả pháp lý phát sinh (nếu có) do bạn tự chịu trách nhiệm.",
                "Nếu bạn không đồng ý với các điều khoản trên, hãy chọn “Tôi không đồng ý” — ứng dụng sẽ không dùng model online này (các model offline đã cài vẫn dùng bình thường)."
            ]
        }
        return [
            "Model được phân phối bởi các nhà cung cấp độc lập, dưới giấy phép (license) riêng của họ. StoryAudio không liên kết và không đại diện cho bất kỳ nhà cung cấp model nào.",
            "Một số giấy phép có thể hạn chế hoặc không cho phép cài đặt model vào ứng dụng, phân phối lại, hoặc sử dụng cho mục đích thương mại. Bạn chịu trách nhiệm đọc, hiểu và tuân thủ giấy phép của model trước khi tải về và sử dụng.",
            "StoryAudio chỉ là công cụ tải về và chạy model ngay trên máy của bạn. Ứng dụng không chịu bất kỳ trách nhiệm pháp lý nào liên quan đến nhà cung cấp model, nội dung do model tạo ra, hoặc mục đích sử dụng của bạn.",
            "Việc tải và sử dụng model là hoàn toàn tự nguyện. Mọi hệ quả pháp lý phát sinh (nếu có) do bạn tự chịu trách nhiệm.",
            "Nếu bạn không đồng ý với các điều khoản trên, hãy chọn “Tôi không đồng ý” — ứng dụng sẽ không tải model về máy."
        ]
    }
}
