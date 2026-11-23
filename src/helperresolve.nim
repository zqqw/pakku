## Finding the helper binary that `lib/tools` installs.
##
## Kept apart from `utils` so the search order, the protocol probe and the choice
## of a candidate live in one place. `utils` turns the outcome into warnings and
## errors, and the tests read the order and the policy directly.

import std/[options, os, osproc, streams, strutils]
import helperproto

type
  HelperSource* {.pure.} = enum
    compiledPrefix, ## the prefix this binary was built for
    standardPrefix, ## `/usr` or `/usr/local`, where a package installs one
    devTree         ## `lib/tools` in a source tree, development builds only

  HelperState* {.pure.} = enum
    absent, compatible, incompatible, unverified

  HelperLocation* = object
    ## A place a helper may be, before anything has looked at it.
    command*: seq[string]
      ## the argv to run for a tool. The development wrapper takes the tool
      ## name as its second element.
    tools*: string
      ## the binary to ask about its protocol. Never the tool symlink, because
      ## running that would dispatch into the tool.
    source*: HelperSource

  HelperCandidate* = object
    ## A location and what the probe found there.
    location*: HelperLocation
    state*: HelperState
    protocol*: string ## what the helper printed, empty when it printed nothing
    fatalOnMismatch*: bool
      ## pakku runs from the prefix it was built for, so a helper there that
      ## speaks another protocol is a broken install rather than a foreign one.

  HelperResolution* = object
    ## The candidate a run should use, if any, and everything it tried.
    candidates*: seq[HelperCandidate]
    chosen*: Option[int]

const devHelpers* = not defined(release) or defined(pakkuDev)
  ## A build is a release when it has `-d:release` and not `-d:pakkuDev`, the
  ## condition `config.nims` names `IsRelease`. Anything else also looks next to
  ## itself, so a source tree works without an install and the optimised `-git`
  ## package keeps that path.

func addLocation(locations: var seq[HelperLocation]; seen: var seq[string];
    command: seq[string]; tools: string; source: HelperSource) =
  ## Record a location once. `tools` is the deduplication key: two prefixes can
  ## point at the same helper binary without pointing at the same tool path.
  if tools in seen:
    return
  seen.add tools
  locations.add HelperLocation(command: command, tools: tools, source: source)

func helperLocations*(tool, appDir, libDir: string;
    dev: static[bool] = devHelpers): seq[HelperLocation] =
  ## The places a helper may be, best first. `appDir` is the directory of the
  ## running binary and `libDir` the prefix it was built for.
  ##
  ## Install prefixes come first and share one layout, `<prefix>/lib/pakku`. The
  ## built prefix leads and `/usr` and `/usr/local` follow. A development build
  ## also accepts `lib/tools` in its source tree, next to the binary or one level
  ## above.
  ##
  ## `$PATH` and the working directory are never searched. Whatever is picked
  ## runs through sudo, so no other place is guessed.
  var seen: seq[string]

  addLocation(result, seen, @[libDir / tool], libDir / "tools",
    HelperSource.compiledPrefix)
  for prefix in ["/usr", "/usr/local"]:
    let dir = prefix / "lib" / "pakku"
    addLocation(result, seen, @[dir / tool], dir / "tools",
      HelperSource.standardPrefix)
  when dev:
    let parent = appDir.parentDir()
    for dir in [appDir / "lib" / "tools", parent / "lib" / "tools"]:
      addLocation(result, seen, @[dir, tool], dir, HelperSource.devTree)

proc probeHelper(tools: string): tuple[state: HelperState; protocol: string] =
  ## Ask a helper binary which protocol it speaks.
  ##
  ## The probe arm only prints a number. Helpers older than that arm fall into
  ## their unknown-tool branch and exit non-zero without touching anything. A
  ## binary this user cannot start is left for sudo, which may still run it.
  ##
  ## Stderr joins stdout so a helper that complains cannot fill an unread pipe
  ## and leave the child blocked.
  var process: Process
  try:
    process = startProcess(tools, args = [helperProtocolArg],
      options = {poStdErrToStdOut})
  except CatchableError:
    return (HelperState.unverified, "")

  try:
    result.protocol = process.outputStream.readAll().strip
    result.state =
      if process.waitForExit() == 0 and result.protocol == $helperProtocol:
        HelperState.compatible
      else:
        HelperState.incompatible
  finally:
    process.close()

proc probeLocations(tool, appDir, libDir: string): seq[HelperCandidate] =
  ## Probe the locations that exist, in order, and stop at the first one a run
  ## could use or at a mismatch the install cannot recover from.
  let installed = appDir == libDir.parentDir.parentDir / "bin"
  for location in helperLocations(tool, appDir, libDir):
    var candidate = HelperCandidate(location: location,
      state: HelperState.absent,
      fatalOnMismatch: installed and
        location.source == HelperSource.compiledPrefix)
    if fileExists(location.command[0]):
      (candidate.state, candidate.protocol) = probeHelper(location.tools)
    result.add candidate
    case candidate.state
    of HelperState.compatible, HelperState.unverified:
      break
    of HelperState.incompatible:
      if candidate.fatalOnMismatch:
        break
    of HelperState.absent:
      discard

func chooseHelper*(candidates: openArray[HelperCandidate]): Option[int] =
  ## The candidate a run should use, if any.
  ##
  ## The first helper that answers, or that cannot be asked, wins. A mismatch
  ## only stops the search in the prefix pakku itself runs from, where it means a
  ## broken install. A development build that finds an older helper at its build
  ## prefix keeps looking.
  for index, candidate in candidates:
    case candidate.state
    of HelperState.compatible, HelperState.unverified:
      return some(index)
    of HelperState.incompatible:
      if candidate.fatalOnMismatch:
        return none(int)
    of HelperState.absent:
      discard

proc resolveHelper*(tool, appDir, libDir: string): HelperResolution =
  ## Search, probe and choose. Warnings and failure messages are left to the
  ## caller.
  result.candidates = probeLocations(tool, appDir, libDir)
  result.chosen = chooseHelper(result.candidates)
