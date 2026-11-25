import std/[options, os, sets, strutils, tables, unittest]
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
      "IgnoreArch = 1\nViewNoDefault = no\nCheckDevel\n")
    check not cfg.aurComments
    check cfg.checkIgnored
    check cfg.ignoreArch
    check not cfg.viewNoDefault
    check cfg.checkDevel

  test "an unparsable flag value is reported":
    check "invalid value 'off' for 'PrintAurNotFound'" in
      errorOf("[options]\nPrintAurNotFound = off\n")

suite "devel ignore options":
  test "ignore lists are parsed from whitespace or commas":
    let cfg = configOf("[options]\n" &
      "IgnoreDevel = foo-git bar-*\n" &
      "IgnoreDevelSource = https://bad.example/*, *://mirror/*\n")
    check cfg.ignoreDevel == @["foo-git", "bar-*"]
    check cfg.ignoreDevelSource == @["https://bad.example/*", "*://mirror/*"]

  test "ignore patterns match package names and git URLs":
    let cfg = configOf("[options]\n" &
      "IgnoreDevel = foo-* exact-git\n" &
      "IgnoreDevelSource = *://bad.example/*\n")
    check cfg.develIgnored("foo-git")
    check cfg.develIgnored("exact-git")
    check not cfg.develIgnored("bar-git")
    check cfg.develSourceIgnored("https://bad.example/x.git")
    check not cfg.develSourceIgnored("https://good.example/x.git")

  test "devel suffixes have broad defaults and can be overridden":
    let cfg = configOf("[options]\n")
    check "cvs" in cfg.develSuffixes
    check "nightly" in cfg.develSuffixes
    check cfg.hasDevelSuffix("foo-nightly")
    let custom = configOf("[options]\nDevelSuffixes = git -nightly\n")
    check custom.develSuffixes == @["git", "nightly"]
    check custom.hasDevelSuffix("foo-nightly")
    check not custom.hasDevelSuffix("foo-cvs")

suite "glob matching":
  proc ignores(pattern, value: string): bool =
    configOf("[options]\nIgnoreDevel = " & pattern & "\n").develIgnored(value)

  test "exact names do not match prefixes":
    check ignores("foo-git", "foo-git")
    check not ignores("foo-git", "foo-git-extra")
    check not ignores("foo-git", "bar-git")

  test "question mark matches exactly one character":
    check ignores("foo-?it", "foo-git")
    check not ignores("foo-?", "foo-git")
    check not ignores("?", "ab")

  test "star matches any run, including none":
    check ignores("foo-*", "foo-")
    check ignores("foo-*", "foo-git")
    check ignores("*git", "git")
    check ignores("*git", "foo-git")
    check not ignores("*git", "foo-gits")

  test "a star backtracks to the rest of the pattern":
    check ignores("foo*baz", "foo-a-b-baz")
    check not ignores("foo*baz", "foo-a-bay")
    check ignores("foo**bar", "foo-bar")

  test "URL patterns ignore every transport":
    let cfg = configOf("[options]\n" &
      "IgnoreDevelSource = *://bad.example/*\n")
    check cfg.develSourceIgnored("https://bad.example/x.git")
    check cfg.develSourceIgnored("git://bad.example/x.git")
    check not cfg.develSourceIgnored("https://good.example/x.git")

suite "directory patterns":
  test "directory options expand variables once":
    let
      initial = initialUser.get(currentUser)
      cfg = configOf("[options]\n" &
        "UserCacheDir = ${HOME}/cache-${USER}-${UID}\n" &
        "TmpDir = /tmp/pakku-$${USER}\n" &
        "PackageOutputDir = ${HOME}/out\n")
      initialCache = initial.home /
        ("cache-" & initial.name & "-" & $initial.uid)
      currentCache = currentUser.home /
        ("cache-" & currentUser.name & "-" & $currentUser.uid)
    check cfg.userCacheInitial == initialCache
    check cfg.userCacheCurrent == currentCache
    check cfg.tmpRootInitial == "/tmp" / "pakku-${USER}"
    check cfg.tmpRootCurrent == "/tmp" / "pakku-${USER}"
    check cfg.packageOutputDir == initial.home / "out"

  test "default directory templates use the initial user":
    let
      initial = initialUser.get(currentUser)
      cfg = configOf("[options]\n")
    check cfg.userCacheInitial == initial.home / ".cache" / "pakku"
    check cfg.tmpRootInitial == "/tmp" / ("pakku-" & initial.name)

  test "repeated slashes collapse in sysroot paths":
    let pc = PacmanConfig(common: CommonConfig(dbs: @["core"], arch: "x86_64"),
      sysroot: "/sys//root", colorMode: ColorMode.colorNever)
    check obtainConfig(pc, fixture("[options]\n")).root == "/sys/root/"

  test "sysroot joins resolve dot components and keep trailing separators":
    let pc = PacmanConfig(common: CommonConfig(dbs: @["core"], arch: "x86_64"),
      sysroot: "/sys//root",
      dbRelOption: some("/var/../lib/pacman/"),
      colorMode: ColorMode.colorNever)
    check obtainConfig(pc, fixture("[options]\n")).db == "/sys/root/lib/pacman/"

suite "ordinary ignores":
  test "package names and groups are ignored without set temporaries":
    let cfg = Config(common: CommonConfig(
      ignorePkgs: @["foo"].toHashSet,
      ignoreGroups: @["base"].toHashSet))
    check cfg.ignored("foo", [])
    check cfg.ignored("bar", ["base"])
    check cfg.ignored("bar", ["other", "base"])
    check not cfg.ignored("bar", ["other"])
    check not cfg.ignored("baz", [])

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
