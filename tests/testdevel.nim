import std/[options, os, osproc, posix, sequtils, sets, strutils, tables, unittest]
import ../src/devel

## Source parsing, the devel decision, the ledger codec and the ref lookup. No
## network, no pacman, no ALPM: these are the parts of `--devel` that can be
## pinned down without an AUR.

suite "trackable sources":
  const rmlint = """
pkgbase = rmlint-git
	pkgver = 2.10.3.r497.gd3781546
	source = rmlint::git+https://github.com/sahib/rmlint.git
	sha256sums = SKIP
"""

  test "name:: prefix and git+ transport normalise to a git URL":
    check trackableSources(rmlint, "x86_64") ==
      @[TrackedSource(url: "https://github.com/sahib/rmlint.git",
        branch: none(string))]

  test "branch fragments are kept, pinned sources dropped":
    let info = """
	source = git+https://example.org/a.git#branch=dev
	source = git+https://example.org/b.git#tag=v1
	source = git+https://example.org/c.git#commit=abc
	source = git+https://example.org/d.git#unknown=1
"""
    check trackableSources(info, "x86_64") ==
      @[TrackedSource(url: "https://example.org/a.git", branch: some("dev"))]

  test "non-git and unusable sources are dropped":
    let info = """
	source = https://example.org/b.tar.gz
	source = svn+https://example.org/svn
	source = hg+https://example.org/hg
	source = ext::sh -c whoami
	source = git+file:///etc/passwd
	source = git+https://
"""
    check trackableSources(info, "x86_64").len == 0

  test "only source and source_<arch> are read":
    let info = """
	source = git+https://example.org/base.git
	source_x86_64 = git+https://example.org/x86.git
	source_aarch64 = git+https://example.org/arm.git
"""
    check trackableSources(info, "x86_64").mapIt(it.url) ==
      @["https://example.org/base.git", "https://example.org/x86.git"]
    check trackableSources(info, "aarch64").mapIt(it.url) ==
      @["https://example.org/base.git", "https://example.org/arm.git"]

  test "duplicates collapse and queries are stripped":
    let info = """
	source = git+https://example.org/a.git?rev=1
	source = name::git+https://example.org/a.git#branch=
	source = git://example.org/b.git
	source = git+ssh://example.org/c.git
"""
    check trackableSources(info, "x86_64") == @[
      TrackedSource(url: "https://example.org/a.git", branch: none(string)),
      TrackedSource(url: "git://example.org/b.git", branch: none(string)),
      TrackedSource(url: "ssh://example.org/c.git", branch: none(string))]

suite "pkgver detection":
  test "function definitions are recognised":
    for pkgbuild in ["pkgver() {", "pkgver ()", "pkgver()\n{",
        "\tpkgver() {", "function pkgver {", "function pkgver() {"]:
      check definesPkgver(pkgbuild)

  test "assignments, comments and other functions are not":
    for pkgbuild in ["pkgver=1.0", "pkgver=1.0.3", "pkgverfoo() {",
        "# pkgver() {", "pkgrel() {", ""]:
      check not definesPkgver(pkgbuild)

