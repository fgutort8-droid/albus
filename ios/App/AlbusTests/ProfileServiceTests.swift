import Foundation
import Supabase
import Testing
@testable import Albus

/// `create_course` is reached through PostgREST, which picks the function by
/// the argument names in the request body. A name the function does not
/// declare is a failed call, and the course sync only logs failures, so a drift
/// here would silently leave every new subject off the server.
@Suite("Course sync")
struct ProfileServiceTests {

    /// `public.create_course(p_display_name text, p_color_key text,
    /// p_template_code text)`, as migration 20260917120000 left it.
    private static let declared: Set<String> = ["p_display_name", "p_color_key", "p_template_code"]

    @Test("the request names only arguments create_course declares")
    func onlyDeclaredArguments() throws {
        // The encoder the Supabase client uses for RPC bodies.
        let data = try PostgrestClient.Configuration.jsonEncoder.encode(
            ProfileService.CreateCourseParams(p_display_name: "Biology",
                                              p_color_key: "red",
                                              p_template_code: nil))
        let json = try JSONSerialization.jsonObject(with: data)
        let sent = Set(try #require(json as? [String: Any]).keys)

        #expect(sent.isSubset(of: Self.declared),
                "create_course does not declare \(sent.subtracting(Self.declared).sorted())")
        // A nil template is left out, not sent as null, so the default applies.
        #expect(sent == ["p_display_name", "p_color_key"])
    }
}
