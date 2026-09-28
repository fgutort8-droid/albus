import Foundation
import SwiftData
import UIKit

/// Marking that outlives the screen that asked for it.
///
/// A marking takes half a minute or more. It used to run inside the grader
/// screen, so a student either watched a spinner or lost track of it: the
/// result was saved when it arrived, but nothing said so. The job lives here
/// instead. The student can leave, and when it is done they hear about it: a
/// banner in the app, or a notification when Albus is in the background. One
/// tap opens the result.
///
/// It also covers the answer that never comes back. The server saves every
/// grading it produces, so when the connection drops or times out after the
/// work was sent, this looks for the saved grading rather than reporting a
/// failure for work that was marked. The work is never sent twice: a second
/// send could start a second, paid marking while the first is still running.
@Observable
@MainActor
final class MarkingCoordinator {

    struct Job: Equatable {
        let title: String?
        let wordCount: Int
        let isBlind: Bool
        let startedAt: Date
    }

    enum Outcome: Equatable {
        /// Stored, as the local `Grading.id`.
        case marked(UUID)
        case failed(GradingService.Failure)
        /// The account was deleted while the work was being marked. Nothing
        /// is stored or announced.
        case discarded
    }

    /// The marking under way, if any.
    private(set) var current: Job?
    /// How the last marking ended.
    private(set) var lastOutcome: Outcome?
    /// A finished marking the student has not opened yet. Drives the banner.
    private(set) var ready: UUID?
    /// A grader screen has the marking on screen, so its result needs no
    /// banner: the screen shows it.
    var isWatched = false

    private let service: GradingService
    private let announcer: any MarkingAnnouncer
    /// How long after sending the work to keep looking for a grading whose
    /// answer was lost. Longer than the server can spend marking (its
    /// functions stop after 150 s), so a grading still being written is found.
    private let recoveryWindow: TimeInterval
    private let pollInterval: Duration
    /// The device clock and the server's need not agree; a saved grading is
    /// looked for from a little before the work was sent.
    private let clockSkew: TimeInterval = 120

    init(service: GradingService = GradingService(),
         announcer: any MarkingAnnouncer = SystemMarkingAnnouncer(),
         recoveryWindow: TimeInterval = 160,
         pollInterval: Duration = .seconds(5)) {
        self.service = service
        self.announcer = announcer
        self.recoveryWindow = recoveryWindow
        self.pollInterval = pollInterval
    }

    /// Marks the work, stores the result, and says so if nobody is watching.
    ///
    /// - Parameter mayStore: false once the account that asked has gone, so a
    ///   late answer is not written into the store of whoever comes next.
    func mark(work: String, rubricID: UUID?, assignment: Assignment?,
              presentation: String?, title: String?, isBlind: Bool,
              context: ModelContext,
              mayStore: @escaping @MainActor () -> Bool) async -> Outcome {
        let job = Job(title: title,
                      wordCount: work.split(whereSeparator: \.isWhitespace).count,
                      isBlind: isBlind, startedAt: .now)
        current = job
        lastOutcome = nil
        // Room to finish if the student switches apps: iOS allows about
        // thirty seconds more. Past that the app is suspended, the answer is
        // lost, and the recovery below finds it once they are back.
        let background = BackgroundTime()
        background.begin()
        defer {
            background.end()
            current = nil
        }

        let outcome: Outcome
        do {
            let marked = try await service.grade(work: work, rubricID: rubricID,
                                                 assignmentID: assignment?.remoteID,
                                                 presentation: presentation, title: title)
            outcome = store(marked, inputChars: work.count, fallbackTitle: title,
                            assignment: assignment, context: context, mayStore: mayStore)
        } catch GradingService.Failure.answerLost {
            outcome = await recover(job, inputChars: work.count, assignment: assignment,
                                    context: context, mayStore: mayStore)
        } catch let failure as GradingService.Failure {
            outcome = .failed(failure)
        } catch {
            outcome = .failed(.unavailable)
        }

        lastOutcome = outcome
        if case .marked(let id) = outcome {
            announce(id, title: title)
        }
        return outcome
    }

