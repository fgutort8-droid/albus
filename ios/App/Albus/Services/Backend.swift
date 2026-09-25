import Foundation
import Supabase

/// The app's single connection to Supabase.
///
/// Configuration comes from the build's Info.plist, populated from
/// `Config.xcconfig` — which is gitignored. The publishable key is designed to
/// be public (RLS is what protects data, not the key), but keeping it out of
/// source means it can be rotated without a code change.
enum Backend {

    enum ConfigError: LocalizedError {
        case missing(String)
        var errorDescription: String? {
            switch self {
            case .missing(let k):
                "\(k) is not set. Copy App/Config.example.xcconfig to Config.xcconfig and fill it in."
            }
        }
    }

    /// `nil` when the build has no real configuration.
    ///
    /// This used to `fatalError`, which crashed the app on launch — including
    /// in CI, where placeholder values are expected and the app is the test
    /// host. Crashing is also the wrong product behaviour: an app that says
    /// "not signed in: not configured" is strictly better than one that dies
    /// before drawing a frame.
    static let shared: SupabaseClient? = {
        do {
            return try makeClient()
        } catch {
            print("[Albus] \(error.localizedDescription)")
            return nil
        }
    }()

    static let authStorage = ResilientAuthStorage()

    private static func makeClient() throws -> SupabaseClient {
        let info = Bundle.main.infoDictionary ?? [:]

        guard let raw = info["SUPABASE_URL"] as? String,
              !raw.isEmpty, !raw.contains("YOUR_PROJECT_REF"),
              let url = URL(string: raw)
        else { throw ConfigError.missing("SUPABASE_URL") }

        guard let key = info["SUPABASE_PUBLISHABLE_KEY"] as? String,
              !key.isEmpty, !key.hasSuffix("xxxxxxxxxxxxxxxxxxxx")
        else { throw ConfigError.missing("SUPABASE_PUBLISHABLE_KEY") }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: .init(
                // Marking a full essay on Opus legitimately runs past thirty
                // seconds, and the default sixty is close enough to that for a
                // slow call to be abandoned while the server is still happily
                // working on it. The student then sees a failure for work that
                // *was* marked, having spent a grading to see it.
                //
                // Applied to the whole client rather than one call: the same
                // headroom is harmless everywhere else, and a per-call timeout
                // is not something this SDK exposes.
                auth: .init(
                    // Credentials are persisted only in Keychain.
                    storage: authStorage,
                    autoRefreshToken: true
                ),
                global: .init(session: Self.patientSession)
            )
        )
    }

    /// A session that waits as long as a grading actually takes.
    private static let patientSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 240
        return URLSession(configuration: configuration)
    }()
}
