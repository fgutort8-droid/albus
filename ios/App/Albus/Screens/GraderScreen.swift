import SwiftUI
import SwiftData
import PhotosUI
import AlbusCore

/// Albus Grader — the first-party tool.
///
/// Four questions, in the order a student can answer them:
///   1. What am I marking?      — an assignment, a file, photos, or pasted text
///   2. What against?           — a saved rubric, one you upload, or nothing
///   3. How do you want it?     — the scale their course actually uses
///   4. …then mark it.
///
/// **Step 2 and 3 are what make a real grade possible.** Albus has no way to
/// know whether a course marks out of 100, in IB 1–7, or in letter bands — so
/// rather than inventing a scale, the student says. And rather than refusing to
/// mark work with no rubric on file, they can hand one over, or accept a blind
/// reading that is clearly labelled as not a grade.
struct GraderScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(AccountDeletion.self) private var accountDeletion
    @Environment(\.dismiss) private var dismiss

    /// Opened from an assignment rather than from Tools.
    ///
    /// There were two graders until this existed: this screen, and a `Form`
    /// sheet on the task detail page that could not upload, could not
    /// photograph a rubric and never asked how the student's course marks — so
    /// the same button meant two different products depending on where it was
    /// pressed. One flow, entered from either place.
    var assignment: Assignment?

    @Query(sort: \Assignment.deadline) private var assignments: [Assignment]
    @Query(sort: \Rubric.updatedAt, order: .reverse) private var rubrics: [Rubric]
    @Query(sort: \Grading.createdAt, order: .reverse) private var gradings: [Grading]

    /// Where the student is in the flow. One value, so back always means back.
    private enum Stage: Equatable {
        case start, work, rubric, presentation, marking, result
    }

    @State private var stage: Stage = .start
    /// The grader's allowance comes from the one call that answers for the
    /// whole app, not from a grader-specific meter. `grading_allowance()` used
    /// to be that meter and it reported only this feature — which is how it
    /// ended up counting differently from the gate that refuses.
    @Environment(EntitlementService.self) private var entitlements

    // What is being marked.
    @State private var chosenAssignment: Assignment?
    @State private var work = ""
    @State private var sourceLabel: String?
    @State private var importing = false
    @State private var photo: PhotosPickerItem?
    @State private var workPhotoPicking = false
    @State private var extracting = false
    @State private var extractionFailure: String?

    // What it is marked against.
    @State private var chosenRubric: Rubric?
    @State private var acceptedBlind = false
    @State private var editingRubric: RubricDraft?
    @State private var rubricPhotoPicking = false
    @State private var rubricPhoto: PhotosPickerItem?
    @State private var syncFailure: String?

    // How the student wants it back.
    @State private var presentation = ""

    @State private var failure: GradingService.Failure?
    @State private var result: Grading?
    @State private var showingPaywall = false

    /// Which line the marking screen is on, and whether the cactus is breathing.
    @State private var beat = 0
    @State private var breathing = false

    private var wordCount: Int {
        work.split(whereSeparator: \.isWhitespace).count
    }

    /// What this grading will be called in history.
    ///
    /// The work itself is deliberately never stored, so without a label a list
    /// of past gradings is a column of identical dates. The assignment's title
    /// when there is one, otherwise where the text came from — a filename, a
    /// photo — and nothing at all for text pasted straight in, which the server
    /// then names for us.
    private var workTitle: String? {
        chosenAssignment?.title ?? sourceLabel
    }

    /// Blind is the absence of a rubric, however the student got here — they
    /// picked none, or the assignment they chose has none on file.
    private var isBlind: Bool {
        chosenRubric == nil && (chosenAssignment?.rubric == nil)
    }

    var body: some View {
        Group {
            // The result owns the whole screen.
            //
            // It has its own `ScrollView`, and putting that inside this one
            // gave a long grading two nested scrollers fighting each other —
            // the criteria list would scroll to its end and then the page
            // underneath would start moving. The flow's own footer rides above
            // it as a safe-area inset instead.
            if stage == .result, let result {
                GradeResultView(grading: result)
                    .safeAreaInset(edge: .bottom) { resultFooter }
            } else {
                flow
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Albus Grader")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Arriving from an assignment answers "what am I marking?" already,
            // so the flow starts at the next real question rather than showing
            // a chooser with one obvious answer pre-ticked.
            if let assignment, chosenAssignment == nil {
                choose(assignment)
                if stage == .start { stage = .work }
            }
            await entitlements.refresh()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: stage)
        .sheet(isPresented: $showingPaywall) { PaywallScreen() }
        .sheet(item: $editingRubric) { draft in
            RubricEditorSheet(draft: draft) { saved in
                RubricWriter.commit(saved, context: context) { syncFailure = $0 }
                // Select what was just written, so the student does not have to
                // find it in a list they were not looking at.
                chosenRubric = rubrics.first { $0.id == saved.id }
                acceptedBlind = false
            }
        }
        .photosPicker(isPresented: $workPhotoPicking, selection: $photo, matching: .images)
        .photosPicker(isPresented: $rubricPhotoPicking, selection: $rubricPhoto, matching: .images)
        .onChange(of: rubricPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let text = try? await WorkExtractor.text(from: .image(image))
                else {
                    syncFailure = "Albus couldn't read that rubric — try a clearer photo."
                    return
                }
                // Straight into the editor rather than saved silently: OCR of a
                // photographed handout is worth a glance before it becomes the
                // thing a grade is based on.
                var draft = RubricDraft.empty
                draft.body = String(text.prefix(Rubric.maxBodyCharacters))
                draft.name = "Photographed rubric"
                editingRubric = draft
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.pdf, .plainText, .rtf, .text],
                      allowsMultipleSelection: false) { outcome in
            guard case .success(let urls) = outcome, let url = urls.first else { return }
            extract(.file(url), label: url.lastPathComponent)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else { return }
                extract(.image(image), label: "Photo of your work")
            }
        }
    }

    /// Every stage that is a question rather than an answer.
    private var flow: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                switch stage {
                case .start:        startStage
                case .work:         workStage
                case .rubric:       rubricStage
                case .presentation: presentationStage
                case .marking:      markingStage
                case .result:       resultStage
                }
            }
            .padding(Tokens.Spacing.xl)
        }
    }

    // MARK: - 0 · Start

    @ViewBuilder private var startStage: some View {
        if entitlements.refreshFailed {
            EntitlementRefreshNotice()
        }

        card(rail: Tokens.Palette.accent) {
            // No model named here on purpose. Which model marks depends on
            // whether a rubric turns up, and nothing has been chosen yet — the
            // first version showed "Sonnet 5" on this screen because `isBlind`
            // is trivially true before the student has answered anything, which
            // both undersold it and was a claim made too early to be true.
            HStack {
                Text("A full grading")
                    .font(Tokens.Typography.overline).fontWeight(.bold)
                    .foregroundStyle(Tokens.Palette.accent)
                    .padding(.horizontal, Tokens.Spacing.s)
                    .padding(.vertical, 3)
                    .background(Tokens.Palette.accentWash, in: Capsule())
                Spacer()
                meter
            }
            Text("A grading reads every paragraph and marks it against your "
                 + "rubric, quoting your own sentences back to you.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            SectionHeader(label: "How it works") { EmptyView() }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                    Text("\(index + 1)")
                        .font(Tokens.Typography.caption).fontWeight(.bold)
                        .foregroundStyle(Tokens.Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(Tokens.Palette.accentWash, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.0).font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(step.1).font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        if grader.hasAny {
            PrimaryButton(title: "Grade a piece of work") { stage = .work }
        } else {
            blockedCard
        }

        historyLink
    }

    /// Everything marked before.
    ///
    /// Shown even when a student is out of gradings — that is precisely when
    /// they want to reread the one they have, and it is the only thing on the
    /// screen they can still do.
    @ViewBuilder private var historyLink: some View {
        if !gradings.isEmpty {
            NavigationLink {
                Screen { GradingHistoryScreen() }
            } label: {
                HStack(spacing: Tokens.Spacing.m) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(Tokens.Palette.accent)
                        .frame(width: 32, height: 32)
                        .background(Tokens.Palette.accentWash,
                                    in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Marked work")
                            .font(Tokens.Typography.cardTitle)
                            .foregroundStyle(Tokens.Palette.ink)
                        Text(gradings.count == 1
                             ? "1 grading, kept"
                             : "\(gradings.count) gradings, kept")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                    Spacer()
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
            }
            .buttonStyle(.plain)
        }
    }

    private var steps: [(String, String)] {
        [("Give me the work", "Pick a task, upload a file, photograph it, or paste it."),
         ("Say what marks it", "A rubric you've saved, or one you hand me now."),
         ("Tell me how you're marked", "Out of 100, IB 1–7, letters — whatever your course uses."),
         ("Get the marks back", "Where they went, quoted from your own writing.")]
    }

    // MARK: - 1 · The work

    @ViewBuilder private var workStage: some View {
        stageTitle("What am I marking?",
                   "Anything on your list brings its rubric and deadline with it.")

        // Arriving from an assignment answers this question before the student
        // sees the screen. Saying so is the difference between "already sorted"
        // and "my tap did nothing".
        if let chosen = chosenAssignment {
            AlbusNote("Marking **\(chosen.title)**. Pick another below to change it.")
        }

        if !markableAssignments.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader(label: "Your work") { EmptyView() }
                ForEach(markableAssignments) { assignment in
                    Button { choose(assignment) } label: {
                        assignmentRow(assignment)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or bring it in") { EmptyView() }
            importRow("Upload a file", "PDF or plain text", "arrow.up.doc") { importing = true }
            importRow("Take a photo", "Handwriting is fine", "camera") {
                workPhotoPicking = true
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or paste it") { EmptyView() }
            TextEditor(text: $work)
                .font(Tokens.Typography.body)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Spacing.m)
                .background(Tokens.Palette.cardSurface,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.card)
                        .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                }
        }

        if extracting {
            StatusBanner(tone: .working, message: "Reading it…")
        }
        if let extractionFailure {
            StatusBanner(tone: .warning, message: extractionFailure)
        }
        if let sourceLabel, !work.isEmpty {
            AlbusNote("Read **\(sourceLabel)** — \(wordCount) words.", isBusy: true)
        }

        PrimaryButton(title: "Continue", isEnabled: wordCount > 30) { stage = .rubric }
    }

    /// What the picker offers, and why it is not simply "active work".
    ///
    /// **Finished work stays markable for a month.** Filtering to `.active`
    /// dropped an assignment out of this list at the exact moment it became
    /// most worth marking — a student ticks the last step, taps Mark my work,
    /// and the thing they just finished is the one option missing.
    ///
    /// **Whatever the screen was opened with is always first, and never cut.**
    /// Arriving from an assignment pre-selects it in `.task`, but the checkmark
    /// is drawn by `assignmentRow`, which only exists for rows in this list. An
    /// assignment that was finished, or sat past the cap, was selected with
    /// nothing on screen saying so — indistinguishable from a broken button.
    private var markableAssignments: [Assignment] {
        Self.markable(from: assignments, chosen: chosenAssignment)
    }

    /// The rule above, as a function of its inputs so it can be tested.
    ///
    /// Twelve rather than six: Plus allows ten open at once and Pro has no cap,
    /// so six silently hid work on both paid plans.
    static func markable(from all: [Assignment],
                         chosen: Assignment?,
                         now: Date = .now,
                         keepFinishedFor: TimeInterval = 30 * 24 * 60 * 60,
                         limit: Int = 12) -> [Assignment] {
        let active = all.filter { $0.statusValue == .active }
        let recentlyFinished = all
            .filter { $0.statusValue == .completed
                      && $0.updatedAt > now.addingTimeInterval(-keepFinishedFor) }
            .sorted { $0.updatedAt > $1.updatedAt }

        var shown = active + recentlyFinished
        if let chosen {
            shown.removeAll { $0.id == chosen.id }
            shown.insert(chosen, at: 0)
        }
        return Array(shown.prefix(limit))
    }

    // MARK: - 2 · The rubric

    @ViewBuilder private var rubricStage: some View {
        stageTitle("What should I mark it against?",
                   "A rubric is the difference between a grade and an opinion.")

        if !rubrics.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SectionHeader(label: "Saved rubrics") { EmptyView() }
                ForEach(rubrics.prefix(6)) { rubric in
                    Button {
                        chosenRubric = rubric
                        acceptedBlind = false
                    } label: {
                        selectableRow(title: rubric.name,
                                      detail: rubric.source,
                                      selected: chosenRubric?.id == rubric.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "Or add one") { EmptyView() }
            // The same editor and the same writer the Rubrics tab uses, so a
            // rubric added here is a real saved rubric rather than a one-off
            // that vanishes after marking.
            importRow("Type or paste a rubric", "Saved for next time", "doc.text") {
                editingRubric = .empty
            }
            importRow("Photograph a rubric", "From a handout or the board", "camera.viewfinder") {
                rubricPhotoPicking = true
            }
        }

        // Blind is offered, never defaulted into silently.
        Button { acceptedBlind = true; chosenRubric = nil } label: {
            blindOption
        }
        .buttonStyle(.plain)

        PrimaryButton(title: "Continue",
                      isEnabled: chosenRubric != nil || acceptedBlind
                                 || chosenAssignment?.rubric != nil) {
            stage = .presentation
        }
    }

    private var blindOption: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(spacing: Tokens.Spacing.s) {
                AlbusCactus(size: 26, mood: .cooked)
                Text("I don't have a rubric")
                    .font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Spacer()
                if acceptedBlind {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Tokens.Palette.accent)
                }
            }
            Text("Albus will read it and say what looks strong or weak — but it "
                 + "won't be a grade, and it won't award marks.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(acceptedBlind ? Tokens.Palette.accent : Tokens.Palette.hairline,
                              lineWidth: acceptedBlind ? 1.5 : 0.5)
        }
    }

    // MARK: - 3 · How they are marked

    @ViewBuilder private var presentationStage: some View {
        stageTitle("How does your course mark this?",
                   "Albus can't know your scale. Tell it, and the result comes "
                   + "back in the form you'll actually be graded in.")

        TextEditor(text: $presentation)
            .font(Tokens.Typography.body)
            .frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(Tokens.Spacing.m)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.card)
                    .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
            }

        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            SectionHeader(label: "For example") { EmptyView() }
            ForEach(presentationExamples, id: \.self) { example in
                Button { presentation = example } label: {
                    Text(example)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                        .padding(.horizontal, Tokens.Spacing.m)
                        .padding(.vertical, Tokens.Spacing.s)
                        .background(Tokens.Palette.accentWash, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }

        if isBlind && !presentation.isEmpty {
            StatusBanner(tone: .warning,
                         message: "With no rubric, Albus still won't give a mark — "
                                + "whatever scale you ask for.")
        }

        // Named here, where the basis is finally known and the claim is true.
        HStack(spacing: Tokens.Spacing.s) {
            modelBadge
            Text(isBlind
                 ? "No rubric, so no marks — a read, not a grade."
                 : "Marked against your rubric.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }

        PrimaryButton(title: "Mark my work") { Task { await submit() } }
    }

    private var presentationExamples: [String] {
        ["Out of 100, with a letter grade",
         "IB 1–7, with the criterion bands",
         "Percentage, and how far off the next grade I am",
         "No marks — just tell me what's weak"]
    }

    // MARK: - 4 · Marking

    /// Thirty to forty seconds is a long time to look at a spinner.
    ///
    /// The lines are what is actually happening, in order, rather than filler:
    /// a student who reads them learns what marking involves, and one who does
    /// not still gets a screen that is visibly alive. Nothing here is a
    /// progress claim — the model does not report progress, so neither does
    /// this.
    private var markingBeats: [String] {
        isBlind
            ? ["Reading it through.",
               "Working out what it is trying to do.",
               "Finding the parts that are carrying it.",
               "Finding the parts that are not.",
               "Writing it up."]
            : ["Reading it through.",
               "Lining it up against your criteria.",
               "Marking each strand in turn.",
               "Finding the sentences that cost you marks.",
               "Working out what the next band needs.",
               "Writing it up."]
    }

    @ViewBuilder private var markingStage: some View {
        VStack(spacing: Tokens.Spacing.l) {
            AlbusCactus(size: 74, mood: .busy)
                // A slow breath, not a bounce. The cactus is concentrating.
                .scaleEffect(breathing ? 1.04 : 0.97)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                           value: breathing)

            Text(isBlind ? "Reading your work." : "Marking against your rubric.")
                .font(Tokens.Typography.cardTitle)
                .foregroundStyle(Tokens.Palette.ink)

            Text(markingBeats[min(beat, markingBeats.count - 1)])
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .id(beat)
                .transition(.opacity.combined(with: .move(edge: .bottom)))

            Text("\(wordCount) words. About half a minute.")
                .font(Tokens.Typography.micro)
                .foregroundStyle(Tokens.Palette.inkMuted)

            ProgressView().tint(Tokens.Palette.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Tokens.Spacing.xxl)
        .task {
            breathing = true
            // Stops at the last line rather than looping. Coming back round to
            // "Reading it through" after forty seconds reads as stuck.
            while beat < markingBeats.count - 1 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) { beat += 1 }
            }
        }
    }

    // MARK: - 5 · Result

    /// Sits over the result rather than after it, so it is reachable without
    /// scrolling to the bottom of a long grading.
    private var resultFooter: some View {
        HStack(spacing: Tokens.Spacing.m) {
            SecondaryButton(title: "Mark something else") { reset() }
            NavigationLink {
                Screen { GradingHistoryScreen() }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.accent)
                    .frame(width: 46, height: 46)
                    .background(Tokens.Palette.cardSurface, in: Circle())
                    .overlay { Circle().strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Marked work")
        }
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.vertical, Tokens.Spacing.m)
        .background(.ultraThinMaterial)
    }

    /// The failure half of the result stage. Still inside the scrolling flow —
    /// it is four lines, not a document.
    @ViewBuilder private var resultStage: some View {
        if let failure {
            StatusBanner(tone: .error, message: failure.errorDescription ?? "Marking failed.")

            // Running out is the one failure a retry cannot fix, so it does not
            // offer one. Everything else is worth another go — and costs
            // nothing, because an identical request comes back from the server
            // without a second model call.
            if failure.isAnswerableByUpgrading {
                blockedCard
            } else {
                PrimaryButton(title: "Try again") { stage = .presentation }
            }
            historyLink
        }
    }

    // MARK: - Pieces

    private var modelBadge: some View {
        HStack(spacing: 5) {
            Circle().frame(width: 4, height: 4)
            Text(isBlind ? "Sonnet 5" : "Opus 5")
                .font(Tokens.Typography.overline).fontWeight(.bold)
        }
        .foregroundStyle(Tokens.Palette.accent)
        .padding(.horizontal, Tokens.Spacing.s)
        .padding(.vertical, 3)
        .background(Tokens.Palette.accentWash, in: Capsule())
    }

    /// The grader's allowance, in the plan's own terms.
    ///
    /// Three states, and they are genuinely three. This drew five dots and said
    /// "3 left this week" while a free student was being stopped by a daily cap
    /// of two — both numbers true, and together a lie. It now reads one number
    /// from one window, and that window is the one the server enforces.
    private var grader: EntitlementService.Allowance { entitlements.plan.grader }

    @ViewBuilder private var meter: some View {
        // `isIncluded` before `remaining`, always. A limit of zero has a
        // remaining of zero, and rendering "0 left this week" to somebody who
        // never had any promises a Monday that is never coming.
        if !grader.isIncluded {
            Text("Not on the \(entitlements.plan.displayName) plan")
                .font(Tokens.Typography.overline)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        } else if let left = grader.remaining, let limit = grader.limit {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(0..<limit, id: \.self) { index in
                        Capsule()
                            .fill(index < left ? Tokens.Palette.accent
                                               : Tokens.Palette.hairline)
                            .frame(width: 14, height: 4)
                    }
                }
                Text("\(left) left this week")
                    .font(Tokens.Typography.overline)
                    .foregroundStyle(left > 0 ? Tokens.Palette.inkSecondary
                                              : Tokens.Palette.danger)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: left)
        } else {
            Text("Unlimited")
                .font(Tokens.Typography.overline)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
    }

    /// Why marking is unavailable, and what to do about it.
    ///
    /// Two cards, because there are two situations and they want opposite
    /// sentences. Somebody who has never had a grading needs a price; somebody
    /// who has used this week's needs a date. Showing the second to the first
    /// promises a Monday that never arrives; showing the first to the second
    /// sells a Plus subscriber Plus.
    private var blockedCard: some View {
        let notOnPlan = !grader.isIncluded
        return VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            AlbusCactus(size: 56, mood: notOnPlan ? .calm : .cooked)
            Text(notOnPlan
                 ? "Marking is part of Plus and Pro."
                 : "That's this week's markings used.")
                .font(Tokens.Typography.cardTitle)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(notOnPlan ? offerLine : returnsLine)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: notOnPlan ? "See the plans" : "Get more") {
                showingPaywall = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
    }

    /// What the next plan up buys, in gradings rather than adjectives.
    ///
    /// Named as plans, not as bare counts. "Plus marks two pieces of work a
    /// week" sat under a title about Plus and Pro and read as a statement about
    /// what the student already had — so a Free student was told, on the screen
    /// refusing them, that they got two a week. Every clause now starts with
    /// the plan it belongs to.
    private var offerLine: String {
        "Plus includes two markings a week, against your own rubric. "
        + "Pro includes five."
    }

    /// When the next one is back, said as a time rather than a duration.
    ///
    /// "In 4 hours" is a number a student has to do arithmetic on; "back on
    /// Tuesday" is a thing they can plan around. Falls back to the vaguer line
    /// only when the server could not say — never invents a time.
    private var returnsLine: String {
        let upgrade = entitlements.plan.tier == .pro
            ? "" : " Pro marks five a week."
        guard let resets = grader.resetsAt, resets > .now else {
            return "They come back as the week rolls on.\(upgrade)"
        }
        let when = Calendar.current.isDateInToday(resets)
            ? resets.formatted(date: .omitted, time: .shortened)
            : resets.formatted(date: .abbreviated, time: .shortened)
        return "The next one is back \(when).\(upgrade)"
    }

    private func stageTitle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func assignmentRow(_ assignment: Assignment) -> some View {
        let rubric = assignment.rubric != nil ? "Rubric on file" : "No rubric saved"
        return selectableRow(
            title: assignment.title,
            // Finished work is listed on purpose; without the word, a student
            // wonders why a task they completed is still here.
            detail: assignment.statusValue == .completed ? "Finished · \(rubric)" : rubric,
            selected: chosenAssignment?.id == assignment.id
        )
    }

    private func selectableRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                    .lineLimit(1)
                Text(detail).font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Tokens.Palette.accent : Tokens.Palette.hairline)
        }
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(selected ? Tokens.Palette.accent : Tokens.Palette.hairline,
                              lineWidth: selected ? 1.5 : 0.5)
        }
    }

    private func importRow(_ title: String, _ detail: String, _ icon: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { importRowLabel(title, detail, icon) }
            .buttonStyle(.plain)
    }

    private func importRowLabel(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: icon)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(width: 32, height: 32)
                .background(Tokens.Palette.accentWash,
                            in: RoundedRectangle(cornerRadius: Tokens.Radius.chip))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Tokens.Typography.cardTitle)
                    .foregroundStyle(Tokens.Palette.ink)
                Text(detail).font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
        .padding(Tokens.Spacing.l)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
        }
    }

    private func card(rail: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Spacing.l)
            .background(Tokens.Palette.cardSurface,
                        in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(alignment: .leading) {
                Rectangle().fill(rail).frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            }
    }

    // MARK: - Actions

    /// Back to the top, without re-asking what has not changed.
    ///
    /// The rubric and the scale survive: a student who marks a draft and then
    /// the revision is marking the same thing against the same criteria, and
    /// making them answer both questions again is the fastest way to make a
    /// second grading not worth the trouble. The work does not survive — that
    /// is the thing being replaced.
    private func reset() {
        work = ""
        sourceLabel = nil
        extractionFailure = nil
        result = nil
        failure = nil
        beat = 0
        stage = .work
    }

    private func choose(_ assignment: Assignment) {
        chosenAssignment = assignment
        chosenRubric = assignment.rubric
        sourceLabel = assignment.title
    }

    private func extract(_ source: WorkExtractor.Source, label: String) {
        extracting = true
        extractionFailure = nil
        Task {
            do {
                work = try await WorkExtractor.text(from: source)
                sourceLabel = label
            } catch {
                extractionFailure = (error as? WorkExtractor.Failure)?.errorDescription
                    ?? "Albus couldn't read that."
            }
            extracting = false
        }
    }

    private func submit() async {
        let accountGeneration = accountDeletion.generation
        stage = .marking
        failure = nil

        do {
            let marked = try await GradingService().grade(
                work: work,
                rubricID: chosenRubric?.remoteID,
                assignmentID: chosenAssignment?.remoteID,
                presentation: presentation,
                title: workTitle
            )

            guard !accountDeletion.requiresCleanup, accountDeletion.generation == accountGeneration else { return }

            let grading = Grading(
                remoteID: marked.id,
                model: marked.model,
                inputChars: work.count,
                overallMarks: marked.overallMarks,
                totalMarks: marked.totalMarks,
                gradeLabel: marked.gradeLabel,
                gradeNote: marked.gradeNote,
                // The server's title wins: it resolves the assignment's real
                // name when there is one, and echoing back what we sent would
                // label a grading with a filename the student has forgotten.
                workTitle: marked.title ?? workTitle,
                criteria: marked.criteria.map {
                    GradedCriterion(code: $0.code, name: $0.name, marks: $0.marks,
                                    outOf: $0.outOf, comment: $0.comment,
                                    quote: $0.quote, whereFound: $0.whereFound)
                },
                feedback: marked.feedback,
                improvements: marked.improvements.map {
                    GradedImprovement(change: $0.change, why: $0.why)
                },
                basis: marked.basis,
                assignment: chosenAssignment
            )
            context.insert(grading)
            try? context.save()

            // Dropped once stored: the work has been marked, and holding an
            // essay in memory behind a visible result serves nobody.
            work = ""
            result = grading
            await entitlements.refresh()
            stage = .result

        } catch let error as GradingService.Failure {
            failure = error

            // Running out is not something the student did wrong, so it opens
            // the plans rather than an error — but only after the plan has been
            // re-read, so the screen behind it stops claiming a grading is
            // available.
            //
            // The server's refusal already distinguishes "not on your plan"
            // from "this week's is spent", and those are the two cases the card
            // renders differently. Re-reading the plan is what lets the card
            // name the date; it is not what decides which card to show.
            if error.isAnswerableByUpgrading {
                await entitlements.refresh()
                if case .allowanceUsed = error {
                    failure = .allowanceUsed(resetsAt: entitlements.plan.grader.resetsAt)
                }
                showingPaywall = true
            }
            stage = .result
        } catch {
            failure = .unavailable
            stage = .result
        }
    }
}
