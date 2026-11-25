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
  DevelGitSource* = object
    ## One `source` entry from `.SRCINFO`, reduced to what `git ls-remote` needs.
    url*: string
    branch*: Option[string] ## none = remote HEAD, else the `#branch=` fragment

  SavedGitRef* = object
    ## The ref a build used, and the commit it pointed at when the build started.
    source*: DevelGitSource
    commit*: string

  DevelStateEntry* = object
    ## What one pkgbase was built from, and which AUR entry that build saw.
    lastModified*: int64 ## AUR pkgbase metadata stamp at record time
    sources*: seq[SavedGitRef]

  DevelStateData* = OrderedTable[string, DevelStateEntry] ## pkgbase -> record

  DevelStateStatus* = enum
    ## Result of loading devel state. An empty file is recoverable and is
    ## rewritten on load; a malformed one is left untouched.
    develStateOk        ## absent or valid state
    develStateEmpty     ## zero-length or whitespace-only file, repaired
    develStateMalformed ## unreadable or invalid file, kept as-is

  DevelStateLoad* = object
    ## Always carries the decoded ledger. Only a malformed file carries a reason;
    ## an empty file needs no payload once its status is known.
    db*: DevelStateData
    case status*: DevelStateStatus
    of develStateOk, develStateEmpty:
      discard
    of develStateMalformed:
      reason*: string

  GitRefAnswer* = object
    ## What a lookup answered for one source now.
    source*: DevelGitSource
    commit*: Option[string] ## none = the ref could not be verified
    error*: Option[string] ## first git diagnostic when verification failed

const
  gitProtocols = ["git", "https", "http", "ssh"]
    ## Schemes `git ls-remote` may talk. The source list is unreviewed AUR
    ## input, so `ext::` (arbitrary command transport) and `file://` stay out.
  observeTimeoutMs = 15_000
  hexDigits = {'0'..'9', 'a'..'f', 'A'..'F'}
  refForbidden = {'\x00'..'\x20', '\x7f', '~', '^', ':', '?', '*', '[', '\\'}

func endsWithLock(part: openArray[char]): bool =
  const suffix = ".lock"
  if part.len < suffix.len:
    return false
  for index, character in suffix:
    if part[part.len - suffix.len + index] != character:
      return false
  true

func isRefComponent(part: openArray[char]): bool =
  part.len > 0 and part[0] != '.' and part[part.high] != '.' and
    not endsWithLock(part)

func isRefName(name: string): bool =
  ## `#branch=` is handed to `git ls-remote` as a ref name, so every component
  ## has to satisfy git's rules. A bare `*` is the dangerous case: git matches
  ## patterns against ref tails and would list every ref in the repository.
  if name.len == 0 or name == "@":
    return false
  if not isRefComponent(name.toOpenArray(0, name.high)):
    return false
  if name.contains("..") or name.contains("@{"):
    return false
  var componentStart = 0
  for index, character in name:
    if character in refForbidden:
      return false
    if character == '/':
      if index == componentStart:
        return false
      if not isRefComponent(name.toOpenArray(componentStart, index - 1)):
        return false
      componentStart = index + 1
  if componentStart >= name.len:
    return false
  isRefComponent(name.toOpenArray(componentStart, name.high))

func parseSourceEntry(value: string): Option[DevelGitSource] =
  ## `<name>::<scheme>+<transport>://<path>[?query][#branch=<ref>]`, with the
  ## parts `git ls-remote` actually accepts. Everything else is dropped: a
  ## source that cannot be verified must not become an upgrade signal.
  let schemeAt = value.find("://")
  if schemeAt < 0:
    return none(DevelGitSource)
  let prefixAt = value.find("::")
  let body = if prefixAt >= 0 and prefixAt < schemeAt: value[prefixAt + 2 .. ^1]
    else: value
  let bodySchemeAt = body.find("://")
  if bodySchemeAt < 0:
    return none(DevelGitSource)

  var hasGit = false
  var protocol = ""
  for token in split(body[0 ..< bodySchemeAt], '+'):
    if token == "git":
      hasGit = true
    protocol = token
  if not hasGit or protocol notin gitProtocols:
    return none(DevelGitSource)

  let rest = body[bodySchemeAt + 3 .. ^1]
  let fragmentAt = rest.find('#')
  let pathAndQuery = if fragmentAt >= 0: rest[0 ..< fragmentAt] else: rest
  let queryAt = pathAndQuery.find('?')
  let path = if queryAt >= 0: pathAndQuery[0 ..< queryAt] else: pathAndQuery
  if path.len == 0 or path[0] == '-':
    return none(DevelGitSource)
  let url = protocol & "://" & path

  var branch = none(string)
  if fragmentAt >= 0:
    let fragment = rest[fragmentAt + 1 .. ^1]
    let nameEnd = fragment.find('?')
    let fragmentName = if nameEnd >= 0: fragment[0 ..< nameEnd] else: fragment
    if not fragmentName.startsWith("branch="):
      return none(DevelGitSource) # pinned source, not a moving ref
    let name = fragmentName["branch=".len .. ^1]
    if name.startsWith('-') or not isRefName(name):
      return none(DevelGitSource)
    branch = some(name)

  some(DevelGitSource(url: url, branch: branch))

