import std/[options, unittest]
import ../src/utils

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

suite "containsIgnoreCase":
  test "matches ASCII case without allocating lowered strings":
    check containsIgnoreCase("Visual-Studio-Code-Bin", "code")
    check containsIgnoreCase("FOOBAR", "bar")
    check not containsIgnoreCase("foobar", "baz")

  test "empty pattern matches":
    check containsIgnoreCase("anything", "")

  test "pattern longer than text fails":
    check not containsIgnoreCase("abc", "abcd")

suite "parseNumberIntervals":
  test "returns only requested intervals":
    check parseNumberIntervals("2 4-5", 10).get == @[2..2, 4..5]

  test "merges adjacent ranges":
    check parseNumberIntervals("1-2,3 5", 10).get == @[1..3, 5..5]

  test "rejects invalid values":
    check parseNumberIntervals("0", 10).isNone
