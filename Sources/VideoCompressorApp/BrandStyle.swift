import SwiftUI

extension Color {
    /// The single chromatic accent shared across the apps. Used as punctuation,
    /// never decoration: selection, progress, hover, one status dot at a time.
    static let brandOrange = Color(red: 0xFF / 255, green: 0x47 / 255, blue: 0x26 / 255)
}

extension Font {
    /// Monospace voice for metadata, captions, and indexing — paths, codecs,
    /// formats, metric labels. Signals "this is data."
    static func mono(_ style: Font.TextStyle) -> Font {
        .system(style, design: .monospaced)
    }
}
