import std/[options, strutils, unittest]
import ../src/utils

suite "stripHtmlTags":
  test "removes well-formed markup regions":
    check stripHtmlTags("<b>bold</b>") == "bold"
    check stripHtmlTags("<i>a</i>b<p>c") == "abc"
    check stripHtmlTags("plain text") == "plain text"

  test "region ends at first closing bracket":
    check stripHtmlTags("""<b>hi</b> x <a href="l>weird">y""") ==
      "hi x weird\">y"
    check stripHtmlTags("<>>x") == ">x"

  test "empty regions disappear":
    check stripHtmlTags("<>") == ""

  test "regions never span lines":
    check stripHtmlTags("<a\nb>x") == "<a\nb>x"
    check stripHtmlTags("a\n<a\nb>c<d>e") == "a\n<a\nb>ce"

  test "unterminated opener survives verbatim":
    for s in ["<abc", "<abc ", "a<"]:
      check stripHtmlTags(s) == s

  test "scanning resumes after a lone '<'":
    check stripHtmlTags("a<b\nc>x<y>d") == "a<b\nc>xd"

suite "replaceRuns":
  test "collapses runs of spaces to one space":
    check replaceRuns("a  b", {' '}, 2, " ") == "a b"
    check replaceRuns("a     b", {' '}, 2, " ") == "a b"

  test "runs shorter than minRun pass through":
    check replaceRuns("a b c", {' '}, 2, " ") == "a b c"
    check replaceRuns("no-space", {' '}, 2, " ") == "no-space"

  test "newline runs cap at two newlines":
    check replaceRuns("a\n\n\n\n\n\nb", {'\n'}, 2, "\n\n") == "a\n\nb"
    check replaceRuns("a\nb", {'\n'}, 2, "\n\n") == "a\nb"

  test "mixed blanks collapse to a single space":
    check replaceRuns("a \tb", {' ', '\t'}, 2, " ") == "a b"
    # a lone tab never rewrites to a space

  test "fills can expand a collapsed run":
    # each qualifying run maps to exactly one `by`, whatever its length
    check replaceRuns("a\n\n\nb", {'\n'}, 2, "\n\n") == "a\n\nb"

  test "runs at both ends are rewritten":
    check replaceRuns("   x   ", {' '}, 2, " ") == " x "

suite "splitKeyval (INI directive splitting)":
  # contract follows pacman parse_ini + every lenient .SRCINFO reader:
  # split at first "=", strtrim both halves; empty key or missing "=" never
  # matches; values keep everything else verbatim.

  test "plain and repeated assignments":
    check splitKeyval("k = v").get ==
      (key: "k", value: "v")
    check splitKeyval("IgnorePkg = foo bar").get ==
      (key: "IgnorePkg", value: "foo bar")
    check splitKeyval("a=b").get == (key: "a", value: "b")

  test "whitespace of every kind around = is trimmed":
    check splitKeyval("k\t= v").get == (key: "k", value: "v")
    check splitKeyval("k = v ").get == (key: "k", value: "v")
    check splitKeyval("\tkey =\tvalue\t").get ==
      (key: "key", value: "value")

  test "digit-leading keys match pacman leniency":
    check splitKeyval("9k = v").get.key == "9k"

  test "first = splits, later ones belong to the value":
    check splitKeyval("a == b").get.value == "= b"
    check splitKeyval("X = y=z").get.value == "y=z"

  test "empty values are matches with an empty string":
    check splitKeyval("key =").get.value == ""

  test "lines without = or without a key never match":
    for s in ["onlytext", "Quiet", "", " ", "=", " = nokey"]:
      check splitKeyval(s).isNone

suite "replaceRuns across the whitespace class":
  # the comment formatter collapses `re"\s{2,}"` in scraped dates, so the set
  # has to cover newlines, not just spaces and tabs
  test "runs containing newlines collapse with Whitespace":
    check replaceRuns("a\n  b", Whitespace, 2, " ") == "a b"
    check replaceRuns("a \r\n b", Whitespace, 2, " ") == "a b"

  test "space-and-tab alone leaves the newline in place":
    check replaceRuns("a\n  b", {' ', '\t'}, 2, " ") == "a\n b"
