import
  std/[algorithm, options, os, posix, sequtils, sets, strutils, sugar, tables],
  ".."/[args, aur, config, common, format, package, pacman, utils],
  "../wrapper/alpm"
when not declared(system.stdout): import std/syncio

const
  PkgExtGlob = ".pkg.tar.*"

type
  Installed = object
    name: string
    version: string
    groups: seq[string]
    explicit: bool
    foreign: bool

  SatisfyResult = object
    installed: bool
    name: string
    buildPkgInfo: Option[PackageInfo]

  LocalIsNewer = object
    name: string
    version: string
    aurVersion: string

  ReplacePkgInfo = object
    name: Option[string]
    pkgInfo: PackageInfo

  BuildArtifact = object
    name: Option[string]
    pkgInfo: PackageInfo
    file: string

  BuildResult = object
    artifacts: seq[BuildArtifact]

  InstallTarget = object
    ## A package-to-archive mapping selected for installation.
    name: string
    file: string

  InstallItem = object
    ## Packages to install via the positional subprocess protocol.
    ## Field order must stay in sync with the install helper.
    name: string
    file: string
    mode: string

  BuildBasesRes = object
    results: seq[BuildResult]
    skipped: int
    code: int

  InstallArtifacts = object
    artifacts: seq[BuildArtifact] ## all built archives including split-package siblings
    install: seq[InstallTarget]
    installFiles: HashSet[string] ## file paths of install targets; precomputed for O(1) cleanup lookup
    builtBases: HashSet[string]
    renames: CanonicalRenames

  CanonicalRenames = Table[string, string]
    ## Maps artifact names to canonical AUR names for split packages.
    ## Only populated for actual renames (artifact.name != rpc.name).

  InstallGroupRes = object
    canonicalRenames: CanonicalRenames
    code: int

  CleanupSpec = object
    ## Post-install cleanup settings. Computed once from
    ## CleanupPolicy + context so callers don't re-derive it independently.
    removeWorktrees: bool ## remove per-base git clone dirs under tmpRoot
    removeArchives: bool ## remove built `PkgExtGlob` files
    nukeTmpPrefix: bool ## use removeTmpDirQuiet (chases firstCreatedTmpDir) vs removeDirQuiet

  Upgrade = object
    rpcInfo: RpcPackageInfo
    needed: bool

  InstallMode {.pure.} = enum
    ## Passed verbatim to the install helper subprocess.
    ## Values must stay in sync with install.nim.
    auto = "auto",
    explicit = "explicit",
    dependency = "dependency"

  ExecMode = enum
    emNormal
    emSilent
    emRedirect

  AurFetchRes = object ## Result of fetching AUR package infos
    ## (clone or RPC-only depending on printMode).
    pkgInfos: seq[PackageInfo]
    additionalPkgInfos: seq[PackageInfo]
    paths: seq[string]
    errors: seq[string]

  AurPackageInfosRes = object ## Result of `obtainAurPackageInfos`_
    pkgInfos: seq[PackageInfo]
    additionalPkgInfos: seq[PackageInfo]
    paths: seq[string]
    upToDateNeeded: seq[Installed]
    localIsNewerSeq: seq[LocalIsNewer]
    errors: seq[string]

  BuildTargetsRes = object ## Result of `resolveBuildTargets`_
    code: int
    installed: seq[Installed]
    targetNamesSet: HashSet[string]
    pkgInfos: seq[PackageInfo]
    additionalPkgInfos: seq[PackageInfo]
    paths: seq[string]

  PacmanBuildTargetsRes = object ## Result of `obtainPacmanBuildTargets`_
    checked: bool
    pkgInfos: seq[PackageInfo]
    upToDateNeeded: seq[(string, string)]
    paths: seq[string]
    errors: seq[string]

  PackageInfoGroup = object
    pkgInfos: seq[PackageInfo]
    names: HashSet[string]

  ResolvedReference = object
    reference: PackageReference
    result: SatisfyResult

  IsContainer = concept
    proc len(x: Self): int

template requireNonEmpty(container: IsContainer; routine: static string) =
  assert container.len > 0, routine & " requires a non-empty sequence"

func toSeq(pkgGroups: ptr AlpmList[cstring]): seq[string] =
  for s in items(pkgGroups):
    result.add $s

proc createCloneProgress(config: Config, count: int, flexible: bool, printMode: bool):
  (proc (update: int, terminate: int) {.closure.}, proc() {.closure.}) =
  if count >= 1 and not printMode:
    let (update, terminate) = printProgressShare(config.common.progressBar,
      config.common.chomp, tr"cloning repositories")
    update(0, count)

    if flexible:
      proc cloneUpdate(progress: int; newCount: int) {.closure.} =
        # newCount can be < count if some packages were not found
        update(max(count - newCount + progress, 0), count)
      (cloneUpdate, terminate)
    else:
      (update, terminate)
  else:
    (proc (a: int, b: int) {.closure.} = discard, proc {.closure.} = discard)

## Runs body inside a clone-progress display, always calling terminate()
## even if body raises. The injected `updateIdent` name is the progress callback.
## At call sites that need a return value, use `result =` inside the body.
template withCloneProgress(config: Config; count: int; flexible, printMode: bool;
    updateIdent, body: untyped): untyped =
  let (updateIdent {.inject.}, cloneTerminate) =
    createCloneProgress(config, count, flexible, printMode)
  try:
    body
  finally:
    cloneTerminate()

func isVcs(name: string): bool =
  let index = name.rfind('-')
  index >= 0 and (let suffix = name[index + 1 .. ^1];
    suffix == "bzr" or suffix == "git" or suffix == "hg" or suffix == "svn")

func checkSatisfied(handle: ptr AlpmHandle; nodepsCount: int;
    reference: PackageReference): bool =
  for pkg in handle.local.packages:
    if reference.isProvidedBy(pkg.toPackageReference, nodepsCount == 0):
      return true
    for provides in pkg.provides:
      if reference.isProvidedBy(provides.toPackageReference, nodepsCount == 0):
        return true
  false

func initPackageInfoGroup(pkgInfos: seq[PackageInfo]): PackageInfoGroup =
  result.pkgInfos = pkgInfos
  for pkgInfo in pkgInfos:
    result.names.incl pkgInfo.rpc.name

func hasBuildDependency(satisfied: Table[PackageReference, SatisfyResult];
    orderedNames, groupNames: HashSet[string]; pkgInfos: seq[PackageInfo]): bool =
  for pkgInfo in pkgInfos:
    for reference in pkgInfo.allDepends:
      for satres in satisfied.opt(reference):
        if satres.buildPkgInfo.isSome and
          satres.buildPkgInfo.unsafeGet.rpc.name notin groupNames and
          satres.buildPkgInfo.unsafeGet.rpc.name notin orderedNames:
          return true
  false

proc orderInstallation(pkgInfos: seq[PackageInfo];
    satisfied: Table[PackageReference, SatisfyResult]): seq[seq[seq[PackageInfo]]] =
  ## Builds dependency layers by package base. Each pass emits bases whose
  ## build-time dependencies are already emitted or live in the same base.
  var remaining = pkgInfos.groupBy(i => i.rpc.base).mapIt(it.values.initPackageInfoGroup)
  var orderedNames = initHashSet[string]()

  while remaining.len > 0:
    var layer: seq[seq[PackageInfo]]
    var next: seq[PackageInfoGroup]

    for group in remaining:
      if hasBuildDependency(satisfied, orderedNames, group.names, group.pkgInfos):
        next.add group
      elif group.pkgInfos.len > 0:
        layer.add group.pkgInfos

    if layer.len == 0:
      var cycleLayer: seq[seq[PackageInfo]]
      for group in next:
        if group.pkgInfos.len > 0:
          cycleLayer.add group.pkgInfos
      if cycleLayer.len > 0:
        result.add cycleLayer
      break

    result.add layer
    for group in layer:
      for pkgInfo in group:
        orderedNames.incl pkgInfo.rpc.name
    remaining = next

func checkDependencyCycle(satisfied: Table[PackageReference, SatisfyResult];
    pkgInfo: PackageInfo; reference: PackageReference): bool =
  for checkReference in pkgInfo.allDepends:
    if checkReference == reference:
      return false
    let buildPkgInfo = satisfied.opt(checkReference).map(r => r.buildPkgInfo).flatten
    if buildPkgInfo.isSome and not checkDependencyCycle(satisfied, buildPkgInfo.unsafeGet, reference):
      return false
  true

func findInSatisfied(satisfied: Table[PackageReference, SatisfyResult];
    reference: PackageReference; nodepsCount: int): Option[PackageInfo] =
  for satref, res in satisfied.pairs:
    if res.buildPkgInfo.isSome:
      let pkgInfo = res.buildPkgInfo.unsafeGet
      if satref == reference or reference
          .isProvidedBy(pkgInfo.rpc.toPackageReference, nodepsCount == 0):
        return some(pkgInfo)
      for provides in pkgInfo.provides:
        if reference.isProvidedBy(provides, nodepsCount == 0) and
            checkDependencyCycle(satisfied, pkgInfo, reference):
          return some(pkgInfo)
  none(PackageInfo)

func findInAdditional(additionalPkgInfos: seq[PackageInfo];
    satisfied: Table[PackageReference, SatisfyResult];
    reference: PackageReference; nodepsCount: int): Option[PackageInfo] =
  for pkgInfo in additionalPkgInfos:
    if reference.isProvidedBy(pkgInfo.rpc.toPackageReference, nodepsCount == 0):
      return some(pkgInfo)
    for provides in pkgInfo.provides:
      if reference.isProvidedBy(provides, nodepsCount == 0) and
          checkDependencyCycle(satisfied, pkgInfo, reference):
        return some(pkgInfo)
  none(PackageInfo)

func findInDatabaseWithGroups(db: ptr AlpmDatabase; reference: PackageReference;
    directName: bool; nodepsCount: int): Option[tuple[name: string, groups: seq[string]]] =
  for pkg in db.packages:
    if reference.isProvidedBy(pkg.toPackageReference, nodepsCount == 0):
      return some(($pkg.name, pkg.groups.toSeq()))
    for provides in pkg.provides:
      if reference.isProvidedBy(provides.toPackageReference, nodepsCount == 0):
        return some(((if directName: $pkg.name else: $provides.name), pkg.groups.toSeq()))
  none((string, seq[string]))

func findInDatabase(config: Config; db: ptr AlpmDatabase; reference: PackageReference;
    directName, checkIgnored: bool; nodepsCount: int): Option[string] =
  let res = findInDatabaseWithGroups(db, reference, directName, nodepsCount)
  if res.isSome:
    let r = res.unsafeGet
    if checkIgnored and config.ignored(r.name, r.groups):
      none(string)
    else:
      some(r.name)
  else:
    none(string)

