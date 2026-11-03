## AUR package-comment extraction without a DOM, htmlparser, or regex.
##
## This module is the comment scraper used by `aur.nim`'s
## `downloadAurComments`. It is intentionally narrow: it understands only the
## markup AUR emits for package comment pages, not general HTML.
##
## Markup contract
## ===============
##
## A package page contains one or more `div` elements whose `class` contains
## `package-comments` (in practice two: pinned comments, then regular
## comments). Inside each block:
##
## * `h4` text of the form `<author> commented on <date>` identifies a comment
##   header. The current scraper does not require a class on the `h4`; this
##   parser keeps that behavior.
## * a `div` whose `class` contains `article-content` carries the body.
## * the whole block is marked `pinned` when its text contains
##   `"Pinned Comments"` (the same block-level flag the current scraper uses).
##
## Comments are paired in document order: an `h4` sets the current author and
## date, and the next `article-content` div consumes them. This is stricter
## than the old collect-all-then-zip approach and avoids mis-pairing when a
## header has no body.
##
## Algorithm
## =========
##
## One forward scan locates each `package-comments` div and its matching
## `</div>` by depth. Within the block, another forward scan finds `h4` and
## `article-content` elements and their matching closes. Only those fragments
## are decoded: tags are dropped, `br`/`p` become newlines, entities are
## decoded, and whitespace is normalized in the same pass. The scanner works
## on indices into the original page, so tags, attributes, and fragments are
## never copied before they are selected. No tree, no DOM, no regex.
##
## Scope and guarantees
## ====================
##
## * Tags and attribute names are case-insensitive; attribute values preserve
##   case.
## * Quoted and unquoted attributes are accepted; `>` inside quotes does not
##   end a tag.
## * Comments (`<!-- ... -->`) and declarations (`<!doctype ...>`, `<?...>`)
##   are skipped, including inside the comment block.
## * `script` and `style` contents are skipped as raw text.
## * Nested `div`s inside `article-content` are handled by depth counting.
## * Unclosed blocks/elements are accepted best-effort; scanning stops at the
##   end of input. This is a scraper, not a validator.
## * Unknown named entities are left literal. Decimal and hexadecimal numeric
##   entities are decoded; invalid/surrogate/out-of-range values become
##   U+FFFD.
## * The returned text is unwrapped. Paragraph/line breaks are normalized but
##   terminal wrapping remains the caller's job (`format.printComments`).
##
## Entity policy
## =============
##
## Four saved AUR pages (yay, paru, visual-studio-code-bin, spotify) contained
## only `amp`, `quot`, `gt`, `nbsp`, `copy`, and `lt`; numeric references were
## absent. The table below adds common text names defensively. It deliberately
## excludes the HTML5 math/symbol lexicon: HTML parsing is not the goal.
##
## AUR still paginates `pkgbase/<base>/?comments=all`; the fetcher in
## `aur.nim` needs paru's `packages/<base>?PP=` scheme to fetch more than the
## first page. That fetch change is orthogonal to this parser.
##
## Usage
## =====
##
## ```nim
## import aurcomments
##
## let comments = parseAurComments(readFile("page.html"))
## for c in comments:
##   echo c.author, " | ", c.date, " | pinned=", c.pinned
## ```
import std/[strutils, unicode]

{.experimental: "views".}

type
  AurComment* = object
    author*: string
    date*: string
    text*: string
    pinned*: bool

  TagKind = enum
    tkOther, tkDiv, tkH4, tkScript, tkStyle, tkBr, tkP

  Tag = object
    kind: TagKind
    openEnd: int
    classStart: int
    classLen: int
    closing: bool
    selfClose: bool

  TextState = object
    pendingBreaks: int
    pendingSpace: bool
    hasText: bool
    afterCR: bool

