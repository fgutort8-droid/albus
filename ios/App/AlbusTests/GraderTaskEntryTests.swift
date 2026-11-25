import Testing
@testable import Albus

/// A Grader opened from an assignment skips its first screen only while the
/// plan has a marking to spend, and the server's answer can move the student
/// on or back. Found at the exhibition in November 2026: on Free, a task's
/// "Mark my work" went straight to the work, past the screen that says
/// marking needs Plus or Pro, and the student was turned away only when they
/// pressed mark.
// `GraderScreen` is a `View`, so its statics are main-actor isolated.
@MainActor
@Suite("Grader opened from a task")
struct GraderTaskEntryTests {

    @Test("on Free, or with this week's markings used, it stays on the screen that says so")
    func lockedStaysOnTheFirstScreen() {
        #expect(GraderScreen.taskEntryStage(.start, hasMarking: false, workStarted: false) == .start)
    }

    @Test("with a marking to spend it goes straight to the work")
    func openGoesToTheWork() {
        #expect(GraderScreen.taskEntryStage(.start, hasMarking: true, workStarted: false) == .work)
    }

    @Test("a plan that turns out to have a marking moves the student on")
    func serverUnlocks() {
        // The phone still showed Free; the server has the Plus just bought.
        let opened = GraderScreen.taskEntryStage(.start, hasMarking: false, workStarted: false)
        #expect(opened == .start)
        #expect(GraderScreen.taskEntryStage(opened, hasMarking: true, workStarted: false) == .work)
    }

    @Test("a plan that turns out to have none left moves the student back")
    func serverLocks() {
        // The phone showed one left; it was spent on another phone.
        let opened = GraderScreen.taskEntryStage(.start, hasMarking: true, workStarted: false)
        #expect(opened == .work)
        #expect(GraderScreen.taskEntryStage(opened, hasMarking: false, workStarted: false) == .start)
    }

    @Test("work already started is never taken away")
    func startedWorkStays() {
        #expect(GraderScreen.taskEntryStage(.work, hasMarking: false, workStarted: true) == .work)
    }

    @Test("a later stage is never moved", arguments: [false, true])
    func laterStagesStay(hasMarking: Bool) {
        for stage in [GraderScreen.Stage.rubric, .presentation, .marking, .result] {
            #expect(GraderScreen.taskEntryStage(stage, hasMarking: hasMarking, workStarted: false) == stage)
        }
    }
}