func findInDatabases(config: Config; dbs: seq[ptr AlpmDatabase]; reference: PackageReference;
    directName, checkIgnored: bool; nodepsCount: int): Option[string] =
  for db in dbs:
    let name = findInDatabase(config, db, reference, directName, checkIgnored, nodepsCount)
    if name.isSome:
      return name
  none(string)

func resolveReference(config: Config; handle: ptr AlpmHandle;
    dbs: seq[ptr AlpmDatabase]; satisfied: Table[PackageReference, SatisfyResult];
    additionalPkgInfos: seq[PackageInfo]; nodepsCount: int;
    assumeInstalled: seq[PackageReference];
    reference: PackageReference): Option[SatisfyResult] =
  let localName = findInDatabase(config, handle.local, reference, true, false, nodepsCount)
  if localName.isSome:
    return some(SatisfyResult(installed: true, name: localName.unsafeGet,
      buildPkgInfo: none(PackageInfo)))

  if nodepsCount >= 2 or assumeInstalled.anyIt(reference.isProvidedBy(it, true)):
    return some(SatisfyResult(installed: true, name: reference.name,
      buildPkgInfo: none(PackageInfo)))

  let pkgInfo = findInSatisfied(satisfied, reference, nodepsCount)
  if pkgInfo.isSome:
    return some(SatisfyResult(installed: false, name: pkgInfo.unsafeGet.rpc.name,
      buildPkgInfo: pkgInfo))

  let addlPkgInfo = findInAdditional(additionalPkgInfos, satisfied, reference, nodepsCount)
  if addlPkgInfo.isSome:
    return some(SatisfyResult(installed: false, name: addlPkgInfo.unsafeGet.rpc.name,
      buildPkgInfo: addlPkgInfo))

  let syncName = findInDatabases(config, dbs, reference, false, true, nodepsCount)
  if syncName.isSome:
    return some(SatisfyResult(installed: false, name: syncName.unsafeGet,
      buildPkgInfo: none(PackageInfo)))

  none(SatisfyResult)

proc rpcNames(rpcs: openArray[RpcPackageInfo]): seq[string] =
  ## Extracts bare package names from a slice of RPC info records.
  result = newSeqOfCap[string](rpcs.len)
  for r in rpcs:
    result.add r.name

proc fetchAurInfos(config: Config; names: seq[string];
    printMode: bool; update: (int, int) -> void): AurFetchRes =
  ## Fetches AUR package infos, branching on printMode:
  ## - print mode: RPC + HTTP .SRCINFO only (no git clone).
  ## - install mode: clone bare AUR repos into the temp workspace.
  ## The update callback receives (progress, total) for the progress bar.
  if printMode:
    let (pkgInfos, additionalPkgInfos, aerrors) = getAurPackageInfos(names,
      config.aurRepo, config.common.arch, config.common.downloadTimeout, config.color)
    AurFetchRes(
      pkgInfos: pkgInfos,
      additionalPkgInfos: additionalPkgInfos,
      errors: aerrors.deduplicate)
  else:
    let (rpcInfos, aerrors) = getRpcPackageInfos(names,
      config.aurRepo, config.common.downloadTimeout, config.color)
    let (pkgInfos, additionalPkgInfos, paths, cerrors) =
      cloneAurReposWithPackageInfos(config, rpcInfos, true, update, true)
    var errors: seq[string]
    for e in aerrors: errors.add e
    for e in cerrors: errors.add e
    AurFetchRes(
      pkgInfos: pkgInfos,
      additionalPkgInfos: additionalPkgInfos,
      paths: paths,
      errors: errors.deduplicate)

proc findDependencies(config: Config; handle: ptr AlpmHandle; dbs: seq[ptr AlpmDatabase];
    satisfied: Table[PackageReference, SatisfyResult]; unsatisfied: seq[PackageReference];
    totalAurFail: seq[PackageReference]; additionalPkgInfos: seq[PackageInfo];
    paths: seq[string]; nodepsCount: int; assumeInstalled: seq[PackageReference];
    printMode, noaur: bool):
    (Table[PackageReference, SatisfyResult], seq[PackageReference], seq[string]) =
  var currentSatisfied = satisfied
  var currentUnsatisfied = unsatisfied
  var currentAurFail = totalAurFail
  var currentAdditionalPkgInfos = additionalPkgInfos
  var currentPaths = paths

  while true:
    let (success, aurCheck) = block:
      var resolved: seq[ResolvedReference]
      var check: seq[PackageReference]

      for r in currentUnsatisfied:
        let res = resolveReference(config, handle, dbs, currentSatisfied,
          currentAdditionalPkgInfos, nodepsCount, assumeInstalled, r)
        if res.isSome:
          resolved.add ResolvedReference(reference: r, result: res.unsafeGet)
        elif r notin currentAurFail:
          check.add r
      (resolved, check)

    let (aurSuccess, aurFail, newPaths, newAdditionalPkgInfos) = block:
      var resolved: seq[ResolvedReference]
      var failed: seq[PackageReference]
      var fetchedPaths: seq[string]
      var fetchedAdditional: seq[PackageInfo]

      if not noaur and aurCheck.len > 0:
        withCloneProgress(config, aurCheck.len, true, printMode, cloneUpdate):
          withAur():
            let fetched = fetchAurInfos(config, aurCheck.mapIt(it.name), printMode, cloneUpdate)
            for e in fetched.errors: printError(config.color, e)

            let nameTable = block:
              var table = initTable[string, PackageInfo]()
              for i in fetched.pkgInfos:
                if not config.ignored(i.rpc.name, i.groups):
                  table[i.rpc.name] = i
              table
            for r in aurCheck:
              if r.name in nameTable:
                resolved.add ResolvedReference(reference: r,
                  result: SatisfyResult(installed: false, name: r.name,
                    buildPkgInfo: some(nameTable[r.name])))
              else:
                failed.add r
            fetchedPaths = fetched.paths
            fetchedAdditional = fetched.additionalPkgInfos
      else:
        failed = aurCheck
      (resolved, failed, fetchedPaths, fetchedAdditional)

    for sr in success:
      currentSatisfied[sr.reference] = sr.result
    for ar in aurSuccess:
      currentSatisfied[ar.reference] = ar.result

    currentPaths.add newPaths
    currentAdditionalPkgInfos.add newAdditionalPkgInfos
    currentAurFail = (currentAurFail & aurFail).deduplicate

    let newUnsatisfied = deduplicate:
      collect(newSeq):
        for y in aurSuccess:
          for i in y.result.buildPkgInfo:
            for x in i.allDepends:
              x

    if newUnsatisfied.len == 0:
      let finallyUnsatisfied = currentAurFail.filterIt(it notin currentSatisfied)
      return (currentSatisfied, finallyUnsatisfied, currentPaths)

    currentUnsatisfied = (newUnsatisfied & currentAurFail).deduplicate

proc findDependencies(config: Config; handle: ptr AlpmHandle;
    dbs: seq[ptr AlpmDatabase]; pkgInfos: seq[PackageInfo];
    additionalPkgInfos: seq[PackageInfo]; nodepsCount: int;
    assumeInstalled: seq[PackageReference]; printMode, noaur: bool):
    (Table[PackageReference, SatisfyResult], seq[PackageReference], seq[string]) =
  let satisfied = pkgInfos.mapIt(((it.rpc.name, none(string), none(VersionConstraint)),
    SatisfyResult(installed: false, name: it.rpc.name, buildPkgInfo: some(it)))).toTable
  let unsatisfied = deduplicate:
    collect(newSeq):
      for i in pkgInfos:
        for x in i.allDepends:
          x
  findDependencies(config, handle, dbs, satisfied, unsatisfied, @[],
    additionalPkgInfos, @[], nodepsCount, assumeInstalled, printMode, noaur)

proc clearWorktrees(config: Config; paths: openArray[string]; spec: CleanupSpec) =
  ## Removes per-base git clone working trees according to spec.
  ## nukeTmpPrefix drives removeTmpDirQuiet (chases firstCreatedTmpDir up the tree)
  ## vs plain removeDirQuiet (removes only the named directory).
  if not spec.removeWorktrees: return
  for path in paths:
    if spec.nukeTmpPrefix: removeTmpDirQuiet(path)
    else: removeDirQuiet(path)
  discard rmdir(cstring(config.tmpRootInitial))

func cleanupSpec(policy: CleanupPolicy; archivesOutsideTmp: bool): CleanupSpec =
  ## Derives cleanup behaviour from post-install policy.
  ## archivesOutsideTmp must be true when packageOutputDir is set — only then
  ## is it safe to nuke the tmpRoot prefix without losing package archives.
  case policy
  of CleanupPolicy.full:
    CleanupSpec(removeWorktrees: true, removeArchives: true, nukeTmpPrefix: true)
  of CleanupPolicy.worktree:
    CleanupSpec(removeWorktrees: true, removeArchives: false, nukeTmpPrefix: archivesOutsideTmp)
  of CleanupPolicy.none:
    CleanupSpec(removeWorktrees: false, removeArchives: false, nukeTmpPrefix: false)

type FailureKind = enum
  buildFailure
  installFailure

func cleanupSpecForFailure(kind: FailureKind; config: Config;
    archivesOutsideTmp: bool): CleanupSpec =
  case kind
  of buildFailure:
    CleanupSpec(
      removeWorktrees: not config.keepBuildDirOnFailure,
      removeArchives: not config.keepBuiltPackagesOnFailure,
      nukeTmpPrefix: not config.keepBuildDirOnFailure and archivesOutsideTmp)
  of installFailure:
    CleanupSpec(
      removeWorktrees: false,
      removeArchives: false,
      nukeTmpPrefix: false)

proc cleanupArtifacts(config: Config; artifacts: InstallArtifacts;
    savedTo: string; spec: CleanupSpec) =
  ## Removes or retains built package archives according to spec.
  ## Non-install-target files (e.g. split-package siblings) are always removed.
  for a in artifacts.artifacts:
    if spec.removeArchives or a.file notin artifacts.installFiles:
      try: removeFile(a.file)
      except CatchableError: discard
  if not spec.removeArchives and savedTo.len > 0:
    printWarning(config.color, tr"packages are saved to '$#'" % [savedTo])

proc printUnsatisfied(config: Config;
    satisfied: Table[PackageReference, SatisfyResult];
    unsatisfied: seq[PackageReference]) =
  if unsatisfied.len > 0:
    for _, satres in satisfied.pairs:
      for pkgInfo in satres.buildPkgInfo:
        for reference in pkgInfo.allDepends:
          if reference in unsatisfied:
            printError(config.color,
              trp("unable to satisfy dependency '%s' required by %s\n") %
              [$reference, pkgInfo.rpc.name])

