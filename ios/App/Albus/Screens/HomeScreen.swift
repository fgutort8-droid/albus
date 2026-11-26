import SwiftUI
import SwiftData
import AlbusCore

/// Home: the work, not the work's parts.
///
/// This screen listed individual scheduled blocks, and a separate Tasks tab
/// listed the assignments those blocks belonged to — the same information twice,
/// with the less useful half given the more prominent slot. A student keeps
/// track of *assignments*; the steps are what they open an assignment to see.
///
/// So Home is the assignment list now, and the plan lives one tap in. The single
/// exception is the "up next" row: what to do *right now* is the one question a
/// planner must answer without navigation, and it names the assignment rather
/// than exposing the plan.
struct HomeScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(Preferences.self) private var preferences
    @Environment(EntitlementService.self) private var entitlements
    @Environment(FocusSession.self) private var focusSession
    @Environment(NotificationRouter.self) private var router

    @Query(sort: \Assignment.deadline) private var assignments: [Assignment]
    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]

    @State private var filter: Filter

    /// The app opens on All; a snapshot can open on another filter.
    init(filter: Filter = .all) {
        _filter = State(initialValue: filter)
    }
    @State private var addingTask = false
    /// Where Home can push to, as one value.
    ///
    /// **Not three `navigationDestination(isPresented:)` modifiers.** Stacking
    /// them in a single scope does not give you three destinations — SwiftUI
    /// keeps one and silently routes every push through it. Adding the settings
    /// and notification-tap destinations beside the existing month one made
    /// "Month view" open the notification settings, with no warning and no
    /// crash. One modifier, one enum, no ambiguity.
    enum Destination: Hashable, Identifiable {
        case month
        case notificationSettings
        case assignment(Assignment)

        var id: String {
            switch self {
            case .month: "month"
            case .notificationSettings: "settings"
            case .assignment(let assignment): assignment.id.uuidString
            }
        }
    }

    @State private var destination: Destination?
    @State private var showingPaywall = false
    /// The assignment awaiting a yes. Held rather than a bool so the dialog can
    /// name the thing it is about to destroy.
    @State private var confirmingDelete: Assignment?
    @State private var confirmingRelease = false
    /// Why "Stop counting" did not go through, said under its button.
    @State private var releaseFailure: String?
    @State private var focusing: PlanSessionRecord?

    enum Filter: String, CaseIterable, Identifiable {
        case all, dueSoon, overdue, needsTime, done
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .dueSoon: "Due soon"
            case .overdue: "Overdue"
            case .needsTime: "Needs time"
            case .done: "Done"
            }
        }
    }

    /// Grouping is by deadline; "done" is a filter rather than a group, because
    /// a finished assignment still belongs to the week it was due in.
    private enum Group: String, CaseIterable {
        case overdue = "Overdue"
        case today = "Due today"
        case thisWeek = "This week"
        case later = "Later"
        case done = "Done"
    }

    var body: some View {
        // Once a minute: the greeting, the countdown and "happening now" all go
        // stale on their own.
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            content(now: timeline.date)
        }
        .sheet(isPresented: $addingTask) {
            AddTaskSheet { draft in
                Task {
                    await coordinator.addAssignment(draft, context: context,
                                                    availability: preferences.availability,
                                                    taskLimit: entitlements.plan.tasks.limit,
                                                    useAI: preferences.mayUseAI)
                    // Refused, perhaps by a plan full of another phone's
                    // tasks: read the plan again, so Home can say so.
                    if case .failed = coordinator.status { await entitlements.refresh() }
                }
            }
        }
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .confirmationDialog("Delete this assignment?",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let assignment = confirmingDelete {
                    coordinator.deleteAssignment(assignment, context: context,
                                                 focusSession: focusSession,
                                                 availability: preferences.availability)
                }
                confirmingDelete = nil
            }
            Button("Keep it", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(confirmingDelete.map {
                "\($0.title) — its plan, scheduled time and saved marking go with it. A marking in progress may still appear in your history. This cannot be undone."
            } ?? "")
        }
        .confirmationDialog(uncountedOnPhone == 1 ? "Stop counting that task?"
                                                  : "Stop counting those \(uncountedOnPhone) tasks?",
                            isPresented: $confirmingRelease, titleVisibility: .visible) {
            Button("Stop counting") { Task { await releaseUncounted() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uncountedOnPhone == 1
                 ? "It was made on another phone, or before Albus was reinstalled. If you still use "
                   + "that phone, it stays there, but it won't count toward your plan any more."
                 : "They were made on another phone, or before Albus was reinstalled. If you still use "
                   + "that phone, they stay there, but they won't count toward your plan any more.")
        }
        .fullScreenCover(item: $focusing) { record in
            FocusModeScreen(record: record)
        }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case .month:
                Screen { MonthCalendarScreen() }
            case .notificationSettings:
                Screen { NotificationSettingsScreen() }
            case .assignment(let assignment):
                Screen { TaskDetailScreen(assignment: assignment) }
            }
        }
        .onChange(of: router.requestedAssignment) { _, requested in
            guard let requested,
                  let match = assignments.first(where: { $0.id == requested })
            else { return }
            destination = .assignment(match)
            // Cleared immediately so tapping the same notification twice, or
            // returning to Home and tapping another, both route again.
            router.clearRoute()
        }
    }

    private func content(now: Date) -> some View {
        let fit = weekFit(now: now)
        let needsTimeIDs = fit?.assignmentIDs ?? []
        let visible = assignments.filter { matches($0, now: now, needsTimeIDs: needsTimeIDs) }
        let grouped = Dictionary(grouping: visible) { group(for: $0, now: now) }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header(now: now)
                problemCard
                taskMeter

                if let next = upNext(now: now) {
                    UpNextCard(record: next, now: now) {
                        // The timer holds this step: it stays.
                        coordinator.claim(next.subtask?.assignment)
                        focusing = next
                    }
                }

                WeekStrip(sessions: PlanBridge.inPlan(sessions), now: now) { destination = .month }

                if let fit {
                    weekFitNotice(fit)
                }

                FilterChipRow(filters: Filter.allCases.filter { $0 != .needsTime || fit != nil || filter == .needsTime }, selection: $filter) { $0.title }
                    .padding(.horizontal, -Tokens.Spacing.xl)

                if visible.isEmpty {
                    emptyState
                } else {
                    ForEach(Group.allCases, id: \.self) { section in
                        if let items = grouped[section], !items.isEmpty {
                            SectionHeader(section.rawValue, count: items.count)
                                .padding(.top, Tokens.Spacing.xs)
                            VStack(spacing: Tokens.Spacing.s + 2) {
                                ForEach(items) { assignment in
                                    NavigationLink {
                                        Screen { TaskDetailScreen(assignment: assignment) }
                                    } label: {
                                        AssignmentCard(assignment: assignment, now: now,
                                                       isRefining: coordinator.isRefining(assignment),
                                                       localPlan: coordinator.localPlanReason(for: assignment),
                                                       seePlus: { showingPaywall = true })
                                    }
                                    .buttonStyle(.plain)
                                    // The up-next card shows the same title, so
                                    // "the element labelled <title>" is genuinely
                                    // ambiguous on this screen — and the two do
                                    // different things. A UI test that picks the
                                    // wrong one lands in Focus Mode and reports
                                    // that the plan is missing.
                                    .accessibilityIdentifier("assignmentCard")
                                    // Long-press rather than swipe: this is a
                                    // LazyVStack of cards, not a List, so there
                                    // is no swipe affordance to hang it off.
                                    .contextMenu {
                                        Button("Delete assignment", systemImage: "trash",
                                               role: .destructive) {
                                            confirmingDelete = assignment
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Selection

    private func group(for assignment: Assignment, now: Date) -> Group {
        if assignment.isComplete || assignment.isArchived { return .done }
        let cal = Calendar.current
        if assignment.deadline < now { return .overdue }
        if cal.isDateInToday(assignment.deadline) { return .today }
        if let week = cal.date(byAdding: .day, value: 7, to: now),
           assignment.deadline <= week { return .thisWeek }
        return .later
    }

    private func matches(_ assignment: Assignment, now: Date, needsTimeIDs: Set<UUID>) -> Bool {
        Self.shows(assignment, in: filter, now: now, needsTimeIDs: needsTimeIDs)
    }

    /// Whether a filter lists an assignment. An archived one is a closed
    /// record of work rather than open work, so it is listed under Done only.
    static func shows(_ assignment: Assignment, in filter: Filter, now: Date,
                      needsTimeIDs: Set<UUID>) -> Bool {
        let open = !assignment.isComplete && !assignment.isArchived
        switch filter {
        case .all: return open
        case .dueSoon: return open
            && assignment.deadline >= now
            && assignment.deadline <= (Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now)
        case .overdue: return open && assignment.deadline < now
        case .needsTime: return open && needsTimeIDs.contains(assignment.id)
        case .done: return !open
        }
    }

    private func weekFit(now: Date) -> WeekFit? {
        guard coordinator.lastRunSucceeded else { return nil }
        return WeekFit(unplaceable: coordinator.unplacedItems,
                       workload: coordinator.workload, now: now)
    }

    /// Work the week cannot fit before its deadlines. A card, not a cactus:
    /// Albus is already at the top of the screen, and his mood there already
    /// says the week is full.
    private func weekFitNotice(_ fit: WeekFit) -> some View {
        let steps = fit.items.count
        let works = fit.assignmentIDs.count
        return ProblemCard(
            title: "\(steps) \(steps == 1 ? "step doesn't" : "steps don't") fit before \(steps == 1 ? "its deadline" : "their deadlines")",
            message: "\(Self.duration(fit.minutesNeedingTime)) of work across \(works) \(works == 1 ? "assignment" : "assignments"), "
                + "due in the next 7 days or overdue. Split a long step, change an estimate, "
                + "or talk to your teacher about the deadline."
        ) {
            CardButton(title: "See which") { filter = .needsTime }
        }
        .accessibilityIdentifier("weekFitNotice")
    }

    /// "1 h 25", "40 min".
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
    }

    /// The block happening now, or the next one due. Nil once everything is done.
    private func upNext(now: Date) -> PlanSessionRecord? {
        let live = PlanBridge.inPlan(sessions).filter { $0.subtask?.completedAt == nil }
        return live.first { $0.startsAt <= now && $0.endsAt > now }
            ?? live.first { $0.startsAt > now }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            // No date above the greeting: the week strip just below already
            // shows today, picked out, with the month beside it.
            VStack(alignment: .leading, spacing: -2) {
                Text(greeting(at: now) + ",")
                    .font(Tokens.Typography.displayLarge)
                    .tracking(Tokens.Tracking.display)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(preferences.firstName.isEmpty ? "let's go" : preferences.firstName)
                    .font(.system(size: 30, weight: .regular))
                    .italic()
                    .tracking(Tokens.Tracking.display)
                    .foregroundStyle(Tokens.Palette.ink)
            }

            Spacer(minLength: 0)

            VStack(spacing: Tokens.Spacing.s) {
                // Not a fifth tab: `AppShell` documents why a tab was removed
                // for redundancy, and adding one back for settings would argue
                // against reasoning that is already written down.
                Button { destination = .notificationSettings } label: {
                    // The one Albus on Home: when a card below says something
                    // did not go through, he says it with his face.
                    AlbusCactus(size: 36, mood: .init(coordinator.workload),
                                isWorried: showsProblemCard)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notification settings")

                IconButton(systemImage: "plus", isFilled: true,
                           accessibilityLabel: "Add assignment") { addTask() }
            }
        }
        .padding(.top, Tokens.Spacing.s)
    }

    private func greeting(at now: Date) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 0..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// The plan's open-task limit, when it is the thing stopping the student.
    private var taskLimitReached: Bool {
        guard let limit = entitlements.plan.tasks.limit, limit > 0 else { return false }
        return openHere >= limit
    }

    private var openHere: Int {
        assignments.count(where: { !$0.isComplete && !$0.isArchived })
    }

    /// Whether the meter is showing, which already says what a task-limit
    /// refusal would.
    private var showsTaskMeter: Bool {
        taskLimitReached || (uncountedOnPhone > 0 && !coordinator.serverCountSettling)
    }

    private var showsProblemCard: Bool {
        if coordinator.unsaved != nil { return true }
        guard let problem = coordinator.problem else { return false }
        return problem != .taskLimit || !showsTaskMeter
    }

    /// Something the student did that did not go through.
    ///
    /// The AI still writing steps, or the phone having planned without it, is
    /// not here: each is said on the assignment's own card. Neither is being
    /// signed out — `RootView` shows the sign-in screen for that, so a line
    /// about it here could never appear.
    @ViewBuilder private var problemCard: some View {
        // An unsaved change comes first: it is the one problem that loses work.
        if let unsaved = coordinator.unsaved {
            let again = unsaved == .failedAgain
            ProblemCard(
                title: again ? "It still won't save" : "Your last change didn't save",
                message: again
                    ? "This phone is refusing to store it. If it's nearly full, freeing some space usually fixes it."
                    : "It's on screen but not stored on this phone yet. If Albus closes now, it's lost."
            ) {
                CardButton(title: "Save again") { coordinator.retrySave(context: context) }
            }
        } else if showsProblemCard, let problem = coordinator.problem {
            switch problem {
            case .notRebuilt:
                ProblemCard(title: "Your week didn't update",
                            message: "The times below are from before your last change.") {
                    CardButton(title: "Rebuild now") {
                        coordinator.reschedule(context: context, availability: preferences.availability)
                    }
                }
            case .refused(let why, let kept):
                ProblemCard(
                    title: "Albus can't plan that",
                    message: kept
                        ? why + " You've started on it, so it stays until Albus next opens, and what you do on it is kept."
                        : why
                ) {
                    CardButton(title: "Got it", style: .secondary) { coordinator.dismissProblem() }
                }
            case .taskLimit:
                ProblemCard(title: "That's as many tasks as your plan keeps open",
                            message: "Finish one, or move up a plan.") {
                    CardButton(title: "See plans") { showingPaywall = true }
                }
            }
        }
    }

    /// How full the plan is, as one meter rather than two strips that said
    /// nearly the same thing. Guidance only — a trigger on
    /// `public.assignments` enforces it on every write path (migration 0036),
    /// so this being wrong costs a clearer message, never a bypassed limit.
    ///
    /// The number comes from the server's plan rather than a constant here.
    /// Three tiers means three caps, and a literal in this file is a literal
    /// that will eventually disagree with the one the database enforces.
    @ViewBuilder private var taskMeter: some View {
        if showsTaskMeter, let limit = entitlements.plan.tasks.limit, limit > 0 {
            let missing = coordinator.serverCountSettling ? 0 : uncountedOnPhone
            let counted = min(limit, max(openHere + missing, entitlements.plan.tasks.used))
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        Text("\(counted) of \(limit) open tasks")
                            .font(Tokens.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                        // Bars up to ten; past that a row of them stops being
                        // countable at a glance, and the sentence says it.
                        if limit <= 10 {
                            HStack(spacing: 4) {
                                ForEach(0..<limit, id: \.self) { index in
                                    Capsule()
                                        .fill(index < counted ? Tokens.Palette.ink : Tokens.Palette.hairline)
                                        .frame(width: 26, height: 6)
                                }
                            }
                            .accessibilityHidden(true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("See plans") { showingPaywall = true }
                        .font(Tokens.Typography.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(Tokens.Palette.accent)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                }

                Text(Self.meterSentence(plan: entitlements.plan.displayName, limit: limit,
                                        here: openHere, elsewhere: missing))
                    .font(Tokens.Typography.label)
                    .fontWeight(.regular)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if missing > 0 {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        CardButton(title: openHere == 0
                                     ? (missing == 1 ? "Stop counting it" : "Stop counting them")
                                     : "Stop counting the other \(missing)",
                                   style: .secondary) { confirmingRelease = true }
                        if let releaseFailure {
                            ProblemLine(message: releaseFailure)
                        }
                    }
                }
            }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.problemCard, style: .continuous))
            .shadow(color: Tokens.Glass.shadow.opacity(0.5), radius: 12, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("taskMeter")
        }
    }

    /// What the meter says under its count, in one sentence.
    static func meterSentence(plan: String, limit: Int, here: Int, elsewhere: Int) -> String {
        let keeps = "\(plan) keeps \(limit) open at once."
        guard elsewhere > 0 else { return keeps + " Finish one to add the next." }
        let origin = "made on another phone, or before Albus was reinstalled."
        if here == 0 {
            return (elsewhere == 1 ? "It isn't on this phone. It was " : "None of them are on this phone. They were ")
                + origin + " " + keeps
        }
        return "Only \(here) of them \(here == 1 ? "is" : "are") on this phone. The other \(elsewhere) "
            + "\(elsewhere == 1 ? "was" : "were") " + origin + " " + keeps
    }

    /// The add form, or the plans once this phone's open tasks fill the
    /// plan. The form could only end in a refusal then, after the student had
    /// filled it in, and the notice above already says why.
    private func addTask() {
        if entitlements.taskLimit(reachedBy: openHere) != nil {
            showingPaywall = true
        } else {
            addingTask = true
        }
    }

    /// Open tasks the server counts that are not on this phone: made on
    /// another phone, or before Albus was reinstalled. They can fill the plan
    /// with nothing open here, and only the student knows whether that other
    /// phone is still in use, so they choose whether those stop counting.
    private var uncountedOnPhone: Int {
        let open = assignments.filter { !$0.isComplete && !$0.isArchived }
        return PlanCoordinator.uncountedOnPhone(
            used: entitlements.plan.tasks.used, limit: entitlements.plan.tasks.limit,
            openHere: open.count, openHereOnServer: open.count(where: { $0.remoteID != nil }))
    }

    private func releaseUncounted() async {
        releaseFailure = nil
        do {
            try await coordinator.releaseOthers(context: context) { await entitlements.refresh() }
        } catch {
            releaseFailure = (error as? URLError)?.code == .notConnectedToInternet
                ? "Didn't go through. You're offline."
                : "Didn't go through. Tap it again."
        }
    }

    /// Nothing to list. The first run gets the screen's words; a filter with
    /// nothing in it gets one line, because it is usually good news.
    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .all:
            if assignments.isEmpty {
                EmptyState(title: "Your week is open",
                           message: "Add the first thing that's due. Albus breaks it into steps and finds time for them before the deadline.",
                           actionTitle: "Add an assignment") { addTask() }
            } else {
                EmptyState(title: "All caught up",
                           message: "Nothing open right now. Add the next thing when it comes in.",
                           actionTitle: "Add an assignment") { addTask() }
            }
        case .dueSoon:
            EmptyLine(title: "Nothing due in the next 7 days", isGoodNews: true,
                      actionTitle: showAllTitle, action: showAll)
        case .overdue:
            EmptyLine(title: "Nothing's overdue",
                      message: openHere == 0 ? nil
                        : "Your \(openHere) open \(openHere == 1 ? "assignment is" : "assignments are") on time.",
                      isGoodNews: true, actionTitle: showAllTitle, action: showAll)
        case .needsTime:
            let empty = Self.needsTimeEmpty(lastRunSucceeded: coordinator.lastRunSucceeded)
            if empty.isKnown {
                EmptyLine(title: empty.title, message: empty.message,
                          isGoodNews: true, actionTitle: showAllTitle, action: showAll)
            } else {
                EmptyLine(title: empty.title, message: empty.message, actionTitle: "Rebuild now") {
                    coordinator.reschedule(context: context, availability: preferences.availability)
                }
            }
        case .done:
            EmptyLine(title: "Finished assignments land here")
        }
    }

    /// What an empty "Needs time" list says. An empty list proves nothing
    /// when the last re-flow failed — `weekFit` is nil then, not empty — so
    /// it must not say everything fits.
    static func needsTimeEmpty(lastRunSucceeded: Bool) -> (title: String, message: String, isKnown: Bool) {
        lastRunSucceeded
            ? ("Everything fits", "All work due in the next 7 days has time in your plan.", true)
            : ("Albus can't tell yet", "Your week didn't update, so what fits isn't known.", false)
    }

    private var showAllTitle: String? { openHere > 0 ? "Show all" : nil }
    private func showAll() { filter = .all }
}

/// One assignment in the list.
///
/// No completion toggle. Ticking a whole assignment off from a list is how a
/// student banks six steps they did not do, and it is the same shortcut that
/// made the duration estimates worthless. Completion belongs where the steps
/// are visible.
private struct AssignmentCard: View {
    let assignment: Assignment
    let now: Date
    /// The phone's plan is in place and the AI is still writing the steps, so
    /// the step count is about to change: its shape, not a number.
    var isRefining = false
    /// Why the phone planned this rather than the AI, while that is news.
    var localPlan: PlanCoordinator.LocalPlanReason?
    var seePlus: () -> Void = {}

    private var subject: Tokens.SubjectColor {
        assignment.course?.subjectColor ?? .violet
    }

    var body: some View {
        SubjectStripeCard(subject: subject, padding: Tokens.Spacing.m + 2) {
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.m + 2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.s) {
                        CourseTag(code: assignment.course?.displayName ?? "General",
                                  kind: assignment.taskType, subject: subject)
                        if assignment.priorityValue == .high, !assignment.isComplete, !assignment.isArchived {
                            PriorityFlag()
                        }
                    }

                    Text(assignment.title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .strikethrough(assignment.isComplete)
                        .opacity(assignment.isComplete || assignment.isArchived ? 0.55 : 1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if isRefining {
                        HStack(spacing: Tokens.Spacing.s + 2) {
                            SkeletonBar(height: 6, cornerRadius: 3)
                            SkeletonBar(width: 28, height: 10)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                        .skeleton(label: "Albus is writing the steps")
                    } else if assignment.subtasks.isEmpty {
                        Text("No plan yet")
                            .font(Tokens.Typography.micro)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    } else {
                        HStack(spacing: Tokens.Spacing.s + 2) {
                            ProgressBar(fraction: assignment.progress, tint: subject.color)
                            Text("\(assignment.subtasks.count(where: { $0.completedAt != nil }))/\(assignment.subtasks.count)")
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                                .frame(minWidth: 34, alignment: .trailing)
                        }
                    }

                    HStack(spacing: Tokens.Spacing.s) {
                        // A record of work, not work due: no deadline to chase.
                        if assignment.isArchived {
                            Text("Not in your plan")
                                .font(Tokens.Typography.micro)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                        } else {
                            DeadlineLabel(deadline: assignment.deadline, now: now)
                        }
                        if assignment.rubric != nil {
                            MetaDot()
                            Label("Rubric", systemImage: "list.bullet.rectangle.portrait")
                                .labelStyle(.titleAndIcon)
                                .font(Tokens.Typography.micro)
                                .foregroundStyle(Tokens.Palette.inkMuted)
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            // Said on this card, not in a strip over all of Home: it is about
            // this assignment, and only while it is still being planned.
            if let localPlan, !isRefining, !assignment.isComplete, !assignment.isArchived {
                Divider()
                    .overlay(Tokens.Palette.hairline)
                    .padding(.top, Tokens.Spacing.m)
                localPlanLine(localPlan)
                    .padding(.top, Tokens.Spacing.xs)
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assignment.title)
        .accessibilityHint("Opens the plan")
    }
}

extension AssignmentCard {
    @ViewBuilder fileprivate func localPlanLine(_ reason: PlanCoordinator.LocalPlanReason) -> some View {
        let count = assignment.subtasks.count
        let sessions = "\(count) study \(count == 1 ? "session" : "sessions")"
        switch reason {
        case .offline:
            QuietLine(text: "Planned on this phone while you were offline, as \(sessions).",
                      systemImage: "wifi.slash")
        case .aiOff:
            QuietLine(text: "AI is off, so Albus split this into \(sessions). You can turn it on in Settings.")
        case .aiPlansUsed:
            QuietLine(text: "This week's AI plans are used, so Albus split it into \(sessions).",
                      linkTitle: "See Plus", link: seePlus)
        case .aiPlansNotIncluded:
            QuietLine(text: "Split into \(sessions). Step-by-step plans come with Plus.",
                      linkTitle: "See Plus", link: seePlus)
        case .unavailable:
            QuietLine(text: "Albus couldn't write steps just now, so it split this into \(sessions).")
        }
    }
}

private struct PriorityFlag: View {
    var body: some View {
        Label("High", systemImage: "exclamationmark")
            .labelStyle(.titleAndIcon)
            .font(Tokens.Typography.micro)
            .foregroundStyle(Tokens.Tint.orange.foreground)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, 2)
            .background(Tokens.Tint.orange.background,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.chip, style: .continuous))
    }
}
