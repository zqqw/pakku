import std/[options, os, osproc, sets, strutils, tables, unittest]
include ../src/feature/syncinstall

## Recording rules for the devel ledger: only bases that were built in this run
## and fully installed may be recorded, because a record claims "this is the
## revision that is installed". No fixture here reaches the network: each probe
## either reuses the refs a decision already read, skips the base, or finds no
## `pkgver()`. A fixture whose source list differs from the decided answer would
## start a real lookup, so none is written that way.

let root = getTempDir() / "pakku-devel-record-test"

proc fixtureConfig(cacheDir: string): Config =
  Config(common: CommonConfig(arch: "x86_64"), userCacheInitial: cacheDir,
    userCacheCurrent: cacheDir, tmpRootInitial: cacheDir,
    tmpRootCurrent: cacheDir, color: false)

proc fixturePackage(name = "foo-git"; base = "foo-git"; lastModified = 100'i64):
    PackageInfo =
  var pi = default(PackageInfo)
  pi.rpc.repo = "aur"
  pi.rpc.base = base
  pi.rpc.name = name
  pi.rpc.version = "r1.abcdef-1"
  pi.rpc.lastModified = some(lastModified)
  pi.archs = @["x86_64"]
  pi.baseIndex = 0
  pi.baseCount = 1
  pi

let source = DevelGitSource(url: "https://example.org/foo.git", branch: none(string))
let observedGitRefs = {"foo-git": @[GitRefAnswer(source: source,
  commit: some("abcdef1234"))]}.toTable

proc installOf(names: varargs[string]): InstallArtifacts =
  var targets: seq[InstallTarget]
  for name in names:
    targets.add InstallTarget(name: name, file: name & ".pkg.tar.zst")
  InstallArtifacts(install: targets)

func probe(observedGitRefs: Table[string, seq[GitRefAnswer]];
    noPkgverBases: HashSet[string] = initHashSet[string]()): DevelBuildProbe =
  DevelBuildProbe(observedGitRefs: observedGitRefs, noPkgverBases: noPkgverBases)

func state(stateBases: HashSet[string] = initHashSet[string]();
    installedBaseMembers: Table[string, seq[string]] = initTable[string, seq[string]]();
    aurListedBases: HashSet[string] = initHashSet[string]();
    observedGitRefs: Table[string, seq[GitRefAnswer]] = initTable[string, seq[GitRefAnswer]]();
    data: DevelStateData = initOrderedTable[string, DevelStateEntry]();
    checkGitRefs = false; stateReadable = true): DevelRunState =
  let sharedState = new(DevelStateData)
  sharedState[] = data
  DevelRunState(observedGitRefs: observedGitRefs, stateBases: stateBases,
    installedBaseMembers: installedBaseMembers, aurListedBases: aurListedBases,
    checkGitRefs: checkGitRefs, state: sharedState,
    stateReadable: stateReadable)


proc git(args: varargs[string]): string =
  let command = (@["git"] & args.mapIt(quoteShell(it))).join(" ")
  let (output, code) = execCmdEx(command)
  doAssert code == 0, output
  output.strip

proc fixtureRepo(base, pkgbuild, srcInfo: string): string =
  ## A clone-shaped directory: `probeDevelState` records nothing for a base whose
  ## PKGBUILD was edited during the review, and only a versioned directory can
  ## tell the two apart.
  result = root / base
  createDir(result)
  writeFile(result / "PKGBUILD", pkgbuild)
  writeFile(result / ".SRCINFO", srcInfo)
  discard git("init", "-q", result)
  discard git("-C", result, "config", "user.email", "test@example.org")
  discard git("-C", result, "config", "user.name", "test")
  discard git("-C", result, "add", "PKGBUILD", ".SRCINFO")
  discard git("-C", result, "commit", "-qm", "fixture")

suite "recording a built devel base":
  setup:
    removeDir(root)
    createDir(root)

  test "records the observedGitRefs revision and packaging stamp":
    let config = fixtureConfig(root)
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observedGitRefs), state())
    let db = loadDevelState(config.develDbFile)[0]

    check db.len == 1
    check db["foo-git"].lastModified == 100
    check db["foo-git"].sources == @[SavedGitRef(source: source,
      commit: "abcdef1234")]

  test "a base that was not installed is not recorded":
    let config = fixtureConfig(root)
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf(), probe(observedGitRefs),
      state())
    check loadDevelState(config.develDbFile)[0].len == 0

  test "a partially installed split base is not recorded":
    let config = fixtureConfig(root)
    let split = @[fixturePackage(), fixturePackage(name = "foo-tools-git")]
    updateDevelStateFromBuild(config, @[split], installOf("foo-git"), probe(observedGitRefs), state())
    check loadDevelState(config.develDbFile)[0].len == 0

  test "an installed sibling left behind prevents the stamp":
    ## `IgnorePkg = foo-tools-git`, or the user deselected it: the base's
    ## archive is current, the sibling's is not, so the record must not claim it.
    let config = fixtureConfig(root)
    let installedBaseMembers = {"foo-git": @["foo-git", "foo-tools-git"]}.toTable
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observedGitRefs), state(installedBaseMembers = installedBaseMembers))
    check loadDevelState(config.develDbFile)[0].len == 0

  test "a base without a probe is left alone":
    let config = fixtureConfig(root)
    updateDevelStateFromBuild(config, @[@[fixturePackage(base = "other-git")]],
      installOf("foo-git"), probe(initTable[string, seq[GitRefAnswer]]()),
      state())
    check loadDevelState(config.develDbFile)[0].len == 0

  test "a missing RPC stamp prevents a record":
    let config = fixtureConfig(root)
    var pkgInfo = fixturePackage()
    pkgInfo.rpc.lastModified = none(int64)
    updateDevelStateFromBuild(config, @[@[pkgInfo]], installOf("foo-git"), probe(observedGitRefs),
      state())
    check loadDevelState(config.develDbFile)[0].len == 0

  test "recording replaces the previous revision":
    let config = fixtureConfig(root)
    let shared = state()
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observedGitRefs), shared)
    let moved = {"foo-git": @[GitRefAnswer(source: source,
      commit: some("9999999999"))]}.toTable
    updateDevelStateFromBuild(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(moved), shared)

    let db = loadDevelState(config.develDbFile)[0]

    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources[0].commit == "9999999999"

  test "a base that stopped being a development package keeps no refs":
    ## The offer that sent us here came from an AUR change, and the scan sees no
    ## `pkgver()` any more. The record keeps the new stamp with no sources, so
    ## the offer cannot repeat and no revision is claimed the archive lacks.
    let config = fixtureConfig(root)
    let shared = state()
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observedGitRefs), shared)
    var noPkgverBases = initHashSet[string]()
    noPkgverBases.incl "foo-git"
    updateDevelStateFromBuild(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(initTable[string, seq[GitRefAnswer]](), noPkgverBases),
      shared)

    let db = loadDevelState(config.develDbFile)[0]

    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources.len == 0

  test "a base whose refs cannot be read is still settled":
    ## `SudoExec` with an agent-only SSH key is the real case: the build runs as
    ## the user and succeeds, the lookup runs as root and fails. The stamp has to
    ## advance, or the same rebuild is offered for ever.
    let config = fixtureConfig(root)
    let unreadable = {"foo-git": @[GitRefAnswer(source: source,
      commit: none(string))]}.toTable
    updateDevelStateFromBuild(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(unreadable), state())
    let db = loadDevelState(config.develDbFile)[0]

    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources.len == 0

  test "pruning drops the records of bases the AUR no longer lists":
    let config = fixtureConfig(root)
    var seeded: DevelStateData = initOrderedTable[string, DevelStateEntry]()
    discard seeded.updateDevelStateEntry("foo-git", 100, observedGitRefs["foo-git"])
    discard seeded.updateDevelStateEntry("gone-git", 100, observedGitRefs["foo-git"])
    discard saveDevelState(config.develDbFile, seeded)
    var aurListedBases = initHashSet[string]()
    aurListedBases.incl "foo-git"
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observedGitRefs), state(data = seeded, aurListedBases = aurListedBases))
    let db = loadDevelState(config.develDbFile)[0]

    check db.len == 1 and "foo-git" in db