iterator gitSourceEntries*(srcInfo: string; arch: string): DevelGitSource =
  ## Yields each deduplicated git source of the current architecture so callers
  ## can filter while parsing instead of materializing an intermediate seq.
  let archKey = "source_" & arch
  var seen = initHashSet[string]()
  for line in srcInfo.splitLines:
    let stripped = line.strip
    let separator = stripped.find(" = ")
    if separator < 0:
      continue
    let key = stripped[0 ..< separator]
    if key != "source" and key != archKey:
      continue
    for source in parseSourceEntry(stripped[separator + 3 .. ^1]):
      let identity = source.url & "\0" & source.branch.get("")
      if not seen.containsOrIncl(identity):
        yield source

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

func refNames*(source: DevelGitSource): seq[string] =
  ## The exact ref names to ask for: a branch, then a tag of the same name,
  ## because `git clone -b` accepts either; `HEAD` alone when no branch was
  ## named. Fully qualified, because `git ls-remote` matches a pattern against
  ## ref tails - a bare `dev` would also return `refs/heads/a/dev`, and whichever
  ## line came first would be recorded as the revision this package was built
  ## from.
  for branch in source.branch:
    return @["refs/heads/" & branch, "refs/tags/" & branch]
  @["HEAD"]

func isRecordedCommit(commit: openArray[char]): bool =
  commit.len in 7 .. 64 and commit.allIt(it in hexDigits)

func parseRemoteRef*(output: string; names: openArray[string]): Option[string] =
  ## The object id of the first of `names` that the remote reported, when it
  ## looks like an object id. Matching is by whole ref name, so a line about
  ## another ref that happened to match a pattern can never be mistaken for the
  ## one that was asked about.
  for name in names:
    for line in splitLines(output):
      var fields: array[2, string]
      var count = 0
      for field in line.splitWhitespace:
        if count == fields.len: break
        fields[count] = field
        inc count
      if count < 2 or fields[1] != name:
        continue
      let hash = fields[0]
      if isRecordedCommit(hash.toOpenArray(0, hash.high)):
        return some(hash)
  none(string)


func firstDiagnostic(output: string; code: int): Option[string] =
  for line in splitLines(output):
    let trimmed = line.strip
    if trimmed.len > 0:
      return some(trimmed)
  some("git exited with status " & $code)

func gitRefsChanged*(record: DevelStateEntry;
    observed: openArray[GitRefAnswer]): bool =
  ## Whether any observable ref is unknown to the record or points elsewhere.
  ## A ref that could not be looked up says nothing and never counts as a move.
  for o in observed:
    if o.commit.isSome and not record.sources.anyIt(
        it.source == o.source and it.commit == o.commit.unsafeGet):
      return true
  false

func describes*(observed: openArray[GitRefAnswer];
    sources: openArray[DevelGitSource]): bool =
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
    names: seq[string] ## ref names actually sent to git


