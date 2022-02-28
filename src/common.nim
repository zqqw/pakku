import
  options, os, osproc, posix, sequtils, sets, strutils, sugar, tables,
  args, config, format, lists, package, pacman, utils,
  "wrapper/alpm"

type
  CacheKind* {.pure.} = enum
    repositories, packages

  BareKind* {.pure.} = enum
    pkg, repo

  SyncFoundPackageInfo* = tuple[
    base: string,
    version: string,
    arch: Option[string]
  ]

  SyncFoundInfo* = tuple[
    repo: string,
    pkg: Option[SyncFoundPackageInfo]
  ]

  PackageTarget* = tuple[
    reference: PackageReference,
    repo: Option[string],
    destination: Option[string]
  ]

  SyncPackageTarget* = tuple[
    target: PackageTarget,
    foundInfos: seq[SyncFoundInfo]
  ]

  FullPackageTarget* = tuple[
    sync: SyncPackageTarget,
    rpcInfo: Option[RpcPackageInfo]
  ]

  LookupBaseGroup = tuple[
    base: string,
    version: string,
    arch: string,
    repo: string
  ]

var isArtix*: bool
var isArch*: bool
var isParabola*: bool

proc checkAndRefreshUpgradeInternal(
  sudoPrefix: seq[string], color: bool, upgrade: bool, args: seq[Argument]
  ): tuple[code: int, args: seq[Argument]] =
  let refreshCount = args.count(%%%"refresh")
  let upgradeCount = if upgrade: args.count(%%%"sysupgrade") else: 0
  if refreshCount > 0 or upgradeCount > 0:
    let code = pacmanRun(some sudoPrefix, color, args
      .keepOnlyOptions(commonOptions, transactionOptions, upgradeOptions) &
      ("S", none(string), ArgumentType.short) &
      ("y", none(string), ArgumentType.short).repeat(refreshCount) &
      ("u", none(string), ArgumentType.short).repeat(upgradeCount))

    let callArgs = args
      .filter(arg => not arg.matchOption(%%%"refresh") and
        (upgradeCount == 0 or not arg.matchOption(%%%"sysupgrade")))
    (code, callArgs)
  else:
    (0, args)

template checkAndRefreshUpgrade*(sudoPrefix: seq[string], color: bool, args: seq[Argument]):
  tuple[code: int, args: seq[Argument]] =
  checkAndRefreshUpgradeInternal(sudoPrefix, color, true, args)

template checkAndRefresh*(sudoPrefix: seq[string], color: bool, args: seq[Argument]):
  tuple[code: int, args: seq[Argument]] =
  checkAndRefreshUpgradeInternal(sudoPrefix, color, false, args)

proc noconfirm*(args: seq[Argument]): bool =
  args
    .filter(arg => arg.matchOption(%%%"confirm") or
      arg.matchOption(%%%"noconfirm")).optLast
    .map(arg => arg.key == "noconfirm").get(false) or
    args.check(%%%"ask")

proc packageTargets*(args: seq[Argument], parseDestination: bool): seq[PackageTarget] =
  args.targets.map(target => (block:
    let (noDestinationTarget, destination) = if parseDestination: (block:
        let split = target.split("::", 2)
        if split.len == 2:
          (split[0], some(split[1]))
        else:
          (target, none(string)))
      else:
        (target, none(string))

    let splitRepoTarget = noDestinationTarget.split('/', 2)
    let (repo, nameConstraint) = if splitRepoTarget.len == 2:
        (some(splitRepoTarget[0]), splitRepoTarget[1])
      else:
        (none(string), noDestinationTarget)

    let reference = parsePackageReference(nameConstraint, false)
    (reference, repo, destination)))

proc isAurTargetSync*(sync: SyncPackageTarget, aurRepo: string): bool =
  sync.foundInfos.len == 0 and (sync.target.repo.isNone or sync.target.repo == some(aurRepo))

proc isAurTargetFull*(full: FullPackageTarget, aurRepo: string): bool =
  full.sync.foundInfos.len > 0 and full.sync.foundInfos[0].repo == aurRepo

proc filterNotFoundSyncTargets*(syncTargets: seq[SyncPackageTarget],
  rpcInfos: seq[RpcPackageInfo], upToDateNeededTable: Table[string, PackageReference],
  aurRepo: string): seq[SyncPackageTarget] =
  let pkgInfoReferencesTable = rpcInfos.map(i => (i.name, i.toPackageReference)).toTable
  syncTargets.filter(s => not (upToDateNeededTable.opt(s.target.reference.name)
    .map(r => s.target.reference.isProvidedBy(r, true)).get(false)) and s.foundInfos.len == 0 and
    not (s.isAurTargetSync(aurRepo) and pkgInfoReferencesTable.opt(s.target.reference.name)
    .map(r => s.target.reference.isProvidedBy(r, true)).get(false)))