template createViewTag(repo: string; base: string): string =
  "view-" & repo & "/" & base

func targetArguments(names: openArray[string]): seq[Argument] =
  result = newSeqOfCap[Argument](names.len)
  for name in names:
    result.add (name, none(string), ArgumentType.target)

func targetArguments(names: HashSet[string]): seq[Argument] =
  result = newSeqOfCap[Argument](names.len)
  for name in names.items:
    result.add (name, none(string), ArgumentType.target)

proc exec(
    color: bool;
    child: proc(): int {.closure.};
    cwd: Option[string] = none(string);
    mode: ExecMode = emNormal;
    dropPrivs = false
  ): tuple[output: seq[string], code: int] =
  ## Execute child workload in isolated subprocess with optional:
  ## - privilege dropping
  ## - cwd change
  ## - output capture
  ## - stdio suppression
  result = (output: @[], code: -1)

  proc wrapped(): int =
    if dropPrivs:
      let dropOk = if mode == emRedirect: dropPrivRedirect() else: dropPrivileges()
      if not dropOk:
        printError(color, tr"failed to drop privileges")
        quit(1)
    if cwd.isSome and chdir(cstring(cwd.unsafeGet)) != 0:
      printError(color, tr"chdir failed: $#" % [cwd.unsafeGet])
      quit(1)
    if mode == emSilent:
      discard close(0);
      discard open("/dev/null")
      discard close(1);
      discard open("/dev/null")
      discard close(2);
      discard open("/dev/null")
    child()

  if mode == emRedirect:
    result = forkWaitRedirect(wrapped)
  else:
    result.code = forkWait(wrapped)

proc exec(color: bool;
    args: openArray[string];
    cwd: Option[string] = none(string);
    mode: ExecMode = emNormal;
    dropPrivs = false
  ): tuple[output: seq[string], code: int] =
  ## Execute a command with optional privilege drop, output redirection,
  ## and working directory change. Returns captured output (if redirected) and exit code.
  let argv = @args
  exec(color, proc(): int =
    if mode == emRedirect: execRedirect(argv)
    else: execResult(argv), cwd, mode, dropPrivs)

func pkgArch(config: Config; pkgInfo: PackageInfo): string =
  if "any" in pkgInfo.archs: "any" else: config.common.arch

func pkgFileName(pkgInfo: PackageInfo; arch: string): string =
  pkgInfo.rpc.name & "-" & pkgInfo.rpc.version & "-" & arch

func artifactStem(config: Config; pkgInfo: PackageInfo): string =
  pkgFileName(pkgInfo, pkgArch(config, pkgInfo))

func artifactStemFromFilename(filename, extGlob: string): Option[string] =
  if extGlob == PkgExtGlob:
    let idx = filename.find(".pkg.tar.")
    if idx > 0: some(filename[0 ..< idx]) else: none(string)
  elif filename.endsWith(extGlob):
    some(filename[0 ..< filename.len - extGlob.len])
  else:
    none(string)

proc findArtifactsInDir(config: Config; dir: string;
    replacePkgInfos: openArray[ReplacePkgInfo];
    reportErrors: bool; extGlob: string): seq[BuildArtifact] =
  ## Scans dir once for packages matching name-version-arch<extGlob>.
  ## Returns empty seq on first miss (with optional error print).
  if dir.len == 0: return @[]

  var expected = initHashSet[string]()
  for ri in replacePkgInfos:
    expected.incl artifactStem(config, ri.pkgInfo)

  var fileTable = initTable[string, string]()
  for (kind, path) in walkDir(dir):
    if kind == pcFile:
      for stem in artifactStemFromFilename(path.extractFilename, extGlob):
        if stem in expected and stem notin fileTable:
          fileTable[stem] = path

  var artifacts = newSeq[BuildArtifact]()
  for ri in replacePkgInfos:
    let pkgInfo = ri.pkgInfo
    let file = fileTable.opt(artifactStem(config, pkgInfo))
    if file.isSome:
      artifacts.add BuildArtifact(name: ri.name, pkgInfo: pkgInfo, file: file.unsafeGet)
    else:
      if reportErrors:
        printError(config.color, tr"$#: failed to find built package archive" %
          [pkgInfo.rpc.name])
      return @[]
  artifacts

proc findReusableArtifacts(config: Config; pkgInfos: seq[PackageInfo];
    outputDir, effectivePkgdest: string): seq[BuildArtifact] =
  ## Cross-run reuse: scans outputDir then PreserveBuilt destinations.
  ## Returns first match across all directories.
  let replacePkgInfos = pkgInfos.mapIt(ReplacePkgInfo(name: some(it.rpc.name), pkgInfo: it))
  var dirs = @[outputDir]
  case config.preserveBuilt:
  of PreserveBuilt.pkgdest:
    if effectivePkgdest.len > 0: dirs.add effectivePkgdest
  of PreserveBuilt.user:
    let dir = config.userCacheInitial.cache(CacheKind.packages)
    if dir.len > 0: dirs.add dir
  of PreserveBuilt.internal:
    if config.cache.len > 0: dirs.add config.cache
  else: discard
  for dir in dirs:
    let found = findArtifactsInDir(config, dir, replacePkgInfos,
      reportErrors = false, extGlob = PkgExtGlob)
    if found.len > 0: return found
  @[]

func isValidPackagesUrl(url: string): bool =
  url.startsWith("https://github.com/archlinux/") or
  url == "https://gitea.artixlinux.org/packages"

