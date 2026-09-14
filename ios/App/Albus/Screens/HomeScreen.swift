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

    @State private var filter: Filter = .all
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
                                                    taskLimit: entitlements.plan.tasks.limit)
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
                "\($0.title) — its plan, scheduled time and any marking go with it. This cannot be undone."
            } ?? "")
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
                status
                freeLimitNotice

                if let next = upNext(now: now) {
                    UpNextCard(record: next, now: now) { focusing = next }
                }

                WeekStrip(sessions: sessions, now: now) { destination = .month }

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
                                        AssignmentCard(assignment: assignment, now: now)
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
        if assignment.isComplete { return .done }
        let cal = Calendar.current
        if assignment.deadline < now { return .overdue }
        if cal.isDateInToday(assignment.deadline) { return .today }
        if let week = cal.date(byAdding: .day, value: 7, to: now),
           assignment.deadline <= week { return .thisWeek }
        return .later
    }

    private func matches(_ assignment: Assignment, now: Date, needsTimeIDs: Set<UUID>) -> Bool {
        switch filter {
        case .all: !assignment.isComplete
        case .dueSoon: !assignment.isComplete
            && assignment.deadline >= now
            && assignment.deadline <= (Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now)
        case .overdue: !assignment.isComplete && assignment.deadline < now
        case .needsTime:
            !assignment.isComplete && needsTimeIDs.contains(assignment.id)
        case .done: assignment.isComplete
        }
    }

    private func weekFit(now: Date) -> WeekFit? {
        guard coordinator.lastRunSucceeded else { return nil }
        return WeekFit(unplaceable: coordinator.unplacedItems,
                       workload: coordinator.workload, now: now)
    }

    private func weekFitNotice(_ fit: WeekFit) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                AlbusCactus(size: 28, mood: .init(fit.workload))
                Text("Some work still needs time")
                    .font(Tokens.Typography.cardTitle)
            }
            Text("Next 7 days and overdue: \(fit.items.count) \(fit.items.count == 1 ? "step" : "steps") across \(fit.assignmentIDs.count) \(fit.assignmentIDs.count == 1 ? "assignment" : "assignments") could not be scheduled by their deadlines (\(fit.minutesNeedingTime) min).")
                .font(Tokens.Typography.body)
            Text("Review the affected work. You can split a long step into smaller sittings, revise an estimate, or discuss a deadline with your teacher.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
            Button("Review affected work") { filter = .needsTime }
                .font(Tokens.Typography.label)
                .foregroundStyle(Tokens.Palette.accent)
        }
        .foregroundStyle(Tokens.Palette.ink)
        .padding(Tokens.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .accessibilityIdentifier("weekFitNotice")
    }

    /// The block happening now, or the next one due. Nil once everything is done.
    private func upNext(now: Date) -> PlanSessionRecord? {
        let live = sessions.filter { $0.subtask?.completedAt == nil }
        return live.first { $0.startsAt <= now && $0.endsAt > now }
            ?? live.first { $0.startsAt > now }
    }

    // MARK: - Header

    private func header(now: Date) -> some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(Tokens.Typography.overline)
                    .tracking(Tokens.Tracking.dateline)
                    .textCase(.uppercase)
                    .foregroundStyle(Tokens.Palette.inkMuted)

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
            }

            Spacer(minLength: 0)

            VStack(spacing: Tokens.Spacing.s) {
                // Not a fifth tab: `AppShell` documents why a tab was removed
                // for redundancy, and adding one back for settings would argue
                // against reasoning that is already written down.
                Button { destination = .notificationSettings } label: {
                    AlbusCactus(size: 36, mood: .init(coordinator.workload))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Notification settings")

                IconButton(systemImage: "plus", isFilled: true,
                           accessibilityLabel: "Add assignment") { addingTask = true }
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

    @ViewBuilder private var status: some View {
        if coordinator.status == .planning {
            StatusBanner(tone: .working, message: "Albus is planning…")
        }
        if case .plannedLocally(let note, let suggestsUpgrade) = coordinator.status {
            StatusBanner(tone: .working, message: note,
                         retryTitle: suggestsUpgrade ? "See Plus" : nil,
                         retry: suggestsUpgrade ? { showingPaywall = true } : nil)
        }
        if case .failed(let message) = coordinator.status {
            StatusBanner(tone: .error, message: message)
        }
        if case .failed(let why) = session.state {
            StatusBanner(tone: .warning, message: "Not signed in: \(why)")
        }
    }

    /// How full the plan is. Guidance only — a trigger on `public.assignments`
    /// enforces it on every write path (migration 0036), so this being wrong
    /// costs a clearer message, never a bypassed limit.
    ///
    /// The number comes from the server's plan rather than a constant here.
    /// Three tiers means three caps, and a literal in this file is a literal
    /// that will eventually disagree with the one the database enforces.
    @ViewBuilder private var freeLimitNotice: some View {
        let tasks = entitlements.plan.tasks
        if let limit = tasks.limit, limit > 0,
           assignments.count(where: { !$0.isComplete }) >= limit {
            StatusBanner(
                tone: .warning,
                message: "\(entitlements.plan.displayName) keeps \(limit) "
                       + "\(limit == 1 ? "task" : "tasks") open at once. "
                       + "Finish one, or move up a plan.",
                retryTitle: "See plans") { showingPaywall = true }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch filter {
        case .all:
            EmptyState(icon: "tray", title: assignments.isEmpty ? "Nothing here yet" : "No open work",
                       message: assignments.isEmpty
                         ? "Add an assignment and Albus will break it into steps and find time for them."
                         : "Everything you have added is finished. Add the next thing when you're ready.",
                       actionTitle: "Add an assignment") { addingTask = true }
        case .dueSoon:
            EmptyState(icon: "calendar", title: "Nothing due this week",
                       message: "Your next deadline is further out. A good week to get ahead.")
        case .overdue:
            EmptyState(icon: "checkmark.circle", title: "Nothing overdue",
                       message: "You're on top of every deadline.")
        case .needsTime:
            EmptyState(icon: "calendar", title: "No work to review",
                       message: "Unplaced work due in the next seven days or already overdue appears here after your plan is rebuilt.")
        case .done:
            EmptyState(icon: "checkmark.seal", title: "Nothing finished yet",
                       message: "Completed assignments collect here.")
        }
    }
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

    private var subject: Tokens.SubjectColor {
        assignment.course?.subjectColor ?? .violet
    }

    var body: some View {
        SubjectStripeCard(subject: subject, padding: Tokens.Spacing.m + 2) {
            HStack(spacing: Tokens.Spacing.m + 2) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                    HStack(spacing: Tokens.Spacing.s) {
                        CourseTag(code: assignment.course?.displayName ?? "General",
                                  kind: assignment.taskType, subject: subject)
                        if assignment.priorityValue == .high, !assignment.isComplete {
                            PriorityFlag()
                        }
                    }

                    Text(assignment.title)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .strikethrough(assignment.isComplete)
                        .opacity(assignment.isComplete ? 0.55 : 1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if assignment.subtasks.isEmpty {
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
                        DeadlineLabel(deadline: assignment.deadline, now: now)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(assignment.title)
        .accessibilityHint("Opens the plan")
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