proc printSyncNotFound*(config: Config, notFoundTargets: seq[SyncPackageTarget]) =
  let dbs = config.common.dbs.toHashSet

  for sync in notFoundTargets:
    if sync.target.repo.isNone or sync.target.repo == some(config.aurRepo) or
      sync.target.repo.unsafeGet in dbs:
      printError(config.color, trp("target not found: %s\n") % [$sync.target.reference])
    else:
      printError(config.color, trp("database not found: %s\n") % [sync.target.repo.unsafeGet])

proc findSyncTargets*(handle: ptr AlpmHandle, dbs: seq[ptr AlpmDatabase],
  targets: seq[PackageTarget], aurRepo: string, allowGroups: bool, checkProvides: bool, checkVersion: bool):
  (seq[SyncPackageTarget], seq[string]) =
  let dbTable = dbs.map(d => ($d.name, d)).toTable

  proc checkProvided(reference: PackageReference, db: ptr AlpmDatabase): bool =
    for pkg in db.packages:
      for provides in pkg.provides:
        if reference.isProvidedBy(provides.toPackageReference, true):
          return true
    return false

  proc findSync(target: PackageTarget): seq[SyncFoundInfo] =
    if target.repo.isSome:
      let repo = target.repo.unsafeGet

      if dbTable.hasKey(repo):
        let db = dbTable[repo]
        let pkg = db[cstring(target.reference.name)]

        if pkg != nil and target.reference.isProvidedBy(pkg.toPackageReference, true):
          let base = if pkg.base == nil: target.reference.name else: $pkg.base
          return @[(repo, some((base, $pkg.version, some($pkg.arch))))]
        elif checkProvides and target.reference.checkProvided(db):
          return @[(repo, none(SyncFoundPackageInfo))]
        else:
          return @[]
      else:
        return @[]
    else:
      if allowGroups and target.reference.constraint.isNone:
        let groupRepo = optFirst:
          collect(newSeq):
            for d in dbs:
              for g in d.groups:
                if $g.name == target.reference.name:
                  d
        if groupRepo.isSome:
          return @[($groupRepo.unsafeGet.name, none(SyncFoundPackageInfo))]

      let directResults = dbs
        .map(db => (block:
          let pkg = db[cstring(target.reference.name)]
          var checkVer: bool = checkVersion
          if target.reference.constraint.isSome: # skip version check if specified on cmdline
            if target.reference.constraint.unsafeget.operation == ConstraintOperation.eq:
              checkVer = false
          if pkg != nil and target.reference.isProvidedBy(pkg.toPackageReference, checkVer):
            let base = if pkg.base == nil: target.reference.name else: $pkg.base
            var returnVersion: string = $pkg.version
            if target.reference.constraint.isSome: # use version from cmdline if given
              if target.reference.constraint.unsafeget.operation == ConstraintOperation.eq:
                returnVersion = target.reference.constraint.unsafeget.version
            some(($db.name, some((base, returnVersion, some($pkg.arch)))))
          else:
            none(SyncFoundInfo)))
        .filter(i => i.isSome)
        .map(i => i.unsafeGet)

      if directResults.len > 0:
        return directResults
      elif checkProvides:
        for db in dbs:
          if target.reference.checkProvided(db):
            return @[($db.name, none(SyncFoundPackageInfo))]
        return @[]
      else:
        return @[]

  let syncTargets: seq[SyncPackageTarget] = targets.map(t => (t, findSync(t)))
  let checkAurNames = syncTargets
    .filter(s => s.isAurTargetSync(aurRepo))
    .map(s => s.target.reference.name)
  (syncTargets, checkAurNames)

proc mapAurTargets*(targets: seq[SyncPackageTarget], rpcInfos: seq[RpcPackageInfo],
  aurRepo: string): seq[FullPackageTarget] =
  let aurTable = rpcInfos.map(i => (i.name, i)).toTable

  targets.map(proc (sync: SyncPackageTarget): FullPackageTarget =
    let res = if sync.foundInfos.len == 0 and aurTable.hasKey(sync.target.reference.name): (block:
        let rpcInfo = aurTable[sync.target.reference.name]
        if sync.target.reference.isProvidedBy(rpcInfo.toPackageReference, true):
          some(((aurRepo, some((rpcInfo.base, rpcInfo.version, none(string)))), rpcInfo))
        else:
          none((SyncFoundInfo, RpcPackageInfo)))
      else:
        none((SyncFoundInfo, RpcPackageInfo))

    if res.isSome:
      let (syncInfo, rpcInfo) = res.get
      ((sync.target, @[syncInfo]), some(rpcInfo))
    else:
      (sync, none(RpcPackageInfo)))