suite "remote ref parsing":
  const
    head = "fd20430ef830eab25b5726df8498a04d9a4b804f"
    other = "1111111111111111111111111111111111111111"
    tag = "2222222222222222222222222222222222222222"

  test "the asked-for ref, not the first line":
    ## `git ls-remote` matches a pattern on ref tails: asking for a bare `dev`
    ## also reports `refs/heads/a/dev`, sorted first, and recording that would
    ## track a ref the build never uses.
    let output = other & "\trefs/heads/a/dev\n" & head & "\trefs/heads/dev\n"
    check parseRemoteRef(output, ["refs/heads/dev", "refs/tags/dev"]) ==
      some(head)

  test "a tag is accepted when no branch of that name exists":
    let output = other & "\trefs/heads/dev\n" & tag & "\trefs/tags/v1\n"
    check parseRemoteRef(output, ["refs/heads/v1", "refs/tags/v1"]) ==
      some(tag)

  test "HEAD is only the HEAD line":
    check parseRemoteRef(head & "\tHEAD\n", ["HEAD"]) == some(head)
    check parseRemoteRef(other & "\trefs/heads/main\n", ["HEAD"]).isNone

  test "empty, malformed and abbreviated objects are refused":
    check parseRemoteRef("", ["HEAD"]).isNone
    check parseRemoteRef("fatal: repository not found\n", ["HEAD"]).isNone
    check parseRemoteRef("zzzzzzz\tHEAD\n", ["HEAD"]).isNone

  test "the names asked for follow what git clone -b resolves":
    check TrackedSource(url: "u", branch: none(string)).refNames == @["HEAD"]
    check TrackedSource(url: "u", branch: some("dev")).refNames ==
      @["refs/heads/dev", "refs/tags/dev"]

suite "branch values":
  test "glob characters are dropped, not made into patterns":
    let info = """
	source = git+https://example.org/a.git#branch=*
	source = git+https://example.org/b.git#branch=dev*
	source = git+https://example.org/c.git#branch=dev[1]
	source = git+https://example.org/d.git#branch=dev/x
	source = git+https://example.org/e.git#branch=dev..x
	source = git+https://example.org/f.git#branch=dev.lock
	source = git+https://example.org/g.git#branch=dev x
	source = git+https://example.org/h.git#branch=main
	source = git+https://example.org/i.git#branch=team@host
	source = git+https://example.org/j.git#branch=main@{1}
"""
    check trackableSources(info, "x86_64").mapIt(it.branch) ==
      @[some("dev/x"), some("main"), some("team@host")]

suite "tracked refs":
  let source = TrackedSource(url: "https://example.org/a.git", branch: none(string))
  let record = DevelRecord(lastModified: 100, sources: @[
    SourceRevision(source: source, commit: "aaaaaaaa")])

  test "a moved ref counts as a move":
    check refsMoved(record, [ObservedSource(source: source,
      commit: some("bbbbbbbb"))])

  test "an unchanged ref does not":
    check not refsMoved(record, [ObservedSource(source: source,
      commit: some("aaaaaaaa"))])

  test "unverifiable refs never claim a move":
    check not refsMoved(record, [ObservedSource(source: source,
      commit: none(string))])

  test "a source without a recorded revision cannot be called current":
    check refsMoved(record, [ObservedSource(
      source: TrackedSource(url: "https://example.org/new.git"),
      commit: some("cccccccc"))])

