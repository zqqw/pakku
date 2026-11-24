import std/[options, os, sequtils, sets, tables]
include ../src/feature/syncinstall

## End-to-end check of the devel layer against the real AUR, short of running
## makepkg: a real clone (bare cache plus worktree), the real RPC record, the
## real upstream ref, a real ledger file under a temporary root, and the
## decisions that follow.
##
## Not part of `nim test` - it needs the network and the AUR - but it is the
## only check that sees real `.SRCINFO`, a real PKGBUILD and a real remote:
##
##     nim c -r tests/e2e_devel.nim
##
## The one path it cannot reach is a privileged run: the ledger handover to the
## invoking user needs `SudoExec` and root.

let root = getTempDir() / "pakku-e2e"
removeDir(root)
createDir(root)

let cfg = Config(common: CommonConfig(arch: "x86_64"),
  userCacheInitial: root & "/cache", userCacheCurrent: root & "/cache",
  tmpRootInitial: root & "/tmp", tmpRootCurrent: root & "/tmp", color: false)
createDir(cfg.userCacheCurrent)
createDir(cfg.tmpRootCurrent)

func runState(checkGitRefs = false): DevelRunState =
  DevelRunState(checkGitRefs: checkGitRefs, state: new(DevelStateData),
    stateReadable: true)

proc step(title: string) =
  echo "\n== ", title

step "AUR RPC"
let (rpcInfos, rpcErrors) = getRpcPackageInfos(@["rmlint-git"], "aur", true, false)
echo "errors: ", rpcErrors
doAssert rpcInfos.len == 1, "no RPC record"
let aurInfo = rpcInfos[0]
echo "base=", aurInfo.base, " version=", aurInfo.version, " lastModified=",
  aurInfo.lastModified

step "clone (bare cache + worktree), as the install path does"
let (pkgInfos, _, paths, cloneErrors) =
  cloneAurReposWithPackageInfos(cfg, rpcInfos, true,
    proc(progress, total: int) = discard, false)
echo "errors: ", cloneErrors
echo "paths: ", paths
var group: seq[PackageInfo]
for pkgInfo in pkgInfos:
  if pkgInfo.rpc.base == aurInfo.base:
    group.add pkgInfo
doAssert group.len > 0, "no package info for the base"
echo "packages of the base: ", group.mapIt(it.rpc.name)

let dir = pkgbuildDir(cfg, group[0])
echo "pkgbuild dir: ", dir
echo "PKGBUILD intact: ", pkgbuildIntact(cfg, dir)
echo "defines pkgver(): ", definesPkgver(readIfPresent(dir & "/PKGBUILD"))
let sources = gitSourceEntries(readIfPresent(dir & "/.SRCINFO"), cfg.common.arch).toSeq()
echo "trackable sources: ", sources

step "probe: real refs before a build"
let probe = probeDevelState(cfg, @[group], runState(true))
echo "no-pkgver bases: ", probe.noPkgverBases
for base, observedGitRefs in probe.observedGitRefs:
  for entry in observedGitRefs:
    echo base, " ", entry.source.url,
      (if entry.source.branch.isSome: "#branch=" & entry.source.branch.unsafeGet
        else: ""), " -> ", entry.commit

step "record: a build of every package of the base"
var install: seq[InstallTarget]
for pkgInfo in group:
  install.add InstallTarget(name: pkgInfo.rpc.name,
    file: pkgInfo.rpc.name & ".pkg.tar.zst")
updateDevelStateFromBuild(cfg, @[group], InstallArtifacts(install: install), probe, runState())
let db = loadDevelState(cfg.develDbFile)[0]
echo "ledger: ", db
doAssert probe.observedGitRefs.hasKey(aurInfo.base), "no observations for the base"
doAssert db.hasKey(aurInfo.base), "the base was not recorded"
let answered = probe.observedGitRefs[aurInfo.base].filterIt(it.commit.isSome)
doAssert db[aurInfo.base].sources.mapIt(it.source) == answered.mapIt(it.source),
  "record lost a source"
doAssert db[aurInfo.base].sources.allIt(it.commit.len > 0), "empty commit recorded"

step "decision right after the build: quiet"
let installed = Installed(name: group[0].rpc.name, version: "0-1",
  buildDate: 0, installDate: 0, base: aurInfo.base)
let quiet = develUpgradeNeeded(group[0].rpc, installed, true, db,
  probe.observedGitRefs[aurInfo.base])
echo "offered=", quiet.needed, " label=", quiet.label
doAssert not quiet.needed

step "decision after an upstream move: one latest-commit"
var moved: seq[GitRefAnswer]
for entry in probe.observedGitRefs[aurInfo.base]:
  moved.add GitRefAnswer(source: entry.source,
    commit: some("0000000000000000000000000000000000000000"))
let offer = develUpgradeNeeded(group[0].rpc, installed, true, db, moved)
echo "offered=", offer.needed, " label=", offer.label
doAssert offer.needed and offer.label == some("latest-commit")

step "packaging change: one rebuild, and no ref check needed"
var bumped = group[0].rpc
bumped.lastModified = some(aurInfo.lastModified.get(0) + 1)
let rebuild = develUpgradeNeeded(bumped, installed, true, db, probe.observedGitRefs[aurInfo.base])
echo "offered=", rebuild.needed, " label=", rebuild.label
doAssert rebuild.needed and rebuild.label == some("rebuild")

step "an edited PKGBUILD is not recorded"
writeFile(dir / "PKGBUILD", readFile(dir / "PKGBUILD") & "\n# local edit\n")
echo "PKGBUILD intact: ", pkgbuildIntact(cfg, dir)
let edited = probeDevelState(cfg, @[group], runState(true))
echo "no-pkgver bases: ", edited.noPkgverBases, " observed refs: ", edited.observedGitRefs.len
doAssert edited.observedGitRefs.len == 0 and edited.noPkgverBases.len == 0

echo "\nE2E OK"
