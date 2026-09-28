// Tests for ThockRefModel.js against the real example files.
// Run: node test/model.test.js

var fs = require("fs")
var path = require("path")
var assert = require("assert")

var root = path.resolve(__dirname, "..")
var Model = require(path.join(root, "ThockRefModel.js"))

var passed = 0
function test(name, fn) {
  try {
    fn()
    passed += 1
    console.log("ok - " + name)
  } catch (e) {
    console.log("not ok - " + name)
    console.log("  " + (e && e.stack ? e.stack.split("\n").slice(0, 4).join("\n  ") : e))
    process.exitCode = 1
  }
}

function fixture(name) {
  return fs.readFileSync(path.join(root, "examples", name), "utf8")
}

function counts(lib) {
  var sections = 0, shortcuts = 0
  for (var i = 0; i < lib.shortcuts.length; i++) {
    if (lib.shortcuts[i].kind === "section") sections++
    else if (lib.shortcuts[i].kind === "shortcut") shortcuts++
  }
  return {
    items: lib.shortcuts.length,
    sections: sections,
    shortcuts: shortcuts,
    legendLines: lib.layoutLegend === null ? null : lib.layoutLegend.split("\n").length,
    links: lib.links.length
  }
}

function keysOf(lib) {
  var out = []
  for (var i = 0; i < lib.shortcuts.length; i++) {
    if (lib.shortcuts[i].kind === "shortcut") out.push(lib.shortcuts[i].keys)
  }
  return out
}

function sectionsOf(lib) {
  var out = []
  for (var i = 0; i < lib.shortcuts.length; i++) {
    if (lib.shortcuts[i].kind === "section") out.push(lib.shortcuts[i].title)
  }
  return out
}

// ---------------------------------------------------------------- parsing

test("herdr.md parses to the expected shape", function() {
  var lib = Model.parseLibrary(fixture("herdr.md"), "Herdr")
  assert.deepStrictEqual(counts(lib), { items: 88, sections: 10, shortcuts: 78, legendLines: 7, links: 3 })
  assert.deepStrictEqual(sectionsOf(lib), [
    "Jeff's Goto",
    "Session and General",
    "Workspaces and Worktrees",
    "Tabs",
    "Panes",
    "Navigate Mode (after ^b g)",
    "File Viewer: Open (custom bindings)",
    "File Viewer: Inside the Viewer",
    "Review a Batch of Claude Edits",
    "CLI Commands"
  ])
  var first = null
  for (var i = 0; i < lib.shortcuts.length; i++) {
    if (lib.shortcuts[i].kind === "shortcut") { first = lib.shortcuts[i]; break }
  }
  assert.deepStrictEqual(first, { kind: "shortcut", keys: "^b ?", description: "Help / show all keybindings", source: "Herdr" })
  assert.strictEqual(lib.layoutLegend.split("\n")[0], "herdr 0.9.1   prefix = ^b  (same as tmux)")
  assert.deepStrictEqual(lib.links.map(function(l) { return l.url }), [
    "https://herdr.dev",
    "https://github.com/herdrdev/herdr",
    "https://github.com/smarzban/herdr-file-viewer"
  ])
})

test("template covers backticks, arrows, extra and blank columns", function() {
  var lib = Model.parseLibrary(fixture("thockref-keybind-template.md"), "Template")
  assert.deepStrictEqual(counts(lib), { items: 32, sections: 7, shortcuts: 25, legendLines: 5, links: 1 })
  assert.deepStrictEqual(lib.links, [{ label: "Official keyboard shortcut docs", url: "https://example.com/docs/shortcuts" }])
  assert.deepStrictEqual(keysOf(lib), [
    "⌘ ⇧ p", "⌘ p", "⌘ ,",
    "⌘", "⇧", "^", "⌥", "⇥", "␣", "↑ ↓ ← →",
    "⌘k ⌘s", "⌘k z", "⌘k 1",
    "Esc", "Esc → Esc", "Cmd → Shift → 4", "Ctrl → V",
    "⌘ s", "⌘ z",
    "⌘ ↑", "⌘ ↓", "^ ↑",
    "/help", "/compact", "@filename"
  ])
})

test("an empty file is an empty library", function() {
  assert.deepStrictEqual(Model.parseLibrary(fixture("chrome.md"), "Chrome"), { shortcuts: [], layoutLegend: null, links: [] })
  assert.deepStrictEqual(Model.parseLibrary("", "X"), { shortcuts: [], layoutLegend: null, links: [] })
})

test("regression counts for larger fixtures", function() {
  assert.deepStrictEqual(counts(Model.parseLibrary(fixture("vscode.md"), "V")), { items: 126, sections: 11, shortcuts: 115, legendLines: 5, links: 2 })
  assert.deepStrictEqual(counts(Model.parseLibrary(fixture("claude-code.md"), "C")), { items: 38, sections: 7, shortcuts: 31, legendLines: 8, links: 0 })
})

