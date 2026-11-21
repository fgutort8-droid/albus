import SwiftUI
import AlbusCore

/// A step being edited.
///
/// A value, not the `@Model`, so Cancel cancels — editing the model directly
/// would persist every keystroke and re-run the scheduler on each one.
struct StepDraft: Identifiable, Equatable {
    var id: UUID
    var title: String
    var minutesText: String
    var isExisting: Bool

    static var empty: StepDraft {
        StepDraft(id: UUID(), title: "", minutesText: "30", isExisting: false)
    }

    @MainActor
    init(_ step: Subtask) {
        id = step.id
        title = step.title
        minutesText = String(step.estimatedMinutes)
        isExisting = true
    }

    init(id: UUID, title: String, minutesText: String, isExisting: Bool) {
        self.id = id
        self.title = title
        self.minutesText = minutesText
        self.isExisting = isExisting
    }

    /// Clamped to the same range the coordinator enforces, so what the sheet
    /// shows is what gets saved.
    var minutes: Int { max(5, min(600, Int(minutesText.trimmed) ?? 30)) }
    var isSavable: Bool { title.trimmed.count >= 2 }
}

/// Editing one step of the plan.
///
/// Albus proposes; the student decides. A plan you cannot correct is one you
/// stop trusting the first time it is wrong about how long something takes —
/// and being wrong about that is normal, which is the whole reason the app
/// learns from measured sessions.
struct StepEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State var draft: StepDraft
    let onSave: (StepDraft) -> Void
    var onDelete: (() -> Void)?

    @State private var confirmingDelete = false

    private static let presets = [15, 25, 30, 45, 60, 90]

    var body: some View {
        AlbusSheetScaffold(
            eyebrow: draft.isExisting ? "Editing a step" : "Adding a step",
            title: draft.isExisting ? "What changed?" : "What are you doing?",
            primaryTitle: "Save",
            isPrimaryEnabled: draft.isSavable,
            primaryAction: {
                onSave(draft)
                dismiss()
            },
            onCancel: { dismiss() },
            detents: [.medium, .large]
        ) {
            SheetField(label: "The step") {
                TextField("Read chapter 4 and take notes", text: $draft.title, axis: .vertical)
                    .lineLimit(1...4)
                    .font(Tokens.Typography.body)
                    .textInputAutocapitalization(.sentences)
            }

            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                SheetField(label: "How long") {
                    HStack {
                        TextField("30", text: $draft.minutesText)
                            .keyboardType(.numberPad)
                            .font(Tokens.Typography.body)
                        Text("minutes")
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Tokens.Spacing.s) {
                        ForEach(Self.presets, id: \.self) { value in
                            FilterChip(title: "\(value)m",
                                       isSelected: draft.minutesText == String(value)) {
                                // Snappy, because this is a chip a student taps
                                // three or four times deciding — a slow spring
                                // here reads as lag rather than polish. The
                                // quick curve, as Home's filter chips use: it
                                // is done before the next tap lands.
                                withAnimation(Tokens.Motion.quick) {
                                    draft.minutesText = String(value)
                                }
                            }
                        }
                    }
                }

                AlbusNote("Changing this re-flows everything after it. Anywhere between "
                          + "**5 and 600 minutes**.")
            }

            if draft.isExisting, onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    HStack(spacing: Tokens.Spacing.s) {
                        Image(systemName: "trash")
                        Text("Delete step")
                    }
                    .font(Tokens.Typography.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.Palette.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.Spacing.m)
                    .background(Tokens.Palette.danger.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control,
                                                     style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        // Destructive confirmation stays a system dialog on purpose. It is the
        // one interaction where familiarity beats personality: a student needs
        // to recognise it instantly as "this deletes something", and every
        // other app on the phone has taught them what this looks like.
        .confirmationDialog("Delete this step?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The time it was holding goes back to the rest of your plan.")
        }
    }
}

/// Reordering the plan.
///
/// A `List` in edit mode rather than drag handles on the main screen: the plan
/// is a custom rail with a connector between nodes, and a drag gesture on top of
/// that fights the scroll view. A separate sheet gets the system behaviour for
/// free and is honest about being a mode.
struct StepReorderSheet: View {
    @Environment(\.dismiss) private var dismiss

    let steps: [Subtask]
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(steps) { step in
                    HStack(spacing: Tokens.Spacing.m) {
                        Text(step.title)
                            .font(Tokens.Typography.label)
                            .foregroundStyle(Tokens.Palette.ink)
                        Spacer()
                        Text(DurationText.short(minutes: step.estimatedMinutes))
                            .font(Tokens.Typography.mono)
                            .foregroundStyle(Tokens.Palette.inkMuted)
                    }
                }
                .onMove(perform: onMove)
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
