import SwiftUI
import SwiftData
import AlbusCore

/// The month at a glance, pushed from Today.
///
/// Not a fifth tab: the design's own export shows the four-tab bar with Today
/// active behind it, so this is a pushed screen reached from "Month view ›".
struct MonthCalendarScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlanCoordinator.self) private var coordinator

    @Query(sort: \PlanSessionRecord.startsAt) private var sessions: [PlanSessionRecord]

    @State private var month: Date = .now
    @State private var selectedDay: Date?

    private let calendar = Calendar.current

    /// Sessions bucketed by day once per render rather than filtered per cell —
    /// a 42-cell grid filtering the whole array each time is 42 full scans.
    private var byDay: [Date: [PlanSessionRecord]] {
        Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startsAt) }
    }

    /// Six weeks from the Sunday on or before the 1st: a fixed grid, so the
    /// screen does not change height between months.
    private var gridDays: [Date] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let week = calendar.dateInterval(of: .weekOfYear, for: first)
        else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                monthHeader
                weekdayHeader
                grid
                summary
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .sheet(item: Binding(
            get: { selectedDay.map(DayKey.init) },
            set: { selectedDay = $0?.date }
        )) { key in
            DaySheet(day: key.date, sessions: byDay[calendar.startOfDay(for: key.date)] ?? [])
        }
    }

    /// `sheet(item:)` needs Identifiable; a bare Date is not.
    private struct DayKey: Identifiable {
        let date: Date
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    private var monthHeader: some View {
        HStack {
            // "September 2026" needs no "MONTH" over it to say what it is.
            Text(month, format: .dateTime.month(.wide).year())
                .font(Tokens.Typography.displayLarge)
                .foregroundStyle(Tokens.Palette.ink)
            Spacer()
            HStack(spacing: Tokens.Spacing.s) {
                IconButton(systemImage: "chevron.left", accessibilityLabel: "Previous month") {
                    shift(by: -1)
                }
                IconButton(systemImage: "chevron.right", accessibilityLabel: "Next month") {
                    shift(by: 1)
                }
            }
        }
        .padding(.top, Tokens.Spacing.s)
    }

    private func shift(by months: Int) {
        withAnimation(Tokens.Motion.quick) {
            month = calendar.date(byAdding: .month, value: months, to: month) ?? month
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ForEach(calendar.shortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol.prefix(1).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Tokens.Palette.inkMuted)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.xs),
                                 count: 7),
                  spacing: Tokens.Spacing.xs) {
            ForEach(gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                    isToday: calendar.isDateInToday(day),
                    sessions: byDay[calendar.startOfDay(for: day)] ?? []
                ) { selectedDay = day }
            }
        }
    }

    private var summary: some View {
        GlassCard {
            AlbusNote(summaryText)
        }
    }

    private var summaryText: String {
        let inMonth = sessions.filter {
            calendar.isDate($0.startsAt, equalTo: month, toGranularity: .month)
        }
        guard !inMonth.isEmpty else {
            return "Nothing scheduled this month yet. Add an assignment and I'll fill it in."
        }
        let busiest = Dictionary(grouping: inMonth) { calendar.startOfDay(for: $0.startsAt) }
            .max { $0.value.count < $1.value.count }
        let hours = inMonth.reduce(0) { $0 + $1.endsAt.timeIntervalSince($1.startsAt) } / 3600

        var text = "**\(inMonth.count) sessions** planned, about \(Int(hours.rounded())) hours."
        if let busiest, busiest.value.count > 2 {
            text += " \(busiest.key.formatted(.dateTime.month().day())) is the heaviest day — start earlier if you can."
        }
        return text
    }

    private struct DayCell: View {
        let day: Date
        let inMonth: Bool
        let isToday: Bool
        let sessions: [PlanSessionRecord]
        let onTap: () -> Void

        /// One dot per subject present, not per session: five dots on one day
        /// is noise, "history and stats" is information.
        private var subjects: [Tokens.SubjectColor] {
            var seen: [Tokens.SubjectColor] = []
            for session in sessions {
                let subject = session.subtask?.assignment?.course?.subjectColor ?? .violet
                if !seen.contains(subject) { seen.append(subject) }
            }
            return Array(seen.prefix(3))
        }

        var body: some View {
            Button(action: onTap) {
                VStack(spacing: Tokens.Spacing.xs) {
                    Text(day, format: .dateTime.day())
                        .font(Tokens.Typography.label)
                        .foregroundStyle(isToday ? .white
                                         : inMonth ? Tokens.Palette.ink : Tokens.Palette.inkMuted.opacity(0.5))
                    HStack(spacing: 2) {
                        ForEach(Array(subjects.enumerated()), id: \.offset) { _, subject in
                            Circle().fill(subject.color).frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Tokens.Spacing.s)
                .background {
                    if isToday {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tokens.Palette.accent)
                    } else if !sessions.isEmpty {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Tokens.Glass.fill)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(sessions.isEmpty && !inMonth)
            .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
            .accessibilityValue(sessions.isEmpty ? "Nothing scheduled"
                                : "\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
        }
    }
}

/// What is on one day, opened from the month grid.
private struct DaySheet: View {
    @Environment(\.dismiss) private var dismiss
    let day: Date
    let sessions: [PlanSessionRecord]

    var body: some View {
        NavigationStack {
            Screen {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                        if sessions.isEmpty {
                            EmptyState(icon: "sun.max", title: "Nothing scheduled",
                                       message: "This day is clear.")
                        } else {
                            ForEach(sessions.sorted { $0.startsAt < $1.startsAt }) { session in
                                DayRow(session: session)
                            }
                        }
                    }
                    .padding(Tokens.Spacing.xl)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Tokens.Palette.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private struct DayRow: View {
        let session: PlanSessionRecord
        @Environment(PlanCoordinator.self) private var coordinator

        private var subject: Tokens.SubjectColor {
            session.subtask?.assignment?.course?.subjectColor ?? .violet
        }

        var body: some View {
            SubjectStripeCard(subject: subject, padding: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("\(session.startsAt, format: .dateTime.hour().minute()) – \(session.endsAt, format: .dateTime.hour().minute())")
                        .font(Tokens.Typography.mono)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                    if coordinator.isRefining(session.subtask?.assignment) {
                        // The time is placed; the step's name is still being written.
                        SkeletonBar(width: 150, height: 14)
                            .frame(height: 20, alignment: .leading)
                            .skeleton(label: "Albus is writing this step")
                    } else {
                        Text(session.subtask?.title ?? "Study session")
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                            .strikethrough(session.subtask?.completedAt != nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let assignment = session.subtask?.assignment {
                        Text(assignment.title)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }
            }
        }
    }
}
