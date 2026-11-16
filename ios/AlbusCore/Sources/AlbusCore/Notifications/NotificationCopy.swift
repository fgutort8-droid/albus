import Foundation

/// How sharp Albus is allowed to be.
public enum Register: String, Sendable, Hashable, CaseIterable {
    /// Deadpan, absurdist, occasionally aware it is a cactus.
    case chaos
    /// The app's own dry voice. What `seriousMode` selects, and the only
    /// register available for work the student has already missed.
    case plain
}

/// A value a line can interpolate.
public enum Fact: String, Sendable, Hashable, CaseIterable {
    case assignment
    case step
    case days
    case hours
    case steps
    case minutes
    case weekMinutes
    case count
    case blockTime
    case lateBy
}

/// One line Albus might say.
public struct CopyTemplate: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: NotificationKind
    /// `nil` means the line works at any workload.
    public let workload: WorkloadState?
    public let register: Register
    public let title: String
    public let body: String

    public init(_ id: String, _ kind: NotificationKind, _ workload: WorkloadState?,
                _ register: Register, _ title: String, _ body: String) {
        self.id = id
        self.kind = kind
        self.workload = workload
        self.register = register
        self.title = title
        self.body = body
    }

    /// Which facts this line cannot be rendered without.
    ///
    /// **Derived from the text, never declared.** A hand-written list drifts
    /// the moment somebody edits a line, and the failure is silent: the
    /// template renders with a literal `{step}` on a student's lock screen.
    public var requires: Set<Fact> {
        Set(Self.placeholders(in: title) + Self.placeholders(in: body))
    }

    static func placeholders(in text: String) -> [Fact] {
        var found: [Fact] = []
        var current: String?
        for character in text {
            if character == "{" { current = "" }
            else if character == "}" {
                if let name = current, let fact = Fact(rawValue: name) { found.append(fact) }
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return found
    }
}

/// The real numbers a line is filled with.
public struct Facts: Sendable, Equatable {
    private var values: [Fact: String]

    public init(_ values: [Fact: String] = [:]) { self.values = values }

    public subscript(fact: Fact) -> String? {
        get { values[fact] }
        set { values[fact] = newValue }
    }

    public var present: Set<Fact> { Set(values.keys) }
}

/// Chooses and fills a line.
public enum NotificationCopy {

    /// Candidate lines for a moment, narrowest first.
    ///
    /// A line tagged with a workload is preferred over a general one, because
    /// the specific line is the reason the workload exists. General lines are
    /// the fallback that guarantees every cell can produce something.
    public static func candidates(kind: NotificationKind,
                                  workload: WorkloadState,
                                  register: Register,
                                  facts: Facts,
                                  corpus: [CopyTemplate] = Corpus.all) -> [CopyTemplate] {
        let effective = effectiveRegister(kind: kind, requested: register)
        let usable = corpus.filter {
            $0.kind == kind
                && $0.register == effective
                && $0.requires.isSubset(of: facts.present)
        }
        let specific = usable.filter { $0.workload == workload }
        return specific.isEmpty ? usable.filter { $0.workload == nil } : specific
    }

    /// The register a kind is actually allowed, whatever was asked for.
    ///
    /// Two gates, and the second one cannot be turned off: the student's
    /// `seriousMode`, and the kind's own `allowsChaos`.
    public static func effectiveRegister(kind: NotificationKind,
                                         requested: Register) -> Register {
        kind.allowsChaos ? requested : .plain
    }

    /// Picks one line, deterministically.
    ///
    /// `seed` must come from data — see `StableHash`. Recent lines are filtered
    /// out, but never so many that nothing is left: a small corpus that has all
    /// been used recently still says something rather than going silent.
    public static func pick(from candidates: [CopyTemplate],
                            recent: [String],
                            seed: UInt64) -> CopyTemplate? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else { return candidates[0] }

        let recentSet = Set(recent)
        let fresh = candidates.filter { !recentSet.contains($0.id) }
        let pool = fresh.isEmpty ? candidates : fresh

        // Sorted so the pool's order cannot depend on how the corpus was
        // filtered, which would make the same seed pick different lines.
        let ordered = pool.sorted { $0.id < $1.id }
        return ordered[Int(seed % UInt64(ordered.count))]
    }

    /// Fills a line's placeholders. Nil if any fact is missing, which the
    /// candidate filter should already have prevented.
    public static func render(_ template: CopyTemplate,
                              facts: Facts) -> (title: String, body: String)? {
        guard let title = fill(plain(template.title), facts),
              let body = fill(plain(template.body), facts) else { return nil }
        return (title, body)
    }

    /// A line without the bold markers it was written with.
    ///
    /// Thirty lines mark the thing to do next as `**{step}**`. A notification
    /// shows its text exactly as given, so on a lock screen that read
    /// "**Outline the method** is where you start", asterisks and all. Removed
    /// where every line is rendered, so the text that is planned, compared and
    /// scheduled is the text that is shown.
    ///
    /// From the line, before the facts go in, and never from the result: a
    /// step a student named "Evaluate 2**3" must not arrive as "Evaluate 23".
    static func plain(_ line: String) -> String {
        line.replacingOccurrences(of: "**", with: "")
    }

    private static func fill(_ text: String, _ facts: Facts) -> String? {
        var result = text
        for fact in CopyTemplate.placeholders(in: text) {
            guard let value = facts[fact] else { return nil }
            result = result.replacingOccurrences(of: "{\(fact.rawValue)}", with: value)
        }
        return result
    }
}