proc queryUnrequired*(handle: ptr AlpmHandle, withOptional: bool, withoutOptional: bool,
  assumeExplicit: HashSet[string]): (seq[PackageReference], HashSet[string], HashSet[string],
  Table[string, HashSet[PackageReference]]) =
  let (installed, explicit, dependsTable, alternatives) = block:
    var installed = newSeq[PackageReference]()
    var explicit = newSeq[string]()
    var dependsTable = initTable[string,
      HashSet[tuple[reference: PackageReference, optional: bool]]]()
    var alternatives = initTable[string, HashSet[PackageReference]]()

    for pkg in handle.local.packages:
      proc fixProvides(reference: PackageReference): PackageReference =
        if reference.constraint.isNone:
          (reference.name, reference.description,
            some((ConstraintOperation.eq, $pkg.version, true)))
        else:
          reference

      let depends = toSeq(pkg.depends.items)
        .map(d => d.toPackageReference).toHashSet
      let optional = toSeq(pkg.optional.items)
        .map(d => d.toPackageReference).toHashSet
      let provides = toSeq(pkg.provides.items)
        .map(d => d.toPackageReference).map(fixProvides).toHashSet

      installed.add(pkg.toPackageReference)
      if pkg.reason == AlpmReason.explicit:
        explicit &= $pkg.name
      dependsTable[$pkg.name]=
        depends.map(x => (x, false)) + optional.map(x => (x, true))
      if provides.len > 0:
        alternatives[$pkg.name]= provides

    (installed, explicit.toHashSet + assumeExplicit, dependsTable, alternatives)

  let providedBy = collect(newSeq):
    for x in alternatives.namedPairs:
      for y in x.value:
        (reference:y,name:x.key)

  proc findRequired(withOptional: bool, results: HashSet[string],
    check: HashSet[string]): HashSet[string] =
    let full = results + check

    when NimVersion >= "1.3.5":
      let direct = collect(newSeq):
        for y in dependsTable.namedPairs:
          if y.key in check:
            for x in y.value:
              if withOptional or not x.optional:
                x.reference
      let indirect = collect(initHashSet):
        for y in direct:
          for x in providedBy:
            if y.isProvidedBy(x.reference, true):
              {x.name}
    else:
      let direct = block:
        var tmp = newSeq[PackageReference]()
        for y in dependsTable.namedPairs:
          if y.key in check:
            for x in y.value:
              if withOptional or not x.optional:
                tmp.add(x.reference)
        tmp
      let indirect = block:
        var tmp = initHashSet[string]()
        for y in direct:
          for x in providedBy:
            if y.isProvidedBy(x.reference, true):
              tmp.incl(x.name)
        tmp

    let checkNext = (direct.map(p => p.name).toHashSet + indirect) - full
    if checkNext.len > 0: findRequired(withOptional, full, checkNext) else: full

  let installedNames = installed.map(i => i.name).toHashSet

  proc findOrphans(withOptional: bool): HashSet[string] =
    let required = findRequired(withOptional, initHashSet[string](), explicit)
    installedNames - required

  let withOptionalSet = if withOptional: findOrphans(true) else: initHashSet[string]()
  let withoutOptionalSet = if withoutOptional: findOrphans(false) else: initHashSet[string]()

  (installed, withOptionalSet, withoutOptionalSet, alternatives)

proc `$`*(target: PackageTarget): string =
  target.repo.map(proc (r: string): string = r & "/" & $target.reference).get($target.reference)

template tmpRoot(config: Config, dropPrivileges: bool): string =
  if dropPrivileges: config.tmpRootInitial else: config.tmpRootCurrent

template userCache(config: Config, dropPrivileges: bool): string =
  if dropPrivileges: config.userCacheInitial else: config.userCacheCurrent

template cache*(userCache: string, cacheKind: CacheKind): string =
  userCache & "/" & $cacheKind

proc createDirRecursive(dir: string, chownUser: Option[User]): bool =
  let segments = dir.split("/").filter(x => not (x.len == 0 or x == "."))

  proc createDirIndex(index: int): bool =
    if index < segments.len:
      let path = (if dir.len > 0 and dir[0] == '/': "/" else: "") &
        segments[0 .. index].join("/")
      try:
        let exists = path.existsOrCreateDir()
        if chownUser.isSome and (not exists or index == segments.len - 1):
          discard chown(cstring(path), (Uid) chownUser.unsafeGet.uid, (Gid) chownUser.unsafeGet.gid)
        createDirIndex(index + 1)
      except:
        false
    else:
      true

  createDirIndex(0)

