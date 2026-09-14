import SwiftUI
import SwiftData
import AlbusCore

/// First launch: three questions, one deadline, a plan.
///
/// This is also where the account is created. Albus has no signup wall, but
/// "no wall" cannot mean "no check" — anonymous sign-up is the endpoint a
/// script would farm, so the account is created here, at the end, where a
/// CAPTCHA challenge can be attached to it.
struct OnboardingFlow: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences

    enum Step { case profile, deadline, building, meetAlbus }

    @State private var step: Step = .profile

    // Screen 1
    @State private var name = ""
    @State private var program: Preferences.Program = .other
    @State private var load: Preferences.StudyLoad = .standard

    // Screen 2
    @State private var taskTitle = ""
    @State private var taskType = "essay"
    @State private var deadline = Calendar.current.date(byAdding: .day, value: 3, to: .now) ?? .now
    @State private var hours = 2.0

    // Account creation
    @State private var showingCaptcha = false
    @State private var failure: String?

    // Building step: drives the cactus's breathing pulse.
    @State private var pulsing = false

    var body: some View {
        ZStack {
            BackgroundGradient()
            switch step {
            case .profile:    profileStep
            case .deadline:   deadlineStep
            case .building:   buildingStep
            case .meetAlbus:  meetAlbusStep
            }
        }
        .animation(Tokens.Motion.sheet, value: step)
        .sheet(isPresented: $showingCaptcha) {
            CaptchaSheet { token in
                showingCaptcha = false
                Task { await finish(captchaToken: token, required: true) }
            }
            .presentationDetents([.height(320)])
        }
    }

    // MARK: - 1. Profile

    /// Name and study hours, then the first deadline.
    private var formStepCount: Double { 2 }

    private var profileStep: some View {
        OnboardingScaffold(
            progress: 1 / formStepCount,
            title: "A few things first.",
            subtitle: "So Albus can build your first plan.",
            actionTitle: "Next",
            isEnabled: true,
            action: { step = .deadline }
        ) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                field("Your name") {
                    TextField("e.g. Felipe", text: $name)
                        .textInputAutocapitalization(.words)
                        .textContentType(.givenName)
                        .padding(Tokens.Spacing.m)
                        .background(Tokens.Glass.fill,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                         style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                        }
                }

                // One programme is not a question, so the control hides itself
                // rather than presenting a list of length one.
                if Preferences.Program.offered.count > 1 {
                    field("Your program") {
                        ChoiceGrid(columns: 2, options: Preferences.Program.offered,
                                   selection: $program) { $0.rawValue }
                    }
                }

                field("Daily study hours") {
                    ChoiceGrid(columns: 3, options: Preferences.StudyLoad.allCases,
                               selection: $load) { $0.title }
                }
            }
        }
    }

    // MARK: - 2. First deadline

    private var deadlineStep: some View {
        OnboardingScaffold(
            progress: 1.0,
            title: "Give me your most urgent deadline.",
            subtitle: "This is where your first plan begins.",
            actionTitle: "Build my plan",
            isEnabled: taskTitle.trimmingCharacters(in: .whitespaces).count >= 2,
            action: begin
        ) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                field("Task name") {
                    TextField("e.g. History term paper", text: $taskTitle)
                        .textInputAutocapitalization(.sentences)
                        .onChange(of: taskTitle) {
                            if taskTitle.count > NewAssignment.maxTitleCharacters {
                                taskTitle = String(taskTitle.prefix(NewAssignment.maxTitleCharacters))
                            }
                        }
                        .padding(Tokens.Spacing.m)
                        .background(Tokens.Glass.fill,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                         style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                        }
                }

                field("What kind of work") {
                    ChoiceGrid(columns: 3, options: TaskType.offered,
                               selection: Binding(
                                get: { TaskType(storedValue: taskType) },
                                set: { taskType = $0.rawValue })) { $0.title }
                }

                field("Deadline") {
                    DatePicker("", selection: $deadline, in: Date.now...,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }

                field("About how long") {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text("\(hours, format: .number.precision(.fractionLength(1))) hours")
                            .font(Tokens.Typography.label)
                            .foregroundStyle(Tokens.Palette.ink)
                        Slider(value: $hours, in: 0.5...20, step: 0.5)
                            .tint(Tokens.Palette.accent)
                    }
                }

                if let failure {
                    StatusBanner(tone: .error, message: failure, retryTitle: "Retry", retry: begin)
                }
            }
        }
    }

    // `TaskKind` used to be declared here with six cases, while AddTaskSheet
    // had its own eight-entry list — so a student could pick a type when adding
    // a task that onboarding would not offer them. Both now read `TaskType`.

    // MARK: - 3. Building

    private var buildingStep: some View {
        VStack(spacing: Tokens.Spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Tokens.Palette.accent.opacity(0.12))
                    .frame(width: 200, height: 200)
                    .blur(radius: 20)
                // Albus, not a generic SF Symbol leaf — the mascot should be the
                // first thing a student meets, not a placeholder standing in for
                // it. `.calm` because there is no workload to reflect yet; the
                // pulse is the same breathing rhythm Focus Mode uses while it
                // waits.
                AlbusCactus(size: 72, mood: .calm)
                    .scaleEffect(pulsing ? 1.06 : 0.96)
                    .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                              value: pulsing)
                    .onAppear { pulsing = true }
            }
            VStack(spacing: Tokens.Spacing.s) {
                Text("Building your plan.")
                    .font(Tokens.Typography.heading)
                    .foregroundStyle(Tokens.Palette.ink)
                Text("Give me a moment.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer()
            if let failure {
                StatusBanner(tone: .error, message: failure, retryTitle: "Back") {
                    step = .deadline
                }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.xxl)
            } else {
                ProgressBar(fraction: 0.66)
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .padding(.bottom, Tokens.Spacing.xxl)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Building your plan")
    }

    // MARK: - 4. Meet Albus

    private var meetAlbusStep: some View {
        VStack(spacing: Tokens.Spacing.xl) {
            Spacer()
            GlassCard {
                VStack(spacing: Tokens.Spacing.s) {
                    Text(preferences.firstName.isEmpty
                         ? "Your plan is ready."
                         : "Hey \(preferences.firstName), your plan is ready.")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.center)
                    Text("It's waiting on Home. Add anything else you need to plan with the + button.")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)

            AlbusCactus(size: 72, mood: .calm)

            Spacer()
            PrimaryButton(title: "Show me") {
                // The permission ask, at the only moment it is obviously
                // reasonable: a plan now exists, so there is something to be
                // notified *about*.
                //
                // It used to be asked only when a focus session started, which
                // meant a student who never ran one could never grant it and
                // Albus could never speak. Asked here it follows a screen that
                // has just explained what Albus does, and a refusal costs
                // nothing — the settings screen can ask again later.
                Task {
                    await NotificationScheduler().requestPermission()
                    preferences.markOnboarded()
                }
            }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.xxl)
        }
    }

    // MARK: - Account + first plan

    /// Saves the profile, then either presents the challenge or goes straight
    /// to creating the account.
    private func begin() {
        failure = nil
        preferences.name = name
        preferences.program = program
        preferences.load = load

        if case .signedIn = session.state {
            // Already have an account (a flow resumed after a crash, say).
            step = .building
            Task { await finish(captchaToken: nil, required: false) }
        } else if Captcha.isEnabled {
            showingCaptcha = true
        } else {
            step = .building
            Task { await finish(captchaToken: nil, required: false) }
        }
    }

    /// Creates the account if needed, then generates the first plan.
    ///
    /// `required` says whether a token was mandatory. When it was and none
    /// arrived, this refuses rather than silently signing up without one —
    /// falling back would defeat the entire point of the challenge.
    private func finish(captchaToken: String?, required: Bool) async {
        if required && captchaToken == nil {
            failure = "That check didn't complete. Try once more."
            step = .deadline
            return
        }

        step = .building

        if case .signedIn = session.state {} else {
            let ok = await session.createAccount(captchaToken: captchaToken)
            guard ok else {
                failure = "Couldn't set up your account. Check your connection."
                step = .deadline
                return
            }
        }

        // The student names their own subjects once they are in the app; the
        // first assignment does not need one.
        await coordinator.addAssignment(
            NewAssignment(
                title: taskTitle.trimmingCharacters(in: .whitespaces),
                taskType: taskType,
                deadline: deadline,
                estimatedMinutes: Int(hours * 60),
                course: nil
            ),
            context: context,
            availability: preferences.availability
        )

        // A failed generation must not trap the student in onboarding: the
        // assignment is saved either way, and Task detail explains the gap.
        step = .meetAlbus
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(label.uppercased())
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            content()
        }
    }
}

