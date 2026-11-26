import SwiftUI
import SwiftData
import AlbusCore

/// The rubric library: save the sheet your teacher handed out once, use it on
/// every assignment it applies to.
///
/// This is the "smoother flow" half of the add screen. Typing a rubric in while
/// creating an assignment is the reason nobody would do it twice; picking a
/// saved one from a list is the reason they would.
struct RubricsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(EntitlementService.self) private var entitlements

    @Query(sort: \Rubric.updatedAt, order: .reverse) private var rubrics: [Rubric]

    @State private var editing: RubricDraft?
    @State private var deleting: Rubric?
    @State private var syncFailure: String?
    /// Set when a new rubric was asked for with the plan's rubrics used up.
    @State private var rubricLimitReached: Int?
    @State private var showingPaywall = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                header

                if let syncFailure {
                    ProblemLine(message: syncFailure)
                }

                if rubrics.isEmpty {
                    EmptyState(
                        title: "No rubrics yet",
                        message: "Paste the marking criteria from an assignment sheet. "
                               + "Albus can use it to shape your plan. Plus and Pro can estimate a mark for your "
                               + "work against it.",
                        actionTitle: "Add a rubric"
                    ) { addRubric() }
                } else {
                    ForEach(rubrics) { rubric in
                        Button { editing = RubricDraft(rubric) } label: {
                            RubricCard(rubric: rubric)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Duplicate") { duplicate(rubric) }
                            Button("Delete", role: .destructive) { deleting = rubric }
                        }
                    }
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { draft in
            RubricEditorSheet(draft: draft) { saved in
                commit(saved)
            }
        }
        .rubricLimitDialog($rubricLimitReached, planName: entitlements.plan.displayName) {
            showingPaywall = true
        }
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .confirmationDialog(
            deleting.map { "Delete \($0.name)?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let deleting { remove(deleting) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Deleting a rubric must never delete the student's work. The model
            // relationship nullifies rather than cascades; this says so.
            Text(deleting.map(deleteWarning) ?? "")
        }
    }

    private func deleteWarning(_ rubric: Rubric) -> String {
        let used = rubric.assignments.count
        guard used > 0 else { return "This can't be undone." }
        return used == 1
            ? "One assignment uses this rubric. The assignment is kept — it no longer has this rubric attached."
            : "\(used) assignments use this rubric. They're kept — they no longer have this rubric attached."
    }

    /// The title and nothing above it, like every other tab. With no rubrics
    /// saved the line under it goes too: the empty state below already says
    /// what a rubric is for, at more length and in the right place.
    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rubrics")
                    .font(Tokens.Typography.displayLarge)
                    .tracking(Tokens.Tracking.display)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                IconButton(systemImage: "plus", isFilled: true,
                           accessibilityLabel: "Add a rubric") { addRubric() }
            }

            if !rubrics.isEmpty {
                Text("\(rubrics.count) saved. Pick one when you add an assignment.")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
        }
        .padding(.top, Tokens.Spacing.s)
    }

    // MARK: - Writes
    //
    // All of it lives in RubricWriter, because the add-assignment sheet creates
    // rubrics too and the two paths have to produce the same thing.

    private func commit(_ draft: RubricDraft) {
        RubricWriter.commit(draft, context: context) { syncFailure = $0 }
    }

    /// Runs `start` when the plan has room for one more rubric. When it has
    /// not, the plan says so now, instead of the server after the rubric is
    /// written.
    private func whenRoomForRubric(_ start: () -> Void) {
        if let limit = entitlements.rubricLimit(reachedBy: rubrics.count) {
            rubricLimitReached = limit
        } else {
            start()
        }
    }

    private func addRubric() {
        whenRoomForRubric { editing = .empty }
    }

    /// A copy is a new rubric, and counts against the plan like one.
    private func duplicate(_ rubric: Rubric) {
        whenRoomForRubric {
            RubricWriter.duplicate(rubric, context: context) { syncFailure = $0 }
        }
    }

    private func remove(_ rubric: Rubric) {
        RubricWriter.delete(rubric, context: context, onFailure: { syncFailure = $0 })
        deleting = nil
    }
}

private struct RubricCard: View {
    let rubric: Rubric

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                HStack(alignment: .top) {
                    Text(rubric.name)
                        .font(Tokens.Typography.cardTitle)
                        .foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: Tokens.Spacing.s)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Tokens.Palette.inkMuted)
                }

                HStack(spacing: Tokens.Spacing.xs) {
                    Text(rubric.summary)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                    if !rubric.assignments.isEmpty {
                        MetaDot()
                        Text(rubric.assignments.count == 1
                             ? "1 assignment" : "\(rubric.assignments.count) assignments")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                }

                if !rubric.sortedItems.isEmpty {
                    Text(rubric.sortedItems.map(\.displayName).joined(separator: " · "))
                        .font(Tokens.Typography.micro)
                        .foregroundStyle(Tokens.Palette.inkMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
