import Testing
import Foundation
@testable import AlbusCore

/// Every fact populated, so a candidate is excluded only by kind, workload or
/// register — never because the fixture forgot something.
private let everyFact: Facts = {
    var facts = Facts()
    for fact in Fact.allCases { facts[fact] = "X" }
    return facts
}()

@Suite("Copy — structure")
struct CopyStructureTests {

    @Test("template ids are unique across the whole corpus")
    func idsUnique() {
        let ids = Corpus.all.map(\.id)
        #expect(Set(ids).count == ids.count,
                "duplicates: \(Dictionary(grouping: ids, by: { $0 }).filter { $1.count > 1 }.keys)")
    }

    /// The guardrail, as a test rather than as authoring discipline.
    ///
    /// A joke about work a student has already missed is the one line this app
    /// must not be able to send. Making it a property of the kind and proving
    /// it here means it cannot be reintroduced by someone adding a line.
    @Test("no kind that forbids chaos has a chaotic line")
    func noJokesWhereTheyDoNotBelong() {
        for kind in NotificationKind.allCases where !kind.allowsChaos {
            let offenders = Corpus.all.filter { $0.kind == kind && $0.register == .chaos }
            #expect(offenders.isEmpty,
                    "\(kind) allows no chaos but has \(offenders.map(\.id))")
        }
    }

    @Test("asking for chaos on a forbidden kind still returns plain")
    func registerIsForcedDown() {
        #expect(NotificationCopy.effectiveRegister(kind: .overdue, requested: .chaos) == .plain)
        #expect(NotificationCopy.effectiveRegister(kind: .morningBrief, requested: .chaos) == .chaos)
    }

    @Test("every reachable moment has something to say")
    func everyCellIsCovered() {
        for kind in NotificationKind.allCases {
            for workload in [WorkloadState.calm, .busy, .cooked] {
                for register in Register.allCases {
                    let options = NotificationCopy.candidates(
                        kind: kind, workload: workload, register: register, facts: everyFact
                    )
                    #expect(!options.isEmpty, "\(kind)/\(workload)/\(register) is empty")
                }
            }
        }
    }

    /// What the planner actually promises each kind, at its stingiest.
    ///
    /// Deliberately excludes `.step`: a next step exists only when the
    /// assignment has an unfinished one, and `.lateBy` only for overdue work.
    /// `.count` is in none of them: it is offered only for a number that reads
    /// as a plural, so not when exactly one assignment is open. The quiet-app
    /// kinds are promised nothing: an assignment is named only when it is due
    /// a day or more after the reminder.
    /// A cell whose every line demanded an optional fact would go silent for a
    /// real student and pass a test that filled everything in.
    private static let guaranteed: [NotificationKind: Set<Fact>] = [
        .morningBrief: [.minutes, .steps, .step],
        .windowNudge: [.step, .minutes, .assignment],
        .deadline72: [.assignment, .steps, .minutes, .days, .hours],
        .deadline24: [.assignment, .steps, .minutes, .days, .hours],
        .deadline03: [.assignment, .steps, .minutes, .days, .hours],
        .handInToday: [.assignment, .steps, .minutes, .days, .hours],
        .overdue: [.assignment, .steps, .minutes, .days, .hours, .lateBy],
        .planStoppedFitting: [.assignment, .steps, .minutes, .days, .hours],
        .momentum: [.weekMinutes],
        .dormantSoft: [],
        .dormantFinal: [],
        .backOff: []
    ]

    /// The invariant that matters: given only what the planner promises, every
    /// moment can still speak. Filling in every fact — as the test above does —
    /// proves the corpus is well-formed, not that it is usable.
    @Test("every kind can speak using only the facts the planner guarantees")
    func everyKindSpeaksOnMinimumFacts() {
        for kind in NotificationKind.allCases {
            guard let promised = Self.guaranteed[kind] else {
                Issue.record("\(kind) has no declared guarantee"); continue
            }
            var facts = Facts()
            for fact in promised { facts[fact] = "X" }

            for register in Register.allCases {
                let options = NotificationCopy.candidates(
                    kind: kind, workload: .busy, register: register, facts: facts
                )
                #expect(!options.isEmpty,
                        "\(kind)/\(register) cannot render from \(promised.map(\.rawValue).sorted())")
            }
        }
    }

    @Test("nothing renders with a placeholder still in it")
    func rendersCleanly() {
        for template in Corpus.all {
            guard let text = NotificationCopy.render(template, facts: everyFact) else {
                Issue.record("\(template.id) would not render")
                continue
            }
            #expect(!text.title.contains("{"), "\(template.id) title")
            #expect(!text.body.contains("{"), "\(template.id) body")
        }
    }

    @Test("a template missing a fact is never offered")
    func missingFactsExcludeATemplate() {
        var facts = Facts()
        facts[.assignment] = "Bio IA"
        let options = NotificationCopy.candidates(kind: .windowNudge, workload: .busy,
                                                  register: .chaos, facts: facts)
        #expect(options.allSatisfy { $0.requires.isSubset(of: facts.present) })
    }
}

