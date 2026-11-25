import Foundation
import Testing

/// Every button that opens a form the plan limits asks the plan first.
///
/// Found in November 2026: with five tasks open on Free, Home's "+" opened the
/// add form, and with three rubrics saved every way to add a rubric opened the
/// editor. Both forms ended in a refusal after the student had filled them in.
/// `EntitlementServiceTests` proves the rule (`taskLimit`, `rubricLimit`);
/// this proves the buttons use it, so putting a button's old action back fails
/// here.
///
/// The actions are closures in SwiftUI views, which a unit test cannot tap,
/// so this reads the source files, as `GraderPhotoRowTests` does. Each place
/// that opens a new task or a new rubric must sit inside the function that
/// asks the plan. Editing a saved rubric must not.
@Suite("Plan doors ask first")
struct PlanDoorWiringTests {

    private static func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Albus/Screens/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from each match of `action` back to the start of the enclosing
    /// declaration, so the check is "is this inside the asking function",
    /// whatever line the action sits on.
    private static func contexts(of action: String, in source: String) -> [String] {
        var found: [String] = []
        var searchRange = source.startIndex..<source.endIndex
        while let hit = source.range(of: action, range: searchRange) {
            let before = source[..<hit.lowerBound]
            let start = before.range(of: "\n    private func ", options: .backwards)?.lowerBound
                ?? before.range(of: "\n    var body", options: .backwards)?.lowerBound
                ?? source.startIndex
            found.append(String(source[start..<hit.upperBound]))
            searchRange = hit.upperBound..<source.endIndex
        }
        return found
    }

    @Test("Home's add buttons open the form only through the task-limit check")
    func homeAsksBeforeTheAddForm() throws {
        let home = try Self.source("HomeScreen.swift")
        let opens = Self.contexts(of: "addingTask = true", in: home)
        #expect(!opens.isEmpty)
        for context in opens {
            #expect(context.contains("private func addTask()")
                    && context.contains("taskLimit(reachedBy:"),
                    "Home opens the add form without asking the plan")
        }
        // Both doors, "+" and the empty state's "Add an assignment".
        #expect(home.components(separatedBy: "{ addTask() }").count - 1 == 2)
    }

    @Test("every new-rubric door asks the plan first",
          arguments: [("RubricsScreen.swift", "editing = .empty"),
                      ("RubricsScreen.swift", "RubricWriter.duplicate("),
                      ("AddTaskSheet.swift", "creatingRubric = .empty"),
                      ("GraderScreen.swift", "editingRubric = .empty"),
                      ("GraderScreen.swift", "rubricPhotoPicking = true")])
    func newRubricAsksFirst(file: String, action: String) throws {
        let opens = Self.contexts(of: action, in: try Self.source(file))
        #expect(!opens.isEmpty, "\(action) is no longer in \(file); update this test")
        for context in opens {
            let asks = context.contains("rubricLimit(reachedBy:")
                || context.hasSuffix("whenRoomForRubric { \(action)")
                || context.contains("whenRoomForRubric {\n") && context.contains("private func duplicate(")
            #expect(asks, "\(file) opens a new rubric (\(action)) without asking the plan")
        }
    }

    @Test("a saved rubric still opens to edit without asking")
    func editingIsNotGated() throws {
        let rubrics = try Self.source("RubricsScreen.swift")
        #expect(rubrics.contains("Button { editing = RubricDraft(rubric) }"))
    }
}