proc ensureDirOrError(dir: string, dropPrivileges: bool): Option[string] =
  let user = if dropPrivileges: some(initialUser.get(currentUser)) else: none(User)

  if not createDirRecursive(dir, user):
    some(tr"failed to create directory '$#'" % [dir])
  else:
    none(string)

proc ensureTmpOrError*(config: Config, dropPrivileges: bool): Option[string] =
  ensureDirOrError(config.tmpRoot(dropPrivileges), dropPrivileges)

proc ensureUserCacheOrError*(config: Config, cacheKind: CacheKind,
  dropPrivileges: bool): Option[string] =
  ensureDirOrError(config.userCache(dropPrivileges).cache(cacheKind), dropPrivileges)

proc getGitFiles*(repoPath: string, gitSubdir: Option[string],
  dropPrivileges: bool, trunkPath: bool): seq[string] =
  if trunkPath == true:
    let trunkpath = repoPath & "/trunk"
    toSeq(walkDir(trunkPath)).mapIt(it.path.extractFilename)
  else:
    if gitSubdir.isSome:
      forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(gitCmd, "-C", repoPath, "ls-tree", "-r", "--name-only", "@",
            gitSubdir.unsafeGet & "/")
        else:
          quit(1)))
        .output
        .map(s => s[gitSubdir.unsafeGet.len + 1 .. ^1])
    else:
      forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(gitCmd, "-C", repoPath, "ls-tree", "-r", "--name-only", "@")
        else:
          quit(1)))
        .output


proc bisectVersion(repoPath: string, debug: bool, firstCommit: Option[string],
  compareMethod: string, gitSubdir: string, version: string,
  dropPrivileges: bool): Option[string] =
  template forkExecWithoutOutput(args: varargs[string]): int =
    forkWait(() => (block:
      discard close(0)
      if not debug:
        discard close(1)
        discard close(2)

      if not dropPrivileges or dropPrivileges():
        execResult(args)
      else:
        quit(1)))

  let (workFirstCommit, checkFirst) = if firstCommit.isSome:
      (firstCommit, false)
    else:
      (forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(gitCmd, "-C", repoPath,
            "rev-list", "--max-parents=0", "@")
        else:
          quit(1)))
        .output.optLast, true)

  let (realLastThreeCommits, _) = forkWaitRedirect(() => (block:
    if not dropPrivileges or dropPrivRedirect():
      execRedirect(gitCmd, "-C", repoPath,
        "rev-list", "--max-count=3", "@")
    else:
      quit(1)))

  let index = workFirstCommit.map(c => realLastThreeCommits.find(c)).get(-1)
  let lastThreeCommits = if index >= 0:
      realLastThreeCommits[0 .. index]
    else:
      realLastThreeCommits

  proc checkCommit(commit: string): Option[string] =
    let checkout1Code = forkExecWithoutOutput(gitCmd, "-C", repoPath,
      "checkout", commit)

    if checkout1Code != 0:
      none(string)
    else:
      let foundVersion = forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(pkgLibDir & "/bisect",
            compareMethod, repoPath & "/" & gitSubdir, version)
        else:
          quit(1)))
        .output.optFirst

      let checkout2Code = forkExecWithoutOutput(gitCmd, "-C", repoPath,
        "checkout", lastThreeCommits[0])

      if checkout2Code != 0:
        none(string)
      elif foundVersion == some(version):
        some(commit)
      else:
        none(string)

  if lastThreeCommits.len == 0:
    none(string)
  elif lastThreeCommits.len == 1:
    if checkFirst:
      checkCommit(lastThreeCommits[0])
    else:
      none(string)
  elif lastThreeCommits.len == 2:
    let checkedCommit = checkCommit(lastThreeCommits[0])
    if checkedCommit.isSome:
      checkedCommit
    elif checkFirst:
      checkCommit(lastThreeCommits[1])
    else:
      none(string)
  else:
    # find the commit with specific package version using git bisect
    let bisectStartCode = forkExecWithoutOutput(gitCmd, "-C", repoPath,
      "bisect", "start", "@", workFirstCommit.get(""))

    if bisectStartCode != 0:
      none(string)
    else:
      discard forkExecWithoutOutput(gitCmd, "-C", repoPath,
        "bisect", "run", pkgLibDir & "/bisect", compareMethod, gitSubdir, version)

      let commit = forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(gitCmd, "-C", repoPath,
            "rev-list", "--max-count=1", "refs/bisect/bad")
        else:
          quit(1)))
        .output.optFirst

      discard forkExecWithoutOutput(gitCmd, "-C", repoPath,
        "bisect", "reset")

      if commit.isSome:
        let checkedCommit = commit.map(checkCommit).flatten
        if checkedCommit.isSome:
          checkedCommit
        else:
          # non-incremental git history (e.g. downgrade without epoch change), bisect again
          bisectVersion(repoPath, debug, commit, compareMethod, gitSubdir,
            version, dropPrivileges)
      elif checkFirst and workFirstCommit.isSome:
        checkCommit(workFirstCommit.unsafeGet)
      else:
        none(string)

