import SwiftUI

/// Every colour, size and curve in the app, defined once.
///
/// Values are read from the August prototype sources in
/// `Albus AI/1 Prototype/*.jsx`, which supersede the June exports the first
/// version of this file was sampled from. A hardcoded hex in a card is how a
/// palette change becomes a nine-file edit, so views must never name a colour.
public enum Tokens {

    // MARK: - Colour

    public enum Palette {
        /// The single accent. The sources contain four purples: `#7C3AED`
        /// (Today, and the design tweaks panel's stated default), `#6D28D9`
        /// (Tasks and Task detail), `#743EE4` and `#652DD1` (June exports).
        /// The tweaks default wins because it is the one value the designer
        /// declared rather than a value sampled off a render; the darker
        /// `#6D28D9` becomes the pressed state rather than a second accent.
        public static let accent = Color(hex: 0x7C3AED)
        public static let accentPressed = Color(hex: 0x6D28D9)
        /// Tint behind accent-coloured chips and count pills.
        public static let accentWash = Color(hex: 0xEDE9FE)

        public static let ink = Color(hex: 0x1B1726)
        /// Body copy and secondary meta. Warm, matching the paper background.
        public static let inkSecondary = Color(hex: 0x6E6757)
        /// Labels, timestamps, anything deliberately quiet.
        public static let inkMuted = Color(hex: 0x8C8579)
        /// The small separator dot between meta items.
        public static let separator = Color(hex: 0xC9C2B2)
        public static let hairline = Color(hex: 0xE5E1DC)

        /// Opaque white — the surface of stripe cards, which sit on the
        /// gradient and are meant to read as paper, not glass.
        public static let cardSurface = Color.white

        /// Danger. Overdue deadlines and destructive confirmations only.
        public static let danger = Color(hex: 0xEF4444)

        /// The app background is a single full-screen gradient behind all four
        /// tabs, not a per-screen colour. Built once in the shell.
        ///
        /// The prototype paints this as an aurora: a warm paper base with three
        /// blurred colour blobs. `BackgroundGradient` reproduces it; these
        /// stops are the base wash underneath.
        public static let backgroundStops: [Gradient.Stop] = [
            .init(color: Color(hex: 0xF3EDE6), location: 0.00),
            .init(color: Color(hex: 0xF7F2EA), location: 0.45),
            .init(color: Color(hex: 0xF4F0E6), location: 1.00)
        ]

        /// Focus Mode's ground. Near-black rather than pure black, so the
        /// cactus's own shadow tones still read against it. The one dark
        /// surface in the app, and the only place this is used.
        public static let focusBackdrop = Color(hex: 0x0E0B16)

        /// The aurora blobs. Positioned by the view that draws them.
        public static let auroraViolet = Color(hex: 0x7C3AED)
        public static let auroraAmber  = Color(hex: 0xF4B340)
        public static let auroraGreen  = Color(hex: 0x4FBF9F)
    }

    /// Glass is the app's signature surface: translucent white over the
    /// gradient, blurred, with a hairline edge and a long soft shadow.
    /// Defined here so the recipe cannot drift between cards.
    public enum Glass {
        public static let fill = Color.white.opacity(0.78)
        /// Raised variant — the card that is happening now.
        public static let fillProminent = Color.white.opacity(0.92)
        public static let stroke = Color(hex: 0x1B1726).opacity(0.07)
        public static let shadow = Color(hex: 0x1B1726).opacity(0.16)
        public static let shadowRadius: CGFloat = 18
        public static let shadowY: CGFloat = 10
    }

    /// Subject colour is a property of the course, never of the card that shows
    /// it. HIST is red on every screen; a view maps the enum and never picks.
    ///
    /// The four the prototype names (HIST/STAT/ENGL/CHEM) use its exact values.
    /// Blue and pink extend the set for students with more than four courses.
    public enum SubjectColor: String, CaseIterable, Sendable, Codable {
        case violet, red, amber, green, blue, pink

        public var color: Color {
            switch self {
            case .violet: Color(hex: 0x7C3AED)
            case .red:    Color(hex: 0xE45757)
            case .amber:  Color(hex: 0xF4B340)
            case .green:  Color(hex: 0x4FBF9F)
            case .blue:   Color(hex: 0x5B8DEF)
            case .pink:   Color(hex: 0xD98CB3)
            }
        }
    }

    /// Paired background/foreground tints for badges and monograms.
    ///
    /// A closed set rather than free colours: anything wearing a tint needs one
    /// that is legible against it, and pairing them here is what guarantees the
    /// contrast was decided once instead of guessed per call site.
    public enum Tint: String, CaseIterable, Sendable {
        case neutral, blue, violet, green, amber, teal, red, orange, slate

