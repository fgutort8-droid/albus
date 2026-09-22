import Foundation
import Supabase
import AlbusCore

/// Creates the student's subjects on the server.
///
/// A subject exists on the device first. The server copy is what lets
/// `breakdown` attach an assignment to it, so it is created as soon as the
/// student adds the subject.
struct ProfileService {

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// The arguments of `create_course(p_display_name, p_color_key,
    /// p_template_code)`.
    ///
    /// PostgREST chooses the function by the names in the request body, so a
    /// name the function does not declare makes the call fail, and this sync
    /// swallows that failure. `ProfileServiceTests` pins these names. A nil
    /// value is left out of the body entirely, and the function's default
    /// applies.
    struct CreateCourseParams: Encodable {
        let p_display_name: String
        let p_color_key: String
        /// Nothing on the device chooses a template, so this is always nil.
        let p_template_code: String?
    }

    /// Creates a subject server-side and returns its id.
    ///
    /// Through an RPC rather than a plain insert. `user_id` is set from the
    /// verified session inside the function rather than passed in, and RLS
    /// would reject anything else regardless — the row cannot be attributed to
    /// another student even if this code were wrong. The function also holds
    /// the per-student subject limit.
    func createCourse(displayName: String, colorKey: String) async -> UUID? {
        guard let client else { return nil }

        do {
            return try await client.rpc(
                "create_course",
                params: CreateCourseParams(p_display_name: displayName,
                                           p_color_key: colorKey,
                                           p_template_code: nil)
            )
            .execute()
            .value
        } catch {
            print("[Albus] course sync failed: \(error)")
            return nil
        }
    }
}