proc obtainSrcInfo*(path: string): string =
  let (output, code) = forkWaitRedirect(() => (block:
    if dropPrivRedirect() and chdir(path) == 0:
      execRedirect(makePkgCmd, "--printsrcinfo")
    else:
      quit(1)))

  if code == 0:
    output.foldl(a & b & "\n", "")
  else:
    ""

proc reloadPkgInfos*(config: Config, path: string, pkgInfos: seq[PackageInfo]): seq[PackageInfo] =
  let srcInfo = obtainSrcInfo(path)
  let res = parseSrcInfo(pkgInfos[0].rpc.repo, srcInfo, config.common.arch,
    pkgInfos[0].rpc.gitUrl, pkgInfos[0].rpc.gitSubdir)
  if res.len > 0:
    res
  else:
    pkgInfos

template bareFullName*(bareKind: BareKind, bareName: string): string =
  $bareKind & "-" & bareName & ".git"

proc bareFullNameDeconstruct*(bareKind: BareKind, bareFullName: string): Option[string] =
  if bareFullName.find($bareKind & '-') == 0 and bareFullName.rfind(".git") == bareFullName.len - 4:
    some(bareFullName[($bareKind).len + 1 .. ^5])
  else:
    none(string)

proc cloneBareRepo(config: Config, bareKind: BareKind, bareName: string,
  url: string, branchOption: Option[string], dropPrivileges: bool): Option[string] =
  let fullName = bareFullName(bareKind, bareName)
  let cachePath = config.userCache(dropPrivileges).cache(CacheKind.repositories)
  let repoPath = repoPath(cachePath, fullName)

  if forkWait(() => (block:
    if not dropPrivileges or dropPrivileges():
      if dirExists(repoPath):
        let branch = branchOption.get("master")
        execResult(gitCmd, "-C", repoPath, "fetch", "-q", "--no-tags",
          "origin", branch & ":" & branch)
      else:
        execResult(gitCmd, "-C", cachePath, "clone", "-q", "--bare", "--no-tags",
          url, fullName)
    else:
      quit(1))) == 0:
    some(repoPath)
  else:
    none(string)

proc cloneBareRepos*(config: Config, bareKind: BareKind, gitRepos: seq[GitRepo],
  progressCallback: (int, int) -> void, dropPrivileges: bool): (int, seq[string]) =
  let message = ensureUserCacheOrError(config, CacheKind.repositories, dropPrivileges)
  if message.isSome:
    (0, @[message.unsafeGet])
  else:
    let bare = gitRepos
      .filter(t => t.bareName.isSome)
      .map(r => (r.bareName.unsafeGet, r.url, r.branch))
      .deduplicate

    proc cloneNext(index: int, messages: List[string]): seq[string] =
      progressCallback(index, bare.len)

      if index >= bare.len:
        toSeq(messages.reversed.items)
      else:
        let (bareName, url, branch) = bare[index]
        let repoPath = cloneBareRepo(config, bareKind, bareName, url, branch, dropPrivileges)
        if repoPath.isSome:
          cloneNext(index + 1, messages)
        else:
          let message = tr"$#: failed to clone git repository" % [bareName]
          cloneNext(index + 1, message ^& messages)

    (bare.len, cloneNext(0, nil))

proc findVersion(repoPath: string, debug: bool, version: string,
  dropPrivileges: bool): Option[string] =

  template forkExecWithoutOutput(args: varargs[string]): int =
    forkWait(() => (block:
      discard close(0)
      if not debug:
        discard close(1)
        discard close(2)
      if not dropPrivileges or dropPrivileges():
        execResult(args)
      else:
        quit(1)))