proc editFileLoop(config: Config; base, repoPath: string;
    gitSubdir: Option[string]; default: char; noconfirm: bool;
    file: string): char =
  let res = printColonUserChoiceWithHelp(config.color,
    tr"View and edit $#?" % [base / file],
    choices('y', 'n', ('s', tr"skip all"), ('a', tr"abort operation")),
    default, noconfirm, 'n')

  if res != 'y':
    return res

  let visualEnv = getEnv("VISUAL")
  let editorEnv = getEnv("EDITOR")
  let editor = if visualEnv.len > 0: visualEnv
    elif editorEnv.len > 0: editorEnv
    else:
      printColonUserInput(config.color, tr"Enter editor executable name" & ":",
        noconfirm, "", "")

  if editor.strip.len == 0:
    return 'n'

  let buildPath = buildPath(repoPath, gitSubdir)
  discard exec(config.color, [bashCmd, "-c", """$1 "$2"""", "bash", editor, file],
    some(buildPath), emNormal, true)
  editFileLoop(config, base, repoPath, gitSubdir, default, noconfirm, file)

proc editFileLoopAll(config: Config; base, repoPath: string;
    gitSubdir: Option[string]; default: char; noconfirm: bool;
    files: openArray[string]): char =
  ## Offers interactive edit for each file in sequence; returns the last
  ## non-'n' user response (e.g. 's' to skip all, 'a' to abort), or 'n'.
  for file in files:
    let res = editFileLoop(config, base, repoPath, gitSubdir, default, noconfirm, file)
    if res != 'n':
      return res
  'n'

proc viewDiffLoop(config: Config; base, repoPath: string;
    gitSubdir: Option[string]; default: char; noconfirm: bool;
    tag: string; files: openArray[string]; hasChanges: bool): char =
  let res = if hasChanges:
      printColonUserChoiceWithHelp(config.color,
        tr"View changes in $#?" % [base],
        choices('y', 'n', ('e', tr"edit files"), ('s', tr"skip all"), ('a', tr"abort operation")),
        default, noconfirm, 'n')
    else:
      printColonUserChoiceWithHelp(config.color,
        tr"No changes in $#. Edit files?" % [base],
        choices('y', 'n', ('s', tr"skip all"), ('a', tr"abort operation")),
        'n', noconfirm, 'n')

  if hasChanges and res == 'y':
    discard exec(config.color, [gitCmd, "-C", repoPath, "diff", tag & "..@", gitSubdir.get(".")],
      none(string), emNormal, true)
    viewDiffLoop(config, base, repoPath, gitSubdir, default, noconfirm, tag, files, hasChanges)
  elif (hasChanges and res == 'e') or (not hasChanges and res == 'y'):
    editFileLoopAll(config, base, repoPath, gitSubdir, default, noconfirm, files)
  else:
    res

proc editLoop(config: Config; repo, base, repoPath: string;
    gitSubdir: Option[string]; defaultYes, noconfirm, trunkPath: bool): char =
  let default = if defaultYes: 'y' else: 'n'

  let rawFiles = getGitFiles(repoPath, gitSubdir, true, trunkPath)
  var files = ("PKGBUILD" & rawFiles.filterIt(it != ".SRCINFO")).deduplicate
  if trunkPath:
    for i in 0 ..< files.len:
      files[i] = "trunk" / files[i]

  let tag = createViewTag(repo, base)

  let (hasChanges, noTag) = if repo == config.aurRepo:
      let revisions = exec(config.color, [gitCmd, "-C", repoPath, "rev-list", tag & "..@"],
        none(string), emRedirect, true)
      if revisions.code != 0:
        (false, true)
      elif revisions.output.len == 0:
        (false, false)
      else:
        let diff = exec(config.color,
          [gitCmd, "-C", repoPath, "diff", tag & "..@", gitSubdir.get(".")],
          none(string), emRedirect, true)
        (diff.output.len > 0, false)
    else:
      (false, true)

  if noTag:
    editFileLoopAll(config, base, repoPath, gitSubdir, default, noconfirm, files)
  else:
    viewDiffLoop(config, base, repoPath, gitSubdir, default, noconfirm, tag, files, hasChanges)

proc keysLoop(config: Config; pgpKeys: seq[string]; noconfirm: bool): char =
  ## Import missing PGP keys for packages about to be built.
  ## Returns 'a' if the user aborts, otherwise 'n'.
  var skipAll = false
  for pgpKey in pgpKeys:
    if exec(config.color, [gpgCmd, "--list-keys", pgpKey],
        none(string), emSilent, true).code == 0:
      continue  # key already present

    # Retry importing this key until it succeeds, the user skips/aborts,
    # or noconfirm/skipAll is in effect (which skips silently on failure).
    while true:
      let res = if skipAll: 'y'
        else:
          printColonUserChoiceWithHelp(config.color,
            tr"Import PGP key $#?" % [pgpKey],
            choices('y', 'n', ('c', tr"import all keys"), ('a', tr"abort operation")),
            'y', noconfirm, 'y')

      if res == 'a':
        return 'a'
      if res == 'n':
        break  # skip this key, move to next

      if res == 'c':
        skipAll = true

      # res == 'y' or skipAll: attempt import
      let importCode =
        if config.common.pgpKeyserver.isSome:
          exec(config.color, [gpgCmd,
            "--keyserver", config.common.pgpKeyserver.unsafeGet,
            "--recv-keys", pgpKey], none(string), emNormal, true).code
        else:
          exec(config.color, [gpgCmd, "--recv-keys", pgpKey],
            none(string), emNormal, true).code

      if importCode == 0 or skipAll or noconfirm:
        break  # success or non-interactive: move on regardless
      # Import failed interactively: print error and re-ask for the same key.
      echo(tr"Error - gpg return code = ", importCode)
  'n'

proc checkNext(config: Config; flatBasePackages: openArray[seq[PackageInfo]];
    noconfirm: bool): int =
  ## Reviews each package base interactively (diff, edit, PGP keys).
  ## Returns 0 on success, 1 if the user aborts.
  var skipEdit = false
  for pkgInfos in flatBasePackages:
    requireNonEmpty(pkgInfos, "checkNext")
    let repo = pkgInfos[0].rpc.repo
    let base = pkgInfos[0].rpc.base
    let rpath = repoPath(config.tmpRootInitial, base)
    let isTrunkPath = pkgInfos[0].rpc.gitUrl.isValidPackagesUrl()
    let aur = repo == config.aurRepo

    if not skipEdit and aur and not noconfirm and config.aurComments:
      echo(tr"downloading comments from AUR...")
      let (comments, error) = downloadAurComments(base)
      for e in error: printError(config.color, e)
      if comments.len > 0:
        printComments(config.color, pkgInfos[0].rpc.maintainer, toSeq(comments.reversed))

    let editRes = if skipEdit or noconfirm: 'n'
      else:
        editLoop(config, repo, base, rpath, pkgInfos[0].rpc.gitSubdir,
          aur and not config.viewNoDefault, noconfirm, isTrunkPath)

    if editRes == 'a':
      return 1

    let resultPkgInfos =
      if isTrunkPath: reloadPkgInfos(config, rpath / "trunk/", pkgInfos)
      else: reloadPkgInfos(config, rpath / pkgInfos[0].rpc.gitSubdir.get("."), pkgInfos)

    let pgpKeys = deduplicate:
      collect(newSeq):
        for p in resultPkgInfos:
          for x in p.pgpKeys:
            x

    let keysRes = keysLoop(config, pgpKeys, noconfirm)
    if keysRes == 'a':
      return 1

    if editRes == 's': skipEdit = true
  0

proc writeMakepkgConf(config: Config; srcConf, destConf, pkgdest: string): bool =
  ## Copies srcConf to destConf and appends pakku override stanzas.
  ## pkgdest is the effective PKGDEST to write (caller resolves packageOutputDir).
  ## Returns true on success.
  try:
    copyFile(srcConf, destConf)
    var file: File
    if file.open(destConf, fmAppend):
      try:
        file.writeLine("")
        file.writeLine('#'.repeat(73))
        file.writeLine("# PAKKU OVERRIDES")
        file.writeLine('#'.repeat(73))
        file.writeLine("CARCH=", config.common.arch.bashEscape)
        file.writeLine("PKGDEST=", pkgdest.bashEscape)
      finally:
        file.close()
    true
  except CatchableError:
    discard unlink(cstring(destConf))
    false

proc readConfExt(config: Config; workConfFile: string): string =
  ## Reads PKGEXT from the environment or, failing that, sources the makepkg
  ## conf to find the configured extension. Falls back to the glob pattern.
  let envExt = getEnv("PKGEXT")
  if envExt.len > 0:
    return envExt
  let ex = exec(config.color,
    [bashCmd, "-c", "source \"$@\" && echo \"$PKGEXT\"", "bash", workConfFile],
    none(string), emRedirect, true).output.optFirst.get("")
  if ex.len > 0: ex else: PkgExtGlob

proc matchArtifactsToInfos(config: Config; pkgInfos: seq[PackageInfo];
    resultPkgInfos: seq[PackageInfo]): Option[seq[ReplacePkgInfo]] =
  ## Maps each requested PackageInfo to the corresponding post-build info,
  ## falling back to index-based matching when counts agree.
  ## Returns none on any mismatch.
  requireNonEmpty(pkgInfos, "matchArtifactsToInfos")
  let resultTable = block:
    var t = initTable[string, PackageInfo]()
    for ri in resultPkgInfos: t[ri.rpc.name] = ri
    t

  let sameCount = pkgInfos[0].baseCount == resultPkgInfos.len
  var targets = newSeq[ReplacePkgInfo]()
  var failed = newSeq[string]()
  var seen = initHashSet[string]()

  for idx, pi in pkgInfos:
    var found = resultTable.opt(pi.rpc.name)
    if found.isNone and sameCount:
      found = some(resultPkgInfos[pi.baseIndex])
    if found.isNone:
      failed.add pi.rpc.name
    else:
      targets.add ReplacePkgInfo(name: some(pi.rpc.name), pkgInfo: found.unsafeGet)
      seen.incl found.unsafeGet.rpc.name

  # Include split-package siblings that aren't explicitly in the install set.
  for ri in resultPkgInfos:
    if ri.rpc.name notin seen:
      targets.add ReplacePkgInfo(name: none(string), pkgInfo: ri)

  if failed.len > 0:
    for name in failed:
      printError(config.color, tr"$#: failed to extract package info" % [name])
    none(seq[ReplacePkgInfo])
  else:
    some(targets)

proc buildLoop(config: Config; pkgInfos: seq[PackageInfo]; skipDeps, noconfirm,
    noextract: bool; confFile: string): (Option[BuildResult], int, bool) =
  ## Runs makepkg for one package base and returns discovered package artifacts
  ## paired with refreshed package metadata.
  requireNonEmpty(pkgInfos, "buildLoop")
  let base = pkgInfos[0].rpc.base
  let repoPath = repoPath(config.tmpRootInitial, base)
  let gitSubdir = pkgInfos[0].rpc.gitSubdir
  var buildPath = buildPath(repoPath, gitSubdir)
  if pkgInfos[0].rpc.gitUrl.isValidPackagesUrl():
    buildPath = buildPath / "trunk/"

  let stagingDir = config.tmpRootInitial
  let internalPkgdest = if config.packageOutputDir.len > 0:
      config.packageOutputDir else: stagingDir
  let workConfFile = stagingDir / "makepkg.conf"

  if not writeMakepkgConf(config, confFile, workConfFile, internalPkgdest):
    printError(config.color, tr"failed to copy config file '$#'" % [confFile])
    return (none(BuildResult), 1, false)

  let confExt = readConfExt(config, workConfFile)

  let (buildCode, interrupted) = catchInterrupt():
    proc buildChild(): int =
      discard cunsetenv("MAKEPKG_CONF")
      if not noextract:
        removeDirQuiet(buildPath / "src")
      var cmd = @[makepkgCmd, "--config", workConfFile, "--force"]
      for (arg, pred) in [
        ("--noextract", noextract),
        ("--nocolor", not config.color),
        ("--ignorearch", config.ignoreArch),
        ("--nodeps", skipDeps)
      ]:
        if pred: cmd.add arg
      execResult(cmd)
    exec(config.color, buildChild, some(buildPath), emNormal, true).code

  discard unlink(cstring(workConfFile))

  if interrupted:
    return (none(BuildResult), buildCode, true)
  if buildCode != 0:
    printError(config.color, tr"failed to build '$#'" % [base])
    return (none(BuildResult), buildCode, false)

  let resultPkgInfos = reloadPkgInfos(config, buildPath, pkgInfos)
  let replacePkgInfosOpt = matchArtifactsToInfos(config, pkgInfos, resultPkgInfos)
  if replacePkgInfosOpt.isNone:
    return (none(BuildResult), 1, false)

  let artifacts = findArtifactsInDir(config, internalPkgdest,
    replacePkgInfosOpt.unsafeGet, reportErrors = true, extGlob = confExt)
  if artifacts.len == 0:
    return (none(BuildResult), 1, false)

  (some(BuildResult(artifacts: artifacts)), 0, false)

proc tryBuild(config: Config; pkgInfos: seq[PackageInfo]; skipDeps, noconfirm,
    trunkPath: bool; confFile, repoPath: string; gitSubdir: Option[string];
    base: string; noextract, showEditLoop: bool):
    tuple[buildResult: Option[BuildResult], code: int, skipped: bool] =
  ## Build or retry one package base with interactive error handling.
  requireNonEmpty(pkgInfos, "tryBuild")
  if showEditLoop and not noconfirm:
    let res = editLoop(config, pkgInfos[0].rpc.repo, base, repoPath, gitSubdir,
      false, noconfirm, trunkPath)
    if res == 'a':
      return (none(BuildResult), 1, false)

  let (buildResult, code, interrupted) = buildLoop(config, pkgInfos,
    skipDeps, noconfirm, noextract, confFile)

  if interrupted:
    return (buildResult, 1, false)
  if code == 0:
    return (buildResult, 0, false)

  let res = printColonUserChoiceWithHelp(config.color,
    tr"Build failed. Retry, skip this package, or abort?",
    choices('y', ('e', tr"retry with --noextract option"),
      ('s', tr"skip this package"), ('a', tr"abort operation")),
    's', noconfirm, 's')

  case res:
  of 'e':
    tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
      repoPath, gitSubdir, base, true, true)
  of 'y':
    tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
      repoPath, gitSubdir, base, false, true)
  of 's':
    printWarning(config.color, tr"skipping package '$#'" % [base])
    (none(BuildResult), 0, true)
  else:
    (buildResult, code, false)

proc buildFromSources(config: Config; pkgInfos: seq[PackageInfo];
    skipDeps, noconfirm, trunkPath: bool; confFile: string):
    tuple[buildResult: Option[BuildResult], code: int, skipped: bool] =
  ## Wraps buildLoop with pre-build hooks and interactive retry/skip handling
  ## for a single package base.
  requireNonEmpty(pkgInfos, "buildFromSources")
  let base = pkgInfos[0].rpc.base
  let repoPath = repoPath(config.tmpRootInitial, base)
  let gitSubdir = pkgInfos[0].rpc.gitSubdir

  if config.preBuildCommand.isSome:
    printColon(config.color, tr"Running pre-build command...")
    # Run pre-build command in the trunk subdir for official-repo packages,
    # otherwise in the gitSubdir (or repo root when none).
    let preBuildDir = if trunkPath: repoPath / "trunk"
      else: buildPath(repoPath, gitSubdir)
    let code = exec(config.color, [bashCmd, "-c", config.preBuildCommand.unsafeGet],
      some(preBuildDir), emNormal, true).code
    if code != 0 and printColonUserChoice(config.color,
        tr"Command failed, continue?", ['y', 'n'], 'n', 'n', noconfirm, 'n') != 'y':
      return (none(BuildResult), code, false)

  tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
    repoPath, gitSubdir, base, false, false)



