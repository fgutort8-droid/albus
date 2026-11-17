import Foundation
import Testing

/// The Grader's photo rows open the photo library (`photosPicker`). The app has
/// no camera path at all. One row was labelled "Take a photo" with a camera icon
/// and another "Photograph a rubric", so a student, or an App Review tester,
/// tapped expecting the camera and got their library. Found in the
/// pre-submission audit of November 2026, finding A13
/// (`docs/audit/2026-11-pre-submission.md`).
///
/// The labels are string literals in a SwiftUI view, so this reads the source
/// file itself. The tests run on the same Mac as the source, in the simulator.
@Suite("Grader photo rows")
struct GraderPhotoRowTests {

    /// `ios/App/Albus`, found from this file's own path (`ios/App/AlbusTests`).
    private static var appSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Albus")
    }

    /// The title and icon of every Grader row that opens a photo picker.
    private static func photoRows() throws -> [(title: String, icon: String)] {
        let url = appSources.appendingPathComponent("Screens/GraderScreen.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let pattern = #"importRow\("([^"]+)",\s*"[^"]*",\s*"([^"]+)"\)\s*\{\s*(?:workPhotoPicking|rubricPhotoPicking) = true"#
        let regex = try NSRegularExpression(pattern: pattern)
        let all = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: all).map { match in
            (title: String(source[Range(match.range(at: 1), in: source)!]),
             icon: String(source[Range(match.range(at: 2), in: source)!]))
        }
    }

    @Test("both photo rows are found, so the checks below cannot pass by matching nothing")
    func bothRowsAreFound() throws {
        #expect(try Self.photoRows().count == 2)
    }

    @Test("no photo row promises a camera, because each opens the photo library")
    func noRowPromisesACamera() throws {
        for row in try Self.photoRows() {
            let title = row.title.lowercased()
            #expect(!title.contains("take a photo") && !title.contains("photograph"),
                    "\"\(row.title)\" reads as a camera, but the row opens the photo library")
            #expect(!row.icon.hasPrefix("camera"),
                    "\"\(row.title)\" shows the camera icon \(row.icon), but opens the photo library")
        }
    }

    @Test("the app has no camera path, which is what keeps the rows above honest")
    func theAppHasNoCameraPath() throws {
        let markers = ["UIImagePickerController", "AVCaptureSession", "AVCaptureDevice", "sourceType"]
        let files = try #require(FileManager.default.enumerator(
            at: Self.appSources, includingPropertiesForKeys: nil))
        var found: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for marker in markers where text.contains(marker) {
                found.append("\(url.lastPathComponent): \(marker)")
            }
        }
        #expect(found.isEmpty,
                "A camera path now exists, so review the Grader's photo labels and the camera permission text: \(found)")
    }
}
