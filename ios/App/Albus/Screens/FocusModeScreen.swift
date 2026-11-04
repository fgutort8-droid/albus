import SwiftUI
import SwiftData
import AlbusCore

/// Focus Mode: one step, one timer, nothing else.
///
/// Deliberately the only dark screen in the app. The contrast is the point —
/// the world goes quiet, the cactus is the only thing to look at, and there is
/// nothing to tap that is not the session.
///
/// **What it honestly cannot do.** iOS gives no app the ability to block other
/// apps; only Screen Time can, and only for a device's own owner. So this does
/// not claim to lock anything. It keeps the screen awake, counts real time,
/// notices when you leave, and tells you when the timer is done.
struct FocusModeScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FocusSession.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences

    let record: PlanSessionRecord

    @State private var showingEndEarly = false
    @State private var didRequestNotifications = false

    private var subject: Tokens.SubjectColor {
        record.subtask?.assignment?.course?.subjectColor ?? .violet
    }

    var body: some View {
        ZStack {
            FocusBackdrop(tint: subject.color)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                cactus
                Spacer(minLength: 0)
                countdown
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.vertical, Tokens.Spacing.xxl)
        }
        // Locked dark regardless of the rest of the app.
        .preferredColorScheme(.dark)
        .statusBarHidden()
        // A study timer that lets the screen sleep is a study timer nobody
        // watches. Reset on the way out so it does not leak into the app.
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            session.start(record, context: context)
            Task {
                guard !didRequestNotifications else { return }
                didRequestNotifications = true
                // A beat, so the student sees the screen they just opened
                // before iOS puts a dialog over it. Asking here at all is
                // deliberate: this is the first moment the permission is
                // actually worth anything.
                try? await Task.sleep(for: .milliseconds(900))
                await NotificationScheduler().requestPermission()
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { _, phase in
            // Only a real departure counts.
            //
            // `.inactive` is not leaving: an alert, Control Centre, a
            // notification banner or the app switcher preview all produce it
            // while the student is still sitting there. Counting those told a
            // student who had not moved that Albus "noticed you left once" —
            // the permission prompt on this very screen triggered it.
            if phase == .background { session.noteLeftApp() }
        }
        .interactiveDismissDisabled(session.phase == .running)
        .confirmationDialog("End this session early?",
                            isPresented: $showingEndEarly, titleVisibility: .visible) {
            Button("Done — I finished the step") { end(completed: true) }
            Button("Stop, still to do") { end(completed: false) }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Albus records the \(DurationText.short(minutes: max(1, session.focusedSeconds / 60))) on your timer, rather than the \(DurationText.short(minutes: record.plannedSeconds / 60)) planned.")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                if let assignment = record.subtask?.assignment {
                    Text((assignment.course?.displayName ?? assignment.taskType).uppercased())
                        .font(Tokens.Typography.overline)
                        .tracking(Tokens.Tracking.overline)
                        .foregroundStyle(subject.color)
                }
                Text(record.subtask?.title ?? "Study session")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Spacing.l)
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave focus mode")
        }
    }

    private var cactus: some View {
        ZStack {
            // A slow breath, so the screen feels alive without asking for
            // attention. Stops when the timer does.
            BreathingHalo(tint: subject.color, isActive: session.phase == .running)
            // The same week the rest of the app is showing. Mood is a fact
            // about the student's workload, not about the length of whichever
            // block happens to be open — reading it off this session's minutes
            // meant the cactus changed character between screens.
            AlbusCactus(
                size: 150,
                mood: .init(coordinator.workload),
                isResting: session.phase == .running
            )
        }
        .frame(height: 240)
    }

    private var countdown: some View {
        VStack(spacing: Tokens.Spacing.m) {
            Text(timeString(session.remainingSeconds))
                .font(.system(size: 64, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.default, value: session.remainingSeconds)

            Text(statusLine)
                .font(Tokens.Typography.caption)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            ProgressBar(fraction: session.progress, tint: subject.color, height: 5)
                .frame(maxWidth: 240)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time remaining")
        .accessibilityValue(timeString(session.remainingSeconds))
    }

    private var statusLine: String {
        switch session.phase {
        case .finished:
            "Session complete. \(DurationText.short(minutes: max(1, session.focusedSeconds / 60))) focused."
        case .paused:
            "Paused. Time is not counting."
        case .running where session.interruptions > 0:
            "Albus can't lock other apps — but it noticed you left \(session.interruptions == 1 ? "once" : "\(session.interruptions) times")."
        case .running:
            "Albus can't lock your phone. This is you and the timer."
        case .idle:
            "Ready when you are."
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.phase {
        case .finished:
            VStack(spacing: Tokens.Spacing.m) {
                FocusButton(title: "Done — mark the step complete", isProminent: true,
                            tint: subject.color) { end(completed: true) }
                FocusButton(title: "Not finished yet", isProminent: false,
                            tint: subject.color) { end(completed: false) }
            }
        case .running:
            VStack(spacing: Tokens.Spacing.m) {
                FocusButton(title: "Pause", isProminent: false, tint: subject.color) {
                    session.pause()
                }
                Button("I'm done early") { showingEndEarly = true }
                    .font(Tokens.Typography.label)
                    .foregroundStyle(.white.opacity(0.5))
                    .buttonStyle(.plain)
            }
        case .paused:
            VStack(spacing: Tokens.Spacing.m) {
                FocusButton(title: "Resume", isProminent: true, tint: subject.color) {
                    session.resume()
                }
                Button("End session") { showingEndEarly = true }
                    .font(Tokens.Typography.label)
                    .foregroundStyle(.white.opacity(0.5))
                    .buttonStyle(.plain)
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func end(completed: Bool) {
        session.finish(completedWork: completed, context: context,
                       coordinator: coordinator,
                       availability: preferences.availability)
        dismiss()
    }

    /// Closing without ending banks the time and leaves the session to do.
    private func close() {
        session.cancel(context: context)
        dismiss()
    }

    private func timeString(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Focus-only chrome

/// The dark ground. Near-black rather than pure black so the cactus's own
/// shadow tones still read.
private struct FocusBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            Tokens.Palette.focusBackdrop
            RadialGradient(
                colors: [tint.opacity(0.22), .clear],
                center: .center, startRadius: 0, endRadius: 320
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A slow pulse behind the cactus.
private struct BreathingHalo: View {
    let tint: Color
    let isActive: Bool
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [tint.opacity(0.30), .clear],
                                 center: .center, startRadius: 0, endRadius: 130))
            .frame(width: 260, height: 260)
            .scaleEffect(expanded ? 1.08 : 0.94)
            .opacity(isActive ? 1 : 0.5)
            .animation(isActive
                       ? .easeInOut(duration: 4).repeatForever(autoreverses: true)
                       : .default,
                       value: expanded)
            .onAppear { expanded = true }
            .accessibilityHidden(true)
    }
}

private struct FocusButton: View {
    let title: String
    let isProminent: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.label)
                .fontWeight(.semibold)
                .foregroundStyle(isProminent ? .white : .white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    let shape = RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                 style: .continuous)
                    if isProminent {
                        shape.fill(tint)
                    } else {
                        shape.fill(.white.opacity(0.10))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