func resolveInstallMode(pkgName: string; explicit: bool;
    local: ptr AlpmDatabase): InstallMode =
  ## Determines install mode based on the requested reason and the
  ## current reason stored in the local database.
  ## Returning "auto" avoids an unnecessary pacman -D roundtrip for packages
  ## whose reason already matches.
  let package = local[cstring(pkgName)]
  if package != nil:
    let installedExplicitly = package.reason == AlpmReason.explicit
    if explicit == installedExplicitly: InstallMode.auto
    elif explicit: InstallMode.explicit
    else: InstallMode.dependency
  elif explicit: InstallMode.auto
  else: InstallMode.dependency

proc buildAllBases(config: Config; commonArgs: seq[Argument];
    basePackages: seq[seq[PackageInfo]]; skipDeps, noconfirm: bool;
    confFile, savedTo, effectivePkgdest: string): BuildBasesRes =
  ## Build or skip each base in dependency order. On build failure, chmods the
  ## pkg directory and returns early.
  var results: seq[BuildResult]
  var skippedCount = 0
  for index in 0 ..< basePackages.len:
    requireNonEmpty(basePackages[index], "buildAllBases")
    let baseName = basePackages[index][0].rpc.base
    let isTrunkPath = basePackages[index][0].rpc.gitUrl.isValidPackagesUrl()
    let reusable = findReusableArtifacts(config, basePackages[index],
      savedTo, effectivePkgdest)
    if reusable.len > 0:
      results.add BuildResult(artifacts: reusable)
      continue

    let (buildResult, code, skipped) = buildFromSources(
      config, basePackages[index], skipDeps, noconfirm, isTrunkPath, confFile)
    if skipped:
      inc skippedCount
      continue
    if code != 0:
      let path = config.tmpRootInitial / baseName / (if isTrunkPath: "trunk/pkg" else: "pkg")
      discard chmod(cstring(path), 0o0755)
      return BuildBasesRes(results: results, skipped: skippedCount, code: code)
    results.add buildResult.unsafeGet

  assert results.len + skippedCount == basePackages.len,
    "results + skipped != incoming base count"
  BuildBasesRes(results: results, skipped: skippedCount, code: 0)

func prepareArtifacts(buildResults: openArray[BuildResult];
    basePackages: openArray[seq[PackageInfo]]): InstallArtifacts =
  ## Collect built artifacts into install targets and track built bases.
  ## installFiles is precomputed here so cleanup never rebuilds it per-call.
  var artifacts: seq[BuildArtifact]
  for br in buildResults:
    for artifact in br.artifacts:
      artifacts.add artifact

  let filesTable = block:
    var table = initTable[string, string]()
    for a in artifacts:
      if a.name.isSome: table[a.name.unsafeGet] = a.file
    table
  let install = collect(newSeq):
    for g in basePackages:
      for i in g:
        for x in filesTable.opt(i.rpc.name):
          InstallTarget(name: i.rpc.name, file: x)
  let installFiles = block:
    var s = initHashSet[string]()
    for t in install: s.incl t.file
    s
  var builtBases = initHashSet[string]()
  var renames: CanonicalRenames
  for a in artifacts:
    builtBases.incl a.pkgInfo.rpc.base
    if a.name.isSome:
      let aname = a.name.unsafeGet
      if aname != a.pkgInfo.rpc.name:
        assert aname notin renames, "duplicate canonicalization key"
        renames[aname] = a.pkgInfo.rpc.name

  assert installFiles.len == install.len, "mismatched install targets vs files"
  assert install.len <= artifacts.len, "more install targets than artifacts"
  InstallArtifacts(artifacts: artifacts, install: install,
    installFiles: installFiles, builtBases: builtBases, renames: renames)

proc tagBuiltBases(config: Config; basePackages: openArray[seq[PackageInfo]];
    builtBases: HashSet[string]) =
  ## Create git view tags in bare-repo caches for built AUR packages.
  let cachePath = config.userCacheInitial.cache(CacheKind.repositories)
  for pkgInfos in basePackages:
    requireNonEmpty(pkgInfos, "tagBuiltBases")
    let repo = pkgInfos[0].rpc.repo
    if repo != config.aurRepo or pkgInfos[0].rpc.base notin builtBases:
      continue
    let base = pkgInfos[0].rpc.base
    let bareRepoPath = repoPath(cachePath, bareFullName(BareKind.pkg, base))
    let tag = createViewTag(repo, base)
    discard exec(config.color, [gitCmd, "-C", bareRepoPath, "tag", "-d", tag],
      none(string), emSilent, true)
    discard exec(config.color, [gitCmd, "-C", bareRepoPath, "tag", tag],
      none(string), emSilent, true)

proc installGroupFromSources(config: Config; commonArgs: seq[Argument];
    basePackages: seq[seq[PackageInfo]]; explicits: HashSet[string];
    skipDeps, noconfirm: bool; confFile, effectivePkgdest: string): InstallGroupRes =
  ## Builds a dependency-ordered group of source packages, chooses which archives
  ## to install, invokes the privileged install helper, and cleans or preserves
  ## the build artifacts according to the install outcome.
  let archivesOutsideTmp = config.packageOutputDir.len > 0
  let savedTo = if archivesOutsideTmp: config.packageOutputDir
    else: config.tmpRootInitial

  let successSpec = cleanupSpec(config.cleanupAfterInstall, archivesOutsideTmp)
  let failureSpec = cleanupSpecForFailure(buildFailure, config, archivesOutsideTmp)

  let build = buildAllBases(config, commonArgs, basePackages, skipDeps,
    noconfirm, confFile, savedTo, effectivePkgdest)
  let artifacts = prepareArtifacts(build.results, basePackages)
  assert build.results.len + build.skipped <= basePackages.len
  assert build.code == 0 or build.results.len + build.skipped < basePackages.len,
    "incomplete results expected when build failed"

  if build.code != 0:
    cleanupArtifacts(config, artifacts, savedTo, failureSpec)
    return InstallGroupRes(code: build.code)

  if artifacts.install.len == 0:
    assert build.code == 0
    assert build.results.len == 0, "build produced no install targets"
    cleanupArtifacts(config, artifacts, savedTo, successSpec)
    return InstallGroupRes(code: 0)

  if currentUser.uid != 0 and printColonUserChoice(config.color,
      tr"Continue installing?", ['y', 'n'], 'y', 'n', noconfirm, 'y') != 'y':
    cleanupArtifacts(config, artifacts, savedTo, successSpec)
    return InstallGroupRes(code: 1)

  let installWithReason = withAlpmConfig(config, false, handle, dbs, errors):
    let local = handle.local
    collect(newSeq):
      for it in artifacts.install:
        InstallItem(name: it.name,
          file: it.file,
          mode: $resolveInstallMode(it.name, it.name in explicits, local))

  let (cacheDir, cacheUser, cacheGroup) =
    if config.preserveBuilt == PreserveBuilt.internal:
      (config.cache, 0, 0)
    elif config.preserveBuilt == PreserveBuilt.user:
      let error = ensureUserCacheOrError(config, CacheKind.packages, true)
      for e in error: printError(config.color, e)
      let user = initialUser.get(currentUser)
      (config.userCacheInitial.cache(CacheKind.packages), user.uid, user.gid)
    elif config.preserveBuilt == PreserveBuilt.pkgdest and effectivePkgdest.len > 0:
      let user = initialUser.get(currentUser)
      (effectivePkgdest, user.uid, user.gid)
    else:
      ("", -1, -1)

  let pacmanUpgradeParams = pacmanCmd & pacmanParams(config.color,
    commonArgs & ("U", none(string), ArgumentType.short))
  let pacmanDatabaseParams = pacmanCmd & pacmanParams(config.color,
    commonArgs.keepOnlyOptions(commonOptions) & ("D", none(string), ArgumentType.short))

  assert pacmanUpgradeParams.len > 0 and pacmanDatabaseParams.len > 0,
    "install helper protocol requires non-empty pacman command vectors"
  assert installWithReason.len > 0

  let installParams = block:
    var p = config.sudoCommand
    p.add helperToolCommand("install")
    p.add [cacheDir, $cacheUser, $cacheGroup, $pacmanUpgradeParams.len]
    p.add pacmanUpgradeParams
    p.add $pacmanDatabaseParams.len
    p.add pacmanDatabaseParams
    for i in installWithReason:
      p.add [i.name, i.file, i.mode]
    p

  let code = forkWait(() => execResult(installParams))
  if code != 0:
    # Pacman failed: preserve artifacts so the user can inspect or retry.
    let installFailureSpec = cleanupSpecForFailure(installFailure, config, archivesOutsideTmp)
    cleanupArtifacts(config, artifacts, savedTo, installFailureSpec)
    return InstallGroupRes(code: code)

  tagBuiltBases(config, basePackages, artifacts.builtBases)
  cleanupArtifacts(config, artifacts, savedTo, successSpec)

  InstallGroupRes(canonicalRenames: artifacts.renames, code: 0)

proc deduplicatePkgInfos(pkgInfos: seq[PackageInfo];
    config: Config; warnOnDup: bool): seq[PackageInfo] =
  ## Deduplicate by package name, optionally warning on duplicates.
  var seen = initHashSet[string]()
  for pi in pkgInfos:
    if pi.rpc.name in seen:
      if warnOnDup:
        printWarning(config.color, trp("skipping target: %s\n") % [pi.rpc.name])
    else:
      seen.incl pi.rpc.name
      result.add pi

proc resolveDependencies(config: Config; pkgInfos: seq[PackageInfo];
    additionalPkgInfos: seq[PackageInfo]; printMode: bool;
    nodepsCount: int; assumeInstalled: seq[PackageReference]; noaur: bool):
    (bool, Table[PackageReference, SatisfyResult],
     seq[string], seq[seq[seq[PackageInfo]]], seq[string]) =
  if pkgInfos.len > 0 and not printMode:
    echo(trp("resolving dependencies...\n"))
  let (satisfied, unsatisfied, paths) = withAlpmConfig(config, true, handle, dbs, errors):
    findDependencies(config, handle, dbs, pkgInfos, additionalPkgInfos,
      nodepsCount, assumeInstalled, printMode, noaur)

  let (fullPkgInfos, additionalPacmanTargets) = block:
    var buildAndAurNamesSet = initHashSet[string]()
    var all = pkgInfos
    var pacmanTargets: seq[string]

    for pkgInfo in pkgInfos:
      buildAndAurNamesSet.incl pkgInfo.rpc.name

    for satres in satisfied.values:
      if satres.buildPkgInfo.isSome:
        let pkgInfo = satres.buildPkgInfo.unsafeGet
        if pkgInfo.rpc.name notin buildAndAurNamesSet:
          all.add pkgInfo
      elif not satres.installed:
        pacmanTargets.add satres.name
    (all.deduplicatePkgInfos(config, false), pacmanTargets)

  let orderedPkgInfos = orderInstallation(fullPkgInfos, satisfied)

  if unsatisfied.len > 0:
    printUnsatisfied(config, satisfied, unsatisfied)
    (false, satisfied, additionalPacmanTargets, orderedPkgInfos, paths)
  else:
    (true, satisfied, additionalPacmanTargets, orderedPkgInfos, paths)

