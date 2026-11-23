import std/[options, sequtils, unittest]
import ../src/helperresolve

## Pins the helper search order and the choice among candidates. Both are pure,
## so no helper binary has to exist for these checks.

proc candidate(state: HelperState; source: HelperSource;
    fatalOnMismatch = false): HelperCandidate =
  HelperCandidate(
    location: HelperLocation(command: @["/nowhere/install"], source: source),
    state: state, protocol: "1", fatalOnMismatch: fatalOnMismatch)

suite "helper locations":
  test "install prefixes come first, the built one leading":
    let locations = helperLocations("install", "/usr/bin", "/usr/lib/pakku",
      dev = true)
    check locations.mapIt(it.source) == @[
      HelperSource.compiledPrefix, HelperSource.standardPrefix,
      HelperSource.devTree, HelperSource.devTree]
    check locations[0].command == @["/usr/lib/pakku/install"]
    check locations[0].tools == "/usr/lib/pakku/tools"
    check locations[1].command == @["/usr/local/lib/pakku/install"]
    check locations.filterIt(it.tools == "/usr/lib/pakku/tools").len == 1

  test "a release build looks at install prefixes only":
    let locations = helperLocations("install", "/usr/bin", "/usr/lib/pakku",
      dev = false)
    check locations.mapIt(it.source) == @[
      HelperSource.compiledPrefix, HelperSource.standardPrefix]
    check locations.mapIt(it.command[0]) == @[
      "/usr/lib/pakku/install", "/usr/local/lib/pakku/install"]

  test "a custom built prefix leads and is not repeated":
    let locations = helperLocations("install", "/home/dev/pakku",
      "/usr/local/lib/pakku", dev = false)
    check locations.mapIt(it.command[0]) == @[
      "/usr/local/lib/pakku/install", "/usr/lib/pakku/install"]

  test "a development tree passes the tool as argv[1]":
    let locations = helperLocations("bisect", "/src/pakku",
      "/usr/local/lib/pakku", dev = true)
    let dev = locations.filterIt(it.source == HelperSource.devTree)
    check dev.mapIt(it.command) == @[
      @["/src/pakku/lib/tools", "bisect"],
      @["/src/lib/tools", "bisect"]]

suite "helper choice":
  test "the first compatible helper wins":
    check chooseHelper(@[
      candidate(HelperState.absent, HelperSource.compiledPrefix),
      candidate(HelperState.compatible, HelperSource.standardPrefix)]) == some(1)

  test "a helper that cannot be probed stays usable":
    check chooseHelper(@[
      candidate(HelperState.unverified, HelperSource.compiledPrefix)]) == some(0)

  test "a mismatch at a standard prefix skips to the next candidate":
    check chooseHelper(@[
      candidate(HelperState.absent, HelperSource.compiledPrefix),
      candidate(HelperState.incompatible, HelperSource.standardPrefix),
      candidate(HelperState.compatible, HelperSource.devTree)]) == some(2)

  test "a mismatch in the installed prefix stops the walk":
    check chooseHelper(@[
      candidate(HelperState.incompatible, HelperSource.compiledPrefix,
        fatalOnMismatch = true),
      candidate(HelperState.compatible, HelperSource.standardPrefix)]).isNone

  test "a mismatch at the build prefix of a development build is skipped":
    check chooseHelper(@[
      candidate(HelperState.incompatible, HelperSource.compiledPrefix),
      candidate(HelperState.compatible, HelperSource.devTree)]) == some(1)
