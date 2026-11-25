import Foundation
import SwiftData
import Testing
@testable import Albus

/// `RubricWriter.ensureOnServer`, which the marking runs before it sends a
/// rubric's id: the server reads the rubric by that id, so it must hold it.
/// The marking side is in `MarkingCoordinatorTests`.
@MainActor
@Suite("A rubric is on the server before it is marked against", .serialized)
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
