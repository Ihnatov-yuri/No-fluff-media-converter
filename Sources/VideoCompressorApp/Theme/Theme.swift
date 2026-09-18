import AppKit
import CoreText
import SwiftUI

/// Lit Field design system, ported from the portable token file at
/// `~/Documents/Landing/docs/lit-field-tokens.css` — the same port the
/// Transcriberr app uses, so the two apps read as one hand.
///
/// Key principles to preserve:
///   - One chroma, the "Two-Oranges Rule": `AppColor.accent` is fills only
///     (2.92:1 on light); `AppColor.accentOnLight` is the only value legal
///     for text on a light ground (4.86:1). Never use `accent` for text.
///   - This app is "Operate mode": dense working UI, display type shrinks
///     hard, veils run at 0.78/0.88, the field is still (no bloom).
///   - Depth is a lit top edge plus a short contact shadow — never a
///     hairline outline with a wide halo. Hairlines are internal only.
///   - Two faces: Archivo (headings, controls, numbers), Schibsted Grotesk
///     (sentences). No monospace, no icons.
///   - Light only. Lit Field has no app-wide dark mode; `night` is a
///     component-level inversion (the primary pill, the active tab).

// MARK: - Palette

enum AppColor {
    // Base surface and the four field lobes
    static let base       = Color(hex: 0xECEEED)
    static let fieldCool  = Color(hex: 0xB9C8D2)
    static let fieldWarm  = Color(hex: 0xFFD9B8)
    static let fieldEmber = Color(hex: 0xFFCFA8)
    static let fieldHaze  = Color(hex: 0xCFD8D6)

    // Ink — four discrete steps. Don't add a fifth.
    static let ink  = Color(hex: 0x0B0C0E)
    static let ink2 = Color(hex: 0x23262B)
    static let ink3 = Color(hex: 0x454A52)
    static let ink4 = Color(hex: 0x5C626B)

    // Accent — see the "Two-Oranges Rule" note above.
    static let accent        = Color(hex: 0xFF4726)
    static let accentOnLight = Color(hex: 0xC03210)

    // Night — fixed component-level inversion.
    static let night   = Color(hex: 0x0B0C0E)
    static let night2  = Color(hex: 0x16181C)
    static let onNight = Color(hex: 0xF4F5F5)

    // Veils — Operate-mode values, not the 0.54 hero default.
    static let veil       = Color.white.opacity(0.78)
    static let veilStrong = Color.white.opacity(0.88)

    // Hairlines — internal dividers only, never a panel's outer edge.
    static let hair       = ink.opacity(0.12)
    static let hairStrong = ink.opacity(0.22)

    // Status — functional, never decorative, always paired with text.
    static let statusError   = Color(hex: 0x9F1239)
    static let statusSuccess = Color(hex: 0x0F5D3A)
    static let statusWarning = Color(hex: 0x7A4B00)

    // Form controls (3:1 boundary on both base and veil).
    static let controlBorder       = Color(hex: 0x7A8188)
    static let controlBorderStrong = Color(hex: 0x4A5158)
    static let controlDisabledInk  = Color(hex: 0x8B9197)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Typography

@MainActor
enum AppFont {
    private static let displaySemiboldPS = "ArchivoRoman-SemiBold"
    private static let displayBoldPS = "ArchivoRoman-Bold"
    private static let textRegularPS = "SchibstedGrotesk-Regular"
    private static let textBoldPS = "SchibstedGrotesk-Bold"

    /// Archivo — headings, buttons, labels, numbers. Bundled at 600 and 700.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let bold = (weight == .bold || weight == .heavy || weight == .black)
        let name = bold ? displayBoldPS : displaySemiboldPS
        if isFontAvailable(name) {
            return Font.custom(name, fixedSize: size)
        }
        return Font.system(size: size, weight: weight)
    }

    /// Schibsted Grotesk — sentences. Bundled at 400 and 700.
    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = weight == .regular ? textRegularPS : textBoldPS
        if isFontAvailable(name) {
            return Font.custom(name, fixedSize: size)
        }
        return Font.system(size: size, weight: weight)
    }

    /// Registers the bundled TTFs for this process. Looks in the packaged
    /// app's `Resources/Fonts` first, then in the SwiftPM resource bundle
    /// next to the executable (`swift run`). Deliberately avoids
    /// `Bundle.module`, which traps when the bundle isn't where SwiftPM
    /// expects it — a silent system-font fallback is the better failure.
    static func registerBundledFonts() {
        let bundleName = "VideoCompressor_VideoCompressorApp.bundle"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Fonts"))
        }
        if let executable = Bundle.main.executableURL {
            let bundleURL = executable.deletingLastPathComponent().appendingPathComponent(bundleName)
            if let resources = Bundle(url: bundleURL)?.resourceURL {
                candidates.append(resources.appendingPathComponent("Fonts"))
            }
        }

        for directory in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            let fonts = files.filter { $0.pathExtension.lowercased() == "ttf" }
            guard !fonts.isEmpty else { continue }
            for font in fonts {
                CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            }
            return
        }
    }

    private static var availability: [String: Bool] = [:]
    private static func isFontAvailable(_ name: String) -> Bool {
        if let known = availability[name] { return known }
        let available = NSFont(name: name, size: 12) != nil
        availability[name] = available
        return available
    }
}

// MARK: - Metrics

enum AppMetric {
    static let xs: CGFloat = 4
    static let s:  CGFloat = 8
    static let m:  CGFloat = 12
    static let l:  CGFloat = 16
    static let xl: CGFloat = 24

    static let radiusPanel:   CGFloat = 14
    static let radiusControl: CGFloat = 10

    // Compact density (data-dense desktop tool): 36pt controls, 12pt gutter.
    static let controlHeight: CGFloat = 36
    static let gutter:        CGFloat = 12
}

// MARK: - Text helpers

extension Text {
    /// Field labels, column headings, metadata — Archivo 600, normal case.
    @MainActor
    func uiLabel(_ size: CGFloat = 12.5, color: Color = AppColor.ink3) -> some View {
        self
            .font(AppFont.display(size, weight: .semibold))
            .foregroundStyle(color)
    }
}
