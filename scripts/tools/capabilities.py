"""What each tool is *for*, and who it suits.

Separate from `gen.py`'s catalogue because this is a different kind of claim.
The catalogue says a tool exists and where it lives; this says when recommending
it would help a student, which is a judgement and is what the selector reasons
over.

Curated by hand, deliberately. The first pass at this inferred needs from
category plus keywords in the one-line reason, and it was confidently wrong in
ways that would have shipped: every note-taking and calendar app in the `memory`
category was tagged as spaced repetition, because the category is "Notes &
memory" and the inference could not tell Google Calendar from Anki. A tool
recommended for something it does not do is worse than no recommendation.
"""

# What a step can need. Kept small enough that a model can choose from the list
# reliably, and wide enough that the choice is informative.
NEEDS = [
    # Reading and writing
    "source_research", "reading", "note_taking", "outlining", "drafting",
    "editing", "proofreading", "citation", "feedback",
    # Quantitative and scientific
    "worked_examples", "problem_practice", "error_analysis", "computation",
    "graphing", "data_analysis", "simulation", "diagramming",
    # Language acquisition
    "translation", "vocabulary", "listening_speaking",
    # Retention
    "memorisation", "spaced_practice", "self_testing",
    # Making things
    "coding", "debugging", "presentation", "design",
    # Getting the work done at all
    "planning", "focus", "wellbeing",
]

# Subject areas a tool is specifically good for. Absent means it suits any
# subject — most tools do, and claiming otherwise would narrow the catalogue
# back down to the handful this work exists to escape.
# Finer than "sciences" and "humanities" on purpose. The first version had six
# areas, and a Biology lab report was offered Stellarium Web and NASA Earthdata
# because astronomy, climate science and biology were all "sciences". An
# irrelevant recommendation is worse than a general one: a general tool is
# merely unhelpful, a wrong-subject tool says Albus does not know what you study.
AREAS = [
    "humanities", "literature", "social_science",
    "biology", "chemistry", "physics", "earth_science",
    "maths", "computing", "languages", "arts",
]