proc confirmViewAndImportKeys(config: Config; basePackages: seq[seq[seq[PackageInfo]]];
    installed: seq[Installed]; noconfirm: bool): int =
  if basePackages.len == 0:
    return 0
  let installedVersions = installed.mapIt((it.name, it.version)).toTable
  printPackages(config.color, config.common.verbosePkgLists, (block: collect(newSeq):
    for g in basePackages:
      for b in g:
        for i in b:
          (i.rpc.name, i.rpc.repo, installedVersions.opt(i.rpc.name),
           i.rpc.version).PackageInstallFormat
    ).sorted((a, b) => cmp(a.name, b.name)))

  let input = printColonUserChoice(config.color,
    tr"Proceed with building?", ['y', 'n'], 'y', 'n', noconfirm, 'y')
  if input != 'y':
    return 1

  let flatBasePackages = collect(newSeq):
    for a in basePackages:
      for x in a: x
  checkNext(config, flatBasePackages, noconfirm)

proc removeBuildDependencies(config: Config; commonArgs: seq[Argument];
    unrequired, unrequiredOptional: HashSet[string]): int =
  if unrequired.len == 0 and unrequiredOptional.len == 0:
    return 0

  let removeArgs = commonArgs.keepOnlyOptions(commonOptions, transactionOptions)

  let code = if unrequired.len > 0:
      printColon(config.color, tr"Removing build dependencies...")
      let s = unrequired.targetArguments
      pacmanRun(some(config.sudoCommand), config.color,
        removeArgs & ("R", none(string), ArgumentType.short) & s)
    else:
      0

  if code != 0: return code

  if unrequiredOptional.len > 0:
    printColon(config.color, tr"Removing optional build dependencies...")
    let s = unrequiredOptional.targetArguments
    pacmanRun(some config.sudoCommand, config.color,
      removeArgs & ("R", none(string), ArgumentType.short) & s)
  else:
    0

proc printAllWarnings(config: Config; installed: seq[Installed];
    installedTable: Table[string, Installed]; rpcInfos: seq[RpcPackageInfo];
    pkgInfos, acceptedPkgInfos: seq[PackageInfo]; upToDateNeeded: seq[Installed];
    buildUpToDateNeeded: seq[(string, string)]; localIsNewerSeq: seq[LocalIsNewer];
    targetNamesSet: HashSet[string]; upgradeCount: int; noaur: bool) =
  ## Print orphan, up-to-date, downgrade, and ignore warnings.
  ## installedTable is passed in (already computed by the caller) to avoid rebuilding.
  let acceptedSet = acceptedPkgInfos.mapIt(it.rpc.name).toHashSet

  if upgradeCount > 0 and not noaur and config.printAurNotFound:
    let rpcInfoTable = rpcInfos.mapIt((it.name, it)).toTable
    for inst in installed:
      if inst.foreign and not config.ignored(inst.name, inst.groups) and
          inst.name notin rpcInfoTable:
        printWarning(config.color, tr"$# was not found in AUR" % [inst.name])

  if upgradeCount == 1 and config.printLocalIsNewer:
    for lin in localIsNewerSeq:
      printWarning(config.color, tra("%s: local (%s) is newer than %s (%s)\n") %
        [lin.name, lin.version, config.aurRepo, lin.aurVersion])

  for inst in upToDateNeeded:
    printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
      [inst.name, inst.version])

  for (name, version) in buildUpToDateNeeded:
    printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
      [name, version])

  for pkgInfo in pkgInfos:
    if pkgInfo.rpc.name in acceptedSet:
      if pkgInfo.rpc.repo == config.aurRepo:
        if pkgInfo.rpc.maintainer.isNone:
          printWarning(config.color, tr"$# is orphaned" % [pkgInfo.rpc.name])
        if pkgInfo.rpc.name in installedTable:
          let instVer = installedTable[pkgInfo.rpc.name].version
          let newVer = pkgInfo.rpc.version
          if vercmp(cstring(newVer), cstring(instVer)) < 0 and not pkgInfo.rpc.name.isVcs:
            printWarning(config.color,
              tra("%s: downgrading from version %s to version %s\n") %
              [pkgInfo.rpc.name, instVer, newVer])
    else:
      if not (pkgInfo.rpc.name in targetNamesSet) and upgradeCount > 0 and
          pkgInfo.rpc.name in installedTable:
        let instVer = installedTable[pkgInfo.rpc.name].version
        let newVer = pkgInfo.rpc.version
        let warnFmt = if vercmp(cstring(newVer), cstring(instVer)) < 0:
            tra("%s: ignoring package downgrade (%s => %s)\n")
          else:
            tra("%s: ignoring package upgrade (%s => %s)\n")
        printWarning(config.color, warnFmt % [pkgInfo.rpc.name, instVer, newVer])
      else:
        printWarning(config.color, trp("skipping target: %s\n") % [pkgInfo.rpc.name])

proc filterIgnoresAndConflicts(config: Config; pkgInfos: seq[PackageInfo];
    targetNamesSet: HashSet[string]; installed: Table[string, Installed];
    printMode, noconfirm: bool): (seq[PackageInfo], seq[PackageInfo]) =
  let acceptedPkgInfos = block:
    var accepted: seq[PackageInfo]
    for pkgInfo in pkgInfos:
      let groups = block:
        var res = pkgInfo.groups
        for inst in installed.opt(pkgInfo.rpc.name):
          res = (inst.groups & res).deduplicate
        res

      if not config.ignored(pkgInfo.rpc.name, groups):
        accepted.add pkgInfo
      elif pkgInfo.rpc.name in targetNamesSet:
        if printMode or printColonUserChoice(config.color,
            trp"%s is in IgnorePkg/IgnoreGroup. Install anyway?" % [pkgInfo.rpc.name],
            ['y', 'n'], 'y', 'n', noconfirm, 'y') != 'n':
          accepted.add pkgInfo
    accepted

  if printMode:
    return (acceptedPkgInfos, acceptedPkgInfos)

  let nonConflicting = block:
    var res: seq[PackageInfo]
    for b in acceptedPkgInfos:
      let bRef = b.rpc.toPackageReference
      var conflictsWith = newSeq[string]()
      for p in res:
        let pRef = p.rpc.toPackageReference
        if b.conflicts.anyIt(it.isProvidedBy(pRef, true)) or
           p.conflicts.anyIt(it.isProvidedBy(bRef, true)):
          conflictsWith.add p.rpc.name

      if conflictsWith.len > 0:
        for conflictName in conflictsWith:
          printWarning(config.color,
            tra("removing '%s' from target list because it conflicts with '%s'\n") %
            [b.rpc.name, conflictName])
      else:
        res.add b
    res

  (nonConflicting, acceptedPkgInfos)

func checkNeeded(installed: Table[string, Installed];
    name, version: string; downgrade: bool): tuple[needed: bool, vercmp: int] =
  if name in installed:
    let i = installed[name]
    let vc = vercmp(version, cstring(i.version))
    let needed = if downgrade: vc != 0 else: vc > 0
    (needed, vc.int)
  else:
    (true, 0)

proc inputLoop(config: Config; reqUpgrades: openArray[Upgrade];
    noconfirm: bool): seq[RpcPackageInfo] =
  while true:
    let input = printColonUserInput(config.color,
      tr"Packages to skip (syntax: 1, 3-5, 7 11)" & ":", noconfirm, "", "")
    let intervalsOpt = parseNumberIntervals(input, reqUpgrades.len)
    if intervalsOpt.isSome:
      let intervals = intervalsOpt.unsafeGet
      var filtered: seq[RpcPackageInfo]
      for idx, i in reqUpgrades:
        if not intervals.anyIt(idx + 1 in it):
          filtered.add i.rpcInfo
      return filtered
    printError(config.color, tr"invalid package selection")

proc obtainAurPackageInfos(config: Config; rpcInfos: seq[RpcPackageInfo];
    rpcAurTargets: seq[FullPackageTarget]; installed: Table[string, Installed];
    printMode, noconfirm, needed: bool; upgradeCount: int): AurPackageInfosRes =
  let (upToDateNeeded, targetRpcInfos, targetRefs) = block:
    var skipped: seq[Installed]
    var infos: seq[RpcPackageInfo]
    var refs: seq[PackageReference]

    for target in rpcAurTargets:
      doAssert target.rpcInfo.isSome, "obtainAurPackageInfos requires resolved AUR rpcInfo"
      let rpcInfo = target.rpcInfo.get
      let upgradeable = installed.checkNeeded(rpcInfo.name, rpcInfo.version, true).needed
      if needed and not upgradeable:
        skipped.add installed[rpcInfo.name]
      if not needed or upgradeable:
        infos.add rpcInfo
      refs.add target.sync.target.reference
    (skipped, infos, refs)

  let (upgradeStructs, localIsNewerSeq) = block:
    var upgrades: seq[Upgrade]
    var localNewer: seq[LocalIsNewer]

    if upgradeCount > 0:
      for i in rpcInfos:
        let reference = i.toPackageReference
        if targetRefs.anyIt(it.isProvidedBy(reference, true)):
          continue
        let checkRes = installed.checkNeeded(i.name, i.version, upgradeCount >= 2)
        let (newNeeded, localIsNewer) =
          if i.name.isVcs:
            (installed.checkNeeded(i.name, i.version, false).needed, none(LocalIsNewer))
          elif not checkRes.needed and checkRes.vercmp < 0:
            (checkRes.needed, some(LocalIsNewer(name: i.name,
              version: installed[i.name].version, aurVersion: i.version)))
          else:
            (checkRes.needed, none(LocalIsNewer))
        for lin in localIsNewer:
          localNewer.add lin
        upgrades.add Upgrade(rpcInfo: i, needed: newNeeded)
    (upgrades, localNewer)

  var reqUpgrades, ignoredUpgrades: seq[Upgrade]
  for u in upgradeStructs:
    if not u.needed: continue
    if config.ignored(u.rpcInfo.name, installed[u.rpcInfo.name].groups):
      ignoredUpgrades.add u
    else:
      reqUpgrades.add u

  for upgrade in ignoredUpgrades:
    let instVer = installed[upgrade.rpcInfo.name].version
    let newVer = upgrade.rpcInfo.version
    let warnFmt = if vercmp(newVer.cstring, instVer.cstring) < 0:
        tra("%s: ignoring package downgrade (%s => %s)\n")
      else:
        tra("%s: ignoring package upgrade (%s => %s)\n")
    printWarning(config.color, warnFmt % [upgrade.rpcInfo.name, instVer, newVer])

  let selectedUpgradeRpcInfos =
    if printMode or noconfirm: reqUpgrades.mapIt(it.rpcInfo)
    elif reqUpgrades.len == 0: @[]
    else:
      printColon(config.color, tr"Available AUR upgrades")
      echo()
      let numberWidth = max(($reqUpgrades.len).len, 2)
      for index, upgrade in reqUpgrades:
        let instVer = installed[upgrade.rpcInfo.name].version
        echo(align($(index + 1), numberWidth, ' '), ") ", config.aurRepo, "/",
          upgrade.rpcInfo.name, " ", instVer, " -> ", upgrade.rpcInfo.version)
      echo()
      inputLoop(config, reqUpgrades, noconfirm)

  let fullRpcInfos = block:
    var res = targetRpcInfos
    for u in selectedUpgradeRpcInfos:
      res.add u
    res

  withCloneProgress(config, fullRpcInfos.len, true, printMode, cloneUpdate):
    let fetched = fetchAurInfos(config, rpcNames(fullRpcInfos), printMode, cloneUpdate)
    result = AurPackageInfosRes(
      pkgInfos: fetched.pkgInfos,
      additionalPkgInfos: fetched.additionalPkgInfos,
      paths: fetched.paths,
      upToDateNeeded: upToDateNeeded,
      localIsNewerSeq: localIsNewerSeq,
      errors: fetched.errors)