suite "ledger":
  let path = getTempDir() / "pakku-devel-test.json"
  let base = "rmlint-git"
  let source = TrackedSource(url: "https://example.org/a.git", branch: none(string))
  let observed = @[ObservedSource(source: source, commit: some("aaaaaaaa"))]

  setup:
    removeFile(path)
    defer: removeFile(path)

  test "a key is grouped once, and an empty batch resolves without a lookup":
    var batch: ObservationBatch
    check batch.resolve().len == 0
    let other = TrackedSource(url: "https://example.org/b.git", branch: none(string))
    check batch.add("base-a", [source])
    check not batch.add("base-a", [other])
    check batch.add("base-b", [source, other])
    check batch.len == 2

  test "a key that brought no sources gets an empty slice":
    ## A `pkgver()` base whose `.SRCINFO` holds nothing trackable: the batch has
    ## a key and no sources at all, so nothing is started and the slice is empty.
    var batch: ObservationBatch
    check batch.add("pinned", [])
    check batch.len == 1
    let slices = batch.resolve()
    check slices.hasKey("pinned")
    check slices["pinned"].len == 0

  test "stamp, store, load round-trips":
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed)
    discard storeDevelDb(path, db)
    let loaded = loadDevelDb(path)
    check loaded == db
    check loaded[base].lastModified == 100
    check loaded[base].sources == @[SourceRevision(source: source,
      commit: "aaaaaaaa")]

  test "an absent or broken file is an empty ledger":
    check loadDevelDb(path).len == 0
    writeFile(path, "{not json")
    check loadDevelDb(path).len == 0
    writeFile(path, """{"schema": 99, "packages": {"x": {}}}""")
    check loadDevelDb(path).len == 0
    writeFile(path, """{"schema": 1, "packages": {"x": {"lastModified": 1}}}""")
    check loadDevelDb(path).len == 0

  test "an unreadable ref keeps the revision already recorded":
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed)
    discard db.stampDevelRecord(base, 200, @[ObservedSource(source: source,
      commit: none(string))])
    check db[base].lastModified == 200
    check db[base].sources[0].commit == "aaaaaaaa"

  test "a source that left the package drops out of the record":
    let other = TrackedSource(url: "https://example.org/b.git", branch: none(string))
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed & @[ObservedSource(
      source: other, commit: some("bbbbbbbb"))])
    discard db.stampDevelRecord(base, 200, @[ObservedSource(
      source: source, commit: some("cccccccc"))])
    check db[base].sources == @[SourceRevision(source: source,
      commit: "cccccccc")]

  test "a new source that cannot be read is not recorded blindly":
    let other = TrackedSource(url: "https://example.org/b.git", branch: none(string))
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed)
    discard db.stampDevelRecord(base, 200, @[ObservedSource(source: source,
      commit: none(string)), ObservedSource(source: other,
      commit: none(string))])
    check db[base].sources == @[SourceRevision(source: source,
      commit: "aaaaaaaa")]

  test "the packaging stamp advances even when nothing could be read":
    ## Holding the old stamp back would make every later run offer the same
    ## rebuild, since a record turns the comparison into an equality.
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 200, @[ObservedSource(source: source,
      commit: none(string))])
    check db[base].lastModified == 200
    check db[base].sources.len == 0

  test "no trackable source is a fact worth recording":
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, [])
    check db[base].sources.len == 0
    discard storeDevelDb(path, db)
    check loadDevelDb(path)[base].sources.len == 0

  test "prune drops uninstalled bases only":
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed)
    discard db.stampDevelRecord("other-git", 100, observed)
    db.pruneDevelDb(["rmlint-git"].toHashSet)
    check db.len == 1 and base in db

  test "store leaves no temporary file behind":
    var db = initOrderedTable[string, DevelRecord]()
    discard db.stampDevelRecord(base, 100, observed)
    discard storeDevelDb(path, db)
    discard storeDevelDb(path, db)
    check not fileExists(path & "." & $getCurrentProcessId() & ".tmp")

  test "a ledger directory that does not exist yet is not a refusal":
    ## The first run has no cache directory; the clone creates it before any
    ## build can record, so warning "not writable" there would be noise.
    check ledgerWritable(getTempDir() / "pakku-devel-absent" / "devel.json")
    check ledgerWritable(path)

  test "a directory that cannot be written is refused":
    if posix.getuid() == 0: skip()   ## root ignores directory permissions
    let parent = getTempDir() / "pakku-devel-locked"
    removeDir(parent)
    createDir(parent)
    setFilePermissions(parent, {fpUserRead, fpUserExec})
    try:
      check not ledgerWritable(parent / "devel.json")
    finally:
      setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
      removeDir(parent)