# name -> needs. Every tool in the catalogue must appear; `gen.py` asserts it.
TOOL_NEEDS = {
    # ── AI ────────────────────────────────────────────────────────────────
    "Claude": ["feedback", "outlining", "error_analysis"],
    "ChatGPT": ["feedback", "outlining", "error_analysis"],
    "Perplexity Pro": ["source_research", "reading"],
    "NotebookLM": ["reading", "note_taking", "self_testing"],
    "Gemini": ["feedback", "drafting"],
    "Consensus": ["source_research"],
    "Elicit": ["source_research"],
    "Scite": ["source_research", "citation"],

    # ── Writing ───────────────────────────────────────────────────────────
    "Grammarly": ["proofreading", "editing"],
    "Hemingway Editor": ["editing"],
    "ProWritingAid": ["editing", "proofreading"],
    "LanguageTool": ["proofreading"],
    "Quillbot": ["editing"],
    "Thesaurus.com": ["drafting"],
    "Merriam-Webster": ["vocabulary", "drafting"],
    "Oxford Learner's": ["vocabulary"],
    "Purdue OWL": ["citation"],
    "Notion": ["note_taking", "planning", "outlining"],
    "Obsidian": ["note_taking", "outlining"],
    "Google Docs": ["drafting"],
    "Overleaf": ["drafting"],
    "Scrivener": ["drafting", "outlining"],
    "Ulysses": ["drafting"],
    "Zotero": ["citation", "source_research"],
    "Mendeley": ["citation", "source_research"],
    "EndNote": ["citation"],
    "Citation Machine": ["citation"],
    "ZoteroBib": ["citation"],
    "Scribbr": ["citation", "proofreading"],
    "Readability Formulas": ["editing"],
    "WordCounter": ["drafting"],
    "OneLook": ["drafting", "vocabulary"],

    # ── Research ──────────────────────────────────────────────────────────
    "Google Scholar": ["source_research"],
    "JSTOR": ["source_research"],
    "PubMed": ["source_research"],
    "arXiv": ["source_research"],
    "Semantic Scholar": ["source_research"],
    "Connected Papers": ["source_research"],
    "ResearchGate": ["source_research"],
    "CORE": ["source_research"],
    "DOAJ": ["source_research"],
    "Unpaywall": ["source_research"],
    "Internet Archive": ["source_research", "reading"],
    "Project Gutenberg": ["reading"],
    "Perplexity": ["source_research", "reading"],
    "Wikipedia": ["reading", "source_research"],
    "Britannica": ["reading", "source_research"],
    "Our World in Data": ["data_analysis", "source_research"],
    "Statista": ["data_analysis", "source_research"],
    "World Bank Data": ["data_analysis"],
    "UN Data": ["data_analysis"],
    "Eurostat": ["data_analysis"],
    "Google Dataset Search": ["data_analysis"],
    "Open Library": ["source_research", "reading"],
    "HathiTrust": ["source_research", "reading"],
    "JSTOR Daily": ["reading"],
    "Nature": ["source_research", "reading"],
    "Science": ["source_research", "reading"],
    "SSRN": ["source_research"],
    "PhilPapers": ["source_research"],
    "Historical Atlas": ["reading", "source_research"],

    # ── Maths ─────────────────────────────────────────────────────────────
    "Wolfram Alpha": ["computation", "worked_examples"],
    "Symbolab": ["computation", "worked_examples", "error_analysis"],
    "Desmos": ["graphing"],
    "GeoGebra": ["graphing", "diagramming"],
    "Photomath": ["worked_examples", "error_analysis"],
    "Mathway": ["worked_examples", "computation"],
    "Khan Academy": ["worked_examples", "problem_practice"],
    "Brilliant": ["problem_practice", "worked_examples"],
    "Paul's Notes": ["worked_examples", "reading"],
    "3Blue1Brown": ["worked_examples"],
    "Integral Calculator": ["computation", "worked_examples"],
    "Derivative Calculator": ["computation", "worked_examples"],
    "Matrix Calculator": ["computation", "worked_examples"],
    "Statistics Kingdom": ["data_analysis", "computation"],
    "Desmos Matrix": ["computation", "graphing"],
    "SageMath": ["computation"],
    "Numbas": ["problem_practice", "self_testing"],
    "Project Euler": ["problem_practice"],
    "OEIS": ["computation"],
    "Mathigon": ["worked_examples", "problem_practice"],

    # ── Science ───────────────────────────────────────────────────────────
    "PhET Simulations": ["simulation"],
    "ChemSpider": ["source_research", "diagramming"],
    "PubChem": ["source_research"],
    "Periodic Table": ["reading", "source_research"],
    "BioRender": ["diagramming", "design"],
    "Protein Data Bank": ["source_research", "diagramming"],
    "NASA Earthdata": ["data_analysis"],
    "Stellarium Web": ["simulation"],
    "Physics Classroom": ["worked_examples", "reading"],
    "HyperPhysics": ["reading", "worked_examples"],
    "Anatomy Atlas": ["diagramming", "reading"],
    "Genetics Home Ref": ["reading"],
    "Climate Data": ["data_analysis"],
    "USGS": ["data_analysis", "source_research"],
    "Encyclopedia of Life": ["source_research", "reading"],
    "Foldit": ["simulation"],
    "Labster": ["simulation"],
    "Concord Consortium": ["simulation"],

    # ── Coding ────────────────────────────────────────────────────────────
    "GitHub": ["coding"],
    "Replit": ["coding", "debugging"],
    "Stack Overflow": ["debugging"],
    "MDN Web Docs": ["coding", "reading"],
    "W3Schools": ["coding", "worked_examples"],
    "LeetCode": ["problem_practice", "coding"],
    "HackerRank": ["problem_practice", "coding"],
    "Codecademy": ["coding", "worked_examples"],
    "freeCodeCamp": ["coding", "worked_examples"],
    "Exercism": ["problem_practice", "feedback"],
    "Regex101": ["debugging", "coding"],
    "JSON Formatter": ["debugging"],
    "Compiler Explorer": ["debugging", "coding"],
    "DevDocs": ["coding", "reading"],
    "CodePen": ["coding", "design"],
    "Jupyter": ["data_analysis", "coding"],
    "Google Colab": ["data_analysis", "coding"],
    "Kaggle": ["data_analysis", "problem_practice"],
    "Python Docs": ["coding", "reading"],
    "Swift Docs": ["coding", "reading"],
    "Visual Studio Code": ["coding"],
    "Git Docs": ["coding", "reading"],

    # ── Notes & memory ────────────────────────────────────────────────────
    # Only the six that genuinely schedule repetition carry `spaced_practice`.
    "Quizlet": ["memorisation", "spaced_practice", "self_testing"],
    "Anki Web": ["memorisation", "spaced_practice"],
    "RemNote": ["note_taking", "memorisation", "spaced_practice"],
    "Brainscape": ["memorisation", "spaced_practice"],
    "Knowt": ["note_taking", "self_testing", "memorisation"],
    "GoodNotes": ["note_taking"],
    "Notability": ["note_taking"],
    "OneNote": ["note_taking"],
    "Evernote": ["note_taking"],
    "Milanote": ["note_taking", "outlining"],
    "Miro": ["diagramming", "outlining"],
    "Excalidraw": ["diagramming"],
    "Whimsical": ["diagramming", "outlining"],
    "XMind": ["outlining", "diagramming"],
    "Coggle": ["outlining", "diagramming"],
    "Todoist": ["planning"],
    "TickTick": ["planning", "focus"],
    "Google Calendar": ["planning"],
    "Trello": ["planning"],

    # ── Revision ──────────────────────────────────────────────────────────
    "Save My Exams": ["self_testing", "reading"],
    "Physics & Maths Tutor": ["self_testing", "problem_practice"],
    "Revision World": ["reading", "self_testing"],
    "Seneca Learning": ["spaced_practice", "self_testing"],
    "BBC Bitesize": ["reading", "worked_examples"],
    "CrashCourse": ["worked_examples", "reading"],
    "Khan Academy SAT": ["problem_practice", "self_testing"],
    "College Board": ["self_testing", "source_research"],
    "IB official site": ["source_research", "reading"],
    "Quizizz": ["self_testing"],
    "Kahoot": ["self_testing"],
    "Wooclap": ["self_testing"],
    "Chegg Study": ["worked_examples"],
    "Course Hero": ["reading"],
    "Studocu": ["reading", "source_research"],
    "SparkNotes": ["reading"],
    "LitCharts": ["reading"],
    "Shmoop": ["reading"],
    "Marked by Teachers": ["feedback", "reading"],

    # ── Languages ─────────────────────────────────────────────────────────
    "DeepL": ["translation"],
    "Linguee": ["translation", "vocabulary"],
    "Google Translate": ["translation"],
    "WordReference": ["translation", "vocabulary"],
    "Duolingo": ["vocabulary", "spaced_practice"],
    "Anki": ["memorisation", "spaced_practice"],
    "Memrise": ["vocabulary", "spaced_practice"],
    "Conjuguemos": ["problem_practice", "vocabulary"],
    "Reverso Context": ["translation", "vocabulary"],
    "Forvo": ["listening_speaking"],
    "Tatoeba": ["vocabulary", "translation"],
    "Lang-8 / HiNative": ["feedback", "listening_speaking"],
    "Clozemaster": ["vocabulary", "problem_practice"],
    "Readlang": ["reading", "vocabulary"],

    # ── Presenting ────────────────────────────────────────────────────────
    "Canva": ["design", "presentation"],
    "Google Slides": ["presentation"],
    "Beautiful.ai": ["presentation", "design"],
    "Prezi": ["presentation"],
    "Pitch": ["presentation"],
    "Unsplash": ["design"],
    "Pexels": ["design"],
    "The Noun Project": ["design"],
    "Flaticon": ["design"],
    "Coolors": ["design"],
    "Google Fonts": ["design"],
    "Remove.bg": ["design"],
    "Figma": ["design", "diagramming"],
    "Loom": ["presentation", "listening_speaking"],
    "OBS Studio": ["presentation"],
    "Descript": ["presentation"],
    "Audacity": ["presentation"],
    "DaVinci Resolve": ["presentation", "design"],
    "Datawrapper": ["data_analysis", "design"],
    "Flourish": ["data_analysis", "presentation"],

    # ── Focus ─────────────────────────────────────────────────────────────
    "Forest": ["focus"],
    "Pomofocus": ["focus"],
    "Toggl Track": ["focus", "planning"],
    "Cold Turkey": ["focus"],
    "Freedom": ["focus"],
    "Noisli": ["focus"],
    "Brain.fm": ["focus"],
    "Rainy Mood": ["focus"],
    "Lofi Girl": ["focus"],
    "Focusmate": ["focus"],
    "Study Together": ["focus"],
    "Habitica": ["focus", "planning"],
    "Streaks": ["focus", "planning"],
    "Sleep Cycle": ["wellbeing"],

    # ── Wellbeing ─────────────────────────────────────────────────────────
    "Headspace": ["wellbeing"], "Calm": ["wellbeing"], "Insight Timer": ["wellbeing"],
    "Finch": ["wellbeing"], "Daylio": ["wellbeing"], "Stretchly": ["wellbeing"],
    "f.lux": ["wellbeing"], "Water Reminder": ["wellbeing"], "Nike Training": ["wellbeing"],
    "Yoga with Adriene": ["wellbeing"], "7 Cups": ["wellbeing"],
    "Student Minds": ["wellbeing"], "Sleepyti.me": ["wellbeing"],
    "MyFitnessPal": ["wellbeing"],
}

