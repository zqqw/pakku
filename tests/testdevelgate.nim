import std/[options, tables, unittest]
include ../src/feature/syncinstall

## The devel upgrade decision is packaging age, not version order: a devel
## version ends in a commit hash, so `vercmp` turns a content identifier into a
## fake chronology and an offer that a rebuild cannot satisfy repeats forever.
## These cases pin the replacement rule (#47).

suite "devel packaging gate":
  test "packaging changed after the build offers a rebuild":
    check develNeeded(some(100'i64), 50, 0)

  test "packaging older than the build offers nothing":
    check not develNeeded(some(50'i64), 100, 0)

  test "equal timestamps offer nothing":
    check not develNeeded(some(100'i64), 100, 0)

  test "the later of build and install time is the reference":
    # A rebuild installs after building, so the install date advances even when
    # the packaged build date does not.
    check not develNeeded(some(100'i64), 10, 200)
    check not develNeeded(some(150'i64), 10, 200)
    check develNeeded(some(250'i64), 10, 200)

  test "a pinned build date cannot keep the gate true forever":
    # Reproducible builds pin %BUILDDATE% to SOURCE_DATE_EPOCH. Without the
    # install date the gate would stay true for every later sysupgrade.
    check develNeeded(some(1000'i64), 10, 0)
    check not develNeeded(some(1000'i64), 10, 2000)

  test "missing timestamps never offer":
    check not develNeeded(none(int64), 100, 200)
    check not develNeeded(some(100'i64), 0, 0)

  test "an install date alone is enough to decide":
    check develNeeded(some(100'i64), 0, 50)
    check not develNeeded(some(100'i64), 0, 150)

suite "devel candidates":
  test "vcs suffixes are candidates":
    for name in ["rmlint-git", "foo-svn", "foo-hg", "foo-bzr"]:
      check name.isVcs

  test "other names keep the version comparison":
    for name in ["rmlint", "git", "foo-git-bin", "foo-github", "btrfs-progs"]:
      check not name.isVcs

suite "devel upgrade decision":
  let source = TrackedSource(url: "https://example.org/a.git",
    branch: none(string))

  proc installedAt(buildDate, installDate: int64): Installed =
    Installed(name: "foo-git", version: "r1.abcdef-1",
      buildDate: buildDate, installDate: installDate)

  proc rpcInfo(lastModified: Option[int64]): RpcPackageInfo =
    var info: RpcPackageInfo
    info.repo = "aur"
    info.base = "foo-git"
    info.name = "foo-git"
    info.version = "r1.abcdef-1"
    info.lastModified = lastModified
    info

  proc ledger(lastModified: int64; commit: string): DevelDb =
    result = initOrderedTable[string, DevelRecord]()
    result["foo-git"] = DevelRecord(lastModified: lastModified,
      sources: @[SourceRevision(source: source, commit: commit)])

  let observed = @[ObservedSource(source: source, commit: some("ffffffff"))]

  test "no record: packaging age decides and the offer says rebuild":
    let (needed, label) = develUpgrade(rpcInfo(some(100'i64)), installedAt(50, 60),
      false, initOrderedTable[string, DevelRecord](), [])
    check needed
    check label == some("rebuild")

  test "no record and packaging older than the install: nothing":
    let (needed, label) = develUpgrade(rpcInfo(some(10'i64)), installedAt(50, 60),
      false, initOrderedTable[string, DevelRecord](), [])
    check not needed
    check label.isNone

  test "record, unchanged packaging and ref: nothing":
    let (needed, label) = develUpgrade(rpcInfo(some(100'i64)), installedAt(50, 60),
      true, ledger(100, "ffffffff"), observed)
    check not needed
    check label.isNone

  test "record and a moved ref with ref checks: latest-commit":
    let (needed, label) = develUpgrade(rpcInfo(some(100'i64)), installedAt(50, 60),
      true, ledger(100, "aaaaaaaa"), observed)
    check needed
    check label == some("latest-commit")

  test "a moved ref without ref checks decides on packaging alone":
    let (needed, label) = develUpgrade(rpcInfo(some(100'i64)), installedAt(50, 60),
      false, ledger(100, "aaaaaaaa"), observed)
    check not needed
    check label.isNone

  test "packaging drift beats an unchanged ref, and says rebuild":
    let (needed, label) = develUpgrade(rpcInfo(some(200'i64)), installedAt(50, 60),
      true, ledger(100, "ffffffff"), observed)
    check needed
    check label == some("rebuild")
