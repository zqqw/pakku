import std/[options, os, tables, unittest]
import ../src/config

suite "matchConfigSection":
  # canonical rule from src/pacman/ini.c: '[' first char + ']' last char,
  # name is the verbatim interior.

  test "plain and empty sections":
    check matchConfigSection("[options]").get == "options"
    check matchConfigSection("[]").get == ""

  test "brackets inside the name stay verbatim":
    check matchConfigSection("[a][b]").get == "a][b"
    check matchConfigSection("[nested]x]").get == "nested]x"

  test "trailing junk before a non-bracket end disqualifies":
    for s in ["[core] junk", "[options] # note"]:
      check matchConfigSection(s).isNone

suite "readConfigFile end-to-end on fixture":
  let confPath = getTempDir() / "pakku-test-pacman.conf"
  # writeLines emits real control characters: the fixture line ends with a
  # true TAB, which upstream `readLine().strip()` removes before parsing --
  # so the value arrives as "linux", matching production behavior.
  var f = open(confPath, fmWrite)
  f.write("[options]\n",
    "HoldPkg = gcc glibc\n",
    "IgnorePkg = linux\t\n",
    "X = y\n",
    "[weird]\n",
    "bad line here\n",
    "[kernel]\n")
  f.close()

  test "sections, accumulations and fallback lines parse identically":
    let (table, wasError) = readConfigFile(confPath)
    let sectionCount = table.len
    let options = table["options"][]
    let kernelEntries = table["kernel"][].len
    check not wasError
    check sectionCount == 3  # options, weird, kernel
    check options["HoldPkg"] == "gcc glibc"
    check options["IgnorePkg"] == "linux"
    check options["X"] == "y"
    # non-keyval line inside a section falls into `category[line] = ""`
    check table["weird"]["bad line here"] == ""
    check kernelEntries == 0

suite "keys the old pattern rejected":
  # `re"(\w+)\ *=\ *(.*)"` refused hyphens, non-ASCII and tabs before `=`;
  # parse_ini trims the key and keeps it verbatim, so these are valid
  # pacman.conf directives and must reach the table under their own names.
  let confPath = getTempDir() / "pakku-test-lenient.conf"
  var f = open(confPath, fmWrite)
  f.write("[options]\n",
    "my-key = v\n",
    "\xC3\x9Cnicode = x\n",
    "IgnorePkg\t= a b\n",
    "9digit = z\n")
  f.close()

  test "hyphenated, non-ASCII, tab-separated and digit-leading keys parse":
    let (table, wasError) = readConfigFile(confPath)
    let options = table["options"][]
    check not wasError
    check options["my-key"] == "v"
    check options["\xC3\x9Cnicode"] == "x"
    check options["IgnorePkg"] == "a b"
    check options["9digit"] == "z"

suite "a bracketed line with trailing junk is a directive":
  # parse_ini requires '[' first and ']' last, so `[options] junk` opens no
  # section; the reader keeps it as a bare directive of the current section
  let confPath = getTempDir() / "pakku-test-junk.conf"
  var f = open(confPath, fmWrite)
  f.write("[core]\n", "[options] junk\n", "X = y\n")
  f.close()

  test "the section stays the previous one":
    let (table, wasError) = readConfigFile(confPath)
    check not wasError
    check table.hasKey("core")
    check not table.hasKey("options")
    check table["core"]["[options] junk"] == ""
    check table["core"]["X"] == "y"