/// Shared chrome for the two form steps.
private struct OnboardingScaffold<Content: View>: View {
    let progress: Double
    let title: String
    let subtitle: String
    let actionTitle: String
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(fraction: progress)
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.top, Tokens.Spacing.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text(title)
                            .font(Tokens.Typography.title)
                            .foregroundStyle(Tokens.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                    content
                }
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.top, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)

            PrimaryButton(title: actionTitle, isEnabled: isEnabled, action: action)
                .padding(.horizontal, Tokens.Spacing.xl)
                .padding(.bottom, Tokens.Spacing.xl)
        }
    }
}

/// A grid of single-choice chips.
private struct ChoiceGrid<Option: Identifiable & Hashable>: View {
    let columns: Int
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.s),
                           count: columns),
            spacing: Tokens.Spacing.s
        ) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .font(Tokens.Typography.label)
                        .foregroundStyle(isSelected ? .white : Tokens.Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            isSelected ? AnyShapeStyle(Tokens.Palette.accent)
                                       : AnyShapeStyle(Tokens.Glass.fill),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                 style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                                .strokeBorder(isSelected ? .clear : Tokens.Palette.hairline,
                                              lineWidth: 0.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }
}

/// `ChoiceGrid` for values that are already codes rather than model types.
///
/// The subject and component grids choose between strings that came out of the
/// bundled curriculum data, and wrapping each one in an `Identifiable` shim just
/// to satisfy a generic constraint would be more code than this.
private struct CodeGrid: View {
    let columns: Int
    let options: [(value: String, title: String)]
    @Binding var selection: String