@Suite("Copy — house rules")
struct CopyHouseRuleTests {

    @Test("titles fit on a lock screen")
    func titlesFit() {
        for template in Corpus.all {
            #expect(template.title.count <= 40,
                    "\(template.id): \(template.title.count) chars")
        }
    }

    @Test("bodies fit on a lock screen")
    func bodiesFit() {
        for template in Corpus.all {
            #expect(template.body.count <= 110,
                    "\(template.id): \(template.body.count) chars")
        }
    }

    @Test("Albus is deadpan — no exclamation marks anywhere")
    func noExclamations() {
        for template in Corpus.all {
            #expect(!template.title.contains("!") && !template.body.contains("!"),
                    "\(template.id)")
        }
    }

    @Test("the high-frequency kinds have enough lines not to repeat")
    func enoughVariety() {
        for kind in [NotificationKind.morningBrief, .windowNudge] {
            for workload in [WorkloadState.calm, .busy, .cooked] {
                let options = NotificationCopy.candidates(
                    kind: kind, workload: workload, register: .chaos, facts: everyFact
                )
                #expect(options.count >= 4, "\(kind)/\(workload) has only \(options.count)")
            }
        }
    }
}

@Suite("Copy — selection")
struct CopySelectionTests {

    private let pool = Corpus.all.filter { $0.kind == .morningBrief && $0.register == .chaos }

    @Test("the same seed always picks the same line")
    func deterministic() {
        let first = NotificationCopy.pick(from: pool, recent: [], seed: 12_345)
        let second = NotificationCopy.pick(from: pool, recent: [], seed: 12_345)
        #expect(first?.id == second?.id)
    }

    @Test("different seeds reach different lines")
    func seedsSpread() {
        let picked = Set((0..<200).compactMap {
            NotificationCopy.pick(from: pool, recent: [], seed: UInt64($0) &* 2_654_435_761)?.id
        })
        #expect(picked.count >= 4, "only reached \(picked.count) of \(pool.count)")
    }

    @Test("a recently used line is skipped")
    func skipsRecent() {
        guard let first = NotificationCopy.pick(from: pool, recent: [], seed: 7) else {
            Issue.record("nothing picked"); return
        }
        let next = NotificationCopy.pick(from: pool, recent: [first.id], seed: 7)
        #expect(next?.id != first.id)
    }

    @Test("an exhausted pool still says something rather than going silent")
    func degradesGracefully() {
        let everythingUsed = pool.map(\.id)
        #expect(NotificationCopy.pick(from: pool, recent: everythingUsed, seed: 3) != nil)
    }

    @Test("an empty pool returns nothing rather than crashing")
    func emptyPool() {
        #expect(NotificationCopy.pick(from: [], recent: [], seed: 1) == nil)
    }

    @Test("the order the pool arrives in does not change the pick")
    func orderIndependent() {
        let forward = NotificationCopy.pick(from: pool, recent: [], seed: 99)
        let backward = NotificationCopy.pick(from: pool.reversed(), recent: [], seed: 99)
        #expect(forward?.id == backward?.id)
    }
}

@Suite("Stable hashing")
struct StableHashTests {

    /// The test that stops someone "simplifying" this to `hashValue`.
    ///
    /// Swift's `Hashable` is seeded per process, so a picker built on it returns
    /// a different line every launch while looking perfectly deterministic
    /// inside any single test run. Pinning a literal is the only way that
    /// substitution fails loudly.
    @Test("a fixed string always hashes to the same number")
    func pinnedString() {
        #expect(StableHash.value("albus.plan.brief.2026-05-20") == 9_888_407_286_907_534_411)
    }

    @Test("a fixed uuid always hashes to the same number")
    func pinnedUUID() {
        let uuid = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        #expect(StableHash.value(uuid, "morningBrief") == 16_237_556_764_881_547_017)
    }

    @Test("a signature does not depend on the order ids arrive in")
    func signatureIsOrderFree() {
        let a = UUID(), b = UUID(), c = UUID()
        #expect(StableHash.signature([a, b, c]) == StableHash.signature([c, a, b]))
    }

    @Test("an empty signature is empty, so it can mean 'everything fits'")
    func emptySignature() {
        #expect(StableHash.signature([UUID]()) == "")
    }

    @Test("different inputs do not collide")
    func noObviousCollisions() {
        let values = Set((0..<5_000).map { StableHash.value("albus.plan.brief.\($0)") })
        #expect(values.count == 5_000)
    }
}