# Subject areas a tool is *specifically* for. Everything absent suits any
# subject, which is the common case and the point.
TOOL_AREAS = {
    "Overleaf": ["maths", "physics", "computing"],
    "arXiv": ["maths", "physics", "computing"],

    # Humanities, split so a philosophy index does not surface for economics.
    "JSTOR": ["humanities", "literature", "social_science"],
    "PhilPapers": ["humanities"],
    "Historical Atlas": ["humanities"],
    "Project Gutenberg": ["literature"],
    "SparkNotes": ["literature"], "LitCharts": ["literature"], "Shmoop": ["literature"],
    "SSRN": ["social_science"],
    "Our World in Data": ["social_science"], "Statista": ["social_science"],
    "World Bank Data": ["social_science"], "UN Data": ["social_science"],
    "Eurostat": ["social_science"],

    # Sciences, by discipline.
    "PubMed": ["biology"], "BioRender": ["biology"], "Protein Data Bank": ["biology"],
    "Anatomy Atlas": ["biology"], "Genetics Home Ref": ["biology"],
    "Encyclopedia of Life": ["biology"], "Foldit": ["biology"],
    "ChemSpider": ["chemistry"], "PubChem": ["chemistry"], "Periodic Table": ["chemistry"],
    "Physics Classroom": ["physics"], "HyperPhysics": ["physics"],
    "Stellarium Web": ["earth_science"], "NASA Earthdata": ["earth_science"],
    "Climate Data": ["earth_science"], "USGS": ["earth_science"],
    "PhET Simulations": ["biology", "chemistry", "physics"],
    "Labster": ["biology", "chemistry", "physics"],
    "Concord Consortium": ["biology", "chemistry", "physics"],

    # Maths.
    "Wolfram Alpha": ["maths", "physics", "chemistry"], "Symbolab": ["maths"],
    "Desmos": ["maths"], "GeoGebra": ["maths"], "Photomath": ["maths"],
    "Mathway": ["maths"], "Paul's Notes": ["maths"], "3Blue1Brown": ["maths"],
    "Integral Calculator": ["maths"], "Derivative Calculator": ["maths"],
    "Matrix Calculator": ["maths"], "Desmos Matrix": ["maths"],
    "SageMath": ["maths"], "Numbas": ["maths"], "Project Euler": ["maths"],
    "OEIS": ["maths"], "Mathigon": ["maths"],
    "Statistics Kingdom": ["maths", "social_science", "biology"],

    # Computing.
    "GitHub": ["computing"], "Replit": ["computing"], "Stack Overflow": ["computing"],
    "MDN Web Docs": ["computing"], "W3Schools": ["computing"], "LeetCode": ["computing"],
    "HackerRank": ["computing"], "Codecademy": ["computing"], "freeCodeCamp": ["computing"],
    "Exercism": ["computing"], "Regex101": ["computing"], "JSON Formatter": ["computing"],
    "Compiler Explorer": ["computing"], "DevDocs": ["computing"], "CodePen": ["computing"],
    "Jupyter": ["computing"], "Google Colab": ["computing"], "Kaggle": ["computing"],
    "Python Docs": ["computing"], "Swift Docs": ["computing"],
    "Visual Studio Code": ["computing"], "Git Docs": ["computing"],

    # Languages.
    "DeepL": ["languages"], "Linguee": ["languages"], "Google Translate": ["languages"],
    "WordReference": ["languages"], "Duolingo": ["languages"], "Memrise": ["languages"],
    "Conjuguemos": ["languages"], "Reverso Context": ["languages"], "Forvo": ["languages"],
    "Tatoeba": ["languages"], "Lang-8 / HiNative": ["languages"],
    "Clozemaster": ["languages"], "Readlang": ["languages"],

    # Arts.
    "Canva": ["arts"], "Figma": ["arts"], "Unsplash": ["arts"], "Pexels": ["arts"],
    "The Noun Project": ["arts"], "Flaticon": ["arts"], "Coolors": ["arts"],
    "Google Fonts": ["arts"], "Remove.bg": ["arts"], "DaVinci Resolve": ["arts"],
    # OBS, Descript and Audacity are deliberately *not* tagged: they are general
    # recording tools, and claiming them for the arts made a Visual Arts
    # presentation step recommend a screen recorder over Canva.
}

