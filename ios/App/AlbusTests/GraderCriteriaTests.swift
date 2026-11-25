import Foundation
import Testing
@testable import Albus

/// Choosing which of a rubric's criteria the Grader marks. Every criterion is
/// ticked to start with; one left out is not marked, and its marks are not in
/// the total. All ticked sends nothing, so the server marks the whole rubric
/// exactly as it did before the choice existed.
@MainActor
@Suite("Grader: choosing the criteria to mark")
struct GraderCriteriaTests {

    @Test("all criteria ticked sends no choice")
    func allTickedSendsNothing() {
        #expect(GraderScreen.criteriaToMark(count: 3, leftOut: []) == nil)
    }

    @Test("a left-out criterion is not sent, and the rest keep the rubric's order")
    func leftOutIsDropped() {
        #expect(GraderScreen.criteriaToMark(count: 4, leftOut: [1, 3]) == [0, 2])
    }

    @Test("leaving every criterion out sends nothing to mark, which the Grader stops")
    func noneLeftIsEmpty() {
        #expect(GraderScreen.criteriaToMark(count: 2, leftOut: [0, 1]) == [])
    }

    @Test("a rubric with one criterion, or none, has nothing to choose")
    func oneCriterionHasNoChoice() {
        #expect(GraderScreen.criteriaToMark(count: 1, leftOut: [0]) == nil)
        #expect(GraderScreen.criteriaToMark(count: 0, leftOut: []) == nil)
    }

    @Test("each criterion says what it is worth")
    func detail() {
        #expect(GraderScreen.criterionDetail(marks: 6, guidance: "x") == "6 marks")
        #expect(GraderScreen.criterionDetail(marks: 1, guidance: nil) == "1 mark")
        #expect(GraderScreen.criterionDetail(marks: nil, guidance: " Clear thesis ") == "Clear thesis")
        #expect(GraderScreen.criterionDetail(marks: nil, guidance: nil) == "No marks set")
    }

    /// The choice is made in a SwiftUI view, which a unit test cannot tap, so
    /// this reads the source, as `PlanDoorWiringTests` does: the marking is
    /// sent the choice, and Continue stays off when nothing is left to mark.
    @Test("the Grader sends the choice, and will not go on with none")
    func wiring() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Albus/Screens/GraderScreen.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("rubric: chosenRubric,\n            criteria: criteriaToMark,"))
        #expect(source.contains("&& criteriaToMark != []"))
        #expect(source.contains(".onChange(of: chosenRubric?.id) { leftOutCriteria = [] }"))
    }
}
