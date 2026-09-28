// ThockRef model: parsing, naming, search, and list helpers.
//
// A faithful port of the macOS app's MarkdownParser.swift, FuzzySearch.swift,
// and LibraryStore.swift, so both platforms render the same .md files
// identically. Kept in plain ES5 so it loads in Quickshell's QML JavaScript
// engine (`import "ThockRefModel.js" as Model`) and in Node for the tests
// (`require("./ThockRefModel.js")`).

// ---------------------------------------------------------------- strings

// Swift's `.whitespaces` set: spaces and tabs, never newlines.
function trimSpaces(s) {
  return String(s === undefined || s === null ? "" : s).replace(/^[ \t ]+|[ \t ]+$/g, "")
}

function startsWith(s, prefix) {
  return s.length >= prefix.length && s.slice(0, prefix.length) === prefix
}

function escapeHtml(s) {
  return String(s === undefined || s === null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

// ---------------------------------------------------------------- parsing

function looksLikePipeRow(line) {
  var trimmed = trimSpaces(line)
  return startsWith(trimmed, "|") || trimmed.indexOf(" | ") !== -1
}

function isSeparatorRow(line) {
  var trimmed = trimSpaces(line)
  if (!startsWith(trimmed, "|")) return false
  return trimmed.replace(/[|\-: ]/g, "") === ""
}

// Strips markdown backticks and normalises ` -> ` separators to `→`.
// e.g. "`Shift` -> `Tab`" becomes "Shift → Tab"
function normalizeKeys(raw) {
  var s = String(raw).replace(/`/g, "")
  s = s.split(" -> ").join(" → ")
  return trimSpaces(s)
}

function parsePipeCells(line) {
  var trimmed = trimSpaces(line)
  if (startsWith(trimmed, "|")) trimmed = trimmed.slice(1)
  if (trimmed.length > 0 && trimmed.charAt(trimmed.length - 1) === "|") trimmed = trimmed.slice(0, -1)
  return trimmed.split("|")
}

var LINK_PATTERN = /\[([^\]]+)\]\((https?:\/\/[^)]+)\)/g

// Only absolute http/https links, anywhere in a non-table line.
function extractLinks(line) {
  var links = []
  var match
  LINK_PATTERN.lastIndex = 0
  while ((match = LINK_PATTERN.exec(line)) !== null) {
    links.push({ label: match[1], url: match[2] })
  }
  return links
}

// Returns { shortcuts, layoutLegend, links }.
//   shortcuts: [{ kind: "section", title } | { kind: "shortcut", keys, description, source }]
//   layoutLegend: the body of the first ```laptop-layout fenced block, or null
//   links: [{ label, url }]
function parseLibrary(text, source) {
  var shortcuts = []
  var layoutLegend = null
  var links = []

  var lines = String(text === undefined || text === null ? "" : text).split(/\r\n|\r|\n/)
  var index = 0
  var passedHeader = false

  while (index < lines.length) {
    var line = lines[index]

    if (startsWith(line, "```")) {
      var isLayoutBlock = startsWith(line, "```laptop-layout")
      var blockLines = []
      index += 1
      while (index < lines.length && !startsWith(lines[index], "```")) {
        blockLines.push(lines[index])
        index += 1
      }
      index += 1 // consume closing ```
      if (isLayoutBlock && layoutLegend === null) {
        layoutLegend = blockLines.join("\n")
      }
      // Don't reset passedHeader: code blocks can appear between table sections.
      continue
    }

    if (looksLikePipeRow(line)) {
      if (isSeparatorRow(line)) {
        passedHeader = true
        index += 1
        continue
      }
      if (!passedHeader) {
        // Header row: skip it and wait for the separator.
        index += 1
        continue
      }
      var cells = parsePipeCells(line)
      var trimmedCells = []
      for (var c = 0; c < cells.length; c++) trimmedCells.push(trimSpaces(cells[c]))
      // First non-empty cell is the key sequence, the next non-empty cell after
      // it is the description. Extra columns and blank reverse-binding
      // columns are skipped.
      var keysIdx = -1
      var descIdx = -1
      for (var k = 0; k < trimmedCells.length; k++) {
        if (trimmedCells[k] !== "") { keysIdx = k; break }
      }
      if (keysIdx !== -1) {
        for (var d = keysIdx + 1; d < trimmedCells.length; d++) {
          if (trimmedCells[d] !== "") { descIdx = d; break }
        }
      }
      if (keysIdx !== -1 && descIdx !== -1) {
        shortcuts.push({
          kind: "shortcut",
          keys: normalizeKeys(trimmedCells[keysIdx]),
          description: trimmedCells[descIdx],
          source: source
        })
      }
      index += 1
      continue
    }

    // A non-table, non-blank line resets the header state so the next table's
    // header row is treated correctly.
    var trimmedLine = trimSpaces(line)
    if (trimmedLine !== "") {
      passedHeader = false
      if (startsWith(trimmedLine, "## ")) {
        shortcuts.push({ kind: "section", title: trimSpaces(trimmedLine.slice(3)) })
      } else {
        var found = extractLinks(trimmedLine)
        for (var l = 0; l < found.length; l++) links.push(found[l])
      }
    }
    index += 1
  }

  return { shortcuts: shortcuts, layoutLegend: layoutLegend, links: links }
}

// ---------------------------------------------------------------- naming

// "003-herdr.md" -> "Herdr", "nvim-octo-keys.md" -> "Nvim Octo Keys",
// "Workflow-2.0.md" -> "Workflow 2.0". Mirrors LibraryStore.libraryName.
function libraryName(filename) {
  var base = String(filename === undefined || filename === null ? "" : filename)
  var dot = base.lastIndexOf(".")
  if (dot > 0) base = base.slice(0, dot)
  base = base.replace(/^\d{3}-/, "")
  var parts = base.split("-")
  var words = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "") continue // Swift's split(separator:) drops empty parts
    words.push(part.charAt(0).toUpperCase() + part.slice(1))
  }
  return words.join(" ")
}

function isMarkdownFilename(name) {
  var s = String(name || "")
  var dot = s.lastIndexOf(".")
  if (dot < 0) return false
  return s.slice(dot + 1).toLowerCase() === "md"
}

// Sorted by raw filename, which is why the NNN- prefix controls the order.
function sortByFilename(entries) {
  var indexed = []
  for (var i = 0; i < entries.length; i++) indexed.push({ entry: entries[i], index: i })
  indexed.sort(function(a, b) {
    var an = String(a.entry.name || "")
    var bn = String(b.entry.name || "")
    if (an < bn) return -1
    if (an > bn) return 1
    return a.index - b.index
  })
  var out = []
  for (var j = 0; j < indexed.length; j++) out.push(indexed[j].entry)
  return out
}

// Turns the JSON emitted by list-libraries.sh ([{path, name, text}]) into
// parsed libraries: [{ name, filename, path, shortcuts, layoutLegend, links }].
function parseScan(rawJson) {
  var entries
  try {
    entries = JSON.parse(String(rawJson === undefined || rawJson === null ? "" : rawJson))
  } catch (e) {
    return []
  }
  if (!entries || Object.prototype.toString.call(entries) !== "[object Array]") return []

  var kept = []
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (!entry || typeof entry !== "object") continue
    if (!isMarkdownFilename(entry.name)) continue
    kept.push(entry)
  }
  kept = sortByFilename(kept)

  var libraries = []
  for (var j = 0; j < kept.length; j++) {
    var e = kept[j]
    var name = libraryName(e.name)
    var parsed = parseLibrary(typeof e.text === "string" ? e.text : "", name)
    libraries.push({
      name: name,
      filename: String(e.name),
      path: String(e.path || ""),
      shortcuts: parsed.shortcuts,
      layoutLegend: parsed.layoutLegend,
      links: parsed.links
    })
  }
  return libraries
}

function indexOfLibrary(libraries, name) {
  for (var i = 0; i < libraries.length; i++) {
    if (libraries[i] && libraries[i].name === name) return i
  }
  return -1
}

// ---------------------------------------------------------------- search

var SYMBOL_ALIASES = [
  { symbol: "⌘", aliases: ["command", "cmd"] },
  { symbol: "⇧", aliases: ["shift"] },
  { symbol: "⌥", aliases: ["option", "opt", "alt"] },
  { symbol: "^", aliases: ["control", "ctrl"] }
]

// Replaces alias words in the query with their symbols: "cmd r 1" -> "⌘ r 1".
function normalizeQuery(query) {
  var result = String(query).toLowerCase()
  for (var i = 0; i < SYMBOL_ALIASES.length; i++) {
    var aliases = SYMBOL_ALIASES[i].aliases
    for (var j = 0; j < aliases.length; j++) {
      result = result.split(aliases[j]).join(SYMBOL_ALIASES[i].symbol)
    }
  }
  return result
}

// Augments a stored key string with alias words for any symbols present, so
// "⌘ r 1" also matches bare alias queries like "c", "cm", "cmd".
function expandedKeys(keys) {
  var extras = []
  for (var i = 0; i < SYMBOL_ALIASES.length; i++) {
    if (keys.indexOf(SYMBOL_ALIASES[i].symbol) !== -1) {
      extras = extras.concat(SYMBOL_ALIASES[i].aliases)
    }
  }
  return extras.length === 0 ? keys : keys + " " + extras.join(" ")
}

// Substring search across every library. Returns
// [{ shortcut, keysMatch, descMatch, libraryIndex }] ranked: key-sequence
// prefix, description prefix, key-sequence contains, then the rest.
function search(query, libraries) {
  var q = String(query === undefined || query === null ? "" : query)
  if (q === "") return []
  q = normalizeQuery(q)

  var scored = []
  var order = 0
  for (var li = 0; li < libraries.length; li++) {
    var items = libraries[li].shortcuts || []
    for (var si = 0; si < items.length; si++) {
      var item = items[si]
      if (!item || item.kind !== "shortcut") continue
      var keys = expandedKeys(item.keys).toLowerCase()
      var desc = String(item.description).toLowerCase()
      var keysHit = keys.indexOf(q) !== -1
      var descHit = desc.indexOf(q) !== -1
      if (!keysHit && !descHit) continue

      var rank
      if (startsWith(String(item.keys).toLowerCase(), q)) rank = 0
      else if (startsWith(desc, q)) rank = 1
      else if (keysHit) rank = 2
      else rank = 3

      scored.push({
        result: { shortcut: item, keysMatch: keysHit, descMatch: descHit, libraryIndex: li },
        rank: rank,
        order: order++
      })
    }
  }
  scored.sort(function(a, b) {
    if (a.rank !== b.rank) return a.rank - b.rank
    return a.order - b.order
  })
  var results = []
  for (var r = 0; r < scored.length; r++) results.push(scored[r].result)
  return results
}

// First case-insensitive occurrence of the raw query, as { start, length },
// or null. Mirrors ContentView.highlightedText.
function highlightRange(text, query) {
  var t = String(text === undefined || text === null ? "" : text)
  var q = String(query === undefined || query === null ? "" : query)
  if (q === "") return null
  var start = t.toLowerCase().indexOf(q.toLowerCase())
  if (start === -1) return null
  return { start: start, length: q.length }
}

// StyledText markup with the match bold and colored. Input is escaped so
// file contents can never inject markup.
function highlightMarkup(text, query, colorHex) {
  var t = String(text === undefined || text === null ? "" : text)
  var range = highlightRange(t, query)
  if (!range) return escapeHtml(t)
  var before = t.slice(0, range.start)
  var match = t.slice(range.start, range.start + range.length)
  var after = t.slice(range.start + range.length)
  return escapeHtml(before)
    + '<font color="' + String(colorHex) + '"><b>' + escapeHtml(match) + "</b></font>"
    + escapeHtml(after)
}

// ---------------------------------------------------------------- lists

// Flat row model for the detail view: the library's shortcut/section items
// followed by a links header and one row per link.
function detailRows(library) {
  if (!library) return []
  var rows = []
  var items = library.shortcuts || []
  for (var i = 0; i < items.length; i++) rows.push(items[i])
  var links = library.links || []
  if (links.length > 0) {
    rows.push({ kind: "linksHeader" })
    for (var j = 0; j < links.length; j++) {
      rows.push({ kind: "link", label: links[j].label, url: links[j].url })
    }
  }
  return rows
}

function isSelectable(row) {
  if (!row) return false
  return row.kind === "library" || row.kind === "result" || row.kind === "shortcut" || row.kind === "link"
}

// Moves a cursor through `rows` by `delta` (±1), skipping rows that cannot be
// selected and clamping at the ends. When `allowHeader` is true, moving up
// past the first selectable row lands on -1 (the header position).
function stepCursor(rows, from, delta, allowHeader) {
  var count = rows ? rows.length : 0
  if (count === 0) return -1
  var step = delta < 0 ? -1 : 1
  var i = (from === undefined || from === null) ? -1 : from
  while (true) {
    var next = i + step
    if (next < 0) return allowHeader ? -1 : (isSelectable(rows[i]) ? i : firstSelectable(rows))
    if (next >= count) return isSelectable(rows[i]) ? i : lastSelectable(rows)
    if (isSelectable(rows[next])) return next
    i = next
  }
}

function firstSelectable(rows) {
  for (var i = 0; i < rows.length; i++) if (isSelectable(rows[i])) return i
  return -1
}

function lastSelectable(rows) {
  for (var i = rows.length - 1; i >= 0; i--) if (isSelectable(rows[i])) return i
  return -1
}

// ---------------------------------------------------------------- exports

if (typeof module !== "undefined") {
  module.exports = {
    trimSpaces: trimSpaces,
    escapeHtml: escapeHtml,
    parseLibrary: parseLibrary,
    libraryName: libraryName,
    sortByFilename: sortByFilename,
    parseScan: parseScan,
    indexOfLibrary: indexOfLibrary,
    normalizeQuery: normalizeQuery,
    expandedKeys: expandedKeys,
    search: search,
    highlightRange: highlightRange,
    highlightMarkup: highlightMarkup,
    detailRows: detailRows,
    isSelectable: isSelectable,
    stepCursor: stepCursor,
    firstSelectable: firstSelectable,
    lastSelectable: lastSelectable
  }
}
