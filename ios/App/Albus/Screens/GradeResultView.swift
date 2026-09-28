import SwiftUI
import SwiftData
import AlbusCore

/// What came back from a marking.
///
/// Used in three places — straight after a grading, reopened from history, and
/// reopened from the assignment it belongs to — so it takes a `Grading` and
/// owns no flow of its own.
///
/// **The order of this screen is the argument it makes.** What the marks were
/// based on comes first, the grade second, what to change third, and the
/// criteria last. A student who reads only the top of the screen should not be
/// able to come away with a number whose basis they never saw.
struct GradeResultView: View {
    let grading: Grading

    /// Drives the one animation on this screen. A grade is the sentence the
    /// student came for, and letting it settle in rather than appear fully
    /// formed is the difference between a result and a readout.
    @State private var revealed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                basisBanner
                headline
                improvements

                if !grading.feedback.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        SectionHeader(grading.basis == .blind ? "Albus's read" : "Overall")
                        Text(grading.feedback)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.ink)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !grading.criteria.isEmpty {
                    SectionHeader(grading.basis == .blind ? "What stood out" : "Against the rubric",
                                  count: grading.criteria.count)
                    VStack(spacing: Tokens.Spacing.s) {
                        ForEach(grading.criteria) { criterion in
                            CriterionCard(criterion: criterion)
                        }
                    }
                }

                Text("Marked by \(grading.model) · about \(grading.approximateWords) words")
                    .font(Tokens.Typography.micro)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
            .padding(Tokens.Spacing.xl)
        }
        .background(BackgroundGradient())
        .task {
            // Guarded so reopening a grading from history does not replay the
            // reveal every time the view is reconstructed by a scroll.
            guard !revealed else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { revealed = true }
        }
    }

    /// What this was marked against, said before anything that looks like a mark.
    ///
    /// **The blind case is the reason this is the first thing on the screen.** A
    /// reading with no rubric behind it must never be mistaken for a grade, and
    /// a disclaimer underneath a big number is a disclaimer nobody reads.
    @ViewBuilder private var basisBanner: some View {
        switch grading.basis {
        case .blind:
            HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                AlbusCactus(size: 34, mood: .cooked)
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Text("Albus is grading blindly")
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text("There was no rubric for this, so Albus can only say what "
                         + "it thinks is strong or weak on its own reading. It has "
                         + "not awarded marks, and this may not reflect your real grade.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Tokens.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(alignment: .leading) {
                Rectangle().fill(Tokens.SubjectColor.amber.color).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }

        case .personal, .curriculum:
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Tokens.SubjectColor.green.color)
                Text(grading.basis == .personal
                     ? "Graded against your rubric"
                     : "Graded against your course's marking criteria")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
    }

    // MARK: - The grade

    /// The one number the student came for.
    ///
    /// This screen used to show `overall_marks / total_marks` and call it done,
    /// which is why it read as feedback with no grade attached: an MYP rubric
    /// totals 32, and "0/32" is arithmetic. The grade is what a teacher writes
    /// at the top — a 1, an F, 62% — and it only exists because the student is
    /// asked which scale their course uses before anything is marked.
    @ViewBuilder private var headline: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                if let headline = grading.headline {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                        Text(headline)
                            .font(Tokens.Typography.displayLarge)
                            .foregroundStyle(Tokens.Palette.ink)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                            .contentTransition(.numericText())

                        // The raw marks, but only when they are not already the
                        // headline — "36/100" printed twice helps nobody.
                        if grading.headlineIsGrade, let score = grading.scoreText {
                            Text(score)
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                        }
                    }
                    .scaleEffect(revealed ? 1 : 0.86, anchor: .leading)
                    .opacity(revealed ? 1 : 0)

                    if let fraction = grading.fraction {
                        ProgressBar(fraction: revealed ? fraction : 0,
                                    tint: Tokens.Palette.accent, height: 6)
                            .animation(.spring(response: 0.9, dampingFraction: 0.9)
                                .delay(0.15), value: revealed)
                    }

                    if let note = grading.gradeNote, !note.isEmpty {
                        Text(note)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if grading.basis == .blind {
                    // Never a headline here, and never the "no marks" copy
                    // below — that line says "this rubric", and a blind reading
                    // has no rubric to speak of.
                    Text("A read, not a grade")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text("Add the rubric this is marked against and Albus can give "
                         + "you the actual grade.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // A rubric that carries no marks is a real case, and
                    // rendering it as "0" would be a lie about the work.
                    Text("Marked")
                        .font(Tokens.Typography.title)
                        .foregroundStyle(Tokens.Palette.ink)
                    Text("This rubric doesn't carry marks, so Albus commented instead of scoring.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var improvements: some View {
        if !grading.improvements.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader("What to change", count: grading.improvements.count)
                ForEach(Array(grading.improvements.enumerated()), id: \.offset) { index, move in
                    HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                        Text("\(index + 1)")
                            .font(Tokens.Typography.caption).fontWeight(.bold)
                            .foregroundStyle(Tokens.Palette.accent)
                            .frame(width: 22, height: 22)
                            .background(Tokens.Palette.accentWash, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(move.change)
                                .font(Tokens.Typography.cardTitle)
                                .foregroundStyle(Tokens.Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !move.why.isEmpty {
                                Text(move.why)
                                    .font(Tokens.Typography.caption)
                                    .foregroundStyle(Tokens.Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct CriterionCard: View {
        let criterion: GradedCriterion

        var body: some View {
            GlassCard(padding: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(criterion.displayName)
                            .font(Tokens.Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        if let score = criterion.scoreText {
                            Text(score)
                                .font(Tokens.Typography.mono)
                                .foregroundStyle(Tokens.Palette.accent)
                        }
                    }
                    if !criterion.comment.isEmpty {
                        Text(criterion.comment)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // The student's own sentence, next to the mark it earned or
                    // cost. A criticism beside the line it is about reads as
                    // marking; the same criticism alone reads as invented.
                    if let quote = criterion.quote, !quote.isEmpty {
                        HStack(alignment: .top, spacing: Tokens.Spacing.s) {
                            Rectangle()
                                .fill(Tokens.Palette.accent.opacity(0.5))
                                .frame(width: 2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quote)
                                    .font(Tokens.Typography.caption)
                                    .italic()
                                    .foregroundStyle(Tokens.Palette.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let source = criterion.whereFound, !source.isEmpty {
                                    Text(source)
                                        .font(Tokens.Typography.micro)
                                        .foregroundStyle(Tokens.Palette.inkMuted)
                                }
                            }
                        }
                        .padding(Tokens.Spacing.s)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.accentWash.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The shape of `GradeResultView` while the marking is written: the score, the
/// feedback, and a card for each criterion. Only the bars shine, not the cards.
struct GradeResultSkeleton: View {
    /// Criterion cards to sketch. The real number arrives with the result.
    var criteria = 3

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            GlassCard {
                HStack(alignment: .center, spacing: Tokens.Spacing.m) {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                        SkeletonBar(width: 110, height: 16, cornerRadius: 6)
                        SkeletonBar(width: 170, height: 10)
                    }
                    Spacer(minLength: 0)
                    SkeletonBar(width: 64, height: 30, cornerRadius: 8)
                }
                .skeleton()
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SkeletonBar()
                SkeletonBar(fraction: 0.94)
                SkeletonBar(fraction: 0.62)
            }
            .skeleton()

            VStack(spacing: Tokens.Spacing.s) {
                ForEach(0..<criteria, id: \.self) { _ in
                    GlassCard(padding: Tokens.Spacing.m) {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                            HStack(spacing: Tokens.Spacing.m) {
                                SkeletonBar(width: 120, height: 12)
                                Spacer(minLength: 0)
                                SkeletonBar(width: 36, height: 12)
                            }
                            SkeletonBar(height: 9)
                            SkeletonBar(fraction: 0.7, height: 9)
                        }
                        .skeleton()
                    }
                }
            }
        }
        // One element for VoiceOver, not a dozen empty shapes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your feedback will appear here")
    }
}
