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

let source = TrackedSource(url: "https://example.org/foo.git", branch: none(string))
let observed = {"foo-git": @[ObservedSource(source: source,
  commit: some("abcdef1234"))]}.toTable

proc installOf(names: varargs[string]): InstallArtifacts =
  var targets: seq[InstallTarget]
  for name in names:
    targets.add InstallTarget(name: name, file: name & ".pkg.tar.zst")
  InstallArtifacts(install: targets)

func probe(observed: Table[string, seq[ObservedSource]];
    plain: HashSet[string] = initHashSet[string]()): DevelProbe =
  DevelProbe(observed: observed, plain: plain)

func state(tracked: HashSet[string] = initHashSet[string]();
    siblings: Table[string, seq[string]] = initTable[string, seq[string]]();
    live: HashSet[string] = initHashSet[string]()): DevelState =
  DevelState(tracked: tracked, siblings: siblings, live: live)

proc git(args: varargs[string]): string =
  let command = (@["git"] & args.mapIt(quoteShell(it))).join(" ")
  let (output, code) = execCmdEx(command)
  doAssert code == 0, output
  output.strip

proc fixtureRepo(base, pkgbuild, srcInfo: string): string =
  ## A clone-shaped directory: `probeDevel` records nothing for a base whose
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

  test "records the observed revision and packaging stamp":
    let config = fixtureConfig(root)
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observed), state())
    let db = loadDevelDb(config.develDbFile)
    check db.len == 1
    check db["foo-git"].lastModified == 100
    check db["foo-git"].sources == @[SourceRevision(source: source,
      commit: "abcdef1234")]

  test "a base that was not installed is not recorded":
    let config = fixtureConfig(root)
    recordDevel(config, @[@[fixturePackage()]], installOf(), probe(observed),
      state())
    check loadDevelDb(config.develDbFile).len == 0

  test "a partially installed split base is not recorded":
    let config = fixtureConfig(root)
    let split = @[fixturePackage(), fixturePackage(name = "foo-tools-git")]
    recordDevel(config, @[split], installOf("foo-git"), probe(observed), state())
    check loadDevelDb(config.develDbFile).len == 0

  test "an installed sibling left behind prevents the stamp":
    ## `IgnorePkg = foo-tools-git`, or the user deselected it: the base's
    ## archive is current, the sibling's is not, so the record must not claim it.
    let config = fixtureConfig(root)
    let siblings = {"foo-git": @["foo-git", "foo-tools-git"]}.toTable
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observed), state(siblings = siblings))
    check loadDevelDb(config.develDbFile).len == 0

  test "a base without a probe is left alone":
    let config = fixtureConfig(root)
    recordDevel(config, @[@[fixturePackage(base = "other-git")]],
      installOf("foo-git"), probe(initTable[string, seq[ObservedSource]]()),
      state())
    check loadDevelDb(config.develDbFile).len == 0

  test "a missing RPC stamp prevents a record":
    let config = fixtureConfig(root)
    var pkgInfo = fixturePackage()
    pkgInfo.rpc.lastModified = none(int64)
    recordDevel(config, @[@[pkgInfo]], installOf("foo-git"), probe(observed),
      state())
    check loadDevelDb(config.develDbFile).len == 0

  test "recording replaces the previous revision":
    let config = fixtureConfig(root)
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observed), state())
    let moved = {"foo-git": @[ObservedSource(source: source,
      commit: some("9999999999"))]}.toTable
    recordDevel(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(moved), state())
    let db = loadDevelDb(config.develDbFile)
    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources[0].commit == "9999999999"

  test "a base that stopped being a development package keeps no refs":
    ## The offer that sent us here came from an AUR change, and the scan sees no
    ## `pkgver()` any more. The record keeps the new stamp with no sources, so
    ## the offer cannot repeat and no revision is claimed the archive lacks.
    let config = fixtureConfig(root)
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observed), state())
    var plain = initHashSet[string]()
    plain.incl "foo-git"
    recordDevel(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(initTable[string, seq[ObservedSource]](), plain),
      state())
    let db = loadDevelDb(config.develDbFile)
    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources.len == 0

  test "a base whose refs cannot be read is still settled":
    ## `SudoExec` with an agent-only SSH key is the real case: the build runs as
    ## the user and succeeds, the lookup runs as root and fails. The stamp has to
    ## advance, or the same rebuild is offered for ever.
    let config = fixtureConfig(root)
    let unreadable = {"foo-git": @[ObservedSource(source: source,
      commit: none(string))]}.toTable
    recordDevel(config, @[@[fixturePackage(lastModified = 200)]],
      installOf("foo-git"), probe(unreadable), state())
    let db = loadDevelDb(config.develDbFile)
    check db["foo-git"].lastModified == 200
    check db["foo-git"].sources.len == 0

  test "pruning drops the records of bases the AUR no longer lists":
    let config = fixtureConfig(root)
    var seeded: DevelDb = initOrderedTable[string, DevelRecord]()
    discard seeded.stampDevelRecord("foo-git", 100, observed["foo-git"])
    discard seeded.stampDevelRecord("gone-git", 100, observed["foo-git"])
    discard storeDevelDb(config.develDbFile, seeded)
    var live = initHashSet[string]()
    live.incl "foo-git"
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"),
      probe(observed), state(live = live))
    let db = loadDevelDb(config.develDbFile)
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
    let decided = {"foo-git": @[ObservedSource(source: source,
      commit: some("abcdef1234"))]}.toTable
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: true, observed: decided))
    check probed.observed == decided

  test "a base without pkgver() is marked plain":
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", "pkgver=1.0\n", srcInfo)
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: true))
    check probed.observed.len == 0
    check "foo-git" in probed.plain

  test "a tracked base is probed with the check off":
    ## The packaging stamp has to advance on every build of a tracked base, or a
    ## metadata-change offer would repeat for someone who turned the flag off.
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild, srcInfo)
    let decided = {"foo-git": @[ObservedSource(source: source,
      commit: some("abcdef1234"))]}.toTable
    var tracked = initHashSet[string]()
    tracked.incl "foo-git"
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: false, tracked: tracked, observed: decided))
    check probed.observed == decided

  test "an untracked base is not probed with the check off":
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild, srcInfo)
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: false))
    check probed.observed.len == 0 and probed.plain.len == 0

  test "a dev package with nothing trackable is recorded as gate-only":
    ## `pkgver()` with a pinned source: the probe finds the base, has no refs to
    ## read, and the record says so - no lookup, no offer from refs afterwards.
    let config = fixtureConfig(root)
    discard fixtureRepo("foo-git", devPkgbuild,
      "pkgbase = foo-git\n\tsource = git+https://example.org/foo.git#tag=v1\n")
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: true))
    check probed.observed.hasKey("foo-git")
    check probed.observed["foo-git"].len == 0
    recordDevel(config, @[@[fixturePackage()]], installOf("foo-git"), probed,
      state())
    let db = loadDevelDb(config.develDbFile)
    check db["foo-git"].lastModified == 100
    check db["foo-git"].sources.len == 0

  test "an edited PKGBUILD is not probed":
    ## `.SRCINFO` is not regenerated after an edit, so the sources on disk no
    ## longer describe what makepkg will compile.
    let config = fixtureConfig(root)
    let dir = fixtureRepo("foo-git", devPkgbuild, srcInfo)
    writeFile(dir / "PKGBUILD", devPkgbuild & "\n# local change\n")
    let probed = probeDevel(config, @[@[fixturePackage()]],
      DevelState(checkRefs: true))
    check probed.observed.len == 0 and probed.plain.len == 0
