import SwiftUI
import AlbusCore
import SwiftData

/// Owns the two things every screen sits inside: the full-screen gradient and
/// the floating tab bar.
///
/// Both live here rather than in each screen so the safe-area maths is solved
/// once. Content scrolls *under* the bar, which means the bottom inset is set
/// in exactly one place and no screen adds padding of its own.
struct AppShell: View {
    @State private var tab: Tab
    @Environment(\.modelContext) private var context
    @Environment(MarkingCoordinator.self) private var marking
    @Environment(NotificationRouter.self) private var router
    /// A finished marking opened from its banner or its notification.
    @State private var openedGrading: Grading?

    init() {
#if DEBUG
        let initial: Tab = ProcessInfo.processInfo.arguments
            .contains("-albus.debug.openSettings") ? .settings : .home
#else
        let initial: Tab = .home
#endif
        _tab = State(initialValue: initial)
    }

    /// Four destinations.
    ///
    /// Home and Tasks used to be two tabs showing the same thing from different
    /// angles — Home listed session blocks, Tasks listed the assignments those
    /// blocks belonged to. Home is now the assignment list, which is what a
    /// student actually keeps track of, and the freed slot went to Rubrics,
    /// which needed somewhere to live.
    ///
    /// Ask Albus held the third slot and no longer does. A conversation about
    /// an assignment belongs *beside that assignment*, where it already knows
    /// the rubric and the deadline without being told — so it lives in Task
    /// detail now, and the tab went to Settings, which had never had a home at
    /// all. Every preference in the app was previously reachable only through
    /// one small button on Home.
    enum Tab: String, CaseIterable, Identifiable {
        case home, rubrics, tools, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "Home"
            case .rubrics: "Rubrics"
            case .tools: "Tools"
            case .settings: "Settings"
            }
        }

        var icon: String {
            switch self {
            case .home: "house"
            case .rubrics: "list.bullet.rectangle.portrait"
            case .tools: "wrench.and.screwdriver"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // A stack per tab so pushing a plan from Home does not reset
            // scroll position elsewhere.
            Group {
                switch tab {
                case .home: NavigationStack { Screen { HomeScreen() } }
                case .rubrics: NavigationStack { Screen { RubricsScreen() } }
                case .tools: NavigationStack { Screen { ToolsScreen() } }
                case .settings: NavigationStack { Screen { SettingsScreen() } }
                }
            }

            AppTabBar(selection: $tab)
        }
        .ignoresSafeArea(.keyboard)
        // A marking finished while the student was elsewhere in the app. The
        // grader screen, when it is open, shows the result itself.
        .overlay(alignment: .top) {
            if let id = marking.ready, !marking.isWatched, let grading = grading(id) {
                MarkingReadyBanner(title: grading.workTitle) {
                    marking.markSeen()
                    openedGrading = grading
                } onDismiss: {
                    marking.markSeen()
                }
                .padding(.horizontal, Tokens.Spacing.l)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Tokens.Motion.sheet, value: marking.ready)
        .onChange(of: marking.ready) { _, id in
            if id != nil {
                AccessibilityNotification.Announcement("Your feedback is ready").post()
            }
        }
        .sheet(item: $openedGrading) { GradeResultView(grading: $0) }
        // A "feedback is ready" notification, tapped. `initial` covers a tap
        // that launched the app, which sets the route before this appears.
        .onChange(of: router.requestedGrading, initial: true) { _, id in
            guard let id else { return }
            router.clearGradingRoute()
            marking.markSeen()
            if let grading = grading(id) { openedGrading = grading }
        }
    }

    private func grading(_ id: UUID) -> Grading? {
        var descriptor = FetchDescriptor<Grading>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// "Your feedback is ready", wherever the student is when a marking finishes.
private struct MarkingReadyBanner: View {
    let title: String?
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Tokens.Radius.glass, style: .continuous)
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            AlbusCactus(size: 30, mood: .calm)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your feedback is ready")
                    .font(Tokens.Typography.label)
                    .foregroundStyle(Tokens.Palette.ink)
                if let title {
                    Text(title)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Tokens.Spacing.s)
            Button("View", action: onOpen)
                .font(Tokens.Typography.label.weight(.semibold))
                .foregroundStyle(Tokens.Palette.accent)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .padding(.vertical, Tokens.Spacing.s + 2)
        // Frosted, then whitened: it floats over whatever screen is open, and
        // a translucent card let that screen's headline show through the text.
        .background {
            shape.fill(.regularMaterial)
            shape.fill(Tokens.Glass.fillProminent)
        }
        .overlay { shape.strokeBorder(Tokens.Glass.stroke) }
        .shadow(color: Tokens.Glass.shadow, radius: Tokens.Glass.shadowRadius,
                y: Tokens.Glass.shadowY)
    }
}

/// Wraps a screen's content with the shared background and the inset the
/// floating tab bar needs.
///
/// The gradient has to live *inside* the NavigationStack: a stack paints its
/// own surface, so a gradient placed behind one is simply covered. Putting the
/// scaffold here means screens still never think about either concern.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BackgroundGradient())
            .safeAreaPadding(.bottom, Tokens.Spacing.tabBarInset)
    }
}

/// The app's aurora background: a warm paper wash with three blurred colour
/// blobs, matching `PhoneBackground(variant: "aurora")` in the prototype.
///
/// Drawn with `.blur` on plain circles rather than as a shipped image so it
/// scales to any device without an asset, and so a palette change stays a
/// token edit. `drawingGroup()` flattens the blurs into one offscreen pass —
/// without it three large blurred layers are recomposited on every scroll
/// frame, which is visible on older devices.
struct BackgroundGradient: View {
    var body: some View {
        LinearGradient(stops: Tokens.Palette.backgroundStops,
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack {
                        blob(Tokens.Palette.auroraViolet, opacity: 0.35, size: w * 0.95)
                            .offset(x: -w * 0.35, y: -w * 0.30)
                        blob(Tokens.Palette.auroraAmber, opacity: 0.22, size: w * 0.90)
                            .offset(x: w * 0.42, y: w * 0.30)
                        blob(Tokens.Palette.auroraGreen, opacity: 0.18, size: w * 0.85)
                            .offset(x: -w * 0.30, y: w * 0.95)
                    }
                    .blur(radius: 60)
                    .drawingGroup()
                }
            }
            .ignoresSafeArea()
            // Purely decorative: it must never be announced or focused.
            .accessibilityHidden(true)
    }

    private func blob(_ color: Color, opacity: Double, size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
    }
}

struct AppTabBar: View {
    @Binding var selection: AppShell.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppShell.Tab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: Tokens.Spacing.xs) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 18, weight: .medium))
                        Text(tab.title)
                            .font(Tokens.Typography.caption)
                    }
                    .foregroundStyle(selection == tab
                                     ? Tokens.Palette.accent
                                     : Tokens.Palette.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.vertical, Tokens.Spacing.m)
        .padding(.horizontal, Tokens.Spacing.s)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.bottom, Tokens.Spacing.s)
    }
}

#Preview {
    AppShell()
}
