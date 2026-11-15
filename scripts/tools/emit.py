import re, importlib.util, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import capabilities as cap
spec = importlib.util.spec_from_file_location("gen", "gen.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
T, CATS, IDS = m.T, m.CATS, m.IDS

# Every tool must declare what it is for. A tool with no needs is invisible to
# the selector, which is a silent failure — it simply never gets recommended.
_names = {t[0] for t in T}
_missing = _names - set(cap.TOOL_NEEDS)
assert not _missing, f"tools with no declared needs: {sorted(_missing)}"
_extra = set(cap.TOOL_NEEDS) - _names
assert not _extra, f"needs declared for tools not in the catalogue: {sorted(_extra)}"

def swift_case(snake):
    head, *rest = snake.split("_")
    return head + "".join(w.title() for w in rest)

def ident(name):
    s = re.sub(r"[^A-Za-z0-9]+", " ", name).title().replace(" ", "")
    s = s[0].lower() + s[1:]
    if s[0].isdigit(): s = "t" + s
    return s

# A renamed tool keeps the ID `gen.IDS` gives it, so its case and its
# `logo-<id>` asset stay where they were.
ids = [IDS.get(t[0]) or ident(t[0]) for t in T]
assert len(ids) == len(set(ids)), [i for i in ids if ids.count(i) > 1]

out = ['''import Foundation
import AlbusCore

/// The tool library.
///
/// A fixed catalogue rather than anything fetched: every destination is a
/// compile-time constant, so nothing a model wrote or a student typed can
/// become a URL the app opens, and the whole list works offline.
///
/// **On logos.** A tool shows its real logo or it shows nothing. It never shows
/// a colour this app invented for it: Notion is not teal because a palette said
/// so, and a made-up brand colour is the loudest possible tell that nobody
/// checked. `ToolIcon` renders the asset named `logo-<id>` when one is bundled
/// and falls back to a neutral monogram-free placeholder otherwise — so a tool
/// carries no colour of its own, and dropping artwork in later touches no code.
///
/// Runtime favicon fetching was considered and rejected: it would tell two
/// hundred companies when a student opens this tab, cost a request per tile,
/// and leave the screen broken offline. Logos are fetched at build time by
/// `fetch_logos.py` and reviewed by hand.
enum StudyTool: String, CaseIterable, Identifiable, Sendable {
''']

for t, i in zip(T, ids):
    out.append(f"    case {i}\n")

out.append('''
    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all
''')
for key, _ in CATS:
    out.append(f"        case {key}\n")
out.append('''        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
''')
for key, label in CATS:
    out.append(f'            case .{key}: "{label}"\n')
out.append('''            }
        }
    }

    /// What a step can need doing to it.
    ///
    /// The selector reasons over these rather than over the words in a step's
    /// title, and the planner chooses one per step. Generated from
    /// `scripts/tools/capabilities.py` so the vocabulary the model is offered,
    /// the one the server validates, and the one the catalogue is tagged with
    /// cannot drift apart.
    enum Need: String, CaseIterable, Sendable {
''')

for n in cap.NEEDS:
    out.append(f'        case {swift_case(n)} = "{n}"\n')

out.append("""
        /// What to call this under a step, for a student rather than a model.
        var label: String {
            switch self {
""")
for n in cap.NEEDS:
    out.append(f'            case .{swift_case(n)}: "{cap.NEED_LABELS[n]}"\n')
out.append("""            }
        }
    }

    /// Subject areas a tool is *specifically* suited to. A tool with none suits
    /// any subject, which is the common case and deliberately so — narrowing
    /// every tool to a subject would shrink the catalogue back to the handful
    /// this selector exists to escape.
    enum Area: String, CaseIterable, Sendable {
""")
for a in cap.AREAS:
    out.append(f'        case {swift_case(a)} = "{a}"\n')

out.append("""    }

    /// What a tool costs before it does anything: `light` opens in a tab,
    /// `heavy` wants an install, an account, or a format to learn.
    enum Setup: Sendable { case light, heavy }

    /// Name, host, category, symbol, the one line explaining why you would open
    /// it, and what it is actually for. Kept in one table so a new tool is a
    /// single edit.
    ///
    /// No colour here on purpose — see the note on logos above.
    private var spec: (name: String, host: String, category: Category,
                       symbol: String, reason: String,
                       needs: [Need], areas: [Area], setup: Setup) {
        switch self {
""")

for t, i in zip(T, ids):
    name, host, cat, sym, _tint, why = t
    needs = ", ".join("." + swift_case(n) for n in cap.TOOL_NEEDS[name])
    areas = ", ".join("." + swift_case(a) for a in cap.TOOL_AREAS.get(name, []))
    setup = ".heavy" if name in cap.HEAVY_SETUP else ".light"
    out.append(
        f'        case .{i}: ("{name}", "{host}", .{cat}, "{sym}", "{why}", '
        f'[{needs}], [{areas}], {setup})\n')

out.append('''        }
    }

    var name: String { spec.name }
    var category: Category { spec.category }
    var reason: String { spec.reason }
    /// What this tool is for. Empty is impossible — the generator asserts it.
    var needs: [Need] { spec.needs }
    /// Subjects it is specifically for; empty means it suits any.
    var areas: [Area] { spec.areas }
    var setup: Setup { spec.setup }
    /// Shape-only fallback used when no real logo is bundled. Rendered in a
    /// neutral ink, never a brand colour this app guessed at.
    var symbolName: String { spec.symbol }
    /// Asset name a bundled brand logo would use.
    var logoAssetName: String { "logo-\\(rawValue)" }

    /// Shown to a student when asked where a tap will take them.
    var host: String { spec.host }

    /// Every string here is a literal this file controls, so it cannot fail —
    /// and a typo is caught by `ToolCatalogTests`, not by a student tapping a
    /// dead tile.
    var url: URL { URL(string: "https://\\(spec.host)")! }

    /// Matches a search across name, reason and category.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || reason.lowercased().contains(q)
            || category.title.lowercased().contains(q)
    }

}
''')

pathlib.Path("StudyTool.swift").write_text("".join(out))
print("emitted StudyTool.swift", len("".join(out)), "bytes,", len(T), "tools")
