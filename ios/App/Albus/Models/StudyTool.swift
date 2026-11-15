import Foundation
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
    case claude
    case chatgpt
    case perplexityPro
    case notebooklm
    case gemini
    case consensus
    case elicit
    case scite
    case grammarly
    case hemingwayEditor
    case prowritingaid
    case languagetool
    case quillbot
    case thesaurusCom
    case merriamWebster
    case oxfordLearnerS
    case purdueOwl
    case notion
    case obsidian
    case googleDocs
    case overleaf
    case scrivener
    case ulysses
    case zotero
    case mendeley
    case endnote
    case citationMachine
    case zoterobib
    case scribbr
    case hemingwayGrade
    case wordcounter
    case onelook
    case googleScholar
    case jstor
    case pubmed
    case arxiv
    case semanticScholar
    case connectedPapers
    case researchgate
    case core
    case doaj
    case unpaywall
    case internetArchive
    case projectGutenberg
    case perplexity
    case wikipedia
    case britannica
    case ourWorldInData
    case statista
    case worldBankData
    case unData
    case eurostat
    case googleDatasetSearch
    case libraryGenesisInfo
    case hathitrust
    case jstorDaily
    case nature
    case science
    case ssrn
    case philpapers
    case historicalAtlas
    case wolframAlpha
    case symbolab
    case desmos
    case geogebra
    case photomath
    case mathway
    case khanAcademy
    case brilliant
    case paulSNotes
    case t3Blue1Brown
    case integralCalculator
    case derivativeCalculator
    case matrixCalculator
    case statisticsKingdom
    case desmosMatrix
    case sagemath
    case numbas
    case projectEuler
    case oeis
    case mathigon
    case phetSimulations
    case chemspider
    case pubchem
    case periodicTable
    case biorender
    case proteinDataBank
    case nasaEarthdata
    case stellariumWeb
    case physicsClassroom
    case hyperphysics
    case anatomyAtlas
    case geneticsHomeRef
    case climateData
    case usgs
    case encyclopediaOfLife
    case foldit
    case labster
    case concordConsortium
    case github
    case replit
    case stackOverflow
    case mdnWebDocs
    case w3Schools
    case leetcode
    case hackerrank
    case codecademy
    case freecodecamp
    case exercism
    case regex101
    case jsonFormatter
    case compilerExplorer
    case devdocs
    case codepen
    case jupyter
    case googleColab
    case kaggle
    case pythonDocs
    case swiftDocs
    case visualStudioCode
    case gitDocs
    case deepl
    case linguee
    case googleTranslate
    case wordreference
    case duolingo
    case anki
    case memrise
    case conjuguemos
    case reversoContext
    case forvo
    case tatoeba
    case lang8Hinative
    case clozemaster
    case readlang
    case forest
    case pomofocus
    case togglTrack
    case coldTurkey
    case freedom
    case noisli
    case brainFm
    case rainyMood
    case lofiGirl
    case focusmate
    case studyTogether
    case habitica
    case streaks
    case sleepCycle
    case quizlet
    case ankiWeb
    case remnote
    case brainscape
    case knowt
    case goodnotes
    case notability
    case onenote
    case evernote
    case milanote
    case miro
    case excalidraw
    case whimsical
    case xmind
    case coggle
    case todoist
    case ticktick
    case googleCalendar
    case trello
    case canva
    case googleSlides
    case beautifulAi
    case prezi
    case pitch
    case unsplash
    case pexels
    case theNounProject
    case flaticon
    case coolors
    case googleFonts
    case removeBg
    case figma
    case loom
    case obsStudio
    case descript
    case audacity
    case davinciResolve
    case datawrapper
    case flourish
    case saveMyExams
    case physicsMathsTutor
    case revisionWorld
    case senecaLearning
    case bbcBitesize
    case crashcourse
    case khanAcademySat
    case collegeBoard
    case ibDocuments
    case quizizz
    case kahoot
    case wooclap
    case cheggStudy
    case courseHero
    case studocu
    case sparknotes
    case litcharts
    case shmoop
    case markedByTeachers
    case headspace
    case calm
    case insightTimer
    case finch
    case daylio
    case stretchly
    case fLux
    case waterReminder
    case nikeTraining
    case yogaWithAdriene
    case t7Cups
    case studentMinds
    case sleepytiMe
    case myfitnesspal

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case all
        case ai
        case writing
        case research
        case math
        case science
        case coding
        case languages
        case focus
        case memory
        case presenting
        case revision
        case wellbeing
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .ai: "AI help"
            case .writing: "Writing"
            case .research: "Research"
            case .math: "Maths"
            case .science: "Science"
            case .coding: "Coding"
            case .languages: "Languages"
            case .focus: "Focus"
            case .memory: "Notes & memory"
            case .presenting: "Presenting"
            case .revision: "Revision"
            case .wellbeing: "Wellbeing"
            }
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
        case sourceResearch = "source_research"
        case reading = "reading"
        case noteTaking = "note_taking"
        case outlining = "outlining"
        case drafting = "drafting"
        case editing = "editing"
        case proofreading = "proofreading"
        case citation = "citation"
        case feedback = "feedback"
        case workedExamples = "worked_examples"
        case problemPractice = "problem_practice"
        case errorAnalysis = "error_analysis"
        case computation = "computation"
        case graphing = "graphing"
        case dataAnalysis = "data_analysis"
        case simulation = "simulation"
        case diagramming = "diagramming"
        case translation = "translation"
        case vocabulary = "vocabulary"
        case listeningSpeaking = "listening_speaking"
        case memorisation = "memorisation"
        case spacedPractice = "spaced_practice"
        case selfTesting = "self_testing"
        case coding = "coding"
        case debugging = "debugging"
        case presentation = "presentation"
        case design = "design"
        case planning = "planning"
        case focus = "focus"
        case wellbeing = "wellbeing"

        /// What to call this under a step, for a student rather than a model.
        var label: String {
            switch self {
            case .sourceResearch: "Finding sources"
            case .reading: "Reading"
            case .noteTaking: "Taking notes"
            case .outlining: "Outlining"
            case .drafting: "Drafting"
            case .editing: "Editing"
            case .proofreading: "Proofreading"
            case .citation: "Citing"
            case .feedback: "Getting feedback"
            case .workedExamples: "Seeing it worked through"
            case .problemPractice: "Practising problems"
            case .errorAnalysis: "Checking your working"
            case .computation: "Calculating"
            case .graphing: "Graphing"
            case .dataAnalysis: "Analysing data"
            case .simulation: "Running it virtually"
            case .diagramming: "Diagramming"
            case .translation: "Translating"
            case .vocabulary: "Vocabulary"
            case .listeningSpeaking: "Listening and speaking"
            case .memorisation: "Memorising"
            case .spacedPractice: "Spaced practice"
            case .selfTesting: "Testing yourself"
            case .coding: "Writing code"
            case .debugging: "Debugging"
            case .presentation: "Presenting"
            case .design: "Design"
            case .planning: "Planning"
            case .focus: "Staying focused"
            case .wellbeing: "Looking after yourself"
            }
        }
    }

    /// Subject areas a tool is *specifically* suited to. A tool with none suits
    /// any subject, which is the common case and deliberately so — narrowing
    /// every tool to a subject would shrink the catalogue back to the handful
    /// this selector exists to escape.
    enum Area: String, CaseIterable, Sendable {
        case humanities = "humanities"
        case literature = "literature"
        case socialScience = "social_science"
        case biology = "biology"
        case chemistry = "chemistry"
        case physics = "physics"
        case earthScience = "earth_science"
        case maths = "maths"
        case computing = "computing"
        case languages = "languages"
        case arts = "arts"
    }

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
        case .claude: ("Claude", "claude.ai", .ai, "sparkles", "Think a problem through out loud", [.feedback, .outlining, .errorAnalysis], [], .light)
        case .chatgpt: ("ChatGPT", "chat.openai.com", .ai, "bubble.left.and.text.bubble.right", "Explains, drafts, and argues back", [.feedback, .outlining, .errorAnalysis], [], .light)
        case .perplexityPro: ("Perplexity Pro", "perplexity.ai", .ai, "sparkle.magnifyingglass", "Answers that cite their sources", [.sourceResearch, .reading], [], .light)
        case .notebooklm: ("NotebookLM", "notebooklm.google.com", .ai, "book.and.wrench", "Asks questions of your own notes", [.reading, .noteTaking, .selfTesting], [], .light)
        case .gemini: ("Gemini", "gemini.google.com", .ai, "diamond", "Google's assistant, in your docs", [.feedback, .drafting], [], .light)
        case .consensus: ("Consensus", "consensus.app", .ai, "checkmark.message", "What the papers actually conclude", [.sourceResearch], [], .light)
        case .elicit: ("Elicit", "elicit.com", .ai, "tray.2", "Literature review, automated", [.sourceResearch], [], .light)
        case .scite: ("Scite", "scite.ai", .ai, "quote.bubble.fill", "Shows who disputes a citation", [.sourceResearch, .citation], [], .light)
        case .grammarly: ("Grammarly", "grammarly.com", .writing, "checkmark.bubble", "Grammar and clarity checks", [.proofreading, .editing], [], .light)
        case .hemingwayEditor: ("Hemingway Editor", "hemingwayapp.com", .writing, "scissors", "Cuts sentences down to size", [.editing], [], .light)
        case .prowritingaid: ("ProWritingAid", "prowritingaid.com", .writing, "text.magnifyingglass", "Style report on a long draft", [.editing, .proofreading], [], .light)
        case .languagetool: ("LanguageTool", "languagetool.org", .writing, "abc", "Grammar in 25+ languages", [.proofreading], [], .light)
        case .quillbot: ("Quillbot", "quillbot.com", .writing, "arrow.2.squarepath", "Rephrase a sentence you're stuck on", [.editing], [], .light)
        case .thesaurusCom: ("Thesaurus.com", "thesaurus.com", .writing, "book.closed", "The word on the tip of your tongue", [.drafting], [], .light)
        case .merriamWebster: ("Merriam-Webster", "merriam-webster.com", .writing, "character.book.closed", "Definitions with real citations", [.vocabulary, .drafting], [], .light)
        case .oxfordLearnerS: ("Oxford Learner's", "oxfordlearnersdictionaries.com", .writing, "text.book.closed", "Definitions built for learners", [.vocabulary], [], .light)
        case .purdueOwl: ("Purdue OWL", "owl.purdue.edu", .writing, "graduationcap", "The citation rules, explained", [.citation], [], .light)
        case .notion: ("Notion", "notion.so", .writing, "square.stack.3d.up", "Notes, docs and databases in one", [.noteTaking, .planning, .outlining], [], .heavy)
        case .obsidian: ("Obsidian", "obsidian.md", .writing, "link", "Notes that link to each other", [.noteTaking, .outlining], [], .heavy)
        case .googleDocs: ("Google Docs", "docs.google.com", .writing, "doc.text", "Write and share in the browser", [.drafting], [], .light)
        case .overleaf: ("Overleaf", "overleaf.com", .writing, "function", "LaTeX without installing LaTeX", [.drafting], [.maths, .physics, .computing], .heavy)
        case .scrivener: ("Scrivener", "literatureandlatte.com", .writing, "doc.on.doc", "For work too long for one document", [.drafting, .outlining], [], .heavy)
        case .ulysses: ("Ulysses", "ulysses.app", .writing, "pencil.and.outline", "Distraction-free long-form writing", [.drafting], [], .heavy)
        case .zotero: ("Zotero", "zotero.org", .writing, "books.vertical", "Collects sources and formats them", [.citation, .sourceResearch], [], .heavy)
        case .mendeley: ("Mendeley", "mendeley.com", .writing, "doc.badge.plus", "Reference manager with a PDF reader", [.citation, .sourceResearch], [], .heavy)
        case .endnote: ("EndNote", "endnote.com", .writing, "list.bullet.rectangle", "Reference manager universities use", [.citation], [], .heavy)
        case .citationMachine: ("Citation Machine", "citationmachine.net", .writing, "quote.opening", "One citation, formatted fast", [.citation], [], .light)
        case .zoterobib: ("ZoteroBib", "zbib.org", .writing, "quote.bubble", "A bibliography with no account", [.citation], [], .light)
        case .scribbr: ("Scribbr", "scribbr.com", .writing, "checkmark.seal", "Citation guides and a plagiarism check", [.citation, .proofreading], [], .light)
        case .hemingwayGrade: ("Readability Formulas", "readabilityformulas.com", .writing, "gauge.medium", "How hard your writing is to read", [.editing], [], .light)
        case .wordcounter: ("WordCounter", "wordcounter.net", .writing, "number", "Words, characters, reading time", [.drafting], [], .light)
        case .onelook: ("OneLook", "onelook.com", .writing, "magnifyingglass", "Find the word from its meaning", [.drafting, .vocabulary], [], .light)
        case .googleScholar: ("Google Scholar", "scholar.google.com", .research, "graduationcap.circle", "Scholarly articles and citations", [.sourceResearch], [], .light)
        case .jstor: ("JSTOR", "jstor.org", .research, "building.columns", "Journals and primary sources", [.sourceResearch], [.humanities, .literature, .socialScience], .light)
        case .pubmed: ("PubMed", "pubmed.ncbi.nlm.nih.gov", .research, "cross.case", "Biomedical and life-science papers", [.sourceResearch], [.biology], .light)
        case .arxiv: ("arXiv", "arxiv.org", .research, "doc.plaintext", "Preprints in physics, maths, CS", [.sourceResearch], [.maths, .physics, .computing], .light)
        case .semanticScholar: ("Semantic Scholar", "semanticscholar.org", .research, "brain", "Finds the papers that matter", [.sourceResearch], [], .light)
        case .connectedPapers: ("Connected Papers", "connectedpapers.com", .research, "point.3.connected.trianglepath.dotted", "A map of a field from one paper", [.sourceResearch], [], .light)
        case .researchgate: ("ResearchGate", "researchgate.net", .research, "person.2", "Papers straight from the authors", [.sourceResearch], [], .light)
        case .core: ("CORE", "core.ac.uk", .research, "square.grid.3x3", "Open-access papers, all of them", [.sourceResearch], [], .light)
        case .doaj: ("DOAJ", "doaj.org", .research, "lock.open", "Directory of open-access journals", [.sourceResearch], [], .light)
        case .unpaywall: ("Unpaywall", "unpaywall.org", .research, "lock.open.rotation", "Finds the free version of a paper", [.sourceResearch], [], .light)
        case .internetArchive: ("Internet Archive", "archive.org", .research, "clock.arrow.circlepath", "Books, pages and media, preserved", [.sourceResearch, .reading], [], .light)
        case .projectGutenberg: ("Project Gutenberg", "gutenberg.org", .research, "book", "Sixty thousand free books", [.reading], [.literature], .light)
        case .perplexity: ("Perplexity", "perplexity.ai", .research, "sparkle.magnifyingglass", "Answers that cite their sources", [.sourceResearch, .reading], [], .light)
        case .wikipedia: ("Wikipedia", "wikipedia.org", .research, "globe", "Start here, then follow the footnotes", [.reading, .sourceResearch], [], .light)
        case .britannica: ("Britannica", "britannica.com", .research, "building.columns.circle", "Encyclopaedia you can cite", [.reading, .sourceResearch], [], .light)
        case .ourWorldInData: ("Our World in Data", "ourworldindata.org", .research, "chart.xyaxis.line", "Charts you can actually cite", [.dataAnalysis, .sourceResearch], [.socialScience], .light)
        case .statista: ("Statista", "statista.com", .research, "chart.bar.doc.horizontal", "Statistics with sources attached", [.dataAnalysis, .sourceResearch], [.socialScience], .light)
        case .worldBankData: ("World Bank Data", "data.worldbank.org", .research, "globe.americas", "Country-level economic data", [.dataAnalysis], [.socialScience], .light)
        case .unData: ("UN Data", "data.un.org", .research, "globe.europe.africa", "Official international statistics", [.dataAnalysis], [.socialScience], .light)
        case .eurostat: ("Eurostat", "ec.europa.eu", .research, "flag", "European statistics", [.dataAnalysis], [.socialScience], .light)
        case .googleDatasetSearch: ("Google Dataset Search", "datasetsearch.research.google.com", .research, "tablecells", "Finds datasets across the web", [.dataAnalysis], [], .light)
        case .libraryGenesisInfo: ("Open Library", "openlibrary.org", .research, "books.vertical.circle", "A lending library of digitised books", [.sourceResearch, .reading], [], .light)
        case .hathitrust: ("HathiTrust", "hathitrust.org", .research, "text.book.closed.fill", "Digitised academic library", [.sourceResearch, .reading], [], .light)
        case .jstorDaily: ("JSTOR Daily", "daily.jstor.org", .research, "newspaper", "Scholarship explained readably", [.reading], [], .light)
        case .nature: ("Nature", "nature.com", .research, "leaf", "The journal, and its news", [.sourceResearch, .reading], [], .light)
        case .science: ("Science", "science.org", .research, "atom", "AAAS research and commentary", [.sourceResearch, .reading], [], .light)
        case .ssrn: ("SSRN", "ssrn.com", .research, "doc.richtext", "Social-science preprints", [.sourceResearch], [.socialScience], .light)
        case .philpapers: ("PhilPapers", "philpapers.org", .research, "bubble.left.and.bubble.right", "Philosophy index and archive", [.sourceResearch], [.humanities], .light)
        case .historicalAtlas: ("Historical Atlas", "worldhistory.org", .research, "map", "World history encyclopaedia", [.reading, .sourceResearch], [.humanities], .light)
        case .wolframAlpha: ("Wolfram Alpha", "wolframalpha.com", .math, "function", "Computational answers, step by step", [.computation, .workedExamples], [.maths, .physics, .chemistry], .light)
        case .symbolab: ("Symbolab", "symbolab.com", .math, "x.squareroot", "Solves and shows the working", [.computation, .workedExamples, .errorAnalysis], [.maths], .light)
        case .desmos: ("Desmos", "desmos.com", .math, "chart.dots.scatter", "Graphing that makes it obvious", [.graphing], [.maths], .light)
        case .geogebra: ("GeoGebra", "geogebra.org", .math, "triangle", "Geometry, algebra and calculus", [.graphing, .diagramming], [.maths], .light)
        case .photomath: ("Photomath", "photomath.com", .math, "camera.viewfinder", "Point at the problem, see the steps", [.workedExamples, .errorAnalysis], [.maths], .light)
        case .mathway: ("Mathway", "mathway.com", .math, "equal.square", "Step-by-step across every branch", [.workedExamples, .computation], [.maths], .light)
        case .khanAcademy: ("Khan Academy", "khanacademy.org", .math, "play.rectangle", "Free lessons and practice", [.workedExamples, .problemPractice], [], .light)
        case .brilliant: ("Brilliant", "brilliant.org", .math, "lightbulb", "Maths by solving, not watching", [.problemPractice, .workedExamples], [], .light)
        case .paulSNotes: ("Paul's Notes", "tutorial.math.lamar.edu", .math, "doc.text.below.ecg", "Calculus notes that actually explain", [.workedExamples, .reading], [.maths], .light)
        case .t3Blue1Brown: ("3Blue1Brown", "3blue1brown.com", .math, "eye", "The intuition behind the formula", [.workedExamples], [.maths], .light)
        case .integralCalculator: ("Integral Calculator", "integral-calculator.com", .math, "sum", "Integrals with the steps shown", [.computation, .workedExamples], [.maths], .light)
        case .derivativeCalculator: ("Derivative Calculator", "derivative-calculator.net", .math, "angle", "Derivatives with the steps shown", [.computation, .workedExamples], [.maths], .light)
        case .matrixCalculator: ("Matrix Calculator", "matrixcalc.org", .math, "square.grid.3x3.fill", "Linear algebra, worked through", [.computation, .workedExamples], [.maths], .light)
        case .statisticsKingdom: ("Statistics Kingdom", "statskingdom.com", .math, "chart.bar", "Runs the test and reads the result", [.dataAnalysis, .computation], [.maths, .socialScience, .biology], .light)
        case .desmosMatrix: ("Desmos Matrix", "desmos.com", .math, "squareshape.split.2x2", "Matrices you can see", [.computation, .graphing], [.maths], .light)
        case .sagemath: ("SageMath", "sagemath.org", .math, "terminal", "Open-source computer algebra", [.computation], [.maths], .heavy)
        case .numbas: ("Numbas", "numbas.mathcentre.ac.uk", .math, "checklist", "Practice questions that mark themselves", [.problemPractice, .selfTesting], [.maths], .light)
        case .projectEuler: ("Project Euler", "projecteuler.net", .math, "number.square", "Maths problems worth the struggle", [.problemPractice], [.maths], .light)
        case .oeis: ("OEIS", "oeis.org", .math, "list.number", "Identify any integer sequence", [.computation], [.maths], .light)
        case .mathigon: ("Mathigon", "mathigon.org", .math, "puzzlepiece", "Textbook that talks back", [.workedExamples, .problemPractice], [.maths], .light)
        case .phetSimulations: ("PhET Simulations", "phet.colorado.edu", .science, "atom", "Run the experiment in a browser", [.simulation], [.biology, .chemistry, .physics], .light)
        case .chemspider: ("ChemSpider", "chemspider.com", .science, "testtube.2", "Chemical structures and properties", [.sourceResearch, .diagramming], [.chemistry], .light)
        case .pubchem: ("PubChem", "pubchem.ncbi.nlm.nih.gov", .science, "flask", "The chemistry database", [.sourceResearch], [.chemistry], .light)
        case .periodicTable: ("Periodic Table", "ptable.com", .science, "tablecells.badge.ellipsis", "Interactive, and actually useful", [.reading, .sourceResearch], [.chemistry], .light)
        case .biorender: ("BioRender", "biorender.com", .science, "waveform.path.ecg", "Diagrams that look publishable", [.diagramming, .design], [.biology], .light)
        case .proteinDataBank: ("Protein Data Bank", "rcsb.org", .science, "circles.hexagongrid", "3D structures of proteins", [.sourceResearch, .diagramming], [.biology], .light)
        case .nasaEarthdata: ("NASA Earthdata", "earthdata.nasa.gov", .science, "globe.badge.chevron.backward", "Satellite and climate data", [.dataAnalysis], [.earthScience], .light)
        case .stellariumWeb: ("Stellarium Web", "stellarium-web.org", .science, "moon.stars", "The sky from anywhere, any date", [.simulation], [.earthScience], .light)
        case .physicsClassroom: ("Physics Classroom", "physicsclassroom.com", .science, "bolt", "Mechanics explained slowly", [.workedExamples, .reading], [.physics], .light)
        case .hyperphysics: ("HyperPhysics", "hyperphysics.gsu.edu", .science, "link.circle", "Physics as a concept map", [.reading, .workedExamples], [.physics], .light)
        case .anatomyAtlas: ("Anatomy Atlas", "innerbody.com", .science, "figure.stand", "Human anatomy, layer by layer", [.diagramming, .reading], [.biology], .light)
        case .geneticsHomeRef: ("Genetics Home Ref", "medlineplus.gov", .science, "allergens", "Genetics for non-specialists", [.reading], [.biology], .light)
        case .climateData: ("Climate Data", "climate.gov", .science, "thermometer.medium", "Climate records and explainers", [.dataAnalysis], [.earthScience], .light)
        case .usgs: ("USGS", "www.usgs.gov", .science, "mountain.2", "Geology, water and hazards", [.dataAnalysis, .sourceResearch], [.earthScience], .light)
        case .encyclopediaOfLife: ("Encyclopedia of Life", "eol.org", .science, "tortoise", "Every known species", [.sourceResearch, .reading], [.biology], .light)
        case .foldit: ("Foldit", "fold.it", .science, "hand.raised", "Protein folding as a puzzle", [.simulation], [.biology], .light)
        case .labster: ("Labster", "labster.com", .science, "flask.fill", "Virtual lab work", [.simulation], [.biology, .chemistry, .physics], .heavy)
        case .concordConsortium: ("Concord Consortium", "learn.concord.org", .science, "atom", "Free science simulations", [.simulation], [.biology, .chemistry, .physics], .light)
        case .github: ("GitHub", "github.com", .coding, "chevron.left.forwardslash.chevron.right", "Code hosting and history", [.coding], [.computing], .light)
        case .replit: ("Replit", "replit.com", .coding, "play.square", "Write and run code in the browser", [.coding, .debugging], [.computing], .light)
        case .stackOverflow: ("Stack Overflow", "stackoverflow.com", .coding, "questionmark.bubble", "Someone has hit this before", [.debugging], [.computing], .light)
        case .mdnWebDocs: ("MDN Web Docs", "developer.mozilla.org", .coding, "doc.append", "The web platform reference", [.coding, .reading], [.computing], .light)
        case .w3Schools: ("W3Schools", "w3schools.com", .coding, "tag", "Quick syntax, quick examples", [.coding, .workedExamples], [.computing], .light)
        case .leetcode: ("LeetCode", "leetcode.com", .coding, "brain.head.profile", "Interview-style problem practice", [.problemPractice, .coding], [.computing], .light)
        case .hackerrank: ("HackerRank", "hackerrank.com", .coding, "terminal.fill", "Practice with automated marking", [.problemPractice, .coding], [.computing], .light)
        case .codecademy: ("Codecademy", "codecademy.com", .coding, "laptopcomputer", "Learn by typing, not watching", [.coding, .workedExamples], [.computing], .light)
        case .freecodecamp: ("freeCodeCamp", "freecodecamp.org", .coding, "flame", "Full curriculum, genuinely free", [.coding, .workedExamples], [.computing], .light)
        case .exercism: ("Exercism", "exercism.org", .coding, "dumbbell", "Small exercises, human feedback", [.problemPractice, .feedback], [.computing], .light)
        case .regex101: ("Regex101", "regex101.com", .coding, "textformat.abc.dottedunderline", "Explains your regex back to you", [.debugging, .coding], [.computing], .light)
        case .jsonFormatter: ("JSON Formatter", "jsonformatter.org", .coding, "curlybraces", "Makes unreadable JSON readable", [.debugging], [.computing], .light)
        case .compilerExplorer: ("Compiler Explorer", "godbolt.org", .coding, "cpu", "See what your code compiles to", [.debugging, .coding], [.computing], .light)
        case .devdocs: ("DevDocs", "devdocs.io", .coding, "books.vertical.fill", "Every API doc, one search box", [.coding, .reading], [.computing], .light)
        case .codepen: ("CodePen", "codepen.io", .coding, "square.on.square", "Front-end sketching", [.coding, .design], [.computing], .light)
        case .jupyter: ("Jupyter", "jupyter.org", .coding, "book.and.wrench", "Notebooks for data work", [.dataAnalysis, .coding], [.computing], .heavy)
        case .googleColab: ("Google Colab", "colab.research.google.com", .coding, "cloud", "Notebooks with a free GPU", [.dataAnalysis, .coding], [.computing], .heavy)
        case .kaggle: ("Kaggle", "kaggle.com", .coding, "chart.bar.xaxis", "Datasets and data-science practice", [.dataAnalysis, .problemPractice], [.computing], .light)
        case .pythonDocs: ("Python Docs", "docs.python.org", .coding, "chevron.left.slash.chevron.right", "The language reference", [.coding, .reading], [.computing], .light)
        case .swiftDocs: ("Swift Docs", "swift.org", .coding, "swift", "The Swift language guide", [.coding, .reading], [.computing], .light)
        case .visualStudioCode: ("Visual Studio Code", "code.visualstudio.com", .coding, "square.and.pencil", "The editor most people use", [.coding], [.computing], .heavy)
        case .gitDocs: ("Git Docs", "git-scm.com", .coding, "arrow.triangle.branch", "What that git command does", [.coding, .reading], [.computing], .light)
        case .deepl: ("DeepL", "deepl.com", .languages, "character.bubble", "Translation that reads naturally", [.translation], [.languages], .light)
        case .linguee: ("Linguee", "linguee.com", .languages, "text.quote", "Translations in real sentences", [.translation, .vocabulary], [.languages], .light)
        case .googleTranslate: ("Google Translate", "translate.google.com", .languages, "globe.badge.chevron.backward", "Fast, everywhere, every language", [.translation], [.languages], .light)
        case .wordreference: ("WordReference", "wordreference.com", .languages, "character.book.closed.fill", "Dictionary plus forum arguments", [.translation, .vocabulary], [.languages], .light)
        case .duolingo: ("Duolingo", "duolingo.com", .languages, "bird", "Fifteen minutes a day", [.vocabulary, .spacedPractice], [.languages], .light)
        case .anki: ("Anki", "apps.ankiweb.net", .languages, "rectangle.stack", "Spaced repetition that works", [.memorisation, .spacedPractice], [], .heavy)
        case .memrise: ("Memrise", "memrise.com", .languages, "brain.filled.head.profile", "Vocabulary from real speakers", [.vocabulary, .spacedPractice], [.languages], .light)
        case .conjuguemos: ("Conjuguemos", "conjuguemos.com", .languages, "arrow.trianglehead.2.clockwise", "Verb conjugation drills", [.problemPractice, .vocabulary], [.languages], .light)
        case .reversoContext: ("Reverso Context", "context.reverso.net", .languages, "text.alignleft", "How the phrase is actually used", [.translation, .vocabulary], [.languages], .light)
        case .forvo: ("Forvo", "forvo.com", .languages, "speaker.wave.2", "Hear a native say the word", [.listeningSpeaking], [.languages], .light)
        case .tatoeba: ("Tatoeba", "tatoeba.org", .languages, "text.bubble", "Example sentences, many languages", [.vocabulary, .translation], [.languages], .light)
        case .lang8Hinative: ("Lang-8 / HiNative", "hinative.com", .languages, "person.wave.2", "Ask a native speaker", [.feedback, .listeningSpeaking], [.languages], .light)
        case .clozemaster: ("Clozemaster", "clozemaster.com", .languages, "square.dashed", "Vocabulary in context, gamified", [.vocabulary, .problemPractice], [.languages], .light)
        case .readlang: ("Readlang", "readlang.com", .languages, "doc.text.magnifyingglass", "Read real pages with a click-dictionary", [.reading, .vocabulary], [.languages], .light)
        case .forest: ("Forest", "forestapp.cc", .focus, "tree", "Grow a tree by not touching your phone", [.focus], [], .light)
        case .pomofocus: ("Pomofocus", "pomofocus.io", .focus, "timer", "A clean pomodoro timer", [.focus], [], .light)
        case .togglTrack: ("Toggl Track", "toggl.com", .focus, "stopwatch", "Where the hours actually went", [.focus, .planning], [], .light)
        case .coldTurkey: ("Cold Turkey", "getcoldturkey.com", .focus, "hand.raised.slash", "Blocks sites properly", [.focus], [], .heavy)
        case .freedom: ("Freedom", "freedom.to", .focus, "lock.shield", "Blocks across all your devices", [.focus], [], .heavy)
        case .noisli: ("Noisli", "www.noisli.com", .focus, "waveform", "Background noise that helps", [.focus], [], .light)
        case .brainFm: ("Brain.fm", "brain.fm", .focus, "headphones", "Music built for concentration", [.focus], [], .light)
        case .rainyMood: ("Rainy Mood", "rainymood.com", .focus, "cloud.rain", "Rain, and nothing else", [.focus], [], .light)
        case .lofiGirl: ("Lofi Girl", "lofigirl.com", .focus, "music.note", "The one everybody uses", [.focus], [], .light)
        case .focusmate: ("Focusmate", "focusmate.com", .focus, "person.2.wave.2", "A stranger works alongside you", [.focus], [], .light)
        case .studyTogether: ("Study Together", "studytogether.com", .focus, "rectangle.3.group", "Virtual library rooms", [.focus], [], .light)
        case .habitica: ("Habitica", "habitica.com", .focus, "gamecontroller", "Habits as a role-playing game", [.focus, .planning], [], .heavy)
        case .streaks: ("Streaks", "streaksapp.com", .focus, "flame.fill", "Keep the chain unbroken", [.focus, .planning], [], .light)
        case .sleepCycle: ("Sleep Cycle", "sleepcycle.com", .focus, "bed.double", "Because sleep is study time", [.wellbeing], [], .light)
        case .quizlet: ("Quizlet", "quizlet.com", .memory, "rectangle.on.rectangle", "Flashcards, and everyone else's", [.memorisation, .spacedPractice, .selfTesting], [], .light)
        case .ankiWeb: ("Anki Web", "ankiweb.net", .memory, "rectangle.stack.fill", "Your Anki deck in a browser", [.memorisation, .spacedPractice], [], .heavy)
        case .remnote: ("RemNote", "remnote.com", .memory, "note.text", "Notes that become flashcards", [.noteTaking, .memorisation, .spacedPractice], [], .heavy)
        case .brainscape: ("Brainscape", "brainscape.com", .memory, "square.stack", "Confidence-based repetition", [.memorisation, .spacedPractice], [], .light)
        case .knowt: ("Knowt", "knowt.com", .memory, "doc.text.fill", "Turns your notes into a quiz", [.noteTaking, .selfTesting, .memorisation], [], .light)
        case .goodnotes: ("GoodNotes", "goodnotes.com", .memory, "hand.draw", "Handwriting that stays searchable", [.noteTaking], [], .heavy)
        case .notability: ("Notability", "notability.com", .memory, "pencil.tip", "Notes with the lecture recorded", [.noteTaking], [], .heavy)
        case .onenote: ("OneNote", "onenote.com", .memory, "note", "Free, and syncs everywhere", [.noteTaking], [], .heavy)
        case .evernote: ("Evernote", "evernote.com", .memory, "square.and.pencil.circle", "The original notes app", [.noteTaking], [], .heavy)
        case .milanote: ("Milanote", "milanote.com", .memory, "square.grid.2x2", "Notes on a board, not a list", [.noteTaking, .outlining], [], .light)
        case .miro: ("Miro", "miro.com", .memory, "rectangle.dashed", "A whiteboard big enough", [.diagramming, .outlining], [], .heavy)
        case .excalidraw: ("Excalidraw", "excalidraw.com", .memory, "scribble", "Diagrams that look hand-drawn", [.diagramming], [], .light)
        case .whimsical: ("Whimsical", "whimsical.com", .memory, "flowchart", "Flowcharts and mind maps", [.diagramming, .outlining], [], .light)
        case .xmind: ("XMind", "xmind.app", .memory, "point.topleft.down.to.point.bottomright.curvepath", "Mind maps that stay tidy", [.outlining, .diagramming], [], .light)
        case .coggle: ("Coggle", "coggle.it", .memory, "circle.hexagongrid", "Shared mind maps", [.outlining, .diagramming], [], .light)
        case .todoist: ("Todoist", "todoist.com", .memory, "checklist.checked", "The list that actually gets used", [.planning], [], .light)
        case .ticktick: ("TickTick", "ticktick.com", .memory, "checkmark.circle", "Tasks with a pomodoro built in", [.planning, .focus], [], .light)
        case .googleCalendar: ("Google Calendar", "calendar.google.com", .memory, "calendar", "Where your real week lives", [.planning], [], .light)
        case .trello: ("Trello", "trello.com", .memory, "square.grid.3x1.below.line.grid.1x2", "Boards for a group project", [.planning], [], .heavy)
        case .canva: ("Canva", "canva.com", .presenting, "paintpalette", "Design without being a designer", [.design, .presentation], [.arts], .light)
        case .googleSlides: ("Google Slides", "slides.google.com", .presenting, "rectangle.on.rectangle.angled", "Slides you can share instantly", [.presentation], [], .light)
        case .beautifulAi: ("Beautiful.ai", "beautiful.ai", .presenting, "wand.and.stars", "Slides that lay themselves out", [.presentation, .design], [], .light)
        case .prezi: ("Prezi", "prezi.com", .presenting, "arrow.up.left.and.down.right.magnifyingglass", "When a straight line won't do", [.presentation], [], .light)
        case .pitch: ("Pitch", "pitch.com", .presenting, "play.rectangle.on.rectangle", "Decks built with other people", [.presentation], [], .light)
        case .unsplash: ("Unsplash", "unsplash.com", .presenting, "photo", "Free photographs worth using", [.design], [.arts], .light)
        case .pexels: ("Pexels", "pexels.com", .presenting, "photo.stack", "Free photos and video", [.design], [.arts], .light)
        case .theNounProject: ("The Noun Project", "thenounproject.com", .presenting, "square.on.circle", "An icon for anything", [.design], [.arts], .light)
        case .flaticon: ("Flaticon", "flaticon.com", .presenting, "star.square", "Icons, many formats", [.design], [.arts], .light)
        case .coolors: ("Coolors", "coolors.co", .presenting, "swatchpalette", "A palette in three seconds", [.design], [.arts], .light)
        case .googleFonts: ("Google Fonts", "fonts.google.com", .presenting, "textformat", "Free type that loads fast", [.design], [.arts], .light)
        case .removeBg: ("Remove.bg", "remove.bg", .presenting, "person.crop.rectangle", "Cuts out the background", [.design], [.arts], .light)
        case .figma: ("Figma", "figma.com", .presenting, "pencil.and.ruler", "Design, together, in a browser", [.design, .diagramming], [.arts], .heavy)
        case .loom: ("Loom", "loom.com", .presenting, "record.circle", "Record the walkthrough instead", [.presentation, .listeningSpeaking], [], .light)
        case .obsStudio: ("OBS Studio", "obsproject.com", .presenting, "video", "Record or stream your screen", [.presentation], [], .heavy)
        case .descript: ("Descript", "descript.com", .presenting, "waveform.badge.mic", "Edit audio by editing text", [.presentation], [], .heavy)
        case .audacity: ("Audacity", "audacityteam.org", .presenting, "waveform.circle", "Free audio editing", [.presentation], [], .heavy)
        case .davinciResolve: ("DaVinci Resolve", "blackmagicdesign.com", .presenting, "film", "Professional video, free tier", [.presentation, .design], [.arts], .heavy)
        case .datawrapper: ("Datawrapper", "datawrapper.de", .presenting, "chart.pie", "Charts that explain themselves", [.dataAnalysis, .design], [], .light)
        case .flourish: ("Flourish", "flourish.studio", .presenting, "chart.line.uptrend.xyaxis.circle", "Animated data storytelling", [.dataAnalysis, .presentation], [], .light)
        case .saveMyExams: ("Save My Exams", "savemyexams.com", .revision, "doc.badge.gearshape", "Revision notes by exam board", [.selfTesting, .reading], [], .light)
        case .physicsMathsTutor: ("Physics & Maths Tutor", "physicsandmathstutor.com", .revision, "tray.full", "Past papers, sorted by topic", [.selfTesting, .problemPractice], [], .light)
        case .revisionWorld: ("Revision World", "revisionworld.com", .revision, "book.pages", "Notes across GCSE and A-level", [.reading, .selfTesting], [], .light)
        case .senecaLearning: ("Seneca Learning", "senecalearning.com", .revision, "brain.head.profile.fill", "Revision that adapts to you", [.spacedPractice, .selfTesting], [], .light)
        case .bbcBitesize: ("BBC Bitesize", "bbc.co.uk", .revision, "tv", "Short, clear, and free", [.reading, .workedExamples], [], .light)
        case .crashcourse: ("CrashCourse", "thecrashcourse.com", .revision, "play.tv", "A subject in ten-minute pieces", [.workedExamples, .reading], [], .light)
        case .khanAcademySat: ("Khan Academy SAT", "khanacademy.org", .revision, "pencil.circle", "Official SAT practice", [.problemPractice, .selfTesting], [], .light)
        case .collegeBoard: ("College Board", "collegeboard.org", .revision, "building.columns.fill", "AP and SAT, from the source", [.selfTesting, .sourceResearch], [], .light)
        case .ibDocuments: ("IB official site", "ibo.org", .revision, "doc.zipper", "Programmes and news from the IB itself", [.sourceResearch, .reading], [], .light)
        case .quizizz: ("Quizizz", "quizizz.com", .revision, "gamecontroller.fill", "Revision as a class game", [.selfTesting], [], .light)
        case .kahoot: ("Kahoot", "kahoot.com", .revision, "flag.checkered", "The one everyone shouts at", [.selfTesting], [], .light)
        case .wooclap: ("Wooclap", "wooclap.com", .revision, "hand.thumbsup", "Live questions in a lecture", [.selfTesting], [], .light)
        case .cheggStudy: ("Chegg Study", "chegg.com", .revision, "book.circle", "Worked textbook solutions", [.workedExamples], [], .light)
        case .courseHero: ("Course Hero", "coursehero.com", .revision, "doc.on.clipboard", "Course notes from other students", [.reading], [], .light)
        case .studocu: ("Studocu", "studocu.com", .revision, "doc.text.image", "Shared summaries and past papers", [.reading, .sourceResearch], [], .light)
        case .sparknotes: ("SparkNotes", "sparknotes.com", .revision, "book.closed.fill", "The novel, and what it means", [.reading], [.literature], .light)
        case .litcharts: ("LitCharts", "litcharts.com", .revision, "text.book.closed", "Literature analysis, colour-coded", [.reading], [.literature], .light)
        case .shmoop: ("Shmoop", "shmoop.com", .revision, "face.smiling", "Literature with a sense of humour", [.reading], [.literature], .light)
        case .markedByTeachers: ("Marked by Teachers", "markedbyteachers.com", .revision, "checkmark.rectangle.stack", "Real essays with real marks", [.feedback, .reading], [], .light)
        case .headspace: ("Headspace", "headspace.com", .wellbeing, "figure.mind.and.body", "Ten minutes before you start", [.wellbeing], [], .light)
        case .calm: ("Calm", "calm.com", .wellbeing, "moon.zzz", "For the night before", [.wellbeing], [], .light)
        case .insightTimer: ("Insight Timer", "insighttimer.com", .wellbeing, "timer.circle", "Free guided meditation", [.wellbeing], [], .light)
        case .finch: ("Finch", "finchcare.com", .wellbeing, "bird.fill", "Self-care that doesn't feel like it", [.wellbeing], [], .light)
        case .daylio: ("Daylio", "daylio.net", .wellbeing, "face.dashed", "Mood in two taps a day", [.wellbeing], [], .light)
        case .stretchly: ("Stretchly", "hovancik.net", .wellbeing, "figure.flexibility", "Reminds you to look away", [.wellbeing], [], .light)
        case .fLux: ("f.lux", "justgetflux.com", .wellbeing, "sun.horizon", "Screen warmth after dark", [.wellbeing], [], .light)
        case .waterReminder: ("Water Reminder", "waterllama.app", .wellbeing, "drop", "Drink something that isn't coffee", [.wellbeing], [], .light)
        case .nikeTraining: ("Nike Training", "nike.com", .wellbeing, "figure.run", "Twenty minutes, no equipment", [.wellbeing], [], .heavy)
        case .yogaWithAdriene: ("Yoga with Adriene", "yogawithadriene.com", .wellbeing, "figure.yoga", "Free, and genuinely kind", [.wellbeing], [], .light)
        case .t7Cups: ("7 Cups", "7cups.com", .wellbeing, "heart.text.square", "Someone to talk to, free", [.wellbeing], [], .light)
        case .studentMinds: ("Student Minds", "studentminds.org.uk", .wellbeing, "hand.raised.fill", "Student mental health support", [.wellbeing], [], .light)
        case .sleepytiMe: ("Sleepyti.me", "sleepyti.me", .wellbeing, "alarm", "When to go to bed, working back", [.wellbeing], [], .light)
        case .myfitnesspal: ("MyFitnessPal", "myfitnesspal.com", .wellbeing, "fork.knife", "Eating like a person, not a student", [.wellbeing], [], .heavy)
        }
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
    var logoAssetName: String { "logo-\(rawValue)" }

    /// Shown to a student when asked where a tap will take them.
    var host: String { spec.host }

    /// Every string here is a literal this file controls, so it cannot fail —
    /// and a typo is caught by `ToolCatalogTests`, not by a student tapping a
    /// dead tile.
    var url: URL { URL(string: "https://\(spec.host)")! }

    /// Matches a search across name, reason and category.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.lowercased()
        return name.lowercased().contains(q)
            || reason.lowercased().contains(q)
            || category.title.lowercased().contains(q)
    }

}