test("pipe-row quirk matches the Swift parser", function() {
  // Prose containing " | " before any separator is swallowed as a header row.
  var before = Model.parseLibrary("press a | b then c\n", "Q")
  assert.deepStrictEqual(before.shortcuts, [])
  // After a separator it parses as a shortcut.
  var after = Model.parseLibrary("| K | R |\n|---|---|\npress a | b then c\n", "Q")
  assert.deepStrictEqual(after.shortcuts, [{ kind: "shortcut", keys: "press a", description: "b then c", source: "Q" }])
})

test("only level-2 headings are sections and they reset header state", function() {
  var text = "### Sub\n## Real\n| K | R |\n|---|---|\n| a | b |\n"
  var lib = Model.parseLibrary(text, "S")
  assert.deepStrictEqual(sectionsOf(lib), ["Real"])
  assert.deepStrictEqual(keysOf(lib), ["a"])
})

test("code blocks do not reset header state, unclosed fences swallow to EOF", function() {
  var text = "| K | R |\n|---|---|\n| a | b |\n```bash\necho hi\n```\n| K2 | R2 |\n| c | d |\n"
  var lib = Model.parseLibrary(text, "S")
  // The second table's header row is parsed as a shortcut, exactly like Swift.
  assert.deepStrictEqual(keysOf(lib), ["a", "K2", "c"])
  var open = Model.parseLibrary("| K | R |\n|---|---|\n```\n| x | y |\n", "S")
  assert.deepStrictEqual(open.shortcuts, [])
})

test("only the first laptop-layout block becomes the legend", function() {
  var text = "```laptop-layout\nA\nB\n```\n```laptop-layout\nC\n```\n```\nnot a legend\n```\n"
  assert.strictEqual(Model.parseLibrary(text, "L").layoutLegend, "A\nB")
  assert.strictEqual(Model.parseLibrary("```\nplain\n```\n", "L").layoutLegend, null)
})

test("rows without two non-empty cells are dropped; blank first column is skipped", function() {
  var text = "| K | RK | R |\n|---|---|---|\n| ⌘ ↑ |  | Top |\n|  |  |  |\n| only |\n"
  var lib = Model.parseLibrary(text, "S")
  assert.deepStrictEqual(lib.shortcuts, [{ kind: "shortcut", keys: "⌘ ↑", description: "Top", source: "S" }])
})

test("links are only taken from non-table lines with absolute http(s) URLs", function() {
  var text = "See [docs](https://a.example/x) and [local](file:///tmp) and [rel](/path).\n| [t](https://b.example) | d |\n|---|---|\n"
  var lib = Model.parseLibrary(text, "S")
  assert.deepStrictEqual(lib.links, [{ label: "docs", url: "https://a.example/x" }])
})

test("CRLF input parses the same as LF", function() {
  var lf = Model.parseLibrary(fixture("herdr.md"), "H")
  var crlf = Model.parseLibrary(fixture("herdr.md").replace(/\n/g, "\r\n"), "H")
  assert.deepStrictEqual(counts(crlf), counts(lf))
})

// ---------------------------------------------------------------- naming

test("libraryName strips the NNN- prefix and title-cases hyphenated parts", function() {
  assert.strictEqual(Model.libraryName("003-herdr.md"), "Herdr")
  assert.strictEqual(Model.libraryName("nvim-octo-keys.md"), "Nvim Octo Keys")
  assert.strictEqual(Model.libraryName("001-Workflow-2.0.md"), "Workflow 2.0")
  assert.strictEqual(Model.libraryName("foo--bar.md"), "Foo Bar")
  assert.strictEqual(Model.libraryName("12-x.md"), "12 X")
  assert.strictEqual(Model.libraryName("BetterTouchTool.md"), "BetterTouchTool")
  assert.strictEqual(Model.libraryName("README.MD"), "README")
})

test("parseScan filters, sorts by filename, parses, and tolerates bad input", function() {
  var raw = JSON.stringify([
    { path: "/x/010-b.md", name: "010-b.md", text: "## S\n| k | r |\n|---|---|\n| a | b |\n" },
    { path: "/x/notes.txt", name: "notes.txt", text: "| a | b |" },
    { path: "/x/002-a.MD", name: "002-a.MD", text: "" }
  ])
  var libs = Model.parseScan(raw)
  assert.deepStrictEqual(libs.map(function(l) { return l.name }), ["A", "B"])
  assert.strictEqual(libs[1].shortcuts.length, 2)
  assert.strictEqual(libs[1].shortcuts[1].source, "B")
  assert.strictEqual(libs[1].path, "/x/010-b.md")
  assert.deepStrictEqual(Model.parseScan("not json"), [])
  assert.deepStrictEqual(Model.parseScan("{}"), [])
  assert.deepStrictEqual(Model.parseScan(""), [])
  assert.strictEqual(Model.indexOfLibrary(libs, "B"), 1)
  assert.strictEqual(Model.indexOfLibrary(libs, "Zed"), -1)
})