const
  CommentMarker = " commented on "
  MaxEntityValue = 0x10FFFF
  NoClass = -1
  MaxEntityNameLen = 32
  NamedEntities = [
    ("amp", "&"),
    ("lt", "<"),
    ("gt", ">"),
    ("quot", "\""),
    ("apos", "'"),
    ("nbsp", "\u00A0"),
    ("copy", "\u00A9"),
    ("reg", "\u00AE"),
    ("trade", "\u2122"),
    ("mdash", "\u2014"),
    ("ndash", "\u2013"),
    ("hellip", "\u2026"),
    ("laquo", "\u00AB"),
    ("raquo", "\u00BB"),
    ("lsquo", "\u2018"),
    ("rsquo", "\u2019"),
    ("ldquo", "\u201C"),
    ("rdquo", "\u201D"),
    ("euro", "\u20AC")
  ]

func sameAscii(value: openArray[char]; literal: string): bool =
  ## Compares a view with a lowercase literal without copying the view.
  if value.len != literal.len: return false
  for i in 0 ..< literal.len:
    if toLowerAscii(value[i]) != literal[i]: return false
  true

func sameBytes(value: openArray[char]; literal: string): bool =
  ## Exact view comparison for case-sensitive entity names.
  if value.len != literal.len: return false
  for i in 0 ..< literal.len:
    if value[i] != literal[i]: return false
  true

func tagKind(value: openArray[char]): TagKind =
  ## Classifies a tag-name view into the small set this scraper cares about.
  if sameAscii(value, "div"): tkDiv
  elif sameAscii(value, "h4"): tkH4
  elif sameAscii(value, "script"): tkScript
  elif sameAscii(value, "style"): tkStyle
  elif sameAscii(value, "br"): tkBr
  elif sameAscii(value, "p"): tkP
  else: tkOther

func addNewlines(state: var TextState; count: int) =
  ## Accumulates raw break bytes; `splitLines` turned n breaks into n-1
  ## separators (capped at two) in the old formatter.
  if not state.hasText: return
  state.pendingBreaks = min(state.pendingBreaks + count, 4)
  state.pendingSpace = false

func addSpace(state: var TextState) =
  ## Defers one space; trailing whitespace is dropped at breaks and field edges.
  if state.hasText and state.pendingBreaks == 0: state.pendingSpace = true

func addByte(result: var string; state: var TextState; c: char) =
  ## Flushes deferred breaks/space, then appends one byte of normalized text.
  if state.pendingBreaks > 0:
    let breaks = if state.pendingBreaks == 1: 1
                 else: min(state.pendingBreaks - 1, 2)
    for _ in 0 ..< breaks: result.add '\n'
    state.pendingBreaks = 0
  elif state.pendingSpace:
    result.add ' '
    state.pendingSpace = false
  result.add c
  state.hasText = true

func addTextChar(result: var string; state: var TextState; c: char) =
  ## Routes one raw or decoded byte into the normalizer; folds CRLF to one break.
  if state.afterCR and c == '\n':
    state.afterCR = false
    return
  state.afterCR = false
  if c == '\r':
    state.afterCR = true
    addNewlines(state, 1)
  elif c == '\n':
    addNewlines(state, 1)
  elif c in Whitespace:
    addSpace(state)
  else:
    addByte(result, state, c)

func appendEntity(name: openArray[char]; output: var string;
                  state: var TextState): bool =
  ## Decodes an entity body view into the normalizer; false means pass through.
  ## Numeric bodies keep one bounded pass: `parseSaturatedNatural` accepts
  ## `+`/`_`, `parseHex` accepts `0x`/`#`/`_` and does not saturate, and both
  ## would still need the `> 0x10FFFF` check.
  if name.len < 2: return false
  if name[0] != '#':
    for (literal, value) in NamedEntities:
      if sameBytes(name, literal):
        for c in value: addTextChar(output, state, c)
        return true
    return false

  var value = 0
  if name[1] in {'x', 'X'}:
    if name.len == 2: return false
    for i in 2 ..< name.len:
      let c = name[i]
      var digit: int
      if c in {'0'..'9'}: digit = ord(c) - ord('0')
      elif c in {'a'..'f'}: digit = ord(c) - ord('a') + 10
      elif c in {'A'..'F'}: digit = ord(c) - ord('A') + 10
      else: return false
      if value > (MaxEntityValue - digit) div 16:
        for c in "\uFFFD": addTextChar(output, state, c)
        return true
      value = value * 16 + digit
  else:
    for i in 1 ..< name.len:
      let c = name[i]
      if c notin {'0'..'9'}: return false
      let digit = ord(c) - ord('0')
      if value > (MaxEntityValue - digit) div 10:
        for c in "\uFFFD": addTextChar(output, state, c)
        return true
      value = value * 10 + digit

  if value == 0 or value in 0xD800..0xDFFF:
    for c in "\uFFFD": addTextChar(output, state, c)
  else:
    for c in toUTF8(Rune(value)): addTextChar(output, state, c)
  true

