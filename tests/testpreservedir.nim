import std/[os, unittest]
include ../src/feature/syncinstall

## Covers `PAKKU_PRESERVE_DIR`, the per-invocation override of the
## `PreserveBuilt` copy destination: how it is resolved and validated, and how
## the value reaches the root process across a `SudoExec` re-execution.

proc fixtureConfig(outputDir: string): Config =
  Config(common: CommonConfig(arch: "x86_64"), packageOutputDir: outputDir,
    tmpRootInitial: outputDir, cache: "/var/cache/pacman/pkg", color: false)

let
  root = getTempDir() / "pakku-preserve-dir-test"

removeDir(root)
let
  outputDir = root / "output"
  storeDir = root / "store"
createDir(outputDir)
createDir(storeDir)

let cfg = fixtureConfig(outputDir)

suite "destination resolution":
  setup:
    delEnv(PreserveDirEnv)

  teardown:
    delEnv(PreserveDirEnv)

  test "an unset variable keeps the configured mode":
    check resolvePreserveTarget(cfg, "").dir.len == 0

  test "Pkgdest without PKGDEST is a no-copy mode":
    var other = cfg
    other.preserveBuilt = PreserveBuilt.pkgdest
    check resolvePreserveTarget(other, "").dir.len == 0
    check resolvePreserveTarget(other, "/mnt/pkgdest").dir == "/mnt/pkgdest"

  test "the variable supplies the destination":
    putEnv(PreserveDirEnv, storeDir)
    let target = resolvePreserveTarget(cfg, "")
    check target.dir == expandFilename(storeDir)
    check target.uid == currentUser.uid
    check target.gid == currentUser.gid

  test "the variable replaces a configured mode":
    var other = cfg
    other.preserveBuilt = PreserveBuilt.internal
    putEnv(PreserveDirEnv, storeDir)
    check resolvePreserveTarget(other, "").dir == expandFilename(storeDir)

  test "relative and missing paths are refused":
    putEnv(PreserveDirEnv, "relative/store")
    doAssertRaises CommandError:
      discard resolvePreserveTarget(cfg, "")
    putEnv(PreserveDirEnv, root / "absent")
    doAssertRaises CommandError:
      discard resolvePreserveTarget(cfg, "")

  test "a destination inside the build output is refused":
    putEnv(PreserveDirEnv, outputDir)
    doAssertRaises CommandError:
      discard resolvePreserveTarget(cfg, "")
    let nested = outputDir / "store"
    createDir(nested)
    putEnv(PreserveDirEnv, nested)
    doAssertRaises CommandError:
      discard resolvePreserveTarget(cfg, "")
    removeDir(nested)

suite "sudo re-execution":
  test "the destination survives the environment reset":
    check sudoExecArgs(@["/usr/bin/sudo"], storeDir, "/usr/bin/pakku", @["-Syu"]) ==
      @["/usr/bin/sudo", "env", PreserveDirEnv & "=" & storeDir, "/usr/bin/pakku",
        "-Syu"]

  test "an unset destination adds no environment wrapper":
    check sudoExecArgs(@[], "", "/usr/bin/pakku", @["-S"]) ==
      @["/usr/bin/pakku", "-S"]