// ---------------------------------------------------------------- search

test("normalizeQuery and expandedKeys mirror the Swift alias table", function() {
  assert.strictEqual(Model.normalizeQuery("Cmd Shift P"), "⌘ ⇧ p")
  assert.strictEqual(Model.normalizeQuery("option ctrl"), "⌥ ^")
  assert.strictEqual(Model.expandedKeys("⌘ r 1"), "⌘ r 1 command cmd")
  assert.strictEqual(Model.expandedKeys("^ ⌥ x"), "^ ⌥ x option opt alt control ctrl")
  assert.strictEqual(Model.expandedKeys("plain"), "plain")
})

test("search ranks key prefix, description prefix, key contains, then the rest", function() {
  var libs = Model.parseScan(JSON.stringify([
    { path: "/t.md", name: "001-template.md", text: fixture("thockref-keybind-template.md") },
    { path: "/h.md", name: "002-herdr.md", text: fixture("herdr.md") }
  ]))
  assert.deepStrictEqual(Model.search("", libs), [])

  var cmdP = Model.search("cmd p", libs)
  assert.ok(cmdP.length > 0)
  assert.strictEqual(cmdP[0].shortcut.keys, "⌘ p")
  assert.strictEqual(cmdP[0].keysMatch, true)
  assert.strictEqual(cmdP[0].libraryIndex, 0)

  var help = Model.search("help", libs)
  assert.strictEqual(help[0].shortcut.description, "Help / show all keybindings")
  assert.strictEqual(help[0].descMatch, true)

  // Alias expansion: a bare "c" matches every ⌘ and ^ row through the alias words.
  var c = Model.search("c", libs)
  var sawCmdOnly = false
  for (var i = 0; i < c.length; i++) {
    var s = c[i].shortcut
    if (s.keys === "⌘ ,") sawCmdOnly = c[i].keysMatch
  }
  assert.strictEqual(sawCmdOnly, true)

  // A single space is a legal query and matches keys containing spaces.
  assert.ok(Model.search(" ", libs).length > 0)

  // Equal ranks keep library order, then row order.
  var esc = Model.search("esc", libs)
  assert.strictEqual(esc[0].shortcut.keys, "Esc")
  assert.strictEqual(esc[1].shortcut.keys, "Esc → Esc")
})

test("highlightMarkup escapes and wraps the first raw-query match", function() {
  assert.strictEqual(Model.highlightMarkup("⌘ <p>", "p", "#ff0000"), '⌘ &lt;<font color="#ff0000"><b>p</b></font>&gt;')
  assert.strictEqual(Model.highlightMarkup("⌘ p", "cmd", "#ff0000"), "⌘ p")
  assert.strictEqual(Model.highlightMarkup("a & b", "", "#000"), "a &amp; b")
  assert.strictEqual(Model.highlightMarkup("Open File", "FILE", "#000"), 'Open <font color="#000"><b>File</b></font>')
  assert.deepStrictEqual(Model.highlightRange("Open File", "file"), { start: 5, length: 4 })
  assert.strictEqual(Model.highlightRange("Open File", "zzz"), null)
})

// ---------------------------------------------------------------- lists

test("detailRows appends a links header and link rows", function() {
  var lib = Model.parseLibrary("## S\n| k | r |\n|---|---|\n| a | b |\n[d](https://x.example)\n", "L")
  var rows = Model.detailRows(lib)
  assert.deepStrictEqual(rows.map(function(r) { return r.kind }), ["section", "shortcut", "linksHeader", "link"])
  assert.deepStrictEqual(rows[3], { kind: "link", label: "d", url: "https://x.example" })
  assert.deepStrictEqual(Model.detailRows(null), [])
})

test("stepCursor skips headers, clamps, and can return to the header slot", function() {
  var rows = [{ kind: "section" }, { kind: "shortcut" }, { kind: "shortcut" }, { kind: "linksHeader" }, { kind: "link" }]
  assert.strictEqual(Model.stepCursor(rows, -1, 1, true), 1)
  assert.strictEqual(Model.stepCursor(rows, 1, 1, true), 2)
  assert.strictEqual(Model.stepCursor(rows, 2, 1, true), 4)
  assert.strictEqual(Model.stepCursor(rows, 4, 1, true), 4)
  assert.strictEqual(Model.stepCursor(rows, 4, -1, true), 2)
  assert.strictEqual(Model.stepCursor(rows, 1, -1, true), -1)
  assert.strictEqual(Model.stepCursor(rows, 1, -1, false), 1)
  assert.strictEqual(Model.stepCursor([], -1, 1, true), -1)
  assert.strictEqual(Model.stepCursor([{ kind: "section" }], -1, 1, true), -1)
})

console.log((process.exitCode ? "FAILED" : "PASSED") + " " + passed + " tests")