proc lookupRemoteRefs*(sources: openArray[DevelGitSource]): seq[GitRefAnswer] =
  ## Asks each remote where its tracked ref points. Returns one entry per
  ## source, in order; an entry whose `commit` is `none` could not be verified.
  ##
  ## All processes start first, then one global deadline bounds the whole batch:
  ## a per-process timeout would serialise a dead network into minutes. `--`
  ## terminates options, so an AUR-supplied URL or ref can never become a git
  ## flag, and `GIT_ALLOW_PROTOCOL` keeps `ext::` transports out of reach.
  result = sources.mapIt(GitRefAnswer(source: it,
    commit: none(string), error: none(string)))
  if sources.len == 0:
    return

  let deadline = getMonoTime() + initDuration(milliseconds = observeTimeoutMs)
  let environment = gitEnvironment()
  let observeDir = block:
    let home =
      if environment.hasKey("HOME"): environment["HOME"]
      else: ""
    if home.len == 0: "/"
    else:
      try: home.absolutePath
      except CatchableError: "/"
  environment["HOME"] = observeDir

  let previousDir =
    try: some(getCurrentDir())
    except CatchableError: none(string)

  var running = newSeqOfCap[RunningObservation](sources.len)
  try:
    try:
      setCurrentDir(observeDir)
    except CatchableError:
      discard # children below simply stay unverifiable
    for index, source in sources:
      # Fully qualified names, never a bare branch: `git ls-remote` matches a
      # pattern on ref tails, so `dev` would also return `refs/heads/a/dev` and
      # the answer could describe a ref the build never uses. Both namespaces are
      # asked because `git clone -b` accepts a tag as well, and `--no-tags` does
      # not hide an explicitly requested one. `--` already ended option parsing,
      # so neither a URL nor a ref can become a flag.
      try:
        let names = refNames(source)
        var command = newSeqOfCap[string](4 + names.len)
        command.add ["ls-remote", "--no-tags", "--", source.url]
        command.add names
        running.add RunningObservation(index: index, names: names,
          process: startProcess(gitCmd, args = command, env = environment,
            workingDir = observeDir, options = {poStdErrToStdOut, poUsePath}))

      except CatchableError:
        result[index].error = some(getCurrentExceptionMsg())
  finally:
    for path in previousDir:
      try: setCurrentDir(path)
      except CatchableError: discard

  for entry in running:
    try:
      var code = -1
      while true:
        code = entry.process.peekExitCode
        if code != -1:
          break
        if getMonoTime() >= deadline:
          result[entry.index].error = some("timed out")
          try:
            entry.process.terminate()
          except CatchableError:
            discard
          try:
            discard waitForExit(entry.process)
          except CatchableError:
            discard
          break
        sleep(10)
      if code != -1:
        if code == 0:
          result[entry.index].commit = parseRemoteRef(
            entry.process.outputStream.readAll(), entry.names)
        else:
          result[entry.index].error = firstDiagnostic(
            entry.process.outputStream.readAll(), code)
    except CatchableError:
      result[entry.index].error = some(getCurrentExceptionMsg())
    finally:
      entry.process.close()

type
  ObservationBatch* = object
    ## Sources grouped by key and resolved by one `lookupRemoteRefs` call, so a pass over
    ## many packages pays one deadline instead of one per package. The grouping
    ## is kept, so each key gets its own slice back and callers never rebuild
    ## the offset arithmetic themselves.
    seen: HashSet[string]
    keys: seq[string]
    counts: seq[int]
    sources: seq[DevelGitSource]

func add*(batch: var ObservationBatch; key: string;
    sources: openArray[DevelGitSource]): bool =
  ## Adds one key's sources, once per key. Returns false when the key was already
  ## there, which is what a split base needs: several packages, one lookup.
  if batch.seen.containsOrIncl(key):
    return false
  batch.keys.add key
  batch.counts.add sources.len
  batch.sources.add sources
  true

func len*(batch: ObservationBatch): int =
  ## Number of keys grouped, not number of sources.
  batch.keys.len

proc resolve*(batch: ObservationBatch): Table[string, seq[GitRefAnswer]] =
  ## One lookup for everything in the batch, then a slice per key. Nothing is
  ## started for a key that brought no sources, and an empty batch costs nothing.
  if batch.keys.len == 0:
    return
  let answers = lookupRemoteRefs(batch.sources)
  var offset = 0
  for index, key in batch.keys:
    let count = batch.counts[index]
    result[key] = answers[offset ..< offset + count]
    offset += count

func toJson(db: DevelStateData): JsonNode =
  ## The file this version writes. `schema` is 1 because `fromJson` refuses
  ## anything else: a future layout bumps it, and an older pakku then sees an
  ## empty devel state instead of misreading fields it never wrote.
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

func isRecordedSource(source: DevelGitSource): bool =
  let schemeAt = source.url.find("://")
  if schemeAt < 1 or source.url.len <= schemeAt + 3 or
      source.url[0 ..< schemeAt] notin gitProtocols:
    return false
  for branch in source.branch:
    if not isRefName(branch):
      return false
  true

func fromJson(node: JsonNode): (DevelStateData, Option[string]) =
  ## Invalid entries are skipped so valid ones survive. A file this version did
  ## not write is refused as a whole: overwriting a future schema would destroy
  ## state the next pakku still understands.
  if node == nil or node.kind != JObject:
    return (result[0], some(tr"devel state is not an object"))
  if node{"schema"}.getInt(0) != 1:
    return (result[0], some(tr"unsupported devel state schema"))
  let packages = node{"packages"}
  if packages == nil or packages.kind != JObject:
    return (result[0], some(tr"devel state has no package entries"))


  for base, record in packages.pairs:
    if record == nil or record.kind != JObject:
      continue
    let stampNode = record{"lastModified"}
    if stampNode == nil or stampNode.kind != JInt:
      continue
    let sourcesNode = record{"sources"}
    if sourcesNode == nil or sourcesNode.kind != JArray:
      continue
    var parsed = DevelStateEntry(lastModified: stampNode.getBiggestInt)
    for entry in sourcesNode.items:
      if entry == nil or entry.kind != JObject:
        continue
      let url = entry{"url"}.getStr
      let commit = entry{"commit"}.getStr
      if url.len == 0 or commit.len == 0:
        continue
      let branch = entry{"branch"}.getStr
      let source = DevelGitSource(url: url,
        branch: (if branch.len > 0: some(branch) else: none(string)))
      if not isRecordedSource(source) or
          not isRecordedCommit(commit.toOpenArray(0, commit.high)):
        continue
      parsed.sources.add SavedGitRef(source: source, commit: commit)
    result[0][base] = parsed