func appendDecoded(value: openArray[char]; result: var string;
                   state: var TextState) =
  ## Decodes entities in a text view while normalizing whitespace.
  var i = 0
  while i < value.len:
    if value[i] == '&':
      var j = i + 1
      let numeric = j < value.len and value[j] == '#'
      while j < value.len and (numeric or j - i <= MaxEntityNameLen) and
            value[j] != ';' and value[j] notin Whitespace: inc j
      if j < value.len and value[j] == ';' and j > i + 1 and
         appendEntity(value.toOpenArray(i + 1, j - 1), result, state):
        i = j + 1
        continue
    addTextChar(result, state, value[i])
    inc i

func decodeText(value: openArray[char]): string =
  ## Rare path: decode an entity-bearing attribute value into a string.
  var state = default(TextState)
  appendDecoded(value, result, state)

func appendCollapsed(s: string; start, stop: int; result: var string;
                     state: var TextState) =
  ## Collapses all whitespace in a slice, used for comment dates.
  for i in start ..< stop:
    if s[i] in Whitespace: addSpace(state)
    else: addByte(result, state, s[i])

func appendTrimmed(s: string; start, stop: int; result: var string) =
  ## Copies a slice without leading/trailing whitespace, preserving its interior.
  var lo = start
  var hi = stop
  while lo < hi and s[lo] in Whitespace: inc lo
  while hi > lo and s[hi - 1] in Whitespace: dec hi
  for i in lo ..< hi: result.add s[i]

func afterTag(s: string; tagStart: int): int =
  ## Index just past the next `>`; `s.len` when the tag is unterminated.
  let close = s.find('>', tagStart)
  if close < 0: s.len else: close + 1

func skipComment(s: string; start: int): int =
  ## `start` is the `<` of `<!--`; returns the index past `-->`.
  let close = s.find("-->", start + 4)
  if close < 0: s.len else: close + 3

func skipDeclaration(s: string; start: int): int =
  ## `start` is the `<` of `<!...>` or `<?...>`.
  afterTag(s, start + 2)

func scanTag(s: string; i: int; limit: int): Tag

func skipRawText(s: string; kind: TagKind; startAt, limit: int): int =
  ## Skips to a case-insensitive closing tag of the same kind, not a prefix
  ## match like `</scripture>`.
  var i = startAt
  while true:
    let lt = s.find('<', i)
    if lt < 0 or lt >= limit: return limit
    if s.continuesWith("<!--", lt):
      i = min(skipComment(s, lt), limit)
      continue
    if s.continuesWith("<!", lt) or s.continuesWith("<?", lt):
      i = min(skipDeclaration(s, lt), limit)
      continue
    let tag = scanTag(s, lt, limit)
    if tag.kind == kind and tag.closing: return tag.openEnd
    i = tag.openEnd

