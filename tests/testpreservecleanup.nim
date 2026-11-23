import std/[options, os, sets, unittest]
include ../src/feature/syncinstall

## Covers archives that come from a `PreserveBuilt` destination. That directory
## belongs to the user, so no cleanup policy may remove files from it, while the
## build output under `PackageOutputDir` stays fair game.

proc fixtureConfig(outputDir: string): Config =
  Config(common: CommonConfig(arch: "x86_64"), packageOutputDir: outputDir,
    tmpRootInitial: outputDir, color: false, preserveBuilt: PreserveBuilt.pkgdest)

proc fixturePackage(): PackageInfo =
  var pi = default(PackageInfo)
  pi.rpc.repo = "aur"
  pi.rpc.base = "foo"
  pi.rpc.name = "foo"
  pi.rpc.version = "1-1"
  pi.archs = @["x86_64"]
  pi.baseIndex = 0
  pi.baseCount = 1
  pi

let
  root = getTempDir() / "pakku-preserve-cleanup-test"
  artifactName = "foo-1-1-x86_64.pkg.tar.zst"

removeDir(root)
let
  outputDir = root / "output"
  storeDir = root / "store"
createDir(outputDir)
createDir(storeDir)

let
  cfg = fixtureConfig(outputDir)
  pi = fixturePackage()

proc artifact(file: string; preserved = false): BuildArtifact =
  BuildArtifact(name: some("foo"), pkgInfo: pi, file: file, preserved: preserved)

suite "reuse marks the destination":
  let
    local = outputDir / artifactName
    shared = storeDir / artifactName

  teardown:
    removeFile(local)
    removeFile(shared)

  test "a hit in the build output is not preserved":
    writeFile(local, "output")
    let found = findReusableArtifacts(cfg, @[pi], outputDir, storeDir)
    check found.len == 1
    check found[0].file == local
    check not found[0].preserved

  test "a hit in the destination is preserved":
    writeFile(shared, "store")
    let found = findReusableArtifacts(cfg, @[pi], outputDir, storeDir)
    check found.len == 1
    check found[0].file == shared
    check found[0].preserved

suite "cleanup":
  let
    local = outputDir / artifactName
    shared = storeDir / artifactName

  teardown:
    removeFile(local)
    removeFile(shared)

  test "Full removes the local copy and keeps the destination copy":
    writeFile(local, "output")
    writeFile(shared, "store")
    let artifacts = InstallArtifacts(
      artifacts: @[artifact(local), artifact(shared, preserved = true)],
      installFiles: toHashSet([local, shared]))
    cleanupArtifacts(cfg, artifacts, cleanupSpec(CleanupPolicy.full, true))
    check not fileExists(local)
    check fileExists(shared)

  test "a preserved archive is kept even when it was not installed":
    writeFile(shared, "store")
    let artifacts = InstallArtifacts(artifacts: @[artifact(shared, preserved = true)])
    cleanupArtifacts(cfg, artifacts, cleanupSpec(CleanupPolicy.full, true))
    check fileExists(shared)
