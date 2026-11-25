import Foundation
import SwiftData
import Testing
@testable import Albus

/// The rubric a student picks in the Grader is the one Albus marks against.
///
/// Found in November 2026: the Grader sent `chosenRubric?.remoteID`, which is
/// never set for a rubric, so the marking never received the picked rubric
/// and marked against the task's own rubric or none. That had been true since
/// the Grader was built on 26 August.
@MainActor
@Suite("Grader marks against the picked rubric", .serialized)
struct GraderRubricTests {

    private struct SaveFailed: Error {}

    private func savedRubric() throws -> (Rubric, ModelContext) {
        let context = ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let rubric = Rubric(name: "Essay rubric", body: "A: Knowledge. B: Analysis.")
        context.insert(rubric)
        try context.save()
        return (rubric, context)
    }

    @Test("the marking asks for the id the rubric is saved under")
    func sendsTheSavedID() throws {
        let (rubric, _) = try savedRubric()
        #expect(rubric.remoteID == nil, "a rubric never gets a remoteID; that was the bug")
        // `RubricService.save` stores the rubric under `snapshot.id`.
        #expect(GraderScreen.rubricIDToMark(rubric) == rubric.snapshot.id)
        #expect(GraderScreen.rubricIDToMark(nil) == nil)
    }

    @Test("a rubric the server holds lets the marking go ahead")
    func savedRubricGoesAhead() async throws {
        let (rubric, _) = try savedRubric()
        var sent: UUID?
        let why = await RubricWriter.ensureOnServer(rubric) { sent = $0.id }
        #expect(why == nil)
        #expect(sent == rubric.id)
    }

    @Test("a rubric the server could not take stops the marking, with the reason")
    func unsavedRubricStopsTheMarking() async throws {
        let (rubric, _) = try savedRubric()
        let offline = await RubricWriter.ensureOnServer(rubric) { _ in
            throw RubricService.Failure.offline
        }
        #expect(offline == RubricService.Failure.offline.errorDescription)

        let unknown = await RubricWriter.ensureOnServer(rubric) { _ in throw SaveFailed() }
        #expect(unknown == "Couldn't sync this rubric. It's saved on your phone.")
    }
}