# Tools that cost real time before they do anything: an install, an account, a
# format to learn. Wrong to suggest for a 20-minute step due tomorrow, right for
# a project with three weeks left.
HEAVY_SETUP = {
    "Zotero", "Mendeley", "EndNote", "Scrivener", "Ulysses", "Obsidian", "Notion",
    "Anki", "Anki Web", "RemNote", "GoodNotes", "Notability", "OneNote", "Evernote",
    "Overleaf", "Figma", "Miro", "Jupyter", "Google Colab", "Visual Studio Code",
    "OBS Studio", "DaVinci Resolve", "Audacity", "Descript", "Labster", "SageMath",
    "Habitica", "Cold Turkey", "Freedom", "MyFitnessPal", "Nike Training", "Trello",
}


# How a need is worded to a student. The vocabulary is written for a model to
# choose from; this is written for a person to read under their step.
NEED_LABELS = {
    "source_research": "Finding sources",
    "reading": "Reading",
    "note_taking": "Taking notes",
    "outlining": "Outlining",
    "drafting": "Drafting",
    "editing": "Editing",
    "proofreading": "Proofreading",
    "citation": "Citing",
    "feedback": "Getting feedback",
    "worked_examples": "Seeing it worked through",
    "problem_practice": "Practising problems",
    "error_analysis": "Checking your working",
    "computation": "Calculating",
    "graphing": "Graphing",
    "data_analysis": "Analysing data",
    "simulation": "Running it virtually",
    "diagramming": "Diagramming",
    "translation": "Translating",
    "vocabulary": "Vocabulary",
    "listening_speaking": "Listening and speaking",
    "memorisation": "Memorising",
    "spaced_practice": "Spaced practice",
    "self_testing": "Testing yourself",
    "coding": "Writing code",
    "debugging": "Debugging",
    "presentation": "Presenting",
    "design": "Design",
    "planning": "Planning",
    "focus": "Staying focused",
    "wellbeing": "Looking after yourself",
}
assert set(NEED_LABELS) == set(NEEDS), (
    "every need needs a label: " + str(set(NEEDS) ^ set(NEED_LABELS)))