        public var background: Color {
            switch self {
            case .neutral: Color(hex: 0xF1F2F4)
            case .blue:    Color(hex: 0xDBEAFE)
            case .violet:  Color(hex: 0xEDE9FE)
            case .green:   Color(hex: 0xDCFCE7)
            case .amber:   Color(hex: 0xFEF3C7)
            case .teal:    Color(hex: 0xCCFBF1)
            case .red:     Color(hex: 0xFEE2E2)
            case .orange:  Color(hex: 0xFFEDD5)
            case .slate:   Color(hex: 0xE2E8F0)
            }
        }

        public var foreground: Color {
            switch self {
            case .neutral: Color(hex: 0x6B7280)
            case .blue:    Color(hex: 0x2563EB)
            case .violet:  Color(hex: 0x6D28D9)
            case .green:   Color(hex: 0x16A34A)
            case .amber:   Color(hex: 0xD97706)
            case .teal:    Color(hex: 0x0D9488)
            case .red:     Color(hex: 0xDC2626)
            case .orange:  Color(hex: 0xEA580C)
            case .slate:   Color(hex: 0x475569)
            }
        }
    }

    // MARK: - Type

    /// The prototype sets display type in Josefin Sans. That font is not
    /// bundled, so display styles resolve to the system face at the same
    /// weights. Bundling it later is a change to `display(_:_:)` alone — no
    /// call site names a font family.
    public enum Typography {
        static func display(_ size: CGFloat, _ weight: Font.Weight) -> Font {
            .system(size: size, weight: weight, design: .default)
        }

        public static let displayLarge = display(30, .semibold)
        public static let title        = display(22, .bold)
        /// The date numeral in a calendar cell. Named rather than exposing
        /// `display(_:_:)`, which would let any view invent a size.
        public static let dayNumber    = display(19, .semibold)
        public static let heading      = display(18, .semibold)
        public static let cardTitle    = display(16.5, .semibold)
        public static let body         = Font.system(size: 15, weight: .regular)
        public static let label        = Font.system(size: 13, weight: .medium)
        /// Secondary detail under a title. The design's workhorse size.
        public static let caption      = Font.system(size: 12.5, weight: .regular)
        /// The quietest text in the app — "Assignment", "4 blocks · moderate".
        public static let micro        = Font.system(size: 10.5, weight: .medium)
        /// Uppercase course codes and section headers.
        public static let overline     = display(10, .semibold)
        /// Times, counts and percentages, so digits do not jitter as they change.
        public static let mono         = Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    /// Uppercase labels in the design are widely tracked. Kerning is in points,
    /// which is what `.tracking` takes.
    /// Tracking in points, which is what `.tracking` takes. The design
    /// expresses these in em, so each is (em x size) at the size it is used.
    public enum Tracking {
        /// .14em at 10pt — course codes, HAPPENING NOW, day-of-week labels.
        public static let overline: CGFloat = 1.4
        /// .1em at 13pt — section headers.
        public static let sectionHeader: CGFloat = 1.3
        /// .18em at 11pt — the date above the greeting, the widest in the app.
        public static let dateline: CGFloat = 2.0
        /// Display type is set slightly tight; without this the big headings
        /// read wider and softer than the exports.
        public static let display: CGFloat = -0.3
    }

    // MARK: - Layout

    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 20
        public static let xxl: CGFloat = 28
        /// Height the floating tab bar occupies. Content scrolls under it, so
        /// this is applied once in the shell and never by a screen.
        public static let tabBarInset: CGFloat = 96
    }

    public enum Radius {
        /// Glass cards — the large, soft radius of the Today surfaces.
        public static let glass: CGFloat = 22
        /// Session cards sit one step tighter than the panels around them.
        public static let session: CGFloat = 20
        /// Stripe cards — tighter, so the colour rail reads as an edge.
        public static let card: CGFloat = 12
        public static let sheet: CGFloat = 24
        public static let pill: CGFloat = 999
        public static let chip: CGFloat = 8
        public static let control: CGFloat = 12
        public static let icon: CGFloat = 14
        /// The card that says something did not go through: between a stripe
        /// card and a glass panel, so it reads as part of the screen's flow.
        public static let problemCard: CGFloat = 18
    }

    public enum Motion {
        /// The sheet curve used throughout the designs.
        public static let sheet = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.28)
        public static let quick = Animation.easeOut(duration: 0.18)
    }

    /// Width of the colour rail on a subject card. One value, because the rail
    /// is what makes two otherwise different cards read as the same family.
    public static let subjectRailWidth: CGFloat = 4
}

extension Color {
    /// Hex literals keep the token file legible against the design exports.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
