import SwiftUI

// MARK: - The field

/// The still Operate-mode field (`.lit-field--still`): four soft lobes over a
/// slate-to-amber wash. It sits behind the whole window so panels float on
/// one continuous light, never a lit card on flat grey. No bloom, no motion.
struct LitField: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xDBE3E7), Color(hex: 0xE9E6DF), Color(hex: 0xF7E6D4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                lobe(AppColor.fieldHaze, x: 0.26, y: 0.84, radius: 0.62 * max(w, h), in: proxy.size)
                lobe(AppColor.fieldEmber, x: 0.76, y: 0.92, radius: 0.50 * max(w, h), in: proxy.size)
                lobe(AppColor.fieldWarm, x: 0.90, y: 0.14, radius: 0.55 * max(w, h), in: proxy.size)
                lobe(AppColor.fieldCool, x: 0.06, y: 0.10, radius: 0.66 * max(w, h), in: proxy.size)
            }
        }
        .background(AppColor.base)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func lobe(_ color: Color, x: CGFloat, y: CGFloat, radius: CGFloat, in size: CGSize) -> some View {
        RadialGradient(
            colors: [color, color.opacity(0)],
            center: UnitPoint(x: x, y: y),
            startRadius: 0,
            endRadius: radius
        )
    }
}

// MARK: - Glass, veil, lift

enum LitLift {
    case one, two
}

extension View {
    /// Chrome-layer glass (settings, action bar). Real Liquid Glass on
    /// macOS 26+, a veil fill before that and under Reduce Transparency.
    func litGlass(in shape: some Shape = RoundedRectangle(cornerRadius: AppMetric.radiusPanel, style: .continuous)) -> some View {
        modifier(LitGlassModifier(shape: shape))
    }

    /// Content-layer panel (the queue, metric tables): a solid veil with the
    /// lit edge. Content never sits on live glass.
    func litPanel(strong: Bool = false, lift: LitLift = .one) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppMetric.radiusPanel, style: .continuous)
        return self
            .background(strong ? AppColor.veilStrong : AppColor.veil, in: shape)
            .litLift(lift, in: shape)
    }

    /// `--lift-1/2`: a crisp 1pt top-edge highlight plus a short, offset
    /// contact shadow. `shape` clips the highlight; the shadows are added
    /// afterwards so they aren't clipped away too.
    func litLift(_ tier: LitLift, in shape: some Shape = RoundedRectangle(cornerRadius: AppMetric.radiusPanel, style: .continuous)) -> some View {
        modifier(LitLiftModifier(tier: tier, shape: shape))
    }
}

private struct LitGlassModifier<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(AppColor.veil, in: shape)
                .litLift(.one, in: shape)
        }
    }
}

private struct LitLiftModifier<S: Shape>: ViewModifier {
    var tier: LitLift
    var shape: S

    func body(content: Content) -> some View {
        let highlighted = content
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.9)).frame(height: 1)
            }
            .clipShape(shape)

        switch tier {
        case .one:
            highlighted
                .shadow(color: Color(hex: 0x10141C).opacity(0.05), radius: 1, x: 0, y: 1)
                .shadow(color: Color(hex: 0x10141C).opacity(0.16), radius: 5, x: 0, y: 4)
        case .two:
            highlighted
                .shadow(color: Color(hex: 0x10141C).opacity(0.06), radius: 1, x: 0, y: 1)
                .shadow(color: Color(hex: 0x10141C).opacity(0.22), radius: 10, x: 0, y: 9)
        }
    }
}

// MARK: - Hairlines (internal dividers only)

struct Hairline: View {
    var strong = false
    var body: some View {
        Rectangle()
            .fill(strong ? AppColor.hairStrong : AppColor.hair)
            .frame(height: 1)
    }
}
