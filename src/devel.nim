import
  std/[json, monotimes, options, os, osproc, posix, sequtils, sets, strtabs,
    streams, strutils, tables, times],
  utils

## Tracks the upstream git refs a development package was built from, so an
## upgrade can be offered when upstream moved instead of comparing versions.
##
## Why not versions: a devel `pkgver` ends in a commit identifier, which has no
## chronological order. `vercmp` orders it anyway, so the AUR copy is declared
## newer or older for reasons unrelated to either, and the resulting offer can
## never be satisfied by rebuilding.
##
## Why not resolve versions: `makepkg --nobuild` runs the unreviewed PKGBUILD's
## `pkgver()` and downloads the sources, which contradicts pakku's review
## promise and costs a source clone per package on every invocation.
##
## What is left is identity: remember the refs, ask the remote whether they
## still point where they did, and rebuild when they do not.

type
  TrackedSource* = object
    ## One `source` entry from `.SRCINFO`, reduced to what `git ls-remote` needs.
    url*: string
    branch*: Option[string] ## none = remote HEAD, else the `#branch=` fragment

  SourceRevision* = object
    ## The ref a build used, and the commit it pointed at when the build started.
    source*: TrackedSource
    commit*: string

  DevelRecord* = object
    ## What one pkgbase was built from, and which AUR entry that build saw.
    lastModified*: int64 ## AUR pkgbase metadata stamp at record time
    sources*: seq[SourceRevision]

  DevelDb* = OrderedTable[string, DevelRecord] ## pkgbase -> record

  ObservedSource* = object
    ## What a lookup answered for one source now.
    source*: TrackedSource
    commit*: Option[string] ## none = the ref could not be verified

const
  gitProtocols = ["git", "https", "http", "ssh"]
    ## Schemes `git ls-remote` may talk. The source list is unreviewed AUR
    ## input, so `ext::` (arbitrary command transport) and `file://` stay out.
  observeTimeoutMs = 15_000
  hexDigits = {'0'..'9', 'a'..'f', 'A'..'F'}
  refForbidden = {'\x00'..'\x20', '\x7f', '~', '^', ':', '?', '*', '[', '\\'}

func isRefName(name: string): bool =
  ## `#branch=` is handed to `git ls-remote` as a ref name, so it has to be one
  ## `git clone -b` would also accept. The glob characters are the ones that
  ## matter: `git ls-remote` matches patterns against ref tails, so a `*` asks
  ## for every ref in the repository - gigabytes of output, a killed child and a
  ## source that can never be verified. The rest are `git check-ref-format`
  ## rules that would make the lookup or the build fail anyway.
  if name.len == 0 or name[0] == '.' or name[0] == '/' or name[^1] == '/' or
      name[^1] == '.' or name.endsWith(".lock"):
    return false
  if name.contains("..") or name.contains("@{") or name.contains("//"):
    return false
  for character in name:
    if character in refForbidden:
      return false
  true

func parseSourceEntry(value: string): Option[TrackedSource] =
  ## `<name>::<scheme>+<transport>://<path>[?query][#branch=<ref>]`, with the
  ## parts `git ls-remote` actually accepts. Everything else is dropped: a
  ## source that cannot be verified must not become an upgrade signal.
  let schemeAt = value.find("://")
  if schemeAt < 0:
    return none(TrackedSource)
  let prefixAt = value.find("::")
  let body = if prefixAt >= 0 and prefixAt < schemeAt: value[prefixAt + 2 .. ^1]
    else: value
  let bodySchemeAt = body.find("://")
  if bodySchemeAt < 0:
    return none(TrackedSource)

  let tokens = body[0 ..< bodySchemeAt].split('+')
  if "git" notin tokens:
    return none(TrackedSource)
  let protocol = tokens[^1]
  if protocol notin gitProtocols:
    return none(TrackedSource)

  let rest = body[bodySchemeAt + 3 .. ^1]
  let fragmentAt = rest.find('#')
  let pathAndQuery = if fragmentAt >= 0: rest[0 ..< fragmentAt] else: rest
  let path = pathAndQuery.split('?')[0]
  if path.len == 0:
    return none(TrackedSource)
  let url = protocol & "://" & path
  if url.startsWith('-'):
    return none(TrackedSource)

  var branch = none(string)
  if fragmentAt >= 0:
    let fragment = rest[fragmentAt + 1 .. ^1].split('?')[0]
    if not fragment.startsWith("branch="):
      return none(TrackedSource) # `#tag=`, `#commit=`, or unknown: pinned
    let name = fragment["branch=".len .. ^1]
    if name.startsWith('-') or not isRefName(name):
      return none(TrackedSource)
    branch = some(name)

  some(TrackedSource(url: url, branch: branch))

