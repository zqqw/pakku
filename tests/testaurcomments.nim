## Tests for the DOM-free AUR comment parser.
import std/[random, strutils, unittest]
import ../src/aurcomments

const page = """
<!DOCTYPE html>
<html><head>
<script>var fake = "<div class='package-comments'>";</script>
</head><body>
<!-- <div class="comments package-comments">fake</div> -->
<div class="box">
  <div class="comments package-comments">
    <div class="comments-header"><h3><span>Pinned Comments</span></h3></div>
    <h4 id="c1" class="comment-header">
      Alice commented on 2026-01-01 10:00 (UTC)
    </h4>
    <div id="c1-content" class="article-content">
      <div>
        <p>Hello &amp; welcome.</p>
        <p>Second <code>line</code>.</p>
      </div>
    </div>
    <H4 class="comment-header">Bob commented on 2026-01-02</H4>
    <DIV CLASS="article-content"><p>Text<br>next &#65; &#x42; &unknown; &nbsp;end</p></DIV>
  </div>
  <div class="comments package-comments">
    <div class="comments-header"><h3>Comments</h3></div>
    <h4 class="comment-header">Carol commented on 2026-01-03</h4>
    <div class="article-content"><p>Regular</p></div>
  </div>
</div>
</body></html>
"""

const
  plainAlphabet = "&;#'= \"abcdefghijklmnopqrstuvwxyz0123456789\n\t"
  markupAlphabet = "<>/" & plainAlphabet

proc randomText(rng: var Rand; size: int; alphabet: string): string =
  result = newStringOfCap(size)
  for _ in 0 ..< size:
    result.add alphabet[rng.rand(0 .. alphabet.len - 1)]


suite "parseAurComments":
  test "pinned and regular blocks":
    let comments = parseAurComments(page)
    check comments.len == 3
    check comments[0].author == "Alice"
    check comments[0].date == "2026-01-01 10:00 (UTC)"
    check comments[0].text == "Hello & welcome.\n\nSecond line."
    check comments[0].pinned
    check comments[1].author == "Bob"
    check comments[1].date == "2026-01-02"
    check comments[1].text == "Text\nnext A B &unknown; \u00A0end"
    check comments[1].pinned
    check comments[2].author == "Carol"
    check comments[2].date == "2026-01-03"
    check comments[2].text == "Regular"
    check not comments[2].pinned

  test "unclosed markup":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>X commented on Y</h4>" &
      "<div class=\"article-content\">open")
    check comments.len == 1
    check comments[0].author == "X"
    check comments[0].date == "Y"
    check comments[0].text == "open"

  test "named and invalid numeric entities":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>A commented on B</h4>" &
      "<div class=\"article-content\">" &
      "&apos; &#65; &#x42; &#xD800; &#0; &bogus; &lt; &AMP;" &
      "</div></div>")
    check comments.len == 1
    check comments[0].text == "' A B \uFFFD \uFFFD &bogus; < &AMP;"

  test "oversized numeric entities":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>A commented on B</h4>" &
      "<div class=\"article-content\">" &
      "&#99999999999999999999; &#xFFFFFFFFFFFFFFFFFFFF;" &
      "</div></div>")
    check comments.len == 1
    check comments[0].text == "\uFFFD \uFFFD"

  test "markup in headers and paragraph breaks":
    let comments = parseAurComments(
      "<div class=\"package-comments\">" &
      "<h4><b>Alice</b> commented on 2026-01-01</h4>" &
      "<div class=\"article-content\"><p>one</p><p>two</p>line<br>break</div>" &
      "</div>")
    check comments.len == 1
    check comments[0].author == "Alice"
    check comments[0].date == "2026-01-01"
    check comments[0].text == "one\n\ntwo\nline\nbreak"

  test "numeric whitespace entities and long references":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>A commented on B</h4>" &
      "<div class=\"article-content\">" &
      "a&#9;b&#10;c&#32;d&#13;&#10;e&#00000000000000000000000000000000000065;" &
      "</div></div>")
    check comments.len == 1
    check comments[0].text == "a b\nc d\neA"

  test "raw-text decoys and self-closing tags":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>A commented on B</h4>" &
      "<div class=\"article-content\">" &
      "<SCRIPT>var x=1;</scripture>visible</SCRIPT>" &
      "<div data-url=\"http://x/\">inner</div>tail<div/>tail2" &
      "</div></div>")
    check comments.len == 1
    check comments[0].text == "innertailtail2"

  test "pinned flag comes from the block header":
    let comments = parseAurComments(
      "<div class=\"package-comments\"><h4>A commented on B</h4>" &
      "<div class=\"article-content\">Pinned Comments</div></div>")
    check comments.len == 1
    check not comments[0].pinned

  test "no comments":
    check parseAurComments("<html><body><p>none</p></body></html>").len == 0

  test "seeded malformed-input smoke":
    var rng = initRand(20261118)
    var seen = 0
    for _ in 0 ..< 2_000:
      let header = "u" & randomText(rng, rng.rand(1..40), plainAlphabet)
      let body = randomText(rng, rng.rand(1..120), markupAlphabet)
      let html = "<div class=\"package-comments\">" &
                 "<h4>" & header & " commented on 2026-11-18</h4>" &
                 "<div class=\"article-content\">" & body &
                 "</div></div>"
      var valid = true
      for c in parseAurComments(html):
        inc seen
        valid = valid and c.author.len > 0 and c.text == c.text.strip
        for ch in c.text:
          if ch in {'\r', '\v', '\f'}: valid = false
      check valid
    check seen > 0