suite "probing a base before the build":
  setup:
    removeDir(root)
    createDir(root)

  const
    devPkgbuild = "pkgver() {\n\techo r1\n}\n"
    srcInfo = "pkgbase = foo-git\n\tsource = git+https://example.org/foo.git\n"

  test "refs read for the upgrade decision are not looked up again":
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild, srcInfo)
    let decided = {"foo-git": @[GitRefAnswer(source: source,
      commit: some("abcdef1234"))]}.toTable
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = true, observedGitRefs = decided))
    check probed.observedGitRefs == decided

  test "a base without pkgver() is marked no-pkgver":
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", "pkgver=1.0\n", srcInfo)
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = true))
    check probed.observedGitRefs.len == 0
    check "foo-git" in probed.noPkgverBases

  test "a recorded base is probed with the check off":
    ## The AUR info time has to advance on every build of a recorded base, or a
    ## metadata-change offer would repeat for someone who turned the flag off.
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild, srcInfo)
    let decided = {"foo-git": @[GitRefAnswer(source: source,
      commit: some("abcdef1234"))]}.toTable
    var stateBases = initHashSet[string]()
    stateBases.incl "foo-git"
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = false, stateBases = stateBases, observedGitRefs = decided))
    check probed.observedGitRefs == decided

  test "an untracked base is not probed with the check off":
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild, srcInfo)
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = false))
    check probed.observedGitRefs.len == 0 and probed.noPkgverBases.len == 0

  test "a dev package with nothing trackable is recorded as gate-only":
    ## `pkgver()` with a pinned source: the probe finds the base, has no refs to
    ## read, and the record says so - no lookup, no offer from refs afterwards.
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild,
      "pkgbase = foo-git\n\tsource = git+https://example.org/foo.git#tag=v1\n")
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = true))
    check probed.observedGitRefs.hasKey("foo-git")
    check probed.observedGitRefs["foo-git"].len == 0
    updateDevelStateFromBuild(config, @[@[fixturePackage()]], installOf("foo-git"), probed,
      state())
    let db = loadDevelState(config.develDbFile)[0]
    check db["foo-git"].lastModified == 100
    check db["foo-git"].sources.len == 0

  test "an edited PKGBUILD is not probed":
    ## `.SRCINFO` is not regenerated after an edit, so the sources on disk no
    ## longer describe what makepkg will compile.
    let config = fixtureConfig(root)
    let dir = fixtureRepo("foo-git", devPkgbuild, srcInfo)
    writeFile(dir / "PKGBUILD", devPkgbuild & "\n# local change\n")
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = true))
    check probed.observedGitRefs.len == 0 and probed.noPkgverBases.len == 0

  test "a staged PKGBUILD edit is not probed":
    let config = fixtureConfig(root)
    let dir = fixtureRepo("foo-git", devPkgbuild, srcInfo)
    writeFile(dir / "PKGBUILD", devPkgbuild & "\n# staged change\n")
    discard git("-C", dir, "add", "PKGBUILD")
    let probed = probeDevelState(config, @[@[fixturePackage()]],
      state(checkGitRefs = true))
    check probed.observedGitRefs.len == 0 and probed.noPkgverBases.len == 0


  test "run state is built from foreign members and loaded state":
    var db: DevelStateData = initOrderedTable[string, DevelStateEntry]()
    discard db.updateDevelStateEntry("foo-git", 100, observedGitRefs["foo-git"])
    let installed = @[
      Installed(name: "repo-foo", version: "1", foreign: false, base: "foo-git"),
      Installed(name: "foo-git", version: "1", foreign: true, base: "foo-git")]
    var live = initHashSet[string]()
    live.incl "foo-git"
    let run = buildDevelRunState(installed, db,
      initTable[string, seq[GitRefAnswer]](), live, false, true)
    check run.installedBaseMembers["foo-git"] == @["foo-git"]
    check "foo-git" in run.stateBases
    check run.state[] == db
    check run.stateReadable

  test "explicit untracked git targets are named in the AUR phase":
    ## The numbered upgrade list excludes explicit targets; without this
    ## sublist the user sees their argument disappear before the build prompt.
    let info = fixturePackage().rpc
    var db: DevelStateData
    check develStateTargets(@[info, info], db, true) == @["foo-git"]

  test "checks off, recorded bases, and non-git targets are not named":
    let info = fixturePackage().rpc
    var db: DevelStateData
    check develStateTargets(@[info], db, false).len == 0
    db["foo-git"] = DevelStateEntry(lastModified: 0, sources: @[])
    check develStateTargets(@[info], db, true).len == 0
    let noPkgverBases = fixturePackage(name = "foo", base = "foo").rpc
    var emptyDb: DevelStateData
    check develStateTargets(@[noPkgverBases], emptyDb, true).len == 0

  test "a corrupt state file is not overwritten after a build":
    let config = fixtureConfig(root)
    let path = config.develDbFile
    writeFile(path, "{not json")
    let before = readFile(path)
    var noPkgver = initHashSet[string]()
    noPkgver.incl "foo-git"
    updateDevelStateFromBuild(config, @[@[fixturePackage()]],
      installOf("foo-git"), probe(initTable[string, seq[GitRefAnswer]](), noPkgver),
      state(stateReadable = false))
    check readFile(path) == before

  test "live bases include installed foreign packages without an RPC answer":
    let installed = @[Installed(name: "ignored-git", version: "1",
      foreign: true, base: "ignored-git")]
    check "ignored-git" in develLiveBases(installed, @[])

  test "pruning keeps installed foreign bases with no upgrade candidate":
    let config = fixtureConfig(root)
    var seeded: DevelStateData = initOrderedTable[string, DevelStateEntry]()
    discard seeded.updateDevelStateEntry("ignored-git", 100,
      observedGitRefs["foo-git"])
    discard saveDevelState(config.develDbFile, seeded)
    var live = initHashSet[string]()
    live.incl "ignored-git"
    updateDevelStateFromBuild(config, @[], InstallArtifacts(install: @[]),
      probe(initTable[string, seq[GitRefAnswer]]()),
      state(data = seeded, aurListedBases = live))
    check loadDevelState(config.develDbFile)[0].hasKey("ignored-git")
