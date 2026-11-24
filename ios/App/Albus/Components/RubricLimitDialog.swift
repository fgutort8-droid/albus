import SwiftUI

extension View {
    /// What a door into a new rubric shows once the plan's rubrics are used
    /// up (`EntitlementService.rubricLimit(reachedBy:)`), in place of an
    /// editor whose rubric the server would turn away once it was written.
    ///
    /// Every such door shows the same thing: the Rubrics tab, the add-task
    /// sheet and the Grader. Rubrics already saved still open and edit as
    /// before; only a new one asks.
    func rubricLimitDialog(_ limit: Binding<Int?>, planName: String,
                           seePlans: @escaping () -> Void) -> some View {
        confirmationDialog(
            limit.wrappedValue.map {
                "\(planName) keeps \($0) synced \($0 == 1 ? "rubric" : "rubrics")"
            } ?? "",
            isPresented: Binding(get: { limit.wrappedValue != nil },
                                 set: { if !$0 { limit.wrappedValue = nil } }),
            titleVisibility: .visible
        ) {
            Button("See plans", action: seePlans)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete one, or move up a plan.")
        }
    }
}
