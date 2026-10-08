import Testing
import Foundation
import SwiftData
@testable import Albus

/// Whose tasks the phone holds, and what happens to them when someone signs in.
@Suite("The phone's data and who signs in")
@MainActor
struct LocalAccountTests {
    private let me = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!
    private let someoneElse = UUID(uuidString: "22222222-0000-4000-8000-000000000002")!

    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
    }

    @Test("the rules, case by case")
    func decisions() {
        typealias L = LocalAccount
        // The same account, however it arrived, keeps everything.
        #expect(L.decide(for: me, owner: me, arrival: .signedIn, hasLocalData: true) == .keep)
        #expect(L.decide(for: me, owner: me, arrival: .restored, hasLocalData: false) == .keep)
        // Data from before the phone kept track belongs to the account restored at launch.
        #expect(L.decide(for: me, owner: nil, arrival: .restored, hasLocalData: true)
                == .adopt(resetsSetUp: false))
        // A new phone, or one with nothing on it, becomes this account's.
        #expect(L.decide(for: me, owner: nil, arrival: .signedIn, hasLocalData: false)
                == .adopt(resetsSetUp: true))
        #expect(L.decide(for: me, owner: someoneElse, arrival: .signedIn, hasLocalData: false)
                == .adopt(resetsSetUp: true))
        // Someone else's tasks are here: ask, never remove silently, never hand them over.
        #expect(L.decide(for: me, owner: someoneElse, arrival: .signedIn, hasLocalData: true) == .ask)
        #expect(L.decide(for: me, owner: someoneElse, arrival: .restored, hasLocalData: true) == .ask)
        #expect(L.decide(for: me, owner: nil, arrival: .signedIn, hasLocalData: true) == .ask,
                "tasks from an account this phone lost track of are not the new account's")
    }

    @Test("adopting a phone with nothing on it resets the set-up answers")
    func adoptEmptyPhone() {
        let defaults = isolated()
        let local = LocalAccount(defaults: defaults)
        let preferences = Preferences(defaults: isolated())
        preferences.name = "Someone Else"
        preferences.markOnboarded()

        local.arrived(me, arrival: .signedIn, hasLocalData: false, preferences: preferences)

        #expect(local.owner == me)
        #expect(preferences.name.isEmpty)
        #expect(!preferences.hasOnboarded, "the new account answers the set-up questions")
        #expect(LocalAccount(defaults: defaults).owner == me, "remembered across launches")
    }

    @Test("another account taking over an empty phone replaces the services that held the last one's plan")
    func takeoverReplacesServices() {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(someoneElse, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        let first = local.generation
        #expect(first == 0, "a phone nobody had needs nothing replaced")

        local.arrived(me, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        #expect(local.owner == me)
        #expect(local.generation == first + 1)

        local.arrived(me, arrival: .restored, hasLocalData: false, preferences: preferences)
        #expect(local.generation == first + 1, "the same account again changes nothing")
    }

    @Test("the account that made the tasks signs back in to everything as it was")
    func sameAccountReturns() {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(me, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        preferences.name = "Me"
        preferences.markOnboarded()
        local.signedOut()

        local.arrived(me, arrival: .signedIn, hasLocalData: true, preferences: preferences)

        #expect(local.awaitingDecision == nil)
        #expect(preferences.name == "Me")
        #expect(preferences.hasOnboarded)
    }

    @Test("another account is asked, and nothing changes until it answers")
    func otherAccountAsks() {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(someoneElse, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        preferences.name = "Someone Else"

        local.arrived(me, arrival: .signedIn, hasLocalData: true, preferences: preferences)

        #expect(local.awaitingDecision == me)
        #expect(local.owner == someoneElse)
        #expect(preferences.name == "Someone Else")
    }

    @Test("removing the other account's tasks clears, adopts and starts over")
    func removeAndContinue() async throws {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(someoneElse, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        local.arrived(me, arrival: .signedIn, hasLocalData: true, preferences: preferences)
        let before = local.generation
        var cleared = 0

        try await local.removeOtherAccountsData(for: me) { cleared += 1 }

        #expect(cleared == 1)
        #expect(local.owner == me)
        #expect(local.awaitingDecision == nil)
        #expect(local.generation == before + 1, "services that held the old account's state are replaced, once")
    }

    @Test("a failed clear leaves the other account's tasks theirs, and the question open")
    func failedClear() async {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(someoneElse, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        local.arrived(me, arrival: .signedIn, hasLocalData: true, preferences: preferences)

        await #expect(throws: CocoaError.self) {
            try await local.removeOtherAccountsData(for: me) { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(local.owner == someoneElse)
        #expect(local.awaitingDecision == me)
    }

    @Test("only the account being asked about can remove anything")
    func removeIsForTheAskingAccount() async throws {
        let local = LocalAccount(defaults: isolated())
        var cleared = false
        try await local.removeOtherAccountsData(for: me) { cleared = true }
        #expect(!cleared)
        #expect(local.owner == nil)
    }

    @Test("signing out keeps the owner, so the same account comes back to its tasks")
    func signOutKeepsOwner() {
        let local = LocalAccount(defaults: isolated())
        let preferences = Preferences(defaults: isolated())
        local.arrived(me, arrival: .signedIn, hasLocalData: false, preferences: preferences)
        let before = local.generation
        local.signedOut()
        #expect(local.owner == me)
        #expect(local.generation == before + 1)
    }

    @Test("a deleted account is forgotten")
    func forget() {
        let defaults = isolated()
        let local = LocalAccount(defaults: defaults)
        local.arrived(me, arrival: .signedIn, hasLocalData: false, preferences: Preferences(defaults: isolated()))
        local.forget()
        #expect(local.owner == nil)
        #expect(LocalAccount(defaults: defaults).owner == nil)
    }

    private func emptyStore() throws -> ModelContext {
        let container = try ModelContainer(for: AlbusSchema.schema,
                                           configurations: ModelConfiguration(schema: AlbusSchema.schema,
                                                                              isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test("anything a student made counts as data on the phone")
    func hasData() throws {
        let context = try emptyStore()
        #expect(!LocalAccount.hasData(in: context))
        context.insert(Rubric(name: "Essay rubric"))
        try context.save()
        #expect(LocalAccount.hasData(in: context))
    }

    @Test("a course saved before its first task is data too, so the next account is asked about it")
    func courseAloneIsData() throws {
        let context = try emptyStore()
        context.insert(Course(displayName: "Biology"))
        try context.save()
        #expect(LocalAccount.hasData(in: context))
        #expect(LocalAccount.decide(for: me, owner: someoneElse, arrival: .signedIn,
                                    hasLocalData: LocalAccount.hasData(in: context)) == .ask)
    }
}