# find commit containing correct version using git log grep on commit messages

  var commandOutput: tuple[output: seq[string], code: int]
  commandOutput = forkWaitRedirect(() => (block:
    if not dropPrivileges or dropPrivRedirect():
      execRedirect(gitCmd, "-C", repoPath, "log", "--fixed-strings", "--no-abbrev-commit", "--format=format:%H", "--grep", version)
    else:
      quit(1)))

  for i in countdown(commandOutput.output.len - 1, 0):
    if forkExecWithoutOutput(gitCmd, "-C", repoPath, "checkout", commandOutput.output[i]) == 0:
      let foundVersion = forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(pkgLibDir & "/bisect", "source", repoPath & "/trunk", version, "true")
        else:
          quit(1)))
      if foundVersion.code == 1:
        return commandOutput.output[i].option

# find commit containing correct version by bisecting

  var allRevisions: tuple[output: seq[string], code: int]
  allRevisions = forkWaitRedirect(() => (block:
    if not dropPrivileges or dropPrivRedirect():
      execRedirect(gitCmd, "-C", repoPath, "log", "--fixed-strings", "--no-abbrev-commit", "--format=format:%H")
    else:
      quit(1)))
  var commits: tuple[untested: seq[string], tested: seq[string], leftovers: seq[string]]
  commits.untested = allRevisions.output

  while commits.untested.len > 0:
    var middle: int = (int)commits.untested.len / 2
    if forkExecWithoutOutput(gitCmd, "-C", repoPath, "checkout", commits.untested[middle]) == 0:
      let foundVersion = forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(pkgLibDir & "/bisect", "source", repoPath & "/trunk", version, "true")
        else:
          quit(1)))

      case foundVersion.code
      of 1:
        return commits.untested[middle].option
      of 2:
        when NimVersion >= "1.6.0": # temporary version fix, delete in future
          commits.untested.delete(middle..(commits.untested.len - 1))
        else:
          commits.untested.delete(middle, (commits.untested.len - 1))
      of 0:
        when NimVersion >= "1.6.0":
          commits.untested.delete(0..middle)
        else:
          commits.untested.delete(0, middle)
      else: # allow for other errors like missing file or version
        commits.untested.delete(middle)

# find commit containing correct version by trying every commit not yet tested

  for i in countdown(allRevisions.output.len - 1, 0):
    for j in (0..commits.tested.len - 1):
      if allRevisions.output[i] == commits.tested[j]:
        allRevisions.output.delete(i)
        break

  for i in (0 .. allRevisions.output.len - 1):
    if forkExecWithoutOutput(gitCmd, "-C", repoPath, "checkout", allRevisions.output[i]) == 0:
      let foundVersion = forkWaitRedirect(() => (block:
        if not dropPrivileges or dropPrivRedirect():
          execRedirect(pkgLibDir & "/bisect", "source", repoPath & "/trunk", version, "true")
        else:
          quit(1)))
      if foundVersion.code == 1:
        return allRevisions.output[i].option

  none(string)

proc clonePackageRepoInternal(config: Config, base: string, version: string,
  git: GitRepo, dropPrivileges: bool): Option[string] =
  let repoPath = repoPath(config.tmpRoot(dropPrivileges), base)
  removeDirQuiet(repoPath)

  let url = if git.bareName.isSome:
      repoPath(config.userCache(dropPrivileges).cache(CacheKind.repositories),
        bareFullName(BareKind.repo, git.bareName.unsafeGet))
    else:
      git.url
  if forkWait(() => (block:
    if not dropPrivileges or dropPrivileges():
      if git.branch.isSome:
        if git.url == "https://gitea.artixlinux.org/packages":
          var artixUrl: string = git.url
          artixUrl.add(capitalizeAscii($(base[0])) & "/" & $(base) & ".git")
          execResult(gitCmd, "-C", config.tmpRoot(dropPrivileges), "clone", "-q", artixUrl)
        else:
          execResult(gitCmd, "-C", config.tmpRoot(dropPrivileges),
            "clone", "-q", url, "-b", git.branch.unsafeGet, "--single-branch", base)
      else:
        execResult(gitCmd, "-C", config.tmpRoot(dropPrivileges),
          "clone", "-q", url, "--single-branch", base)
    else:
      quit(1))) == 0:
    var commit: Option[string]
    if git.branch.isNone: # parabola
      commit = bisectVersion(repoPath, config.common.debug, none(string),
        "source", git.path, version, dropPrivileges)
    else:
      commit = findVersion(repoPath, config.common.debug, version, dropPrivileges)
      if commit.isSome:
        return some(repoPath)
      else:
        removeDirQuiet(repoPath)
        return none(string)
    if commit.isNone:
      removeDirQuiet(repoPath)
      none(string)
    else:
      discard forkWait(() => (block:
        if not dropPrivileges or dropPrivileges():
          execResult(gitCmd, "-C", repoPath,
            "checkout", "-q", commit.unsafeGet)
        else:
          quit(1)))
      some(repoPath)
  else:
    removeDirQuiet(repoPath)
    none(string)

