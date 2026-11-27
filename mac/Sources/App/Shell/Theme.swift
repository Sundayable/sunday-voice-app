import AppKit
import SwiftUI

/// Sundayable Brand 2.0 (brand.sundayable.ca/downloads/v2, tokens.css + DESIGN.md) for every
/// surface of the app: onboarding, settings, menu header and the recording HUD.
/// Palette only — no accent colours outside it. Approval green is for state, never decoration.
enum Theme {
    // Primary
    static let paper = Color(hex: 0xF5F3EE)
    static let card = Color(hex: 0xFCFBF8)
    static let ink = Color(hex: 0x1B2233)
    static let night = Color(hex: 0x0A0F1E)
    static let slate = Color(hex: 0x6A7389)
    static let dust = Color(hex: 0xCCBFBC)
    // Secondary
    static let line = Color(hex: 0xDDD9D0)
    static let surface = Color(hex: 0xECE9E2)
    static let approval = Color(hex: 0x3E7C4F)
    // Text
    static let textMuted = Color(hex: 0x4F5768)

    /// Light = Paper ground, Card panels, Ink type. Dark = Night ground, Ink panels, Paper type, Dust metadata.
    static func ground(_ s: ColorScheme) -> Color { s == .dark ? night : paper }
    static func panel(_ s: ColorScheme) -> Color { s == .dark ? ink : card }
    static func text(_ s: ColorScheme) -> Color { s == .dark ? paper : ink }
    static func muted(_ s: ColorScheme) -> Color { s == .dark ? dust : textMuted }
    static func rule(_ s: ColorScheme) -> Color { s == .dark ? paper.opacity(0.18) : line }
    static func well(_ s: ColorScheme) -> Color { s == .dark ? night.opacity(0.6) : paper }
    static func structure(_ s: ColorScheme) -> Color { s == .dark ? paper : ink }   // borders, primary fills
    static func onStructure(_ s: ColorScheme) -> Color { s == .dark ? night : paper }

    // Type: Gabarito = display/actions, Figtree = text, IBM Plex Mono = evidence labels.
    static func display(_ size: CGFloat, semibold: Bool = false) -> Font { .custom(semibold ? "Gabarito-SemiBold" : "Gabarito-Bold", size: size) }
    static func text(_ size: CGFloat = 14, medium: Bool = false) -> Font { .custom(medium ? "Figtree-Medium" : "Figtree-Regular", size: size) }
    static func label(_ size: CGFloat = 11) -> Font { .custom("IBMPlexMono-Medium", size: size) }
    static func nsText(_ size: CGFloat, medium: Bool = false) -> NSFont {
        NSFont(name: medium ? "Figtree-Medium" : "Figtree-Regular", size: size) ?? .systemFont(ofSize: size, weight: medium ? .medium : .regular)
    }
    static func nsDisplay(_ size: CGFloat) -> NSFont { NSFont(name: "Gabarito-Bold", size: size) ?? .boldSystemFont(ofSize: size) }
    static func nsLabel(_ size: CGFloat) -> NSFont { NSFont(name: "IBMPlexMono-Medium", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .medium) }

    /// Fonts ship inside the app (OFL); register for this process only.
    static func registerFonts() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        if !urls.isEmpty { CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil) }
    }

    // Brand artwork (supplied SVGs, never redrawn).
    static func brandImage(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "svg").flatMap(NSImage.init(contentsOf:))
    }
    /// Supplied wordmark: Ink on light, Paper on dark.
    static func wordmark(_ s: ColorScheme) -> NSImage? { brandImage(s == .dark ? "sundayable-wordmark-butter" : "sundayable-wordmark-ink") }
    /// The favicon letterform plate (app icon / small-space use only).
    static var mark: NSImage? { brandImage("sundayable-favicon") }
    static var markOnNight: NSImage? { brandImage("sundayable-square-butter") }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
