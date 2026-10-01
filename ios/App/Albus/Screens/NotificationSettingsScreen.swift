import SwiftUI
import SwiftData
import UserNotifications
import AlbusCore

/// When Albus is allowed to speak, and in what voice.
///
/// **This screen is also the second place permission is asked**, and that is
/// the reason it exists rather than being deferred. Before it, the only ask was
/// inside Focus Mode — so a student who never started a focus session could
/// never grant permission, and the entire feature was unreachable for them.
struct NotificationSettingsScreen: View {
    @Environment(Preferences.self) private var preferences
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context

    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var isAsking = false

    private let weekdays = [(1, "Sun"), (2, "Mon"), (3, "Tue"), (4, "Wed"),
                            (5, "Thu"), (6, "Fri"), (7, "Sat")]

    var body: some View {
        @Bindable var preferences = preferences

        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                permission

                if status == .authorized || status == .provisional {
                    voice($preferences)
                    timing($preferences)
                    warnings($preferences)
                    studyWindow($preferences)
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { status = await NotificationScheduler().authorizationStatus() }
        // One rebuild when the student leaves, rather than one per toggle.
        .onDisappear {
            notifications.scheduleRebuild(context: context, preferences: preferences,
                                          coordinator: coordinator)
        }
    }

    // MARK: - Permission

    @ViewBuilder private var permission: some View {
        switch status {
        case .notDetermined:
            card {
                Text("Let Albus speak first")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("A planner you have to remember to open is a to-do list. "
                     + "Albus will tell you what's due, when a block starts, and "
                     + "when your plan stops fitting.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                PrimaryButton(title: isAsking ? "Asking…" : "Turn on notifications",
                              isEnabled: !isAsking) {
                    isAsking = true
                    Task {
                        await NotificationScheduler().requestPermission()
                        status = await NotificationScheduler().authorizationStatus()
                        isAsking = false
                        notifications.scheduleRebuild(context: context,
                                                      preferences: preferences,
                                                      coordinator: coordinator)
                    }
                }
            }

        case .denied:
            // Nothing in-app can undo a denial, so the only honest thing to
            // offer is the way to the setting that can.
            card {
                Text("Notifications are off")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("Albus can't reach you until they're turned back on in iOS Settings.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.accent)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Sections

    @ViewBuilder private func voice(_ preferences: Bindable<Preferences>) -> some View {
        section("Voice") {
            // Not "Notifications": that is this screen's title, one line up.
            // Said in the voice the rest of the screen uses — "When Albus
            // speaks" is how Settings names the way here.
            Toggle("Let Albus speak", isOn: preferences.notificationsEnabled)
            Toggle("Serious mode", isOn: preferences.seriousMode)
            Text(preferences.wrappedValue.seriousMode
                 ? "Plain and factual. No jokes."
                 : "Albus talks like Albus. Never about work you've already missed.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }

    @ViewBuilder private func timing(_ preferences: Bindable<Preferences>) -> some View {
        section("When") {
            stepper("Morning brief", value: preferences.briefHour, range: 5...11)
            Toggle("Nudge me when a block starts", isOn: preferences.nudgeEnabled)
            stepper("Quiet from", value: preferences.quietStartHour, range: 18...23)
            stepper("Quiet until", value: preferences.quietEndHour, range: 4...11)

            // "Fewer", not "Quiet": two rows up, "Quiet from" and "Quiet
            // until" are the hours, and this is how many.
            Picker("Most per day", selection: preferences.maxPerDay) {
                Text("Fewer").tag(1)
                Text("Normal").tag(2)
                Text("More").tag(3)
            }
            .pickerStyle(.segmented)

            // Said plainly, because the alternative is a student believing a
            // hand-in warning was suppressed to honour a slider.
            Text("Anything overdue, due today, or no longer fitting always gets "
                 + "through, whatever this is set to.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }

    @ViewBuilder private func warnings(_ preferences: Bindable<Preferences>) -> some View {
        section("Deadline warnings") {
            Toggle("Three days before", isOn: preferences.warnAt72h)
            Toggle("The day before", isOn: preferences.warnAt24h)
            Toggle("Three hours before", isOn: preferences.warnAt3h)
        }
    }

    @ViewBuilder private func studyWindow(_ preferences: Bindable<Preferences>) -> some View {
        section("Study window") {
            Text("When Albus is allowed to place work.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
            stepper("From", value: preferences.windowStartHour, range: 6...20)
            stepper("Until", value: preferences.windowEndHour, range: 8...23)

            Text("Days off")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            HStack(spacing: Tokens.Spacing.xs) {
                ForEach(weekdays, id: \.0) { number, label in
                    dayToggle(number: number, label: label, preferences: preferences)
                }
            }
        }
    }

    private func dayToggle(number: Int, label: String,
                           preferences: Bindable<Preferences>) -> some View {
        let isOff = preferences.wrappedValue.daysOff.contains(number)
        // The last available day cannot be switched off: a week with no days in
        // it leaves the scheduler nowhere to place anything, and every step
        // reports unplaceable with no obvious way back.
        let isLastAvailable = !isOff && preferences.wrappedValue.daysOff.count >= 6

        return Button {
            var days = preferences.wrappedValue.daysOff
            if isOff { days.remove(number) } else if !isLastAvailable { days.insert(number) }
            preferences.wrappedValue.daysOff = days
        } label: {
            Text(label)
                .font(Tokens.Typography.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.s)
                .background(isOff ? Tokens.Palette.accentWash : Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                .foregroundStyle(isOff ? Tokens.Palette.accent : Tokens.Palette.inkMuted)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.chip)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(isLastAvailable)
        .accessibilityLabel("\(label), \(isOff ? "off" : "studying")")
    }

    // MARK: - Small pieces

    private func stepper(_ label: String, value: Binding<Int>,
                         range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            HStack {
                Text(label)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                Text(String(format: "%02d:00", value.wrappedValue))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder private func section(
        _ label: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: label) { EmptyView() }
            card { content() }
        }
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) { content() }
            .font(Tokens.Typography.caption)
            .tint(Tokens.Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.l)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
            }
    }
}