    var body: some View {
        ChipGrid(columns: columns, options: options,
                 isSelected: { $0 == selection },
                 toggle: { selection = $0 })
    }
}

/// The same grid, but any number of chips can be on at once.
private struct MultiChoiceGrid: View {
    let columns: Int
    let options: [(value: String, title: String)]
    @Binding var selection: Set<String>

    var body: some View {
        ChipGrid(columns: columns, options: options,
                 isSelected: { selection.contains($0) },
                 toggle: { code in
                     if selection.contains(code) { selection.remove(code) }
                     else { selection.insert(code) }
                 })
    }
}

/// What both grids are made of. Kept separate from `ChoiceGrid` rather than
/// generalising it: that one is bound to a single value of a model type and
/// making one control serve both would mean a generic signature harder to read
/// than the two call sites it saves.
private struct ChipGrid: View {
    let columns: Int
    let options: [(value: String, title: String)]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.s),
                           count: columns),
            spacing: Tokens.Spacing.s
        ) {
            ForEach(options, id: \.value) { option in
                let on = isSelected(option.value)
                Button { toggle(option.value) } label: {
                    Text(option.title)
                        .font(Tokens.Typography.label)
                        .foregroundStyle(on ? .white : Tokens.Palette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Tokens.Spacing.xs)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(
                            on ? AnyShapeStyle(Tokens.Palette.accent)
                               : AnyShapeStyle(Tokens.Glass.fill),
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                 style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                                .strokeBorder(on ? .clear : Tokens.Palette.hairline, lineWidth: 0.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}