func trackableSources*(srcInfo: string; arch: string): seq[TrackedSource] =
  ## Git sources of the current architecture, deduplicated.
  let archKey = "source_" & arch
  for line in srcInfo.splitLines:
    let stripped = line.strip
    let separator = stripped.find(" = ")
    if separator < 0:
      continue
    let key = stripped[0 ..< separator]
    if key != "source" and key != archKey:
      continue
    let source = parseSourceEntry(stripped[separator + 3 .. ^1])
    if source.isSome and source.unsafeGet notin result:
      result.add source.unsafeGet

func hasAt(text: string; at: int; part: string): bool =
  ## `strutils.startsWith` has no offset; comparing in place avoids a slice per
  ## line of every PKGBUILD we look at.
  if at < 0 or at + part.len > text.len:
    return false
  for index, character in part:
    if text[at + index] != character:
      return false
  true

func definesPkgver*(pkgbuild: string): bool =
  ## Whether the PKGBUILD defines `pkgver()`, which is makepkg's own test for a
  ## development package. A repository cloned by a build script is not enough:
  ## without `pkgver()` the version does not follow upstream, so tracking its
  ## refs would report movement that changes nothing.
  for line in pkgbuild.splitLines:
    var index = 0
    while index < line.len and line[index] in {' ', '\t'}:
      inc index
    var keyword = false
    if line.hasAt(index, "function"):
      keyword = true
      index += "function".len
      while index < line.len and line[index] in {' ', '\t'}:
        inc index
    if not line.hasAt(index, "pkgver"):
      continue
    index += "pkgver".len
    while index < line.len and line[index] in {' ', '\t'}:
      inc index
    # `pkgver()` is the usual form; plain bash also allows `function pkgver {`,
    # which makepkg's own `declare -f pkgver` test accepts.
    if index < line.len and (line[index] == '(' or
        (keyword and line[index] == '{')):
      return true
  false

func refNames*(source: TrackedSource): seq[string] =
  ## The exact ref names to ask for: a branch, then a tag of the same name,
  ## because `git clone -b` accepts either; `HEAD` alone when no branch was
  ## named. Fully qualified, because `git ls-remote` matches a pattern against
  ## ref tails - a bare `dev` would also return `refs/heads/a/dev`, and whichever
  ## line came first would be recorded as the revision this package was built
  ## from.
  for branch in source.branch:
    return @["refs/heads/" & branch, "refs/tags/" & branch]
  @["HEAD"]

func parseRemoteRef*(output: string; names: openArray[string]): Option[string] =
  ## The object id of the first of `names` that the remote reported, when it
  ## looks like an object id. Matching is by whole ref name, so a line about
  ## another ref that happened to match a pattern can never be mistaken for the
  ## one that was asked about.
  for name in names:
    for line in output.splitLines:
      let fields = line.splitWhitespace
      if fields.len < 2 or fields[1] != name:
        continue
      let hash = fields[0]
      if hash.len >= 7 and hash.len <= 64 and hash.allIt(it in hexDigits):
        return some(hash)
  none(string)

func refsMoved*(record: DevelRecord;
    observed: openArray[ObservedSource]): bool =
  ## Whether any observable ref is unknown to the record or points elsewhere.
  ## A ref that could not be looked up says nothing and never counts as a move.
  for o in observed:
    if o.commit.isSome and not record.sources.anyIt(
        it.source == o.source and it.commit == o.commit.unsafeGet):
      return true
  false

func describes*(observed: openArray[ObservedSource];
    sources: openArray[TrackedSource]): bool =
  ## Whether the observations cover exactly these sources. Used to reuse a ref
  ## list already read for an upgrade decision: a source list that changed since
  ## then describes a different package and must be read again.
  observed.len == sources.len and observed.allIt(it.source in sources)

proc gitEnvironment(): StringTableRef =
  ## The child's environment: ours, minus the prompts, plus the protocol
  ## allowlist. Under `SudoExec` this process is root while the build later runs
  ## as the invoking user, so git has to look at that user's configuration too -
  ## otherwise `~/.gitconfig` rewrites and `~/.ssh` keys are missing exactly
  ## where the build finds them, and every private source becomes unverifiable.
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  if currentUser.uid == 0:
    for user in initialUser:
      result["HOME"] = user.home
      result["USER"] = user.name
      result["LOGNAME"] = user.name
  result["GIT_TERMINAL_PROMPT"] = "0"
  result["GIT_ALLOW_PROTOCOL"] = gitProtocols.join(":")