proc obtainPacmanBuildTargets(config: Config; pacmanTargets: seq[FullPackageTarget];
    installedTable: Table[string, Installed]; printMode, needed, build: bool):
    PacmanBuildTargetsRes =
  let (neededTargets, buildUpToDateNeeded) = block:
    var targets: seq[FullPackageTarget]
    var skipped: seq[(string, string)]

    if not printMode and build and needed:
      for target in pacmanTargets:
        assert target.sync.foundInfos.len > 0,
          "obtainPacmanBuildTargets requires sync package info"
        assert target.sync.foundInfos[0].pkg.isSome,
          "obtainPacmanBuildTargets requires pacman package info"
        let version = target.sync.foundInfos[0].pkg.get.version
        if installedTable.checkNeeded(target.sync.target.reference.name, version, true).needed:
          targets.add target
        else:
          skipped.add (target.sync.target.reference.name, version)
    else:
      targets = pacmanTargets
    (targets, skipped)

  if printMode or not build or neededTargets.len == 0:
    return PacmanBuildTargetsRes(upToDateNeeded: buildUpToDateNeeded)

  echo(tr"checking official repositories...")
  withCloneProgress(config, neededTargets.len, false, printMode, cloneUpdate):
    let (pkgInfos, paths, errors) = obtainBuildPkgInfos(config, neededTargets, cloneUpdate, true)
    result = PacmanBuildTargetsRes(
      checked: true,
      pkgInfos: pkgInfos,
      upToDateNeeded: buildUpToDateNeeded,
      paths: paths,
      errors: errors)

func createInstalled(dbs: seq[ptr AlpmDatabase]; package: ptr AlpmPackage): Installed =
  let foreign = block:
    var found = false
    for db in dbs:
      if db[package.name] != nil:
        found = true
        break
    not found
  Installed(name: $package.name, version: $package.version,
    groups: package.groups.toSeq(), explicit: package.reason == AlpmReason.explicit,
    foreign: foreign)

proc obtainInstalledWithAur(config: Config): (seq[Installed], seq[string]) =
  withAlpmConfig(config, true, handle, dbs, errors):
    for e in errors: printError(config.color, e)
    let installed = block:
      var res: seq[Installed]
      for p in handle.local.packages:
        res.add createInstalled(dbs, p)
      res
    let checkAurUpgradeNames = block:
      var res: seq[string]
      for inst in installed:
        if inst.foreign and (config.checkIgnored or not config.ignored(inst.name, inst.groups)):
          res.add inst.name
      res
    (installed, checkAurUpgradeNames)

proc resolveBuildTargets(config: Config; syncTargets: seq[SyncPackageTarget];
    fullTargets: seq[FullPackageTarget]; printHeader, printMode: bool;
    upgradeCount: int; noconfirm, needed, noaur, build: bool): BuildTargetsRes =
  template errorResult: BuildTargetsRes = BuildTargetsRes(code: 1)

  let (installed, checkAurUpgradeNames) = obtainInstalledWithAur(config)
  let checkAur = not noaur and checkAurUpgradeNames.len > 0 and upgradeCount > 0

  if not printMode and (checkAur or build) and printHeader:
    printColon(config.color, tr"Resolving build targets...")

  let upgradeRpcInfos =
    if checkAur:
      if not printMode: echo(tr"checking AUR database for upgrades...")
      let (infos, rerrors) = getRpcPackageInfos(checkAurUpgradeNames,
        config.aurRepo, config.common.downloadTimeout, config.color)
      for e in rerrors: printError(config.color, e)
      infos
    else:
      @[]

  let installedTable = installed.mapIt((it.name, it)).toTable
  let (rpcAurTargets, rpcInfos) = block:
    var aurTargets: seq[FullPackageTarget]
    var infos: seq[RpcPackageInfo]
    var infoNames = initHashSet[string]()

    for target in fullTargets:
      if target.isAurTargetFull(config.aurRepo):
        aurTargets.add target
        for info in target.rpcInfo:
          infos.add info
          infoNames.incl info.name
    for info in upgradeRpcInfos:
      if info.name notin infoNames:
        infos.add info
    (aurTargets, infos)

  let aur = obtainAurPackageInfos(config, rpcInfos, rpcAurTargets, installedTable,
    printMode, noconfirm, needed, upgradeCount)
  for e in aur.errors: printError(config.color, e)

  let upToDateNeededTable: Table[string, PackageReference] = aur.upToDateNeeded
    .mapIt((it.name, (it.name, none(string),
      some((ConstraintOperation.eq, it.version, false))))).toTable

  let notFoundTargets = filterNotFoundSyncTargets(syncTargets,
    aur.pkgInfos.mapIt(it.rpc), upToDateNeededTable, config.aurRepo)

  if notFoundTargets.len > 0:
    # Pre-build exit: only worktrees exist, no archives to remove.
    clearWorktrees(config, aur.paths,
      CleanupSpec(removeWorktrees: true, removeArchives: false, nukeTmpPrefix: true))
    printSyncNotFound(config, notFoundTargets)
    return errorResult

  let remappedTargets = mapAurTargets((block:
    var targets: seq[SyncPackageTarget]
    for target in syncTargets:
      let targetRef = target.target.reference
      if not upToDateNeededTable.opt(targetRef.name)
          .map(r => targetRef.isProvidedBy(r, true)).get(false):
        targets.add target
    targets), aur.pkgInfos.mapIt(it.rpc), config.aurRepo)

  let (pacmanTargets, targetNamesSet) = block:
    var pacmanTargets: seq[FullPackageTarget]
    var targetNames = initHashSet[string]()

    for target in remappedTargets:
      targetNames.incl target.sync.target.reference.name
      if not target.isAurTargetFull(config.aurRepo):
        pacmanTargets.add target
    (pacmanTargets, targetNames)

  let pacman = obtainPacmanBuildTargets(config, pacmanTargets, installedTable,
    printMode, needed, build)

  if pacman.checked and pacman.pkgInfos.len < pacmanTargets.len:
    # Pre-build exit: only worktrees exist, no archives to remove.
    clearWorktrees(config, pacman.paths & aur.paths,
      CleanupSpec(removeWorktrees: true, removeArchives: false, nukeTmpPrefix: true))
    for e in pacman.errors: printError(config.color, e)
    return errorResult

  let pkgInfos = (pacman.pkgInfos & aur.pkgInfos).deduplicatePkgInfos(config, not printMode)
  let (finalPkgInfos, acceptedPkgInfos) = filterIgnoresAndConflicts(config, pkgInfos,
    targetNamesSet, installedTable, printMode, noconfirm)

  if not printMode:
    printAllWarnings(config, installed, installedTable, rpcInfos,
      pkgInfos, acceptedPkgInfos, aur.upToDateNeeded, pacman.upToDateNeeded,
      aur.localIsNewerSeq, targetNamesSet, upgradeCount, noaur)

  BuildTargetsRes(
    installed: installed,
    targetNamesSet: targetNamesSet,
    pkgInfos: finalPkgInfos,
    additionalPkgInfos: aur.additionalPkgInfos,
    paths: pacman.paths & aur.paths)

func assumeInstalled(args: openArray[Argument]): seq[PackageReference] =
  for i in args:
    if i.matchOption(%%%"assume-installed"):
      let packRef = i.value.get.parsePackageReference(false)
      if (packRef.constraint.isNone or
          packRef.constraint.unsafeGet.operation == ConstraintOperation.eq):
        result.add packRef