proc clonePackageRepo*(config: Config, base: string, version: string,
  git: GitRepo, dropPrivileges: bool): Option[string] =
  let message = ensureTmpOrError(config, dropPrivileges)
  if message.isSome:
    message
  else:
    let repoPath = clonePackageRepoInternal(config, base, version, git, dropPrivileges)
    if repoPath.isNone:
      some(tr"$#: failed to clone git repository" % [base])
    else:
      none(string)

proc obtainBuildPkgInfosInternal(config: Config, bases: seq[LookupBaseGroup],
  pacmanTargetNames: seq[string], progressCallback: (int, int) -> void, dropPrivileges: bool):
  (seq[PackageInfo], seq[string], seq[string]) =
  let lookupResults: seq[tuple[group: LookupBaseGroup, git: Option[GitRepo]]] = bases
    .map(b => (b, lookupGitRepo(b.repo, b.base, b.arch)))
  let notFoundRepos = lookupResults.filter(r => r.git.isNone)

  if notFoundRepos.len > 0:
    let messages = notFoundRepos.map(r => tr"$#: repository not found" % [r.group.base])
    (newSeq[PackageInfo](), newSeq[string](), messages)
  else:
    let message = ensureTmpOrError(config, dropPrivileges)
    if message.isSome:
      (@[], @[], @[message.unsafeGet])
    else:
      let (bcount, berrors) = cloneBareRepos(config, BareKind.repo,
        lookupResults.map(r => r.git.unsafeGet),
        proc (progress: int, count: int) = progressCallback(progress, count + lookupResults.len),
        dropPrivileges)

      if berrors.len > 0:
        discard rmdir(cstring(config.tmpRoot(dropPrivileges)))
        (newSeq[PackageInfo](), newSeq[string](), berrors)
      else:
        proc findCommitAndGetSrcInfo(base: string, version: string,
          repo: string, git: GitRepo): tuple[pkgInfos: seq[PackageInfo], path: Option[string]] =
          let repoPath = clonePackageRepoInternal(config, base, version, git, dropPrivileges)

          if repoPath.isSome:
            var srcInfo: string
            if contains(git.url, "https://github.com/archlinux/") or git.url == "https://gitea.artixlinux.org/packages":
              srcInfo = obtainSrcInfo(repoPath.unsafeGet & "/trunk/")
            else:
              srcInfo = obtainSrcInfo(repoPath.unsafeGet & "/" & git.path)
            let pkgInfos = parseSrcInfo(repo, srcInfo, config.common.arch,
              git.url, some(git.path))
              .filter(i => i.rpc.version == version)
            (pkgInfos, repoPath)
          else:
            (newSeq[PackageInfo](), none(string))

        let (pkgInfosWithPathsReversed, _) = lookupResults.foldl(block:
          let (list, index) = a
          let res = findCommitAndGetSrcInfo(b.group.base, b.group.version,
            b.group.repo, b.git.unsafeGet) ^& list
          progressCallback(bcount + index + 1, bcount + lookupResults.len)
          (res, index + 1),
          (list[tuple[pkgInfos: seq[PackageInfo], path: Option[string]]](), 0))

        let pkgInfosWithPaths = pkgInfosWithPathsReversed.reversed
        let pkgInfos = collect(newSeq):
          for y in pkgInfosWithPaths:
            for x in y.pkgInfos:
              x
        let paths = collect(newSeq):
          for y in pkgInfosWithPaths:
            for x in y.path:
              x

        let pkgInfosTable = pkgInfos.map(i => (i.rpc.name, i)).toTable
        
        let foundPkgInfos = collect(newSeq):
          for y in pacmanTargetNames:
            for x in pkgInfosTable.opt(y):
              x
        let errorMessages = pacmanTargetNames
          .filter(n => not pkgInfosTable.hasKey(n))
          .map(n => tr"$#: failed to get package info" % [n])

        if errorMessages.len > 0:
          for path in paths:
            removeDirQuiet(path)
        discard rmdir(cstring(config.tmpRoot(dropPrivileges)))
        (foundPkgInfos, paths, errorMessages)