func scanTag(s: string; i: int; limit: int): Tag =
  ## Scans one tag at `s[i] == '<'`, clamped to `limit`. Names and attribute
  ## names stay views; only the class value offsets are retained.
  result = default(Tag)
  result.classStart = NoClass
  let endPos = limit
  var j = i + 1
  if j < endPos and s[j] == '/':
    result.closing = true
    inc j
  while j < endPos and s[j] in Whitespace: inc j
  let nameStart = j
  while j < endPos and (s[j].isAlphaNumeric or s[j] in {'-', ':', '_'}): inc j
  if j > nameStart: result.kind = tagKind(s.toOpenArray(nameStart, j - 1))
  var slashOutside = false
  while j < endPos and s[j] != '>':
    while j < endPos and s[j] in Whitespace: inc j
    if j >= endPos or s[j] == '>': break
    if s[j] == '/':
      slashOutside = true
      break
    let attrStart = j
    while j < endPos and s[j] notin Whitespace and
          s[j] notin {'=', '>', '/'}: inc j
    let isClass = sameAscii(s.toOpenArray(attrStart, j - 1), "class")
    while j < endPos and s[j] in Whitespace: inc j
    if j < endPos and s[j] == '=':
      inc j
      while j < endPos and s[j] in Whitespace: inc j
      if j < endPos and s[j] in {'"', '\''}:
        let quote = s[j]
        inc j
        let valueStart = j
        while j < endPos and s[j] != quote: inc j
        if j >= endPos:
          # Unterminated quote: recover as an unquoted value within the block.
          j = valueStart
          while j < endPos and s[j] notin Whitespace and s[j] != '>': inc j
        elif isClass and result.classStart == NoClass:
          result.classStart = valueStart
          result.classLen = j - valueStart
        if j < endPos and s[j] == quote: inc j
      else:
        let valueStart = j
        while j < endPos and s[j] notin Whitespace and s[j] != '>': inc j
        if isClass and result.classStart == NoClass:
          result.classStart = valueStart
          result.classLen = j - valueStart
  if j >= endPos:
    result.openEnd = endPos
    return
  if slashOutside:
    while j < endPos and s[j] != '>': inc j
    if j >= endPos:
      result.openEnd = endPos
      return
  result.selfClose = slashOutside
  result.openEnd = j + 1

func nextTag(s: string; start, limit: int): tuple[index: int; tag: Tag] =
  ## Next tag before `limit`, skipping comments, declarations, and raw text.
  var i = start
  while i < limit:
    let lt = s.find('<', i)
    if lt < 0 or lt >= limit: return (limit, default(Tag))
    if s.continuesWith("<!--", lt):
      i = min(skipComment(s, lt), limit)
      continue
    if s.continuesWith("<!", lt) or s.continuesWith("<?", lt):
      i = min(skipDeclaration(s, lt), limit)
      continue
    let tag = scanTag(s, lt, limit)
    if tag.kind in {tkScript, tkStyle} and not tag.closing:
      i = skipRawText(s, tag.kind, tag.openEnd, limit)
      continue
    return (lt, tag)
  (limit, default(Tag))

func findMatching(s: string; start, limit: int; kind: TagKind): tuple[index: int; openEnd: int] =
  ## Closing tag matching an already-open `kind`, or `(limit, limit)`.
  var depth = 1
  var i = start
  while true:
    let found = nextTag(s, i, limit)
    if found.index >= limit: return (limit, limit)
    if found.tag.kind == kind:
      if found.tag.closing:
        dec depth
        if depth == 0: return (found.index, found.tag.openEnd)
      elif not found.tag.selfClose: inc depth
    i = found.tag.openEnd

func classContains(s: string; tag: Tag; needle: string): bool =
  ## Matches a class-attribute view; decodes only when it contains an entity.
  if tag.classStart < 0 or tag.classLen <= 0: return false
  let value = s.toOpenArray(tag.classStart,
                            tag.classStart + tag.classLen - 1)
  for c in value:
    if c == '&': return decodeText(value).contains(needle)
  if needle.len > value.len: return false
  for i in 0 .. value.len - needle.len:
    var matches = true
    for k in 0 ..< needle.len:
      if value[i + k] != needle[k]:
        matches = false
        break
    if matches: return true
  false