proc handleInstall(args: seq[Argument]; config: Config;
    syncTargets: seq[SyncPackageTarget]; fullTargets: seq[FullPackageTarget];
    upgradeCount, nodepsCount: int; wrapUpgrade, noconfirm, needed, build, noaur: bool): int =
  let pacmanTargets = fullTargets.filterIt(not it.isAurTargetFull(config.aurRepo))
  let workDirectPacmanTargets = if build: @[] else: pacmanTargets.mapIt($it.sync.target)

  # check for sysupgrade instead of upgradeCount since upgrade could be done before
  # and then removed from the list of arguments
  let (directCode, directSome) =
    if workDirectPacmanTargets.len > 0 or args.check(%%%"sysupgrade"):
      (pacmanRun(some config.sudoCommand, config.color,
        args.filterIt(not it.isTarget) &
        workDirectPacmanTargets.targetArguments), true)
    else:
      (0, false)

  if directCode != 0:
    return directCode

  let resolved = resolveBuildTargets(config, syncTargets, fullTargets,
    directSome or wrapUpgrade, false, upgradeCount, noconfirm, needed, noaur, build)

  if resolved.code != 0:
    removeTmpDirQuiet(config.tmpRootCurrent)
    return resolved.code

  let assumeInst = args.assumeInstalled
  let skipDeps = assumeInst.len > 0 or nodepsCount > 0

  let (_, satisfied, additionalPacmanTargets, basePackages, dependencyPaths) =
    resolveDependencies(config, resolved.pkgInfos, resolved.additionalPkgInfos, false,
      nodepsCount, assumeInst, noaur)

  let paths = resolved.paths & dependencyPaths

  # Spec used for early-exit cleanup (user abort, dep failure)
  # worktrees survive only when requested via `KeepBuildDirOnFailure`.
  let archivesOutsideTmp = config.packageOutputDir.len > 0
  let earlyFailSpec = CleanupSpec(
    removeWorktrees: not config.keepBuildDirOnFailure,
    removeArchives: true,
    nukeTmpPrefix: not config.keepBuildDirOnFailure and archivesOutsideTmp)

  let confirmCode = confirmViewAndImportKeys(config, basePackages, resolved.installed, noconfirm)
  if confirmCode != 0:
    clearWorktrees(config, paths, earlyFailSpec)
    return confirmCode

  let (explicitsNamesSet, depsNamesSet) = block:
    var expl, deps: HashSet[string]
    for installedPack in resolved.installed:
      let name = installedPack.name
      if installedPack.explicit: expl.incl name else: deps.incl name
    (expl, deps)
  let keepNames = explicitsNamesSet + depsNamesSet + resolved.targetNamesSet

  let explicits =
    if args.check(%%%"asexplicit"):
      keepNames # targetNamesSet + explicitsNamesSet + depsNamesSet
    elif args.check(%%%"asdeps"):
      initHashSet[string]()
    else:
      explicitsNamesSet + (resolved.targetNamesSet - depsNamesSet)

  let commonArgs = args
    .keepOnlyOptions(commonOptions, transactionOptions, upgradeOptions)
    .filter(true, false, %%%"asdeps", %%%"asexplicit", %%%"needed")

  let (_, initialUnrequired, initialUnrequiredWithoutOptional, _) =
    withAlpmConfig(config, false, handle, dbs, errors):
      queryUnrequired(handle, true, true, keepNames)

  if additionalPacmanTargets.len > 0:
    printColon(config.color, tr"Installing build dependencies...")
    let addCode = pacmanRun(some config.sudoCommand, config.color, commonArgs &
      ("S", none(string), ArgumentType.short) &
      ("needed", none(string), ArgumentType.long) &
      ("asdeps", none(string), ArgumentType.long) &
      additionalPacmanTargets.targetArguments)
    if addCode != 0:
      clearWorktrees(config, paths, earlyFailSpec)
      return addCode

  if basePackages.len == 0:
    let aurTargets = fullTargets.filterIt(it.isAurTargetFull(config.aurRepo))
    if (not noaur and (aurTargets.len > 0 or upgradeCount > 0)) or build:
      echo(trp(" there is nothing to do\n"))
    clearWorktrees(config, paths,
      CleanupSpec(removeWorktrees: true, removeArchives: true, nukeTmpPrefix: true))
    return 0

  # check all pacman dependencies were installed
  let unsatisfied =
    if nodepsCount <= 1:
      withAlpmConfig(config, true, handle, dbs, errors):
        for e in errors: printError(config.color, e)
        collect(newSeq):
          for x in satisfied.namedPairs:
            if not x.value.installed and x.value.buildPkgInfo.isNone and
                not checkSatisfied(handle, nodepsCount, x.key):
              x.key
    else:
      @[]

  if unsatisfied.len > 0:
    clearWorktrees(config, paths, earlyFailSpec)
    printUnsatisfied(config, satisfied, unsatisfied)
    return 1

  let (confFileOpt, confError) = resolveMakepkgConf()
  if confFileOpt.isNone:
    if confError.len > 0: printError(config.color, confError)
    clearWorktrees(config, paths,
      CleanupSpec(removeWorktrees: true, removeArchives: true, nukeTmpPrefix: true))
    return 1
  let confFile = confFileOpt.unsafeGet.string
  let effectivePkgdest = resolveEffectivePkgdest(confFile)

  var canonicalRenames = initTable[string, string]()
  var code = 0
  var lastIndex = -1

  for index in 0 ..< basePackages.len:
    let installResult = installGroupFromSources(config, commonArgs,
      basePackages[index], explicits, skipDeps, noconfirm, confFile, effectivePkgdest)
    if installResult.code != 0:
      code = installResult.code
      lastIndex = index
      break
    for k, v in installResult.canonicalRenames: canonicalRenames[k] = v
    lastIndex = index

  if code != 0 and lastIndex < basePackages.len - 1:
    printWarning(config.color, tr"installation aborted")

  # Worktree cleanup policy derived directly from config.
  # Archives are already handled per-group inside installGroupFromSources.
  let successSpec = cleanupSpec(config.cleanupAfterInstall, archivesOutsideTmp)
  let failureSpec = CleanupSpec(
    removeWorktrees: not config.keepBuildDirOnFailure,
    removeArchives: false,
    nukeTmpPrefix: not config.keepBuildDirOnFailure and archivesOutsideTmp)

  let spec = if code == 0: successSpec else: failureSpec
  clearWorktrees(config, paths,
    CleanupSpec(removeWorktrees: spec.removeWorktrees,
      removeArchives: false,
      nukeTmpPrefix: spec.nukeTmpPrefix))

  let newKeepNames = block:
    var keep = initHashSet[string]()
    for n in keepNames:
      keep.incl canonicalRenames.getOrDefault(n, n)
    keep



  let (_, finalUnrequired, finalUnrequiredWithoutOptional, _) =
    withAlpmConfig(config, false, handle, dbs, errors):
      queryUnrequired(handle, true, true, newKeepNames)

  let unrequired = finalUnrequired - initialUnrequired
  let unrequiredOptional = finalUnrequiredWithoutOptional -
    initialUnrequiredWithoutOptional - unrequired

  let removeCode = removeBuildDependencies(config, commonArgs, unrequired, unrequiredOptional)
  if removeCode != 0: removeCode else: code

proc handlePrint(args: seq[Argument]; config: Config;
    syncTargets: seq[SyncPackageTarget]; fullTargets: seq[FullPackageTarget];
    upgradeCount, nodepsCount: int; needed, build, noaur: bool;
    printFormat: string): int =
  let pacmanTargets = fullTargets.filterIt(not it.isAurTargetFull(config.aurRepo))
  let directPacmanTargets = pacmanTargets.mapIt($it.sync.target)

  let resolved = resolveBuildTargets(config,
    syncTargets, fullTargets, false, true, upgradeCount, true, needed, noaur, build)
  if resolved.code != 0:
    return resolved.code

  let (resolveSuccess, _, additionalPacmanTargets, basePackages, _) =
    resolveDependencies(config, resolved.pkgInfos, resolved.additionalPkgInfos, true,
      nodepsCount, args.assumeInstalled, noaur)

  let code =
    if directPacmanTargets.len > 0 or additionalPacmanTargets.len > 0 or upgradeCount > 0:
      let callPacmanTargets = if resolveSuccess:
          directPacmanTargets & additionalPacmanTargets
        else:
          directPacmanTargets
      let c = pacmanRun(noPrefix, config.color,
        args.filterIt(not it.isTarget) & callPacmanTargets.targetArguments)
      if resolveSuccess: c else: 1
    else:
      0

  if code != 0:
    return code

  for installGroup in basePackages:
    for pkgInfos in installGroup:
      for pkgInfo in pkgInfos:
        echo printFormat.multiReplace(
          ("%n", pkgInfo.rpc.name),
          ("%v", pkgInfo.rpc.version),
          ("%r", config.aurRepo),
          ("%s", "0"),
          ("%l", pkgInfo.rpc.gitUrl))
  0

proc resolveAurTargets(config: Config; targets: seq[PackageTarget];
    printMode, noaur, build: bool):
    (int, seq[SyncPackageTarget], seq[FullPackageTarget]) =
  let (syncTargets, checkAurTargetNames) = withAlpmConfig(config, true, handle, dbs, errors):
    for e in errors: printError(config.color, e)
    findSyncTargets(handle, dbs, targets, config.aurRepo, not build, not build, true)

  let rpcInfos =
    if not noaur and checkAurTargetNames.len > 0:
      if not printMode:
        printColon(config.color, tr"Resolving build targets...")
        echo(tr"checking AUR database for targets...")
      let (infos, rerrors) = getRpcPackageInfos(checkAurTargetNames,
        config.aurRepo, config.common.downloadTimeout, config.color)
      for e in rerrors: printError(config.color, e)
      infos
    else:
      @[]

  let rpcNotFoundTargets = filterNotFoundSyncTargets(syncTargets,
    rpcInfos, initTable[string, PackageReference](), config.aurRepo)

  if rpcNotFoundTargets.len > 0:
    printSyncNotFound(config, rpcNotFoundTargets)
    (1, syncTargets, newSeq[FullPackageTarget]())
  else:
    let fullTargets = mapAurTargets(syncTargets, rpcInfos, config.aurRepo)
    (0, syncTargets, fullTargets)

proc handleSyncInstall*(args: seq[Argument]; config: Config): int =
  let printModeArg = args.check(%%%"print")
  let printModeFormat = args.filterIt(it.matchOption(%%%"print-format")).optLast
  let printFormat =
    if printModeArg or printModeFormat.isSome:
      some(printModeFormat.map(arg => arg.value.get).get("%l"))
    else:
      none(string)

  let targets = args.packageTargets(false)
  let wrapUpgrade = targets.len == 0

  let (refreshUpgradeCode, callArgs) =
    if wrapUpgrade and printFormat.isNone:
      checkAndRefreshUpgrade(config.sudoCommand, config.color, args)
    else:
      checkAndRefresh(config.sudoCommand, config.color, args)

  if refreshUpgradeCode != 0:
    return refreshUpgradeCode

  let upgradeCount = args.count(%%%"sysupgrade")
  let nodepsCount = args.count(%%%"nodeps")
  let needed = args.check(%%%"needed")
  let noaur = args.check(%%%"noaur")
  let build = args.check(%%%"build")
  let noconfirm = args.noconfirm

  withAur():
    let (code, syncTargets, fullTargets) = resolveAurTargets(config, targets,
      printFormat.isSome, noaur, build)

    let pacmanArgs = callArgs.filterExtensions(true, true,
      commonOptions, transactionOptions, upgradeOptions, syncOptions)

    if code != 0:
      return code

    if printFormat.isSome:
      handlePrint(pacmanArgs, config, syncTargets, fullTargets,
        upgradeCount, nodepsCount, needed, build, noaur, printFormat.unsafeGet)
    else:
      handleInstall(pacmanArgs, config, syncTargets, fullTargets,
        upgradeCount, nodepsCount, wrapUpgrade, noconfirm, needed, build, noaur)