suite "observing a remote":
  ## A repository on the loopback interface stands in for the network. It has to
  ## be a real transport: a local path is `file://`, which the protocol
  ## allowlist blocks on purpose, so `git daemon` provides the `git://` one.
  let
    gitExe = findExe("git")
    root = getTempDir() / "pakku-devel-observe-test"
    src = root / "src"
    remote = root / "remote.git"
    port = 18000 + getCurrentProcessId() mod 40000
    url = "git://127.0.0.1:" & $port & "/remote.git"
  var daemon: Process

  proc git(args: varargs[string]): string =
    let command = (@[gitExe] & args.mapIt(quoteShell(it))).join(" ")
    let (output, code) = execCmdEx(command)
    check code == 0
    output.strip

  proc waitForDaemon(): bool =
    ## Bounded: a daemon that cannot bind its port must fail the fixture, not
    ## hang the suite.
    for _ in 0 ..< 100:
      if execCmdEx("git ls-remote -- " & quoteShell(url) & " dev").exitCode == 0:
        return true
      sleep(20)
    false

  setup:
    if gitExe.len > 0:
      removeDir(root)
      createDir(root)
      discard git("init", "-q", src)
      discard git("-C", src, "config", "user.email", "test@example.org")
      discard git("-C", src, "config", "user.name", "test")
      writeFile(src / "f", "1\n")
      discard git("-C", src, "add", "f")
      discard git("-C", src, "commit", "-qm", "one")
      discard git("-C", src, "tag", "v1")
      discard git("-C", src, "branch", "dev")
      ## A nested ref with the last component of the tracked one: asking git
      ## for a bare `dev` would report this first and sort before `dev`.
      discard git("-C", src, "branch", "a/dev")
      discard git("-C", src, "checkout", "-q", "dev")
      writeFile(src / "f", "2\n")
      discard git("-C", src, "commit", "-qam", "two")
      discard git("clone", "-q", "--bare", src, remote)
      daemon = startProcess(gitExe, args = @["daemon", "--reuseaddr",
        "--base-path=" & root, "--export-all", "--listen=127.0.0.1",
        "--port=" & $port], options = {poStdErrToStdOut, poUsePath})
      ## A fixture that cannot serve must fail, not skip: a skipped test in CI
      ## looks exactly like a passing one.
      doAssert waitForDaemon(), "git daemon did not serve on port " & $port

  teardown:
    if daemon != nil:
      if daemon.running:
        daemon.terminate()
      discard daemon.waitForExit()
      daemon.close()

  test "a branch, a tag named as a branch, and the remote head all resolve":
    if gitExe.len == 0: skip()
    let dev = git("-C", remote, "rev-parse", "dev")
    let nested = git("-C", remote, "rev-parse", "a/dev")
    let tag = git("-C", remote, "rev-parse", "v1")
    let head = git("-C", remote, "rev-parse", "HEAD")
    check dev != nested
    let observed = observe([
      TrackedSource(url: url, branch: some("dev")),
      TrackedSource(url: url, branch: some("a/dev")),
      TrackedSource(url: url, branch: some("v1")),
      TrackedSource(url: url, branch: none(string))])
    check observed.mapIt(it.commit) ==
      @[some(dev), some(nested), some(tag), some(head)]

  test "one lookup hands each key its own slice, in order":
    if gitExe.len == 0: skip()
    let dev = TrackedSource(url: url, branch: some("dev"))
    let tag = TrackedSource(url: url, branch: some("v1"))
    let head = TrackedSource(url: url, branch: none(string))
    var batch: ObservationBatch
    check batch.add("branch-and-tag", [dev, tag])
    check batch.add("head", [head])
    ## A base seen twice in the candidate list is looked up once.
    check not batch.add("branch-and-tag", [head])
    let slices = batch.resolve()
    check slices["branch-and-tag"] == observe([dev, tag])
    check slices["head"] == observe([head])

  test "a ref that does not exist is unverifiable, not a move":
    if gitExe.len == 0: skip()
    check observe([TrackedSource(url: url, branch: some("nosuch"))])[0]
      .commit.isNone

  test "a URL that looks like an option stays a URL":
    if gitExe.len == 0: skip()
    let marker = root / "should-not-exist"
    check observe([TrackedSource(
      url: "--upload-pack=touch " & marker)])[0].commit.isNone
    check not fileExists(marker)