func cleanFragment(s: string; start, stop: int): string =
  ## Converts a selected fragment to normalized text in one pass.
  result = newStringOfCap(stop - start)
  var state = default(TextState)
  var i = start
  while i < stop:
    let lt = s.find('<', i)
    let textEnd = if lt < 0 or lt > stop: stop else: lt
    if textEnd > i: appendDecoded(s.toOpenArray(i, textEnd - 1), result, state)
    if textEnd >= stop: break
    if s.continuesWith("<!--", lt):
      i = min(skipComment(s, lt), stop)
      continue
    if s.continuesWith("<!", lt) or s.continuesWith("<?", lt):
      i = min(skipDeclaration(s, lt), stop)
      continue
    let tag = scanTag(s, lt, stop)
    if not tag.closing:
      case tag.kind
      of tkBr: addNewlines(state, 1)
      of tkP: addNewlines(state, 2)
      of tkScript, tkStyle:
        i = skipRawText(s, tag.kind, tag.openEnd, stop)
        continue
      else: discard
    elif tag.kind == tkP:
      addNewlines(state, 2)
    i = tag.openEnd
  return result

func parseMeta(text: string; start, stop: int; author, date: var string): bool =
  ## Splits `<author> commented on <date>` using the last marker occurrence.
  let first = stop - CommentMarker.len
  var marker = -1
  if first >= start:
    for i in countdown(first, start):
      if text.continuesWith(CommentMarker, i):
        marker = i
        break
  if marker < 0: return false
  author.setLen(0)
  date.setLen(0)
  appendTrimmed(text, start, marker, author)
  var state = default(TextState)
  appendCollapsed(text, marker + CommentMarker.len, stop, date, state)
  author.len > 0

func nextDivOpen(s: string; start, limit: int): tuple[index: int; tag: Tag] =
  ## Finds the next opening `div`, skipping comments and raw text.
  var i = start
  while true:
    let found = nextTag(s, i, limit)
    if found.index >= limit: return (limit, default(Tag))
    if found.tag.kind == tkDiv and not found.tag.closing and
       not found.tag.selfClose: return found
    i = found.tag.openEnd

func parseAurComments*(html: string): seq[AurComment] =
  ## Extracts all comments from an AUR package page in document order.
  ##
  ## Text is unwrapped; the caller may wrap it for terminal output. Malformed
  ## markup is handled best-effort: unclosed elements end at the block or page
  ## boundary, and unrecognized entities remain literal.
  var search = 0
  while true:
    let opened = nextDivOpen(html, search, html.len)
    if opened.index >= html.len: return
    if not classContains(html, opened.tag, "package-comments"):
      search = opened.tag.openEnd
      continue

    let
      openEnd = opened.tag.openEnd
      blockClose = findMatching(html, openEnd, html.len, tkDiv)
      closeStart = blockClose.index

    # AUR marks pinned blocks in a header before the first h4 or body. Do not
    # let a reply mentioning "Pinned Comments" mark the whole block pinned.
    var headerEnd = closeStart
    var headerScan = openEnd
    while true:
      let candidate = nextTag(html, headerScan, closeStart)
      if candidate.index >= closeStart: break
      if candidate.tag.kind == tkH4 or
         (candidate.tag.kind == tkDiv and not candidate.tag.closing and
          classContains(html, candidate.tag, "article-content")):
        headerEnd = candidate.index
        break
      headerScan = candidate.tag.openEnd
    let pinned = "Pinned Comments" in cleanFragment(html, openEnd, headerEnd)

    var
      metaSet = false
      author, date: string
      i = openEnd
    while true:
      let found = nextTag(html, i, closeStart)
      if found.index >= closeStart: break
      let tag = found.tag
      if tag.kind == tkH4 and not tag.closing and not tag.selfClose:
        let close = findMatching(html, tag.openEnd, closeStart, tkH4)
        let header = cleanFragment(html, tag.openEnd, close.index)
        metaSet = parseMeta(header, 0, header.len, author, date)
        i = close.openEnd
      elif tag.kind == tkDiv and not tag.closing and not tag.selfClose and
           classContains(html, tag, "article-content"):
        let close = findMatching(html, tag.openEnd, closeStart, tkDiv)
        if metaSet:
          result.add AurComment(
            author: move(author),
            date: move(date),
            text: cleanFragment(html, tag.openEnd, close.index),
            pinned: pinned)
          metaSet = false
        i = close.openEnd
      else:
        i = tag.openEnd

    search = blockClose.openEnd
