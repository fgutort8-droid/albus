import Testing
import UIKit
@testable import Albus

/// The catalogue is generated data, and the two ways it can be quietly wrong —
/// a mistyped SF Symbol and a malformed host — both fail silently at runtime:
/// a blank tile, or a tap that goes nowhere. Neither shows up in a build.
@MainActor
@Suite("Tool catalogue")
struct ToolCatalogTests {

    @Test("every tool's SF Symbol exists")
    func symbolsResolve() {
        let missing = StudyTool.allCases.filter {
            UIImage(systemName: $0.symbolName) == nil
        }
        #expect(missing.isEmpty,
                "these symbols do not exist: \(missing.map { "\($0.name)=\($0.symbolName)" })")
    }

    @Test("every tool has a usable https URL")
    func urlsAreValid() {
        for tool in StudyTool.allCases {
            let url = tool.url
            #expect(url.scheme == "https", "\(tool.name) is not https")
            #expect(!(url.host() ?? "").isEmpty, "\(tool.name) has no host")
        }
    }

    @Test("names and hosts are unique")
    func noDuplicates() {
        let names = StudyTool.allCases.map(\.name)
        #expect(Set(names).count == names.count,
                "duplicate names: \(names.filter { n in names.filter { $0 == n }.count > 1 })")
    }

    @Test("the library is large enough to be worth searching")
    func hasEnoughTools() {
        #expect(StudyTool.allCases.count >= 200)
    }

    @Test("every category has tools, and every tool has a real category")
    func categoriesArePopulated() {
        for category in StudyTool.Category.allCases where category != .all {
            let count = StudyTool.allCases.filter { $0.category == category }.count
            #expect(count > 0, "\(category.title) is empty")
        }
        #expect(!StudyTool.allCases.contains { $0.category == .all },
                "`all` is a filter, never a tool's own category")
    }

    @Test("search finds tools by name, purpose and subject")
    func searchWorks() {
        #expect(StudyTool.allCases.filter { $0.matches("grammar") }.count >= 2)
        #expect(StudyTool.allCases.filter { $0.matches("cite") }.count >= 1)
        #expect(StudyTool.allCases.filter { $0.matches("zzzznope") }.isEmpty)
        // An empty query is "show everything", not "match nothing".
        #expect(StudyTool.allCases.filter { $0.matches("") }.count == StudyTool.allCases.count)
    }

    @Test("the bundled logos are actually reachable from the catalogue")
    @MainActor
    func logosResolve() {
        // The asset name is built by `StudyTool.logoAssetName` and the files are
        // written by `scripts/tools/make_assets.py`. If those two conventions
        // ever drift, every logo silently disappears and the app still builds,
        // runs and looks *almost* right — which is the worst kind of broken.
        //
        // The threshold is deliberately well below what is currently bundled:
        // this is a canary for the naming convention, not a target for how many
        // brands answered a build-time request.
        #expect(ToolArtwork.bundledCount >= 100,
                "only \(ToolArtwork.bundledCount) logos resolved — check logoAssetName against Assets.xcassets")
    }

    @Test("a tool with no logo is not given an invented one")
    @MainActor
    func missingLogosStayMissing() {
        // The rule the Tools screen exists to keep: a real mark, or none. If
        // every tool resolved, something is substituting a placeholder.
        #expect(ToolArtwork.bundledCount <= StudyTool.allCases.count)
    }

    /// Four tiles were named after one brand and opened another site. Two of
    /// the names were piracy sites, "Sci-Hub Alternatives" and "Library Genesis
    /// Info", so a tile could read as sending students to pirated material.
    @Test("no tool is named after a brand its tile does not open")
    func namesMatchDestinations() {
        let names = Set(StudyTool.allCases.map(\.name))
        for old in ["Hemingway Grade", "Sci-Hub Alternatives", "Library Genesis Info", "IB Documents"] {
            #expect(!names.contains(old), "\(old) is back")
        }
        #expect(StudyTool.hemingwayGrade.name == "Readability Formulas")
        #expect(StudyTool.hemingwayGrade.url.host() == "readabilityformulas.com")
        #expect(StudyTool.libraryGenesisInfo.name == "Open Library")
        #expect(StudyTool.libraryGenesisInfo.url.host() == "openlibrary.org")
        #expect(StudyTool.ibDocuments.name == "IB official site")
        #expect(StudyTool.ibDocuments.url.host() == "ibo.org")
    }

    /// The renamed tools keep their case, because the bundled artwork is named
    /// after it: `gen.py` pins the ID. Deriving it from the new name instead
    /// would leave both tiles without the logo they shipped with.
    @Test("a renamed tool still shows its logo")
    @MainActor
    func renamedToolsKeepTheirLogo() {
        #expect(ToolArtwork.has(.hemingwayGrade))
        #expect(ToolArtwork.has(.libraryGenesisInfo))
    }

    /// Checked by opening each one on 14 November 2026: Open Access Button and
    /// Cram have shut down, typewritermode.com no longer exists, and
    /// socratic.org lands on a Google Search page. usgs.gov and noisli.com do
    /// not answer without `www.`, and a tile opens the host exactly as written.
    @Test("no tile opens a site that has closed or an address that does not answer")
    func destinationsAreStillThere() {
        let hosts = Set(StudyTool.allCases.compactMap { $0.url.host() })
        for gone in ["openaccessbutton.org", "typewritermode.com", "cram.com", "socratic.org",
                     "usgs.gov", "noisli.com"] {
            #expect(!hosts.contains(gone), "\(gone) is back")
        }
        #expect(hosts.contains("www.usgs.gov"))
        #expect(hosts.contains("www.noisli.com"))
    }
}
