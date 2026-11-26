import SwiftUI
import SwiftData
import AlbusCore

/// Everything Albus has marked, newest first.
///
/// Gradings were being written and then losing their only way back: a result
/// lived until the student left the screen, and reopening one was possible only
/// from the assignment it belonged to — which loose work, uploads and photos do
/// not have. Marking a draft and marking the revision is *the* use case the
/// weekly allowance was sized around, and comparing the two was impossible.
///
/// Reads the local store rather than the server. That is the existing shape for
/// gradings — they are written locally the moment one comes back — and it means
/// history opens instantly and works on a train.
struct GradingHistoryScreen: View {
    @Query(sort: \Grading.createdAt, order: .reverse) private var gradings: [Grading]

    /// What the student is looking at now. `Grading` is a `@Model`, so this is
    /// a reference into the store rather than a copy of the result.
    @State private var opened: Grading?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                if gradings.isEmpty {
                    EmptyState(
                        title: "Nothing marked yet",
                        message: "Your saved markings on this phone appear here, so you can put a "
                               + "draft next to the version you fixed."
                    )
                } else {
                    ForEach(sections, id: \.0) { title, items in
                        SectionHeader(title, count: items.count)
                            .padding(.top, Tokens.Spacing.xs)
                        ForEach(items) { grading in
                            Button { opened = grading } label: { row(grading) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Marked work")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $opened) { GradeResultView(grading: $0) }
    }

    /// Grouped by how a student remembers time, not by calendar month. Five
    /// gradings in a week is the whole free allowance, so "Earlier" is where
    /// almost everything ends up and the recent ones stay findable.
    private var sections: [(String, [Grading])] {
        let calendar = Calendar.current
        var today: [Grading] = []
        var week: [Grading] = []
        var earlier: [Grading] = []

        for grading in gradings {
            if calendar.isDateInToday(grading.createdAt) {
                today.append(grading)
            } else if let cutoff = calendar.date(byAdding: .day, value: -7, to: .now),
                      grading.createdAt > cutoff {
                week.append(grading)
            } else {
                earlier.append(grading)
            }
        }

        return [("Today", today), ("This week", week), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
    }

    private func row(_ grading: Grading) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            gradeBadge(grading)

            VStack(alignment: .leading, spacing: 2) {
                Text(grading.displayTitle)
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1)
                Text(subtitle(grading))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Tokens.Spacing.s)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    /// The grade, at a glance.
    ///
    /// A blind reading gets the cactus rather than a number — the same rule the
    /// result screen follows, and for the same reason: anything in this slot
    /// that looks like a mark will be read as one.
    @ViewBuilder private func gradeBadge(_ grading: Grading) -> some View {
        if let headline = grading.headline {
            Text(headline)
                .font(Tokens.Typography.cardTitle)
                .fontWeight(.bold)
                .foregroundStyle(Tokens.Palette.accent)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Spacing.xs)
                .frame(width: 52, height: 44)
                .background(Tokens.Palette.accentWash,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
        } else {
            AlbusCactus(size: 40, mood: grading.basis == .blind ? .cooked : .calm)
                .frame(width: 52, height: 44)
        }
    }

    private func subtitle(_ grading: Grading) -> String {
        let when = grading.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch grading.basis {
        case .blind:      return "A read, no rubric · \(when)"
        case .personal:   return "Your rubric · \(when)"
        case .curriculum: return "Course criteria · \(when)"
        }
    }
}