proc obtainBuildPkgInfos*(config: Config, pacmanTargets: seq[FullPackageTarget],
  progressCallback: (int, int) -> void, dropPrivileges: bool):
  (seq[PackageInfo], seq[string], seq[string]) =
  let bases = pacmanTargets
    .map(proc (full: FullPackageTarget): LookupBaseGroup =
      let info = full.sync.foundInfos[0]
      let pkg = info.pkg.get
      (pkg.base, pkg.version, pkg.arch.get, info.repo))
    .deduplicate

  let pacmanTargetNames = pacmanTargets.map(f => f.sync.target.reference.name)
  obtainBuildPkgInfosInternal(config, bases, pacmanTargetNames, progressCallback, dropPrivileges)

proc cloneAurRepo*(config: Config, base: string, gitUrl: string,
  dropPrivileges: bool): (int, Option[string]) =
  let repoPath = repoPath(config.tmpRoot(dropPrivileges), base)

  let message = block:
    let message = ensureUserCacheOrError(config, CacheKind.repositories, dropPrivileges)
    if message.isNone:
      ensureTmpOrError(config, dropPrivileges)
    else:
      message

  if message.isSome:
    (1, message)
  elif repoPath.dirExists():
    (0, none(string))
  else:
    let fullName = bareFullName(BareKind.pkg, base)
    let cachePath = config.userCache(dropPrivileges).cache(CacheKind.repositories)
    let bareRepoPath = repoPath(cachePath, fullName)

    let cloneBareCode = forkWait(() => (block:
      if not dropPrivileges or dropPrivileges():
        if dirExists(bareRepoPath):
          execResult(gitCmd, "-C", bareRepoPath, "fetch", "-q", "--no-tags",
            "origin", "master:master")
        else:
          execResult(gitCmd, "-C", cachePath, "clone", "-q", "--bare", "--no-tags",
            gitUrl, "--single-branch", fullName)
      else:
        quit(1)))

    let cloneCode = if cloneBareCode == 0:
        forkWait(() => (block:
          if not dropPrivileges or dropPrivileges():
            execResult(gitCmd, "-C", config.tmpRoot(dropPrivileges),
              "clone", "-q", bareRepoPath, "--single-branch", base)
          else:
            quit(1)))
      else:
        cloneBareCode

    if cloneCode != 0:
      (cloneCode, some(tr"$#: failed to clone git repository" % [base]))
    else:
      (0, none(string))

proc cloneAurReposWithPackageInfos*(config: Config, rpcInfos: seq[RpcPackageInfo],
  keepRepos: bool, progressCallback: (int, int) -> void, dropPrivileges: bool):
  (seq[PackageInfo], seq[PackageInfo], seq[string], seq[string]) =
  let bases: seq[tuple[base: string, gitUrl: string]] = rpcInfos
    .map(i => (i.base, i.gitUrl)).deduplicate

  progressCallback(0, bases.len)

  proc cloneNext(index: int, pkgInfos: List[PackageInfo], paths: List[string],
    errors: List[string]): (seq[PackageInfo], seq[string], seq[string]) =
    if index >= bases.len:
      (toSeq(pkgInfos.items), toSeq(paths.items), toSeq(errors.items))
    else:
      let repoPath = repoPath(config.tmpRoot(dropPrivileges), bases[index].base)
      removeDirQuiet(repoPath)

      let (cloneCode, cloneErrorMessage) = cloneAurRepo(config,
        bases[index].base, bases[index].gitUrl, dropPrivileges)

      progressCallback(index + 1, bases.len)

      if cloneCode != 0:
        removeDirQuiet(repoPath)
        cloneNext(index + 1, pkgInfos, paths, cloneErrorMessage.map(m => m ^& errors).get(errors))
      else:
        let srcInfos = try:
          readFile(repoPath & "/.SRCINFO")
        except:
          ""

        let addPkgInfos = parseSrcInfo(config.aurRepo, srcInfos, config.common.arch,
          bases[index].gitUrl, none(string), rpcInfos)
        if keepRepos:
          cloneNext(index + 1, addPkgInfos ^& pkgInfos, repoPath ^& paths, errors)
        else:
          removeDirQuiet(repoPath)
          cloneNext(index + 1, addPkgInfos ^& pkgInfos, paths, errors)

  let (fullPkgInfos, paths, errors) = cloneNext(0, nil, nil, nil)
  let pkgInfosTable = fullPkgInfos.map(i => (i.rpc.name, i)).toTable
  let resultPkgInfos = collect(newSeq):
    for y in rpcInfos:
      for x in pkgInfosTable.opt(y.name):
        x

  let names = rpcInfos.map(i => i.name).toHashSet
  let additionalPkgInfos = fullPkgInfos.filter(i => not (i.rpc.name in names))

  discard rmdir(cstring(config.tmpRoot(dropPrivileges)))
  (resultPkgInfos, additionalPkgInfos, paths, errors)