    /// The banner has been acted on, or the result opened another way.
    func markSeen() {
        ready = nil
    }

    // MARK: - Private

    private func store(_ marked: GradingService.Result, inputChars: Int, fallbackTitle: String?,
                       assignment: Assignment?, context: ModelContext,
                       mayStore: @MainActor () -> Bool) -> Outcome {
        guard mayStore() else { return .discarded }
        let grading = Grading(
            remoteID: marked.id,
            model: marked.model,
            inputChars: inputChars,
            overallMarks: marked.overallMarks,
            totalMarks: marked.totalMarks,
            gradeLabel: marked.gradeLabel,
            gradeNote: marked.gradeNote,
            // The server's title wins: it resolves the assignment's real name
            // when there is one, and echoing back what we sent would label a
            // grading with a filename the student has forgotten.
            workTitle: marked.title ?? fallbackTitle,
            criteria: marked.criteria.map {
                GradedCriterion(code: $0.code, name: $0.name, marks: $0.marks,
                                outOf: $0.outOf, comment: $0.comment,
                                quote: $0.quote, whereFound: $0.whereFound)
            },
            feedback: marked.feedback,
            improvements: marked.improvements.map {
                GradedImprovement(change: $0.change, why: $0.why)
            },
            basis: marked.basis,
            assignment: assignment
        )
        context.insert(grading)
        try? context.save()
        return .marked(grading.id)
    }

    /// Looks for the grading the server saved for a job whose answer was lost,
    /// until the server can no longer be working on it.
    private func recover(_ job: Job, inputChars: Int, assignment: Assignment?,
                         context: ModelContext,
                         mayStore: @MainActor () -> Bool) async -> Outcome {
        let giveUpAt = job.startedAt.addingTimeInterval(recoveryWindow)
        let since = job.startedAt.addingTimeInterval(-clockSkew)
        var offline = false
        // Always at least one look: a student back from minutes in another
        // app arrives after the window, and their marking is most likely saved.
        while true {
            do {
                if let saved = try await service.recover(since: since),
                   !isStored(remoteID: saved.id, context: context) {
                    return store(saved, inputChars: inputChars, fallbackTitle: job.title,
                                 assignment: assignment, context: context, mayStore: mayStore)
                }
                offline = false
            } catch let error as URLError where error.code == .notConnectedToInternet {
                offline = true
            } catch {
                offline = false
            }
            if Date.now >= giveUpAt { break }
            try? await Task.sleep(for: pollInterval)
        }
        return .failed(offline ? .offline : .unavailable)
    }

    /// Whether a grading the server holds is already on this phone: an earlier
    /// one, found before the one being looked for has been saved.
    private func isStored(remoteID: UUID, context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<Grading>(predicate: #Predicate { $0.remoteID == remoteID })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    private func announce(_ id: UUID, title: String?) {
        // A student who switched apps hears about it even if the grader was
        // open when they left.
        if !announcer.isAppActive {
            announcer.notifyMarkingReady(gradingID: id, title: title)
        }
        if !isWatched {
            ready = id
        }
    }
}

/// How a finished marking reaches a student who is not looking at it.
@MainActor
protocol MarkingAnnouncer {
    /// True while Albus is on screen.
    var isAppActive: Bool { get }
    /// A notification, for a marking that finished while Albus was in the
    /// background.
    func notifyMarkingReady(gradingID: UUID, title: String?)
}

struct SystemMarkingAnnouncer: MarkingAnnouncer {
    var isAppActive: Bool { UIApplication.shared.applicationState == .active }

    func notifyMarkingReady(gradingID: UUID, title: String?) {
        NotificationScheduler().markingReady(gradingID: gradingID, title: title)
    }
}

/// The extra time iOS allows an app to finish something after the student
/// switches away.
@MainActor
private final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Albus marking") { [weak self] in
            // Out of time: iOS suspends the app now. The marking is not lost;
            // the dropped connection sends the coordinator looking for it.
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