type
  RunningObservation = object
    ## A child that was started and still has to be waited for.
    index: int ## where this process's answer belongs in the result
    process: Process

proc observe*(sources: openArray[TrackedSource]): seq[ObservedSource] =
  ## Asks each remote where its tracked ref points. Returns one entry per
  ## source, in order; an entry whose `commit` is `none` could not be verified.
  ##
  ## All processes start first, then one global deadline bounds the whole batch:
  ## a per-process timeout would serialise a dead network into minutes. `--`
  ## terminates options, so an AUR-supplied URL or ref can never become a git
  ## flag, and `GIT_ALLOW_PROTOCOL` keeps `ext::` transports out of reach.
  result = newSeq[ObservedSource](sources.len)
  for index, source in sources:
    result[index] = ObservedSource(source: source, commit: none(string))
  if sources.len == 0:
    return

  let started = getMonoTime()
  let environment = gitEnvironment()
  var running: seq[RunningObservation]
  for index, source in sources:
    # Fully qualified names, never a bare branch: `git ls-remote` matches a
    # pattern on ref tails, so `dev` would also return `refs/heads/a/dev` and
    # the answer could describe a ref the build never uses. Both namespaces are
    # asked because `git clone -b` accepts a tag as well, and `--no-tags` does
    # not hide an explicitly requested one. `--` already ended option parsing,
    # so neither a URL nor a ref can become a flag.
    try:
      let command = @["ls-remote", "--no-tags", "--", source.url] &
        refNames(source)
      running.add RunningObservation(index: index, process: startProcess(gitCmd,
        args = command, env = environment,
        options = {poStdErrToStdOut, poUsePath}))
    except CatchableError:
      discard # stays unverifiable

  for entry in running:
    try:
      let remaining = observeTimeoutMs -
        (getMonoTime() - started).inMilliseconds.int
      if waitForExit(entry.process, max(remaining, 1)) == 0:
        result[entry.index].commit = parseRemoteRef(
          entry.process.outputStream.readAll(), refNames(sources[entry.index]))
    except CatchableError:
      discard
    finally:
      entry.process.close()

type
  ObservationBatch* = object
    ## Sources grouped by key and resolved by one `observe` call, so a pass over
    ## many packages pays one deadline instead of one per package. The grouping
    ## is kept, so each key gets its own slice back and callers never rebuild
    ## the offset arithmetic themselves.
    seen: HashSet[string]
    keys: seq[string]
    counts: seq[int]
    sources: seq[TrackedSource]

func add*(batch: var ObservationBatch; key: string;
    sources: openArray[TrackedSource]): bool =
  ## Adds one key's sources, once per key. Returns false when the key was already
  ## there, which is what a split base needs: several packages, one lookup.
  if key in batch.seen:
    return false
  batch.seen.incl key
  batch.keys.add key
  batch.counts.add sources.len
  batch.sources.add sources
  true

func len*(batch: ObservationBatch): int =
  ## Number of keys grouped, not number of sources.
  batch.keys.len

proc resolve*(batch: ObservationBatch): Table[string, seq[ObservedSource]] =
  ## One lookup for everything in the batch, then a slice per key. Nothing is
  ## started for a key that brought no sources, and an empty batch costs nothing.
  if batch.keys.len == 0:
    return
  let answers = observe(batch.sources)
  var offset = 0
  for index, key in batch.keys:
    let count = batch.counts[index]
    result[key] = answers[offset ..< offset + count]
    offset += count

func toJson(db: DevelDb): JsonNode =
  ## The file this version writes. `schema` is 1 because `fromJson` refuses
  ## anything else: a future layout bumps it, and an older pakku then sees an
  ## empty ledger instead of misreading fields it never wrote.
  result = %*{"schema": 1, "packages": newJObject()}
  for base, record in db:
    var sources = newJArray()
    for revision in record.sources:
      var entry = %*{"url": revision.source.url, "commit": revision.commit}
      for branch in revision.source.branch:
        entry["branch"] = %branch
      sources.add entry
    result["packages"][base] = %*{
      "lastModified": record.lastModified, "sources": sources}

