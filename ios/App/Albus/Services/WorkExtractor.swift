import Foundation
import PDFKit
import UIKit
import Vision

/// Turns a file or a photograph into text Albus can mark.
///
/// **Entirely on device, and that is the point.** The alternative — sending the
/// PDF or the photo to the model and letting it read the page — bills image
/// tokens on every upload, and a phone photograph of an essay is expensive:
/// a single page can cost more than the text it contains. PDFKit and Vision
/// cost nothing per call, work offline, and mean a student's coursework never
/// leaves their phone until it is text.
///
/// It also removes a whole failure mode. A scanned PDF is "a picture of your
/// pages" with no text layer; rather than refusing it, Albus rasterises the
/// pages and reads them the same way it reads a photo.
enum WorkExtractor {

    enum Source {
        case file(URL)
        case image(UIImage)
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "Albus couldn't open that file."
            case .empty:
                "Albus couldn't read any text — try a clearer photo, or paste it instead."
            case .tooLarge:
                "That file is too big to read on the phone."
            }
        }
    }

    /// Beyond this a PDF is a book, and rasterising it would take longer than a
    /// student will wait. The grading cap cuts in well before this anyway.
    private static let maxPages = 60
    /// 40 MB. Larger than any essay and small enough to hold in memory safely.
    private static let maxBytes = 40 * 1024 * 1024

    static func text(from source: Source) async throws -> String {
        switch source {
        case .file(let url): return try await text(fromFile: url)
        case .image(let image): return try await recognise([image])
        }
    }

    // MARK: - Files

    private static func text(fromFile url: URL) async throws -> String {
        // Files chosen through the picker live outside the sandbox until asked
        // for. Without this the read silently returns nothing.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw Failure.tooLarge }

        if url.pathExtension.lowercased() == "pdf" {
            return try await text(fromPDF: url)
        }

        // Plain text, markdown, rtf-as-text and anything else that is really
        // just characters. Word and Pages files are zip containers and are not
        // handled — the student is told to export or paste rather than being
        // given a page of XML to look at.
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
        else { throw Failure.unreadable }

        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw Failure.empty }
        return cleaned
    }

    private static func text(fromPDF url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
        guard document.pageCount <= maxPages else { throw Failure.tooLarge }

        // The cheap path: a PDF exported from a word processor already carries
        // its text, and reading it costs nothing.
        if let embedded = document.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !embedded.isEmpty {
            return embedded
        }

        // No text layer — a scan or an export-as-image. Rasterise and read.
        var images: [UIImage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 2x: enough for Vision to resolve body text, without producing a
            // bitmap so large that a sixty-page document exhausts memory.
            let scale: CGFloat = 2
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: bounds.width * scale, height: bounds.height * scale)
            )
            images.append(renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: context.format.bounds.size))
                context.cgContext.translateBy(x: 0, y: bounds.height * scale)
                context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: context.cgContext)
            })
        }
        return try await recognise(images)
    }

    // MARK: - Vision

    /// Reads printed and handwritten text off images, in page order.
    ///
    /// `.accurate` rather than `.fast`: this runs once per upload and the cost
    /// of a misread word is a mark against a sentence the student never wrote.
    private static func recognise(_ images: [UIImage]) async throws -> String {
        var pages: [String] = []

        for image in images {
            guard let cgImage = image.cgImage else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])

            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            if !lines.isEmpty { pages.append(lines.joined(separator: "\n")) }
        }

        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        return text
    }
}