proc saveDevelState*(path: string; db: DevelStateData): Option[string]

proc loadDevelState*(path: string): DevelStateLoad =
  ## An absent file is normal empty state. An empty file warns but is repaired
  ## on load, so the next build records into it. Only a file that cannot be read,
  ## decoded or repaired is abandoned with its reason.
  var db: DevelStateData
  if not fileExists(path):
    return DevelStateLoad(db: db, status: develStateOk)
  let content = block:
    try:
      readFile(path)
    except CatchableError:
      return DevelStateLoad(db: db, status: develStateMalformed,
        reason: getCurrentExceptionMsg())
  if content.strip.len == 0:
    for failure in saveDevelState(path, db):
      return DevelStateLoad(db: db, status: develStateMalformed,
        reason: tr"devel state file is empty; could not recreate it: $#" % [failure])
    return DevelStateLoad(db: db, status: develStateEmpty)
  try:
    let (decoded, problem) = fromJson(parseJson(content))
    for reason in problem:
      return DevelStateLoad(db: decoded, status: develStateMalformed,
        reason: reason)
    DevelStateLoad(db: decoded, status: develStateOk)
  except CatchableError:
    DevelStateLoad(db: db, status: develStateMalformed,
      reason: getCurrentExceptionMsg())

proc dropUnlistedDevelEntries*(db: var DevelStateData; live: HashSet[string]) =
  ## Drops records for pkgbases the AUR no longer lists. The key has to come
  ## from the AUR: `%BASE%` is absent on packages built by older makepkg, so the
  ## local database cannot name a split package's pkgbase.
  var stale = newSeqOfCap[string](db.len)

  for base in db.keys:
    if base notin live:
      stale.add base
  for base in stale:
    db.del base

proc handToInitialUser(path: string) =
  ## `SudoExec` makes this process root while the devel state file belongs in the invoking
  ## user's cache. A root-owned file cannot be rewritten by the next
  ## unprivileged run, whose write failure is silent - and a record that never
  ## advances offers the same rebuild for as long as the package is installed.
  if currentUser.uid == 0:
    for user in initialUser:
      discard chown(cstring(path), (Uid) user.uid, (Gid) user.gid)

proc develStateWritable*(path: string): bool =
  ## Whether an entry could be written where the devel state lives. A state file that can
  ## be read but not rewritten is worse than none: its entries can never advance,
  ## so every run offers the same rebuild, while the AUR info-time check against
  ## the install date - converges on its own. The directory decides, because the
  ## write is a new temporary file plus a rename over the target; a directory
  ## that does not exist yet is not a refusal, since the clone creates it before
  ## any build can record, and a failure there is reported by the write itself.
  let directory = path.parentDir
  not dirExists(directory) or access(cstring(directory), W_OK) == 0

proc saveDevelState*(path: string; db: DevelStateData): Option[string] =
  ## Atomic: a reader sees either the old file or the new one. The pid keeps
  ## concurrent runs from sharing a temporary name. The failure is returned
  ## rather than swallowed, because a state file that cannot be written leaves an
  ## entry that never advances and an offer that repeats on every run.
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

func savedCommitOf*(record: Option[DevelStateEntry]; source: DevelGitSource):
    Option[string] =
  ## What the record already knows about this source, if anything.
  for revision in record:
    for entry in revision.sources:
      if entry.source == source:
        return some(entry.commit)
  none(string)

proc updateDevelStateEntry*(db: var DevelStateData; base: string; lastModified: int64;
    observed: openArray[GitRefAnswer]): bool =
  ## Records what this run built, and reports whether the state changed.
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
  var record = DevelStateEntry(lastModified: lastModified)
  for o in observed:
    var kept = o.commit
    if kept.isNone:
      kept = savedCommitOf(saved, o.source) # keep what the record already had
    for commit in kept:
      record.sources.add SavedGitRef(source: o.source, commit: commit)
  if saved.isSome and saved.unsafeGet == record:
    return false
  db[base] = record
  true
