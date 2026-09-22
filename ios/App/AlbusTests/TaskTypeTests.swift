import Testing
import Foundation
@testable import Albus

/// `TaskType`'s raw values are a wire contract shared by three places: this
/// enum, `assignments_task_type_check` in Postgres, and `TASK_TYPES` in the
/// breakdown Edge Function. They drifted once already — onboarding offered six
/// types while task creation offered eight — and nothing caught it, because
/// nothing was checking.
///
/// These tests pin the shape. The cross-system agreement itself is asserted in
/// `supabase/tests/production_safety_test.sql` and
/// `supabase/tests/courses_and_task_types_test.sql`, which can see the real
/// constraint; what can be checked here is that the client's own list is
/// complete, stable, and degrades safely.
@Suite("Task types")
struct TaskTypeTests {

    /// The exact set the server accepts, transcribed from the migration and the
    /// Edge Function. If this test fails, one of the three lists moved without
    /// the others — which is the bug it exists to catch, not a reason to edit
    /// this array until it goes green.
    private static let serverAccepted: Set<String> = [
        "essay", "problem_set", "lab_report", "reading",
        "revision", "project", "presentation", "other"
    ]

    /// The IB assessment types the app offered until September 2026. The
    /// server no longer stores them, so the app must never send one again.
    private static let retired: Set<String> = [
        "internal_assessment", "extended_essay",
        "tok_essay", "tok_exhibition",
        "mock_exam", "final_exam"
    ]

    @Test("every client type is one the server accepts")
    func noClientTypeTheServerRejects() {
        let client = Set(TaskType.allCases.map(\.rawValue))
        let unknownToServer = client.subtracting(Self.serverAccepted)
        #expect(unknownToServer.isEmpty,
                "these would 422 on the student with nothing they could do: \(unknownToServer.sorted())")
    }

    @Test("every type the server accepts is offered to the student")
    func noServerTypeTheClientHides() {
        let client = Set(TaskType.allCases.map(\.rawValue))
        let unofferedByClient = Self.serverAccepted.subtracting(client)
        #expect(unofferedByClient.isEmpty,
                "the server would accept these but nothing can send them: \(unofferedByClient.sorted())")
    }

    @Test("no retired IB type can be picked")
    func retiredTypesAreNotOffered() {
        let offered = Set(TaskType.offered.map(\.rawValue))
        #expect(offered.isDisjoint(with: Self.retired),
                "the server refuses these: \(offered.intersection(Self.retired).sorted())")
    }

    @Test("both entry points offer the same list")
    func onboardingAndTaskCreationAgree() {
        // The original bug: OnboardingFlow had six, AddTaskSheet had eight.
        // Both read `offered` now, so this holds by construction — the test is
        // here so that reintroducing a second hand-written list fails loudly.
        #expect(Set(TaskType.offered) == Set(TaskType.allCases))
        #expect(TaskType.offered.count == TaskType.allCases.count,
                "offered must not drop or duplicate a type")
    }

    // MARK: - Degrading safely

    @Test("an unknown stored value falls back instead of failing")
    func unknownValueFallsBack() {
        // A newer build writing a type this one does not know must not make the
        // task unreadable. Better a task labelled "Other" than a task that
        // cannot be opened.
        #expect(TaskType(storedValue: "some_future_type") == .other)
        #expect(TaskType(storedValue: nil) == .other)
        #expect(TaskType(storedValue: "") == .other)
    }

    @Test("a task saved with a retired IB type still opens")
    func retiredValueFallsBack() {
        // A task created on this device before September 2026 keeps its old
        // type locally. It must still decode.
        for value in Self.retired {
            #expect(TaskType(storedValue: value) == .other, "\(value) did not fall back")
        }
    }

    @Test("known values still round-trip exactly")
    func knownValuesRoundTrip() {
        for type in TaskType.allCases {
            #expect(TaskType(storedValue: type.rawValue) == type,
                    "\(type.rawValue) did not round-trip")
        }
    }

    @Test("raw values are stable snake_case, never display text")
    func rawValuesAreWireSafe() {
        for type in TaskType.allCases {
            #expect(type.rawValue.wholeMatch(of: /[a-z_]+/) != nil,
                    "\(type.rawValue) is not a safe wire value")
            // A raw value that leaked display text would break every stored row
            // the moment the copy was reworded.
            #expect(type.rawValue != type.title)
        }
    }

    // MARK: - Estimates

    @Test("every type has a usable default duration")
    func defaultsAreSane() {
        for type in TaskType.allCases {
            // The server rejects anything outside 5–12000 minutes.
            #expect(type.defaultMinutes >= 5 && type.defaultMinutes <= 12_000,
                    "\(type.rawValue) defaults outside what the server accepts")
        }
    }

    @Test("long pieces default longer than reading")
    func longPiecesDefaultLonger() {
        // Not a claim about total effort — the scheduler places sessions, not
        // whole projects. Just that a session on a project or an essay should
        // not default shorter than a session of reading.
        #expect(TaskType.project.defaultMinutes > TaskType.reading.defaultMinutes)
        #expect(TaskType.essay.defaultMinutes > TaskType.reading.defaultMinutes)
    }
}
