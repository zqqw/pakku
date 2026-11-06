import std/[options, os, strutils, tables, unittest]
import ../src/[config, utils]

## Covers the pakku.conf side of the parser: comment stripping, the option
## schema and the diagnostics `obtainConfig` reports for a bad file.

let
  testDir = getTempDir() / "pakku-config-test"
  pacmanConfig = PacmanConfig(common: CommonConfig(dbs: @["core"], arch: "x86_64"),
    colorMode: ColorMode.colorNever)

createDir(testDir)

proc fixture(conf: string): string =
  createDir(testDir)
  result = testDir / "pakku.conf"
  writeFile(result, conf)

proc configOf(conf: string): Config =
  obtainConfig(pacmanConfig, fixture(conf))

proc errorOf(conf: string): string =
  ## `obtainConfig` funnels every problem into one CommandError; return its
  ## message so a test can match on the reported keys and values.
  try:
    discard configOf(conf)
  except CommandError as e:
    result = e.msg

suite "readConfigFile comment handling":
  let confPath = testDir / "comments.conf"
  writeFile(confPath, "[options]\nPlain = value # note\nHash = a#b\n" &
    "  # indented comment\nBare\n")

  test "pacman.conf semantics keep '#' verbatim":
    let (table, wasError) = readConfigFile(confPath)
    check not wasError
    check table["options"]["Plain"] == "value # note"
    check table["options"]["Hash"] == "a#b"
    check table["options"]["Bare"] == ""

  test "pakku.conf semantics drop trailing comments":
    let (table, wasError) = readConfigFile(confPath, inlineComments = true)
    check not wasError
    check table["options"]["Plain"] == "value"
    check table["options"]["Hash"] == "a#b"

suite "option values":
  test "inline comments do not become part of a value":
    let cfg = configOf("[options]\nPreserveBuilt = Pkgdest # keep them\n" &
      "CleanupAfterInstall = Worktree\t# archives stay\n")
    check cfg.preserveBuilt == PreserveBuilt.pkgdest
    check cfg.cleanupAfterInstall == CleanupPolicy.worktree

  test "'#' inside a value is preserved":
    let cfg = configOf("[options]\nPreBuildCommand = sed -i s/a#b/c/ PKGBUILD\n")
    check cfg.preBuildCommand == some("sed -i s/a#b/c/ PKGBUILD")

  test "directory patterns expand around a stripped comment":
    check configOf("[options]\nPackageOutputDir = /tmp/out # where\n").packageOutputDir ==
      "/tmp/out"

suite "flag options":
  test "a bare key enables the option":
    let cfg = configOf("[options]\nAurComments\nCheckIgnored\n")
    check cfg.aurComments
    check cfg.checkIgnored

  test "explicit booleans override presence":
    let cfg = configOf("[options]\nAurComments = false\nCheckIgnored = yes\n" &
      "IgnoreArch = 1\nViewNoDefault = no\n")
    check not cfg.aurComments
    check cfg.checkIgnored
    check cfg.ignoreArch
    check not cfg.viewNoDefault

  test "an unparsable flag value is reported":
    check "invalid value 'off' for 'PrintAurNotFound'" in
      errorOf("[options]\nPrintAurNotFound = off\n")

suite "diagnostics":
  test "an unknown key names the option and the file":
    let message = errorOf("[options]\nFrobnicate = 1\n")
    check "unknown option 'Frobnicate'" in message
    check (testDir / "pakku.conf") in message

  test "enum values are matched exactly as documented":
    for value in ["Ful", "full", "FULL", "Full_", ""]:
      check ("invalid value '" & value & "' for 'CleanupAfterInstall'") in
        errorOf("[options]\nCleanupAfterInstall = " & value & "\n")

  test "every problem is reported in one message":
    let message = errorOf("[options]\nFrobnicate = 1\n" &
      "CleanupAfterInstall = nope\nAurComments = maybe\n")
    check message.count('\n') == 3

suite "defaults":
  test "a missing options section keeps the defaults":
    let cfg = configOf("")
    check cfg.cleanupAfterInstall == CleanupPolicy.full
    check cfg.preserveBuilt == PreserveBuilt.disabled
    check not cfg.aurComments
    check cfg.aurRepo == "aur"

  test "a missing file keeps the defaults":
    let cfg = obtainConfig(pacmanConfig, testDir / "absent.conf")
    check cfg.cleanupAfterInstall == CleanupPolicy.full
    check cfg.preserveBuilt == PreserveBuilt.disabled
