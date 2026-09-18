import SwiftUI

// MARK: - Buttons — pills throughout, one primary per view

enum LitButtonVariant {
    /// Night fill. The one action that advances the task.
    case primary
    /// White veil + control border. Everything else.
    case secondary
    /// Transparent. Tertiary, toolbars.
    case ghost
    /// Status-error outline. Stop, delete, reset.
    case destructive
}

struct LitButtonStyle: ButtonStyle {
    var variant: LitButtonVariant = .secondary

    func makeBody(configuration: Configuration) -> some View {
        LitButtonBody(variant: variant, configuration: configuration)
    }

    private struct LitButtonBody: View {
        var variant: LitButtonVariant
        var configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(AppFont.display(13.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(isEnabled ? foreground : disabledForeground)
                .padding(.horizontal, 16)
                .frame(minHeight: AppMetric.controlHeight)
                .background { background }
                .contentShape(Capsule())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }

        @ViewBuilder private var background: some View {
            switch variant {
            case .primary:
                if isEnabled {
                    Capsule().fill(hovering ? AppColor.night2 : AppColor.night).litLift(.one, in: Capsule())
                } else {
                    Capsule().fill(AppColor.ink.opacity(0.10))
                }
            case .secondary:
                Capsule()
                    .fill(Color.white.opacity(isEnabled ? (hovering ? 0.85 : 0.6) : 0.3))
                    .overlay(Capsule().strokeBorder(isEnabled ? border : AppColor.hairStrong))
            case .ghost:
                Capsule().fill(Color.white.opacity(hovering && isEnabled ? 0.5 : 0))
            case .destructive:
                Capsule()
                    .fill(Color.white.opacity(hovering && isEnabled ? 0.5 : 0))
                    .overlay(Capsule().strokeBorder(isEnabled ? AppColor.statusError : AppColor.hairStrong))
            }
        }

        private var border: Color {
            hovering ? AppColor.controlBorderStrong : AppColor.controlBorder
        }

        private var foreground: Color {
            switch variant {
            case .primary:     AppColor.onNight
            case .secondary:   AppColor.ink
            case .ghost:       AppColor.ink2
            case .destructive: AppColor.statusError
            }
        }

        private var disabledForeground: Color {
            AppColor.controlDisabledInk
        }
    }
}

extension ButtonStyle where Self == LitButtonStyle {
    static func lit(_ variant: LitButtonVariant = .secondary) -> LitButtonStyle {
        LitButtonStyle(variant: variant)
    }
}

// MARK: - Pill tabs (Lit Field's role-tab: the active tab inverts to night)

struct PillTabs<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isActive = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(AppFont.display(13, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .foregroundStyle(isActive ? AppColor.onNight : AppColor.ink3)
                        .padding(.horizontal, 14)
                        .frame(minHeight: AppMetric.controlHeight - 6)
                        .background {
                            if isActive {
                                Capsule().fill(AppColor.night)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.6)))
        .overlay(Capsule().strokeBorder(AppColor.controlBorder))
        .opacity(isEnabled ? 1 : 0.55)
    }
}

// MARK: - Menu picker — a control-shaped field that opens a native menu

struct LitMenuPicker<Value: Hashable>: View {
    var options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var currentTitle: String {
        options.first(where: { $0.value == selection })?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(currentTitle)
                    .font(AppFont.display(13.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isEnabled ? AppColor.ink : AppColor.controlDisabledInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Chevron()
                    .stroke(isEnabled ? AppColor.ink3 : AppColor.controlDisabledInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 8, height: 5)
            }
            .padding(.horizontal, 12)
            .frame(height: AppMetric.controlHeight)
            .litControlSurface(hovering: hovering)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
    }
}

private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

extension View {
    /// `--control-bg` + 1px `--control-border` at `--control-radius`.
    func litControlSurface(hovering: Bool = false) -> some View {
        modifier(LitControlSurface(hovering: hovering))
    }
}

private struct LitControlSurface: ViewModifier {
    var hovering: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppMetric.radiusControl, style: .continuous)
        content
            .background(Color.white.opacity(isEnabled ? 0.78 : 0.42), in: shape)
            .overlay(
                shape.strokeBorder(
                    isEnabled
                        ? (hovering ? AppColor.controlBorderStrong : AppColor.controlBorder)
                        : AppColor.hairStrong
                )
            )
    }
}

// MARK: - Labeled field — label above the control, never a placeholder

struct LabeledField<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).uiLabel(12.5, color: AppColor.ink2)
            content
        }
    }
}

// MARK: - Progress — hair-strong track, accent fill. No spring, no shimmer.

struct LitProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppColor.hairStrong)
                Capsule()
                    .fill(AppColor.accent)
                    .frame(width: max(4, proxy.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) percent")
    }
}

// MARK: - Wordmark

/// `media compressor●` — the wordmark with the accent dot.
struct Wordmark: View {
    var size: CGFloat = 16

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: size * 0.22) {
            Text("media compressor")
                .font(AppFont.display(size, weight: .bold))
                .tracking(-size * 0.02)
                .foregroundStyle(AppColor.ink)
            Circle()
                .fill(AppColor.accent)
                .frame(width: size * 0.36, height: size * 0.36)
        }
        .accessibilityElement()
        .accessibilityLabel("Media Compressor")
    }
}

// MARK: - Numeral — the evidence voice (Archivo, tabular, accent unit)

struct BigNumber: View {
    var value: String
    var unit: String?
    var size: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: size * 0.06) {
            Text(value)
                .font(AppFont.display(size, weight: .bold))
                .monospacedDigit()
                .tracking(-size * 0.04)
                .foregroundStyle(AppColor.ink)
            if let unit {
                Text(unit)
                    .font(AppFont.display(size * 0.42, weight: .bold))
                    .foregroundStyle(AppColor.accentOnLight)
                    .padding(.top, size * 0.1)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}