func fromJson(node: JsonNode): DevelDb =
  ## Whatever is not a ledger this version wrote is ignored: a hand-edited or
  ## half-written file degrades to "no records", never to a crash.
  if node == nil or node.kind != JObject or node{"schema"}.getInt(0) != 1:
    return
  let packages = node{"packages"}
  if packages == nil or packages.kind != JObject:
    return

  for base, record in packages.pairs:
    if record == nil or record.kind != JObject:
      continue
    let sourcesNode = record{"sources"}
    if sourcesNode == nil or sourcesNode.kind != JArray:
      continue
    var parsed = DevelRecord(lastModified: record{"lastModified"}.getBiggestInt(0))
    for entry in sourcesNode.items:
      if entry == nil or entry.kind != JObject:
        continue
      let url = entry{"url"}.getStr
      let commit = entry{"commit"}.getStr
      if url.len == 0 or commit.len == 0:
        continue
      let branch = entry{"branch"}.getStr
      parsed.sources.add SourceRevision(
        source: TrackedSource(url: url,
          branch: (if branch.len > 0: some(branch) else: none(string))),
        commit: commit)
    result[base] = parsed

proc loadDevelDb*(path: string): DevelDb =
  ## An absent, unreadable or malformed file is an empty ledger: every
  ## development package then falls back to the packaging-age rule.
  try:
    result = fromJson(parseFile(path))
  except CatchableError:
    discard # absent or malformed: callers see no records

proc pruneDevelDb*(db: var DevelDb; live: HashSet[string]) =
  ## Drops records for pkgbases the AUR no longer lists. The key has to come
  ## from the AUR: `%BASE%` is absent on packages built by older makepkg, so the
  ## local database cannot name a split package's pkgbase.
  var stale: seq[string]
  for base in db.keys:
    if base notin live:
      stale.add base
  for base in stale:
    db.del base

proc handToInitialUser(path: string) =
  ## `SudoExec` makes this process root while the ledger belongs in the invoking
  ## user's cache. A root-owned file cannot be rewritten by the next
  ## unprivileged run, whose write failure is silent - and a record that never
  ## advances offers the same rebuild for as long as the package is installed.
  if currentUser.uid == 0:
    for user in initialUser:
      discard chown(cstring(path), (Uid) user.uid, (Gid) user.gid)

proc ledgerWritable*(path: string): bool =
  ## Whether a record could be written where the ledger lives. A ledger that can
  ## be read but not rewritten is worse than none: its records can never advance,
  ## so every run offers the same rebuild, while Layer 1 - packaging age against
  ## the install date - converges on its own. The directory decides, because the
  ## write is a new temporary file plus a rename over the target; a directory
  ## that does not exist yet is not a refusal, since the clone creates it before
  ## any build can record, and a failure there is reported by the write itself.
  let directory = path.parentDir
  not dirExists(directory) or access(cstring(directory), W_OK) == 0

proc storeDevelDb*(path: string; db: DevelDb): Option[string] =
  ## Atomic: a reader sees either the old file or the new one. The pid keeps
  ## concurrent runs from sharing a temporary name. The failure is returned
  ## rather than swallowed, because a ledger that cannot be written leaves a
  ## record that never advances and an offer that repeats on every run.
  let temporary = path & "." & $getCurrentProcessId() & ".tmp"
  try:
    writeFile(temporary, $toJson(db))
    moveFile(temporary, path)
    handToInitialUser(path)
    none(string)
  except CatchableError:
    let message = getCurrentExceptionMsg()
    try:
      removeFile(temporary)
    except CatchableError:
      discard
    some(message)

func revisionOf(record: Option[DevelRecord]; source: TrackedSource):
    Option[string] =
  ## What the record already knows about this source, if anything.
  for revision in record:
    for entry in revision.sources:
      if entry.source == source:
        return some(entry.commit)
  none(string)

proc stampDevelRecord*(db: var DevelDb; base: string; lastModified: int64;
    observed: openArray[ObservedSource]): bool =
  ## Records what this run built, and reports whether the ledger changed.
  ##
  ## A source whose ref could not be read now keeps the revision the record
  ## already holds: a failed lookup is not evidence that anything moved.
  ## Sources that left the package drop out, and a source nobody has ever read is
  ## not invented, so a changed source list converges instead of accumulating.
  ##
  ## The packaging stamp advances even when nothing could be read. Holding it
  ## back would leave the old stamp in place, and since a record turns the
  ## comparison into an equality, every later run would offer a rebuild that no
  ## rebuild can settle. The cost is that a base whose refs are never readable
  ## is decided by packaging age - which is where an untracked package already
  ## is - so the caller says so.
  let saved = db.opt(base)
  var record = DevelRecord(lastModified: lastModified)
  for o in observed:
    var kept = o.commit
    if kept.isNone:
      kept = revisionOf(saved, o.source) # keep what the record already had
    for commit in kept:
      record.sources.add SourceRevision(source: o.source, commit: commit)
  result = saved != some(record)
  db[base] = record
