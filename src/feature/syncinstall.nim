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

  ArtifactFile = object
    ## A built package archive and its optional install-relevance name.
    name: Option[string]
    file: string

  InstallTarget = object
    ## A package-to-archive mapping selected for installation.
    name: string
    file: string

  BuildBasesResult = object
    results: seq[BuildResult]
    code: int

  InstallArtifacts = object
    allFiles: seq[ArtifactFile]
    install: seq[InstallTarget]
    builtBases: HashSet[string]

  InstallGroupResult = object
    installedAs: seq[(string, string)]
    code: int
    keepBuiltArtifacts: bool

  Upgrade = object
    rpcInfo: RpcPackageInfo
    needed: bool
    localIsNewer: Option[LocalIsNewer]

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
      proc cloneUpdate(progress: int, newCount: int) {.closure.} =
        # newCount can be < count if some packages were not found
        update(max(count - newCount + progress, 0), count)

      (cloneUpdate, terminate)
    else:
      (update, terminate)
  else:
    (proc (a: int, b: int) {.closure.} = discard, proc {.closure.} = discard)

func isVcs(name: string): bool =
  let index = name.rfind('-')
  if index >= 0:
    let suffix = name[index + 1 .. ^1]
    suffix == "bzr" or suffix == "git" or suffix == "hg" or suffix == "svn"
  else:
    false

func checkSatisfied(handle: ptr AlpmHandle; nodepsCount: int;
  reference: PackageReference): bool =
  for pkg in handle.local.packages:
    if reference.isProvidedBy(pkg.toPackageReference, nodepsCount == 0):
      return true
    for provides in pkg.provides:
      if reference.isProvidedBy(provides.toPackageReference, nodepsCount == 0):
        return true
  false

func hasBuildDependency(satisfied: Table[PackageReference, SatisfyResult];
  orderedNamesSet: HashSet[string]; pkgInfos: seq[PackageInfo]): bool =
  for pkgInfo in pkgInfos:
    for reference in pkgInfo.allDepends:
      for satres in satisfied.opt(reference):
        if satres.buildPkgInfo.isSome and
          not (satres.buildPkgInfo.unsafeGet in pkgInfos) and
          not (satres.buildPkgInfo.unsafeGet.rpc.name in orderedNamesSet):
          return true
  false

func orderInstallation(ordered: seq[seq[seq[PackageInfo]]], grouped: seq[seq[PackageInfo]],
  satisfied: Table[PackageReference, SatisfyResult]): seq[seq[seq[PackageInfo]]] =
  let orderedNamesSet = collect(initHashSet):
    for a in ordered:
      for b in a:
        for c in b:
          {c.rpc.name}

  let split: seq[tuple[pkgInfos: seq[PackageInfo], dependent: bool]] =
    grouped.map(i => (i, hasBuildDependency(satisfied, orderedNamesSet, i)))

  let newOrdered = ordered & split.filterIt(not it.dependent).mapIt(it.pkgInfos)
  let unordered = split.filterIt(it.dependent).mapIt(it.pkgInfos)

  if unordered.len > 0:
    if unordered.len == grouped.len:
      newOrdered & unordered
    else:
      orderInstallation(newOrdered, unordered, satisfied)
  else:
    newOrdered

proc orderInstallation(pkgInfos: seq[PackageInfo],
  satisfied: Table[PackageReference, SatisfyResult]): seq[seq[seq[PackageInfo]]] =
  let grouped = pkgInfos.groupBy(i => i.rpc.base).map(p => p.values)

  orderInstallation(@[], grouped, satisfied)
    .mapIt(it.filterIt(it.len > 0))
    .filterIt(it.len > 0)

func checkDependencyCycle(satisfied: Table[PackageReference, SatisfyResult];
  pkgInfo: PackageInfo; reference: PackageReference): bool =
  for checkReference in pkgInfo.allDepends:
    if checkReference == reference:
      return false
    let buildPkgInfo = satisfied.opt(checkReference)
      .map(r => r.buildPkgInfo).flatten
    if buildPkgInfo.isSome and not checkDependencyCycle(satisfied, buildPkgInfo.unsafeGet, reference):
      return false
  return true

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
  directName: bool; checkIgnored: bool; nodepsCount: int): Option[string] =
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
  directName: bool; checkIgnored: bool; nodepsCount: int): Option[string] =
  for db in dbs:
    let name = findInDatabase(config, db, reference, directName, checkIgnored, nodepsCount)
    if name.isSome:
      return name
  return none(string)

func resolveReference(config: Config; handle: ptr AlpmHandle;
  dbs: seq[ptr AlpmDatabase]; satisfied: Table[PackageReference, SatisfyResult];
  additionalPkgInfos: seq[PackageInfo]; nodepsCount: int;
  assumeInstalled: seq[PackageReference];
  reference: PackageReference): Option[SatisfyResult] =
  let localName = findInDatabase(config, handle.local, reference, true, false, nodepsCount)
  if localName.isSome:
    some(SatisfyResult(installed: true, name: localName.unsafeGet, buildPkgInfo: none(PackageInfo)))
  else:
    if nodepsCount >= 2 or
      assumeInstalled.filterIt(reference.isProvidedBy(it, true)).len > 0:
      some(SatisfyResult(installed: true, name: reference.name, buildPkgInfo: none(PackageInfo)))
    else:
      let pkgInfo = findInSatisfied(satisfied, reference, nodepsCount)
      if pkgInfo.isSome:
        some(SatisfyResult(installed: false, name: pkgInfo.unsafeGet.rpc.name, buildPkgInfo: pkgInfo))
      else:
        let pkgInfo = findInAdditional(additionalPkgInfos, satisfied, reference, nodepsCount)
        if pkgInfo.isSome:
          some(SatisfyResult(installed: false, name: pkgInfo.unsafeGet.rpc.name, buildPkgInfo: pkgInfo))
        else:
          let syncName = findInDatabases(config, dbs, reference, false, true, nodepsCount)
          if syncName.isSome:
            some(SatisfyResult(installed: false, name: syncName.unsafeGet, buildPkgInfo: none(PackageInfo)))
          else:
            none(SatisfyResult)

proc findDependencies(config: Config, handle: ptr AlpmHandle, dbs: seq[ptr AlpmDatabase],
  satisfied: Table[PackageReference, SatisfyResult], unsatisfied: seq[PackageReference],
  totalAurFail: seq[PackageReference], additionalPkgInfos: seq[PackageInfo], paths: seq[string],
  nodepsCount: int, assumeInstalled: seq[PackageReference], printMode: bool, noaur: bool):
  (Table[PackageReference, SatisfyResult], seq[PackageReference], seq[string]) =
  type ReferenceResult = tuple[reference: PackageReference, result: Option[SatisfyResult]]

  var success: seq[ReferenceResult]
  var aurCheck: seq[PackageReference]
  for r in unsatisfied:
    let res = resolveReference(config, handle, dbs, satisfied, additionalPkgInfos,
      nodepsCount, assumeInstalled, r)
    if res.isSome:
      success.add (r, res)
    elif r notin totalAurFail:
      aurCheck.add r

  let (aurSuccess, aurFail, newPaths, newAdditionalPkgInfos) =
    if not noaur and aurCheck.len > 0: (block:
      let (update, terminate) = createCloneProgress(config, aurCheck.len, true, printMode)
      try:
        withAur():
          let (pkgInfos, additionalPkgInfos, paths) = if printMode: (block:
              let (pkgInfos, additionalPkgInfos, aerrors) = getAurPackageInfos(aurCheck
                .map(r => r.name), config.aurRepo, config.common.arch,
                config.common.downloadTimeout, config.color)
              for e in aerrors: printError(config.color, e)
              (pkgInfos, additionalPkgInfos, newSeq[string]()))
            else: (block:
              let (rpcInfos, aerrors) = getRpcPackageInfos(aurCheck.map(r => r.name),
                config.aurRepo, config.common.downloadTimeout, config.color)
              for e in aerrors: printError(config.color, e)
              let (pkgInfos, additionalPkgInfos, paths, cerrors) =
                cloneAurReposWithPackageInfos(config, rpcInfos, not printMode, update, true)
              for e in cerrors: printError(config.color, e)
              (pkgInfos, additionalPkgInfos, paths))

          let (aurSuccess, aurFail) = block:
            var success: seq[ReferenceResult]
            var fail: seq[PackageReference]
            var table = initTable[string, PackageInfo]()
            for i in pkgInfos:
              if not config.ignored(i.rpc.name, i.groups):
                table[i.rpc.name] = i
            for r in aurCheck:
              if table.hasKey(r.name):
                success.add (r, some(SatisfyResult(installed: false, name: r.name, buildPkgInfo: some(table[r.name]))))
              else:
                fail.add r
            (success, fail)
          (aurSuccess, aurFail, paths, additionalPkgInfos)
      finally:
        terminate())
    else:
      (@[], aurCheck, @[], @[])

  var newSatisfied = satisfied
  for sr in success:
    newSatisfied[sr.reference] = sr.result.unsafeGet
  for ar in aurSuccess:
    newSatisfied[ar.reference] = ar.result.unsafeGet

  let newUnsatisfied = deduplicate:
    collect(newSeq):
      for y in aurSuccess:
        for r in y.result:
          for i in r.buildPkgInfo:
            for x in i.allDepends:
              x

  let newTotalAurFail = (totalAurFail & aurFail).deduplicate
  let newTotalUnsatisfied = (newUnsatisfied & newTotalAurFail).deduplicate

  if newUnsatisfied.len > 0:
    findDependencies(config, handle, dbs, newSatisfied, newTotalUnsatisfied, newTotalAurFail,
      additionalPkgInfos & newAdditionalPkgInfos, paths & newPaths,
      nodepsCount, assumeInstalled, printMode, noaur)
  else:
    let finallyUnsatisfied = newTotalAurFail.filterIt(not newSatisfied.hasKey(it))
    (newSatisfied, finallyUnsatisfied, paths & newPaths)

proc findDependencies(config: Config, handle: ptr AlpmHandle,
  dbs: seq[ptr AlpmDatabase], pkgInfos: seq[PackageInfo], additionalPkgInfos: seq[PackageInfo],
  nodepsCount: int, assumeInstalled: seq[PackageReference], printMode: bool, noaur: bool):
  (Table[PackageReference, SatisfyResult], seq[PackageReference], seq[string]) =
  let satisfied = pkgInfos.map(p => ((p.rpc.name, none(string), none(VersionConstraint)),
    SatisfyResult(installed: false, name: p.rpc.name, buildPkgInfo: some(p)))).toTable
  let unsatisfied = deduplicate:
    collect(newSeq):
      for i in pkgInfos:
        for x in i.allDepends:
          x
  findDependencies(config, handle, dbs, satisfied, unsatisfied, @[],
    additionalPkgInfos, @[], nodepsCount, assumeInstalled, printMode, noaur)

proc clearPaths(config: Config; paths: openArray[string]; tmpDir = false) =
  ## Removes cloned repo working trees after a build or on failure.
  ## Uses removeTmpDirQuiet when tmpDir is true so the first-created temp
  ## prefix is also pruned, otherwise plain removeDirQuiet for bare repos.
  for path in paths:
    if tmpDir: removeTmpDirQuiet(path)
    else: removeDirQuiet(path)
  discard rmdir(cstring(config.tmpRootInitial))

proc printUnsatisfied(config: Config,
  satisfied: Table[PackageReference, SatisfyResult], unsatisfied: seq[PackageReference]) =
  if unsatisfied.len > 0:
    for _, satres in satisfied.pairs:
      for pkgInfo in satres.buildPkgInfo:
        for reference in pkgInfo.allDepends:
          if reference in unsatisfied:
            printError(config.color,
              trp("unable to satisfy dependency '%s' required by %s\n") %
              [$reference, pkgInfo.rpc.name])

template createViewTag(repo: string, base: string): string =
  "view-" & repo & "/" & base

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
      discard close(0)
      discard open("/dev/null")
      discard close(1)
      discard open("/dev/null")
      discard close(2)
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
    if mode == emRedirect:
      execRedirect(argv)
    else:
      execResult(argv), cwd, mode, dropPrivs)

func pkgArch(config: Config; pkgInfo: PackageInfo): string =
  if "any" in pkgInfo.archs: "any" else: config.common.arch

func pkgFileName(pkgInfo: PackageInfo; arch: string): string =
  pkgInfo.rpc.name & "-" & pkgInfo.rpc.version & "-" & arch

proc findArtifactsInDir(config: Config; dir: string;
  replacePkgInfos: openArray[ReplacePkgInfo];
  reportErrors: bool; extGlob: string): seq[BuildArtifact] =
  ## Scans dir for packages matching name-version-arch<extGlob> globs.
  ## Returns empty seq on first miss (with optional error print).
  if dir.len == 0: return @[]
  var artifacts = newSeq[BuildArtifact]()
  for ri in replacePkgInfos:
    let pkgInfo = ri.pkgInfo
    let arch = pkgArch(config, pkgInfo)
    let pattern = dir / (pkgFileName(pkgInfo, arch) & extGlob)
    var found = false
    for file in walkFiles(pattern):
      artifacts.add BuildArtifact(
        name: ri.name,
        pkgInfo: pkgInfo,
        file: file)
      found = true
      break
    if not found:
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
  let dirs = block:
    var d = @[outputDir]
    case config.preserveBuilt:
    of PreserveBuilt.pkgdest:
      if effectivePkgdest.len > 0: d.add effectivePkgdest
    of PreserveBuilt.user:
      let dir = config.userCacheInitial.cache(CacheKind.packages)
      if dir.len > 0: d.add dir
    of PreserveBuilt.internal:
      if config.cache.len > 0: d.add config.cache
    else: discard
    d
  for dir in dirs:
    let found = findArtifactsInDir(config, dir, replacePkgInfos, reportErrors = false, extGlob = PkgExtGlob)
    if found.len > 0: return found
  @[]

func isValidPackagesUrl(url: string): bool =
  url.startsWith("https://github.com/archlinux/") or
  url == "https://gitea.artixlinux.org/packages"

proc editFileLoop(config: Config; base: string; repoPath: string;
  gitSubdir: Option[string]; default: char; noconfirm: bool;
  file: string): char =
  let res = printColonUserChoiceWithHelp(config.color,
    tr"View and edit $#?" % [base / file],
    choices('y', 'n', ('s', tr"skip all"), ('a', tr"abort operation")),
    default, noconfirm, 'n')

  if res == 'y':
    let visualEnv = getEnv("VISUAL")
    let editorEnv = getEnv("EDITOR")
    let editor = if visualEnv.len > 0:
        visualEnv
      elif editorEnv.len > 0:
        editorEnv
      else:
        printColonUserInput(config.color, tr"Enter editor executable name" & ":",
          noconfirm, "", "")

    if editor.strip.len == 0:
      'n'
    else:
      let buildPath = buildPath(repoPath, gitSubdir)
      discard exec(config.color, [bashCmd, "-c", """$1 "$2"""", "bash", editor, file],
        some(buildPath), emNormal, true)
      editFileLoop(config, base, repoPath, gitSubdir, default, noconfirm, file)
  else:
    res

proc editFileLoopAll(config: Config; base: string; repoPath: string;
  gitSubdir: Option[string]; default: char; noconfirm: bool;
  files: openArray[string]; index: int): char =
  if index < files.len:
    let res = editFileLoop(config, base, repoPath, gitSubdir, default, noconfirm, files[index])
    if res == 'n': editFileLoopAll(config, base, repoPath, gitSubdir, default, noconfirm, files, index + 1) else: res
  else:
    'n'

proc viewDiffLoop(config: Config; base: string; repoPath: string;
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
    editFileLoopAll(config, base, repoPath, gitSubdir, default, noconfirm, files, 0)
  else:
    res

proc editLoop(config: Config, repo: string, base: string, repoPath: string,
  gitSubdir: Option[string], defaultYes: bool, noconfirm: bool, trunkPath: bool): char =
  let default = if defaultYes: 'y' else: 'n'

  let rawFiles = getGitFiles(repoPath, gitSubdir, true, trunkPath)
  var files = ("PKGBUILD" & rawFiles.filterIt(it != ".SRCINFO")).deduplicate
  if trunkPath:
    for i in 0 ..< files.len:
      files[i] = "trunk" / files[i]

  let tag = createViewTag(repo, base)

  let (hasChanges, noTag) = if repo == config.aurRepo: (block:
      let revisions = exec(config.color, [gitCmd, "-C", repoPath, "rev-list", tag & "..@"],
        none(string), emRedirect, true)

      if revisions.code != 0:
        (false, true)
      elif revisions.output.len == 0:
        (false, false)
      else: (block:
        let diff = exec(config.color,
          [gitCmd, "-C", repoPath, "diff", tag & "..@", gitSubdir.get(".")],
          none(string), emRedirect, true)
        (diff.output.len > 0, false)))
    else:
      (false, true)

  if noTag:
    editFileLoopAll(config, base, repoPath, gitSubdir, default, noconfirm, files, 0)
  else:
    viewDiffLoop(config, base, repoPath, gitSubdir, default, noconfirm, tag, files, hasChanges)

proc keysLoop(config: Config; pgpKeys: seq[string]; noconfirm: bool;
  index: int; skipKeys: bool): char =
  if index >= pgpKeys.len:
    'n'
  elif (
    let pgpKey = pgpKeys[index]
    exec(config.color, [gpgCmd, "--list-keys", pgpKey], none(string), emSilent, true).code == 0):
    keysLoop(config, pgpKeys, noconfirm, index + 1, skipKeys)
  else:
    let res = if skipKeys:
        'y'
      else:
        printColonUserChoiceWithHelp(config.color,
          tr"Import PGP key $#?" % [pgpKeys[index]],
          choices('y', 'n', ('c', tr"import all keys"), ('a', tr"abort operation")),
          'y', noconfirm, 'y')

    let newSkipKeys = skipKeys or res == 'c'

    if res == 'y' or newSkipKeys:
      let importCode =
        if config.common.pgpKeyserver.isSome:
          exec(config.color, [gpgCmd,
            "--keyserver", config.common.pgpKeyserver.unsafeGet,
            "--recv-keys", pgpKeys[index]],
            none(string), emNormal, true).code
        else:
          exec(config.color, [gpgCmd, "--recv-keys", pgpKeys[index]],
            none(string), emNormal, true).code

      if importCode == 0 or newSkipKeys or noconfirm:
        keysLoop(config, pgpKeys, noconfirm, index + 1, newSkipKeys)
      else:
        if importCode != 0:
          echo(tr"Error - gpg return code = ", importCode)
        keysLoop(config, pgpKeys, noconfirm, index, newSkipKeys)
    elif res == 'n':
      keysLoop(config, pgpKeys, noconfirm, index + 1, newSkipKeys)
    else:
      res

proc checkNext(config: Config; flatBasePackages: openArray[seq[PackageInfo]];
  noconfirm: bool; index: int; skipEdit: bool; skipKeys: bool): int =
  if index < flatBasePackages.len:
    var resultPkgInfos: seq[PackageInfo]
    let pkgInfos = flatBasePackages[index]
    let repo = pkgInfos[0].rpc.repo
    let base = pkgInfos[0].rpc.base
    let repoPath = repoPath(config.tmpRootInitial, base)
    let isTrunkPath = pkgInfos[0].rpc.gitUrl.isValidPackagesUrl()

    let aur = repo == config.aurRepo

    if not skipEdit and aur and not noconfirm and config.aurComments:
      echo(tr"downloading comments from AUR...")
      let (comments, error) = downloadAurComments(base)
      for e in error: printError(config.color, e)
      if comments.len > 0:
        let commentsReversed = toSeq(comments.reversed)
        printComments(config.color, pkgInfos[0].rpc.maintainer, commentsReversed)

    let editRes = if skipEdit or noconfirm:
        'n'
      else: (block:
        let defaultYes = aur and not config.viewNoDefault
        editLoop(config, repo, base, repoPath, pkgInfos[0].rpc.gitSubdir,
          defaultYes, noconfirm, isTrunkPath))

    if editRes == 'a':
      1
    else:
      if isTrunkPath:
        resultPkgInfos = reloadPkgInfos(config, repoPath / "trunk/", pkgInfos)
      else:
        resultPkgInfos = reloadPkgInfos(config,
          repoPath / pkgInfos[0].rpc.gitSubdir.get("."), pkgInfos)
      let pgpKeys = deduplicate:
        collect(newSeq):
          for p in resultPkgInfos:
            for x in p.pgpKeys:
              x

      let keysRes = keysLoop(config, pgpKeys, noconfirm, 0, skipKeys)
      if keysRes == 'a':
        1
      else:
        checkNext(config, flatBasePackages, noconfirm, index + 1,
          skipEdit or editRes == 's', skipKeys or keysRes == 's')
  else:
    0

proc buildLoop(config: Config, pkgInfos: seq[PackageInfo], skipDeps: bool,
  noconfirm: bool, noextract: bool; confFile: string): (Option[BuildResult], int, bool) =
  ## Runs makepkg for one package base and returns discovered package artifacts
  ## paired with refreshed package metadata.
  let base = pkgInfos[0].rpc.base
  let repoPath = repoPath(config.tmpRootInitial, base)
  let stagingDir = config.tmpRootInitial
  let internalPkgdest = if config.packageOutputDir.len > 0:
      config.packageOutputDir else: stagingDir
  let gitSubdir = pkgInfos[0].rpc.gitSubdir
  var buildPath = buildPath(repoPath, gitSubdir)
  if pkgInfos[0].rpc.gitUrl.isValidPackagesUrl():
    buildPath = buildPath / "trunk/"
  let outputDir = internalPkgdest

  let workConfFile = stagingDir / "makepkg.conf"

  let workConfFileCopySuccess = try:
    copyFile(confFile, workConfFile)
    var file: File
    if file.open(workConfFile, fmAppend):
      try:
        file.writeLine("")
        file.writeLine('#'.repeat(73))
        file.writeLine("# PAKKU OVERRIDES")
        file.writeLine('#'.repeat(73))
        file.writeLine("CARCH=", config.common.arch.bashEscape)
        file.writeLine("PKGDEST=", internalPkgdest.bashEscape)
      finally:
        file.close()
    true
  except CatchableError:
    discard unlink(cstring(workConfFile))
    false

  if not workConfFileCopySuccess:
    printError(config.color, tr"failed to copy config file '$#'" % [confFile])
    (none(BuildResult), 1, false)
  else:
    let envExt = getEnv("PKGEXT")
    let confExt = if envExt.len == 0:
        let ex = exec(config.color,
          [bashCmd, "-c", "source \"$@\" && echo \"$PKGEXT\"", "bash", workConfFile],
          none(string), emRedirect, true).output.optFirst.get("")
        if ex.len > 0: ex else: PkgExtGlob
      else: envExt

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
      (none(BuildResult), buildCode, interrupted)
    elif buildCode != 0:
      printError(config.color, tr"failed to build '$#'" % [base])
      (none(BuildResult), buildCode, false)
    else:
      let resultPkgInfos = reloadPkgInfos(config, buildPath, pkgInfos)

      type ResultInfo = object
        name: string
        baseIndex: int
        pkgInfo: Option[PackageInfo]

      let resultPkgInfosTable = block:
        var t = initTable[string, PackageInfo]()
        for ri in resultPkgInfos:
          t[ri.rpc.name] = ri
        t

      let sameCount = pkgInfos[0].baseCount == resultPkgInfos.len
      let resultByIndices = block:
        var res: seq[ResultInfo]
        for idx in 0 ..< pkgInfos.len:
          let pi = pkgInfos[idx]
          var found = resultPkgInfosTable.opt(pi.rpc.name)
          if found.isNone and sameCount:
            found = some(resultPkgInfos[pi.baseIndex])
          res.add ResultInfo(name: pi.rpc.name, baseIndex: pi.baseIndex, pkgInfo: found)
        res

      let failedNames = block:
        var res: seq[string]
        for ri in resultByIndices:
          if ri.pkgInfo.isNone:
            res.add ri.name
        res

      if failedNames.len > 0:
        for name in failedNames:
          printError(config.color, tr"$#: failed to extract package info" % [name])
        (none(BuildResult), 1, false)
      else:
        let allReplacePkgInfos = block:
          var targets: seq[ReplacePkgInfo]
          var filterNames = initHashSet[string]()
          for ri in resultByIndices:
            targets.add ReplacePkgInfo(name: some(ri.name), pkgInfo: ri.pkgInfo.get)
            filterNames.incl(ri.pkgInfo.get.rpc.name)
          for ri in resultPkgInfos:
            if ri.rpc.name notin filterNames:
              targets.add ReplacePkgInfo(name: none(string), pkgInfo: ri)
          targets
        let artifacts = findArtifactsInDir(config, outputDir,
          allReplacePkgInfos, reportErrors = true, extGlob = confExt)
        if artifacts.len == 0:
          (none(BuildResult), 1, false)
        else:
          (some(BuildResult(artifacts: artifacts)), 0, false)

proc tryBuild(config: Config, pkgInfos: seq[PackageInfo], skipDeps: bool,
  noconfirm: bool, trunkPath: bool, confFile: string, repoPath: string,
  gitSubdir: Option[string], base: string, noextract: bool,
  showEditLoop: bool): tuple[buildResult: Option[BuildResult], code: int, skipped: bool] =
  ## Build or retry one package base with interactive error handling.
  let res = if showEditLoop and not noconfirm:
      editLoop(config, pkgInfos[0].rpc.repo, base, repoPath, gitSubdir, false, noconfirm, trunkPath)
    else:
      'n'

  if res == 'a':
    (none(BuildResult), 1, false)
  else:
    let (buildResult, code, interrupted) = buildLoop(config, pkgInfos,
      skipDeps, noconfirm, noextract, confFile)

    if interrupted:
      (buildResult, 1, false)
    elif code != 0:
      let res = printColonUserChoiceWithHelp(config.color,
        tr"Build failed. Retry, skip this package, or abort?",
        choices('y', ('e', tr"retry with --noextract option"),
          ('s', tr"skip this package"), ('a', tr"abort operation")),
        's', noconfirm, 's')

      if res == 'e':
        tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
          repoPath, gitSubdir, base, true, true)
      elif res == 'y':
        tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
          repoPath, gitSubdir, base, false, true)
      elif res == 's':
        printWarning(config.color, tr"skipping package '$#'" % [base])
        (none(BuildResult), 0, true)
      else:
        (buildResult, code, false)
    else:
      (buildResult, code, false)

proc buildFromSources(config: Config;
  pkgInfos: seq[PackageInfo], skipDeps: bool, noconfirm: bool, trunkPath: bool;
  confFile: string):
  tuple[buildResult: Option[BuildResult], code: int, skipped: bool] =
  ## Wraps buildLoop with pre-build hooks and interactive retry/skip handling for
  ## a single package base.
  let base = pkgInfos[0].rpc.base
  let repoPath = if trunkPath:
      repoPath(config.tmpRootInitial, base) / "trunk"
    else:
      repoPath(config.tmpRootInitial, base)
  let gitSubdir = pkgInfos[0].rpc.gitSubdir

  let preBuildCode = if config.preBuildCommand.isSome: (block:
      printColon(config.color, tr"Running pre-build command...")

      let code = exec(config.color, [bashCmd, "-c", config.preBuildCommand.unsafeGet],
        some(buildPath(repoPath, gitSubdir)), emNormal, true).code

      if code != 0 and printColonUserChoice(config.color,
        tr"Command failed, continue?", ['y', 'n'], 'n', 'n',
        noconfirm, 'n') == 'y':
        0
      else:
        code)
    else:
      0

  if preBuildCode != 0:
    (none(BuildResult), preBuildCode, false)
  else:
    tryBuild(config, pkgInfos, skipDeps, noconfirm, trunkPath, confFile,
      repoPath, gitSubdir, base, false, false)

proc cleanupBuiltArtifacts(config: Config; allFiles: openArray[ArtifactFile];
  install: openArray[InstallTarget]; savedTo: string; clear: bool) =
  let installFiles = block:
    var res = newSeqOfCap[string](install.len)
    for package in install: res.add package.file
    res
  for af in allFiles:
    if clear or af.file notin installFiles:
      try: removeFile(af.file)
      except CatchableError: discard
  if not clear and savedTo.len > 0:
    printWarning(config.color, tr"packages are saved to '$#'" % [savedTo])

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
  basePackages: seq[seq[PackageInfo]]; skipDeps: bool; noconfirm: bool;
  confFile: string; savedTo, effectivePkgdest: string): BuildBasesResult =
  ## Build or skip each base in dependency order. On build failure, chmods the
  ## pkg directory and returns early.
  var results: seq[BuildResult]
  for index in 0 ..< basePackages.len:
    let baseName = basePackages[index][0].rpc.base
    let isTrunkPath = basePackages[index][0].rpc.gitUrl.isValidPackagesUrl()
    let reusableArtifacts = findReusableArtifacts(config,
      basePackages[index], savedTo, effectivePkgdest)
    if reusableArtifacts.len > 0:
      results.add BuildResult(artifacts: reusableArtifacts)
    else:
      let (buildResult, code, skipped) = buildFromSources(
        config, basePackages[index], skipDeps, noconfirm, isTrunkPath, confFile)
      if skipped:
        continue
      elif code != 0:
        let path = config.tmpRootInitial / baseName / (if isTrunkPath: "trunk/pkg" else: "pkg")
        discard chmod(cstring(path), 0o0755)
        return BuildBasesResult(results: results, code: code)
      else:
        results.add(buildResult.unsafeGet)
  BuildBasesResult(results: results, code: 0)

func prepareArtifacts(buildResults: openArray[BuildResult];
  basePackages: openArray[seq[PackageInfo]]): InstallArtifacts =
  ## Collect built artifacts into install targets and track built bases.
  let allFiles = collect(newSeq):
    for br in buildResults:
      for artifact in br.artifacts:
        ArtifactFile(name: artifact.name, file: artifact.file)
  let filesTable = block:
    var table = initTable[string, string]()
    for af in allFiles:
      if af.name.isSome:
        table[af.name.unsafeGet] = af.file
    table
  let install = collect(newSeq):
    for g in basePackages:
      for i in g:
        for x in filesTable.opt(i.rpc.name):
          InstallTarget(name: i.rpc.name, file: x)
  var builtBases = initHashSet[string]()
  for br in buildResults:
    for artifact in br.artifacts:
      builtBases.incl(artifact.pkgInfo.rpc.base)
  InstallArtifacts(allFiles: allFiles, install: install, builtBases: builtBases)

proc tagBuiltBases(config: Config; basePackages: openArray[seq[PackageInfo]];
  builtBases: HashSet[string]) =
  ## Create git view tags in bare-repo caches for built AUR packages.
  let cachePath = config.userCacheInitial.cache(CacheKind.repositories)
  for pkgInfos in basePackages:
    let repo = pkgInfos[0].rpc.repo
    if repo == config.aurRepo and pkgInfos[0].rpc.base in builtBases:
      let base = pkgInfos[0].rpc.base
      let fullName = bareFullName(BareKind.pkg, base)
      let bareRepoPath = repoPath(cachePath, fullName)
      let tag = createViewTag(repo, base)
      discard exec(config.color,
        [gitCmd, "-C", bareRepoPath, "tag", "-d", tag], none(string), emSilent, true)
      discard exec(config.color,
        [gitCmd, "-C", bareRepoPath, "tag", tag], none(string), emSilent, true)

proc installGroupFromSources(config: Config, commonArgs: seq[Argument],
  basePackages: seq[seq[PackageInfo]], explicits: HashSet[string],
  skipDeps: bool, noconfirm: bool;
  confFile: string; effectivePkgdest: string): InstallGroupResult =
  ## Builds a dependency-ordered group of source packages, chooses which archives
  ## to install, invokes the privileged install helper, and cleans or preserves the
  ## build artifacts according to the install outcome.
  let savedTo = if config.packageOutputDir.len > 0:
      config.packageOutputDir
    else:
      config.tmpRootInitial

  let build = buildAllBases(config, commonArgs, basePackages, skipDeps,
    noconfirm, confFile, savedTo, effectivePkgdest)
  let artifacts = prepareArtifacts(build.results, basePackages)

  if build.code != 0:
    cleanupBuiltArtifacts(config, artifacts.allFiles, artifacts.install, savedTo,
      not config.keepBuiltPackagesOnFailure)
    InstallGroupResult(code: build.code,
      keepBuiltArtifacts: config.keepBuildDirOnFailure)
  elif artifacts.install.len == 0:
    cleanupBuiltArtifacts(config, artifacts.allFiles, artifacts.install, savedTo, false)
    InstallGroupResult()
  else:
    if currentUser.uid != 0 and printColonUserChoice(config.color,
      tr"Continue installing?", ['y', 'n'], 'y', 'n',
      noconfirm, 'y') != 'y':
      cleanupBuiltArtifacts(config, artifacts.allFiles, artifacts.install, savedTo, false)
      InstallGroupResult(code: 1, keepBuiltArtifacts: true)
    else:
      let installWithReason = withAlpmConfig(config, false, handle, dbs, errors):
        let local = handle.local
        artifacts.install.mapIt:
          (name: it.name,
           file: it.file,
           mode: $resolveInstallMode(it.name, it.name in explicits, local))

      let (cacheDir, cacheUser, cacheGroup) = if config.preserveBuilt == PreserveBuilt.internal:
          (config.cache, 0, 0)
        elif config.preserveBuilt == PreserveBuilt.user: (block:
          let error = ensureUserCacheOrError(config, CacheKind.packages, true)
          for e in error: printError(config.color, e)
          let user = initialUser.get(currentUser)
          let dir = config.userCacheInitial.cache(CacheKind.packages)
          (dir, user.uid, user.gid))
        elif config.preserveBuilt == PreserveBuilt.pkgdest and effectivePkgdest.len > 0:
          let user = initialUser.get(currentUser)
          (effectivePkgdest, user.uid, user.gid)
        else:
          ("", -1, -1)

      let pacmanUpgradeParams = pacmanCmd & pacmanParams(config.color,
        commonArgs & ("U", none(string), ArgumentType.short))

      let pacmanDatabaseParams = pacmanCmd & pacmanParams(config.color,
        commonArgs.keepOnlyOptions(commonOptions) & ("D", none(string), ArgumentType.short))

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
        cleanupBuiltArtifacts(config, artifacts.allFiles, artifacts.install, savedTo, false)
        InstallGroupResult(code: code, keepBuiltArtifacts: true)
      else:
        tagBuiltBases(config, basePackages, artifacts.builtBases)
        cleanupBuiltArtifacts(config, artifacts.allFiles, artifacts.install, savedTo,
          config.cleanupAfterInstall == CleanupPolicy.full)
        let installedAs = collect(newSeq):
          for br in build.results:
            for artifact in br.artifacts:
              if artifact.name.isSome:
                (artifact.name.unsafeGet, artifact.pkgInfo.rpc.name)
        InstallGroupResult(installedAs: installedAs,
          keepBuiltArtifacts: config.cleanupAfterInstall == CleanupPolicy.none)

proc deduplicatePkgInfos(pkgInfos: seq[PackageInfo],
  config: Config, printWarning: bool): seq[PackageInfo] =
  var seen = initHashSet[string]()
  result = newSeq[PackageInfo]()
  for pi in pkgInfos:
    if pi.rpc.name in seen:
      if printWarning:
        printWarning(config.color, trp("skipping target: %s\n") % [pi.rpc.name])
    else:
      seen.incl(pi.rpc.name)
      result.add pi

proc resolveDependencies(config: Config, pkgInfos: seq[PackageInfo],
  additionalPkgInfos: seq[PackageInfo], printMode: bool,
  nodepsCount: int, assumeInstalled: seq[PackageReference], noaur: bool):
  (bool, Table[PackageReference, SatisfyResult],
  seq[string], seq[seq[seq[PackageInfo]]], seq[string]) =
  if pkgInfos.len > 0 and not printMode:
    echo(trp("resolving dependencies...\n"))
  let (satisfied, unsatisfied, paths) = withAlpmConfig(config, true, handle, dbs, errors):
    findDependencies(config, handle, dbs, pkgInfos, additionalPkgInfos,
      nodepsCount, assumeInstalled, printMode, noaur)

  let buildAndAurNamesSet = pkgInfos.map(i => i.rpc.name).toHashSet
  let fullPkgInfos = (pkgInfos & (block:collect(newSeq):
    for s in satisfied.values:
      for i in s.buildPkgInfo:
        if not (i.rpc.name in buildAndAurNamesSet):
          i
    )).deduplicatePkgInfos(config,false)
  let additionalPacmanTargets = collect(newSeq):
    for x in satisfied.values:
      if not x.installed and x.buildPkgInfo.isNone:
        x.name
  let orderedPkgInfos = orderInstallation(fullPkgInfos, satisfied)
  if unsatisfied.len > 0: # dependency not found
    printUnsatisfied(config, satisfied, unsatisfied)
    (false, satisfied, additionalPacmanTargets, orderedPkgInfos, paths)
  else:
    (true, satisfied, additionalPacmanTargets, orderedPkgInfos, paths)

proc confirmViewAndImportKeys(config: Config, basePackages: seq[seq[seq[PackageInfo]]],
  installed: seq[Installed], noconfirm: bool): int =
  if basePackages.len > 0: (block:
    let installedVersions = installed.map(i => (i.name, i.version)).toTable
    printPackages(config.color, config.common.verbosePkgLists,(block:collect(newSeq):
      for g in basePackages:
        for b in g:
          for i in b:
            (i.rpc.name,i.rpc.repo,installedVersions.opt(i.rpc.name),i.rpc.version).PackageInstallFormat
      ).sorted((a,b) => cmp(a.name, b.name)))
    let input = printColonUserChoice(config.color,
      tr"Proceed with building?", ['y', 'n'], 'y', 'n', noconfirm, 'y')

    if input == 'y':
      let flatBasePackages = collect(newSeq):
        for a in basePackages:
          for x in a:
            x
      checkNext(config, flatBasePackages, noconfirm, 0, false, false)
    else:
      1)
  else:
    0

proc removeBuildDependencies(config: Config, commonArgs: seq[Argument],
  unrequired: HashSet[string], unrequiredOptional: HashSet[string]): int =
  if unrequired.len > 0 or unrequiredOptional.len > 0: (block:
    let removeArgs = commonArgs.keepOnlyOptions(commonOptions, transactionOptions)

    let code = if unrequired.len > 0: (block:
        printColon(config.color, tr"Removing build dependencies...")
        let s = collect(newSeq()):
          for it in unrequired.items():
            (it, none(string), ArgumentType.target)
        pacmanRun(some(config.sudoCommand), config.color, removeArgs &
          ("R", none(string), ArgumentType.short) & s) )
      else:
        0

    if code == 0 and unrequiredOptional.len > 0:
      printColon(config.color, tr"Removing optional build dependencies...")
      let s = collect(newSeq()):
        for it in unrequiredOptional.items():
          (it, none(string), ArgumentType.target)
      pacmanRun(some config.sudoCommand, config.color, removeArgs &
        ("R", none(string), ArgumentType.short) & s)
    else:
      code)
  else:
    0

proc printAllWarnings(config: Config, installed: seq[Installed], rpcInfos: seq[RpcPackageInfo],
  pkgInfos: seq[PackageInfo], acceptedPkgInfos: seq[PackageInfo], upToDateNeeded: seq[Installed],
  buildUpToDateNeeded: seq[(string, string)], localIsNewerSeq: seq[LocalIsNewer],
  targetNamesSet: HashSet[string], upgradeCount: int, noaur: bool) =
  let acceptedSet = acceptedPkgInfos.map(i => i.rpc.name).toHashSet

  if upgradeCount > 0 and not noaur and config.printAurNotFound:
    let rpcInfoTable = rpcInfos.map(i => (i.name, i)).toTable
    for inst in installed:
      if inst.foreign and not config.ignored(inst.name, inst.groups) and
        not rpcInfoTable.hasKey(inst.name):
        printWarning(config.color, tr"$# was not found in AUR" % [inst.name])

  if upgradeCount == 1 and config.printLocalIsNewer:
    for localIsNewer in localIsNewerSeq:
      printWarning(config.color, tra("%s: local (%s) is newer than %s (%s)\n") %
        [localIsNewer.name, localIsNewer.version, config.aurRepo, localIsNewer.aurVersion])

  for inst in upToDateNeeded:
    printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
      [inst.name, inst.version])

  for pair in buildUpToDateNeeded:
    let (name, version) = pair
    printWarning(config.color, tra("%s-%s is up to date -- skipping\n") %
      [name, version])

  let installedTable = installed.map(i => (i.name, i)).toTable
  for pkgInfo in pkgInfos:
    if not (pkgInfo.rpc.name in acceptedSet):
      if not (pkgInfo.rpc.name in targetNamesSet) and upgradeCount > 0 and
        installedTable.hasKey(pkgInfo.rpc.name):
        let installedVersion = installedTable[pkgInfo.rpc.name].version
        let newVersion = pkgInfo.rpc.version
        if vercmp(cstring(newVersion), cstring(installedVersion)) < 0:
          printWarning(config.color, tra("%s: ignoring package downgrade (%s => %s)\n") %
            [pkgInfo.rpc.name, installedVersion, newVersion])
        else:
          printWarning(config.color, tra("%s: ignoring package upgrade (%s => %s)\n") %
            [pkgInfo.rpc.name, installedVersion, newVersion])
      else:
        printWarning(config.color, trp("skipping target: %s\n") % [pkgInfo.rpc.name])
    elif pkgInfo.rpc.repo == config.aurRepo:
      if pkgInfo.rpc.maintainer.isNone:
        printWarning(config.color, tr"$# is orphaned" % [pkgInfo.rpc.name])
      if installedTable.hasKey(pkgInfo.rpc.name):
        let installedVersion = installedTable[pkgInfo.rpc.name].version
        let newVersion = pkgInfo.rpc.version
        if vercmp(cstring(newVersion), cstring(installedVersion)) < 0 and not pkgInfo.rpc.name.isVcs:
          printWarning(config.color,
            tra("%s: downgrading from version %s to version %s\n") %
            [pkgInfo.rpc.name, installedVersion, newVersion])

proc filterIgnoresAndConflicts(config: Config, pkgInfos: seq[PackageInfo],
  targetNamesSet: HashSet[string], installed: Table[string, Installed],
  printMode: bool, noconfirm: bool): (seq[PackageInfo], seq[PackageInfo]) =
  let acceptedPkgInfos = pkgInfos.filter(pkgInfo => (block:
    let instGroups = collect(newSeq):
      for i in installed.opt(pkgInfo.rpc.name):
        for x in i.groups:
          x

    if config.ignored(pkgInfo.rpc.name, (instGroups & pkgInfo.groups).deduplicate):
      if pkgInfo.rpc.name in targetNamesSet:
        if not printMode:
          let input = printColonUserChoice(config.color,
            trp"%s is in IgnorePkg/IgnoreGroup. Install anyway?" % [pkgInfo.rpc.name],
            ['y', 'n'], 'y', 'n', noconfirm, 'y')
          input != 'n'
        else:
          true
      else:
        false
    else:
      true))

  var nonConflictingPkgInfos: seq[PackageInfo]
  for b in acceptedPkgInfos:
    var conflictsWith: seq[string]
    for p in nonConflictingPkgInfos:
      if p.rpc.name != b.rpc.name:
        if b.conflicts.anyIt(it.isProvidedBy(p.rpc.toPackageReference, true)) or
           p.conflicts.anyIt(it.isProvidedBy(b.rpc.toPackageReference, true)):
          conflictsWith.add p.rpc.name

    if conflictsWith.len > 0 and not printMode:
      for conflictName in conflictsWith:
        printWarning(config.color,
          tra("removing '%s' from target list because it conflicts with '%s'\n") %
          [b.rpc.name, conflictName])
    else:
      nonConflictingPkgInfos.add b

  (nonConflictingPkgInfos, acceptedPkgInfos)

func checkNeeded(installed: Table[string, Installed],
  name: string, version: string, downgrade: bool): tuple[needed: bool, vercmp: int] =
  if installed.hasKey(name):
    let i = installed[name]
    let vercmp = vercmp(version, cstring(i.version))
    let needed = if downgrade: vercmp != 0 else: vercmp > 0
    (needed, vercmp.int)
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
  printMode: bool; noconfirm: bool; needed: bool; upgradeCount: int): (seq[PackageInfo], seq[PackageInfo],
  seq[string], seq[Installed], seq[LocalIsNewer], seq[string]) =
  let targetRpcInfoPairs = rpcAurTargets.mapIt():
    let rpcInfo = it.rpcInfo.get
    (info: it.rpcInfo.get,
     upgradeable: installed.checkNeeded(rpcInfo.name, rpcInfo.version, true).needed)

  let upToDateNeeded: seq[Installed] = block:
    var res = newSeq[Installed]()
    if needed:
      for (rpcInfo, upgradeable) in targetRpcInfoPairs:
        if not upgradeable:
          res.add installed[rpcInfo.name]
    res

  let upgradeStructs: seq[Upgrade] = block:
    var res: seq[Upgrade]
    for i in rpcInfos:
      if upgradeCount > 0:
        let reference = i.toPackageReference
        var isTarget = false
        for f in rpcAurTargets:
          if f.sync.target.reference.isProvidedBy(reference, true):
            isTarget = true
            break
        if not isTarget:
          let checkRes = installed.checkNeeded(i.name, i.version, upgradeCount >= 2)
          let (newNeeded, localIsNewer) =
            if i.name.isVcs:
              (installed.checkNeeded(i.name, i.version, false).needed, none(LocalIsNewer))
            elif not checkRes.needed and checkRes.vercmp < 0:
              (checkRes.needed, some(LocalIsNewer(name: i.name, version: installed[i.name].version, aurVersion: i.version)))
            else:
              (checkRes.needed, none(LocalIsNewer))
          res.add Upgrade(rpcInfo: i, needed: newNeeded, localIsNewer: localIsNewer)
    res

  let (reqUpgrades, ignoredUpgrades) = block:
    var selectable, ignored: seq[Upgrade]
    for u in upgradeStructs:
      if u.needed:
        if config.ignored(u.rpcInfo.name, installed[u.rpcInfo.name].groups):
          ignored.add u
        else:
          selectable.add u
    (selectable, ignored)

  for upgrade in ignoredUpgrades:
    let installedVersion = installed[upgrade.rpcInfo.name].version
    let newVersion = upgrade.rpcInfo.version
    let warnStr = if vercmp(newVersion.cstring, installedVersion.cstring) < 0:
        tra("%s: ignoring package downgrade (%s => %s)\n")
      else:
        tra("%s: ignoring package upgrade (%s => %s)\n")
    printWarning(config.color, warnStr %
      [upgrade.rpcInfo.name, installedVersion, newVersion])

  let selectedUpgradeRpcInfos =
    if printMode or noconfirm:
      reqUpgrades.mapIt(it.rpcInfo)
    else:
      if reqUpgrades.len == 0: @[]
      else:
        printColon(config.color, tr"Available AUR upgrades")
        echo()
        let numberWidth = max(($reqUpgrades.len).len, 2)
        for index, upgrade in reqUpgrades:
          let installedVersion = installed[upgrade.rpcInfo.name].version
          let number = align($(index + 1), numberWidth, ' ')
          echo(number, ") ", config.aurRepo, "/", upgrade.rpcInfo.name,
            " ", installedVersion, " -> ", upgrade.rpcInfo.version)
        echo()

        inputLoop(config, reqUpgrades, noconfirm)

  let fullRpcInfos = block:
    var res: seq[RpcPackageInfo]
    for (rpcInfo, upgradeable) in targetRpcInfoPairs:
      if not needed or upgradeable:
        res.add rpcInfo
    for u in selectedUpgradeRpcInfos:
      res.add u
    res

  let (update, terminate) = createCloneProgress(config, fullRpcInfos.len, true, printMode)

  proc rpcNames(rpcs: seq[RpcPackageInfo]): seq[string] =
    result = newSeq[string](rpcs.len)
    for i in 0 ..< rpcs.len:
      result[i] = rpcs[i].name

  let (pkgInfos, additionalPkgInfos, paths, errors) = if printMode: (block:
      let (pkgInfos, additionalPkgInfos, aerrors) = getAurPackageInfos(rpcNames(fullRpcInfos),
        config.aurRepo, config.common.arch, config.common.downloadTimeout, config.color)
      (pkgInfos, additionalPkgInfos, newSeq[string](), aerrors.deduplicate))
    else: (block:
      let (rpcInfos, aerrors) = getRpcPackageInfos(rpcNames(fullRpcInfos),
        config.aurRepo, config.common.downloadTimeout, config.color)
      let (pkgInfos, additionalPkgInfos, paths, cerrors) =
        cloneAurReposWithPackageInfos(config, rpcInfos, not printMode, update, true)
      (pkgInfos, additionalPkgInfos, paths, (block:
        var allErrors: seq[string]
        for e in aerrors: allErrors.add e
        for e in cerrors: allErrors.add e
        allErrors).deduplicate))

  terminate()

  var localIsNewerSeq: seq[LocalIsNewer]
  for u in upgradeStructs:
    if u.localIsNewer.isSome:
      localIsNewerSeq.add u.localIsNewer.unsafeGet

  (pkgInfos, additionalPkgInfos, paths, upToDateNeeded, localIsNewerSeq, errors)

proc obtainPacmanBuildTargets(config: Config, pacmanTargets: seq[FullPackageTarget],
  installedTable: Table[string, Installed], printMode: bool, needed: bool, build: bool):
  (bool, seq[PackageInfo], seq[(string, string)], seq[string], seq[string]) =
  let (neededPacmanBuildTargets, buildUpToDateNeeded) = if not printMode and
    build and needed: (block:
      let neededPairs: seq[tuple[full: FullPackageTarget,
        skipVersion: Option[string]]] = pacmanTargets.map(full => (block:
        let version = full.sync.foundInfos[0].pkg.get.version
        if installedTable.checkNeeded(full.sync.target.reference.name, version, true).needed:
          (full, none(string))
        else:
          (full, some(version))))

      let neededPacmanBuildTargets = neededPairs
        .filter(p => p.skipVersion.isNone)
        .map(p => p.full)

      let buildUpToDateNeeded = neededPairs
        .filter(p => p.skipVersion.isSome)
        .map(p => (p.full.sync.target.reference.name, p.skipVersion.unsafeGet))

      (neededPacmanBuildTargets, buildUpToDateNeeded))
    else:
      (pacmanTargets, @[])

  let checkPacmanBuildPkgInfos = not printMode and build and neededPacmanBuildTargets.len > 0

  let (buildPkgInfos, buildPaths, obtainErrorMessages) = if checkPacmanBuildPkgInfos: (block:
      echo(tr"checking official repositories...")
      let (update, terminate) = createCloneProgress(config, pacmanTargets.len, false, printMode)
      let res = obtainBuildPkgInfos(config, pacmanTargets, update, true)
      terminate()
      res)
    else:
      (@[], @[], @[])

  (checkPacmanBuildPkgInfos, buildPkgInfos, buildUpToDateNeeded, buildPaths, obtainErrorMessages)

func createInstalled(dbs: seq[ptr AlpmDatabase]; package: ptr AlpmPackage): Installed =
  let foreign = dbs.filter(d => d[package.name] != nil).len == 0
  Installed(name: $package.name, version: $package.version,
    groups: package.groups.toSeq(), explicit: package.reason == AlpmReason.explicit,
    foreign: foreign)

proc obtainInstalledWithAur(config: Config): (seq[Installed], seq[string]) =
  withAlpmConfig(config, true, handle, dbs, errors):
    for e in errors: printError(config.color, e)

    let installed = collect(newSeq):
      for p in handle.local.packages:
        createInstalled(dbs, p)
    let checkAurUpgradeNames = installed
      .filter(i => i.foreign and (config.checkIgnored or not config.ignored(i.name, i.groups)))
      .map(i => i.name)

    (installed, checkAurUpgradeNames)

proc resolveBuildTargets(config: Config, syncTargets: seq[SyncPackageTarget],
  fullTargets: seq[FullPackageTarget], printHeader: bool,
  printMode: bool, upgradeCount: int, noconfirm: bool, needed: bool, noaur: bool, build: bool):
  (int, seq[Installed], HashSet[string], seq[PackageInfo], seq[PackageInfo], seq[string]) =
  template errorResult: untyped = (1, newSeq[Installed](), initHashSet[string](),
    newSeq[PackageInfo](), newSeq[PackageInfo](), newSeq[string]())

  let (installed, checkAurUpgradeNames) = obtainInstalledWithAur(config)
  let checkAur = not noaur and checkAurUpgradeNames.len > 0 and upgradeCount > 0

  if not printMode and (checkAur or build) and printHeader:
    printColon(config.color, tr"Resolving build targets...")

  let upgradeRpcInfos = if checkAur: (block:
      if not printMode:
        echo(tr"checking AUR database for upgrades...")
      let (upgradeRpcInfos, rerrors) = getRpcPackageInfos(checkAurUpgradeNames,
        config.aurRepo, config.common.downloadTimeout, config.color)
      for e in rerrors: printError(config.color, e)
      upgradeRpcInfos)
    else:
      @[]

  let installedTable = installed.map(i => (i.name, i)).toTable
  let rpcAurTargets = fullTargets.filter(f => f.isAurTargetFull(config.aurRepo))

  let targetRpcInfos = collect(newSeq):
    for t in rpcAurTargets:
      for x in t.rpcInfo:
        x
  let targetRpcInfoNames = targetRpcInfos.map(i => i.name).toHashSet
  let rpcInfos = targetRpcInfos & upgradeRpcInfos.filter(i => not (i.name in targetRpcInfoNames))

  let (aurPkgInfos, additionalPkgInfos, aurPaths, upToDateNeeded, localIsNewerSeq, aperrors) =
    obtainAurPackageInfos(config, rpcInfos, rpcAurTargets, installedTable,
      printMode, noconfirm, needed, upgradeCount)
  for e in aperrors: printError(config.color, e)

  let upToDateNeededTable: Table[string, PackageReference] = upToDateNeeded.map(i => (i.name,
    (i.name, none(string), some((ConstraintOperation.eq, i.version, false))))).toTable
  let notFoundTargets = filterNotFoundSyncTargets(syncTargets,
    aurPkgInfos.map(p => p.rpc), upToDateNeededTable, config.aurRepo)

  if notFoundTargets.len > 0:
    clearPaths(config, aurPaths)
    printSyncNotFound(config, notFoundTargets)
    errorResult
  else:
    let fullTargets = mapAurTargets(syncTargets
      .filter(s => not (upToDateNeededTable.opt(s.target.reference.name)
      .map(r => s.target.reference.isProvidedBy(r, true)).get(false))),
      aurPkgInfos.map(p => p.rpc), config.aurRepo)
    let pacmanTargets = fullTargets.filter(f => not f.isAurTargetFull(config.aurRepo))
    let aurTargets = fullTargets.filter(f => f.isAurTargetFull(config.aurRepo))

    let (checkPacmanBuildPkgInfos, buildPkgInfos, buildUpToDateNeeded, buildPaths,
      obtainBuildErrorMessages) = obtainPacmanBuildTargets(config, pacmanTargets, installedTable,
      printMode, needed, build)

    if checkPacmanBuildPkgInfos and buildPkgInfos.len < pacmanTargets.len:
      clearPaths(config, buildPaths)
      clearPaths(config, aurPaths)
      for e in obtainBuildErrorMessages: printError(config.color, e)
      errorResult
    else:
      let pkgInfos = (buildPkgInfos & aurPkgInfos)
        .deduplicatePkgInfos(config, not printMode)
      let targetNamesSet = (pacmanTargets & aurTargets)
        .map(f => f.sync.target.reference.name).toHashSet
      let (finalPkgInfos, acceptedPkgInfos) = filterIgnoresAndConflicts(config, pkgInfos,
        targetNamesSet, installedTable, printMode, noconfirm)

      if not printMode:
        printAllWarnings(config, installed, rpcInfos,
          pkgInfos, acceptedPkgInfos, upToDateNeeded, buildUpToDateNeeded,
          localIsNewerSeq, targetNamesSet, upgradeCount, noaur)

      (0, installed, targetNamesSet, finalPkgInfos, additionalPkgInfos, buildPaths & aurPaths)

func assumeInstalled(args: seq[Argument]): seq[PackageReference] =
  args
    .filter(a => a.matchOption(%%%"assume-installed"))
    .map(a => a.value.get.parsePackageReference(false))
    .filter(r => r.constraint.isNone or
      r.constraint.unsafeGet.operation == ConstraintOperation.eq)

proc handleInstall(args: seq[Argument], config: Config, syncTargets: seq[SyncPackageTarget],
  fullTargets: seq[FullPackageTarget], upgradeCount: int, nodepsCount: int,
  wrapUpgrade: bool, noconfirm: bool, needed: bool, build: bool, noaur: bool): int =
  let pacmanTargets = fullTargets.filter(f => not f.isAurTargetFull(config.aurRepo))

  let workDirectPacmanTargets = if build: @[] else: pacmanTargets.map(f => $f.sync.target)

  # check for sysupgrade instead of upgradeCount since upgrade could be done before
  # and then removed from the list of arguments
  let (directCode, directSome) = if workDirectPacmanTargets.len > 0 or args.check(%%%"sysupgrade"):
      (pacmanRun(some config.sudoCommand, config.color, args.filter(arg => not arg.isTarget) &
        workDirectPacmanTargets.map(t => (t, none(string), ArgumentType.target))), true)
    else:
      (0, false)

  if directCode != 0:
    directCode
  else:
    let (resolveTargetsCode, installed, targetNamesSet, pkgInfos, additionalPkgInfos,
      initialPaths) = resolveBuildTargets(config, syncTargets, fullTargets,
      directSome or wrapUpgrade, false, upgradeCount, noconfirm, needed, noaur, build)

    if resolveTargetsCode != 0:
      removeTmpDirQuiet(config.tmpRootCurrent)
      resolveTargetsCode
    else:
      let assumeInstalled = args.assumeInstalled
      let skipDeps = assumeInstalled.len > 0 or nodepsCount > 0

      let (_, satisfied, additionalPacmanTargets, basePackages, dependencyPaths) =
        resolveDependencies(config, pkgInfos, additionalPkgInfos, false,
          nodepsCount, assumeInstalled, noaur)

      let confirmAndResolveCode = confirmViewAndImportKeys(config, basePackages, installed, noconfirm)
      let paths = initialPaths & dependencyPaths
      if confirmAndResolveCode != 0:
        clearPaths(config, paths, not config.keepBuildDirOnFailure)
        confirmAndResolveCode
      else:
        let explicitsNamesSet = installed.filter(i => i.explicit).map(i => i.name).toHashSet
        let depsNamesSet = installed.filter(i => not i.explicit).map(i => i.name).toHashSet
        let keepNames = explicitsNamesSet + depsNamesSet + targetNamesSet

        let explicits = if args.check(%%%"asexplicit"):
            targetNamesSet + explicitsNamesSet + depsNamesSet
          elif args.check(%%%"asdeps"):
            initHashSet[string]()
          else:
            explicitsNamesSet + (targetNamesSet - depsNamesSet)

        let commonArgs = args
          .keepOnlyOptions(commonOptions, transactionOptions, upgradeOptions)
          .filter(true, false, %%%"asdeps", %%%"asexplicit", %%%"needed")

        let (_, initialUnrequired, initialUnrequiredWithoutOptional, _) =
          withAlpmConfig(config, false, handle, dbs, errors):
          queryUnrequired(handle, true, true, keepNames)

        let additionalCode = if additionalPacmanTargets.len > 0: (block:
            printColon(config.color, tr"Installing build dependencies...")

            pacmanRun(some config.sudoCommand, config.color, commonArgs &
              ("S", none(string), ArgumentType.short) &
              ("needed", none(string), ArgumentType.long) &
              ("asdeps", none(string), ArgumentType.long) &
              additionalPacmanTargets.map(t => (t, none(string), ArgumentType.target))))
          else:
            0

        if additionalCode != 0:
          clearPaths(config, paths, not config.keepBuildDirOnFailure)
          additionalCode
        else:
          if basePackages.len > 0:
            # check all pacman dependencies were installed
            let unsatisfied = if nodepsCount <= 1:
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
              clearPaths(config, paths, not config.keepBuildDirOnFailure)
              printUnsatisfied(config, satisfied, unsatisfied)
              1
            else:
              let (confFileOpt, confError) = resolveMakepkgConf()
              if confFileOpt.isNone and confError.len > 0:
                printError(config.color, confError)
                clearPaths(config, paths, true)
                return 1
              let confFile = confFileOpt.unsafeGet.string
              let effectivePkgdest = resolveEffectivePkgdest(confFile)

              var installedAsPairs: seq[(string, string)]
              var code = 0
              var lastIndex = -1
              var keepBuiltArtifacts = false
              for index in 0 ..< basePackages.len:
                let installResult = installGroupFromSources(config, commonArgs,
                  basePackages[index], explicits, skipDeps, noconfirm,
                  confFile, effectivePkgdest)
                installedAsPairs &= installResult.installedAs
                code = installResult.code
                keepBuiltArtifacts = installResult.keepBuiltArtifacts
                lastIndex = index
                if code != 0:
                  break
              let installedAs = installedAsPairs.toTable

              if code != 0 and lastIndex < basePackages.len - 1:
                printWarning(config.color, tr"installation aborted")
              clearPaths(config, paths, tmpDir = not keepBuiltArtifacts)

              let newKeepNames = keepNames.map(n => installedAs.opt(n).get(n))
              let (_, finalUnrequired, finalUnrequiredWithoutOptional, _) =
                withAlpmConfig(config, false, handle, dbs, errors):
                queryUnrequired(handle, true, true, newKeepNames)

              let unrequired = finalUnrequired - initialUnrequired
              let unrequiredOptional = finalUnrequiredWithoutOptional -
                initialUnrequiredWithoutOptional - unrequired

              let removeCode = removeBuildDependencies(config,
                commonArgs, unrequired, unrequiredOptional)
              if removeCode != 0:
                removeCode
              else:
                code
          else:
            let aurTargets = fullTargets.filter(f => f.isAurTargetFull(config.aurRepo))
            if (not noaur and (aurTargets.len > 0 or upgradeCount > 0)) or build:
              echo(trp(" there is nothing to do\n"))
            clearPaths(config, paths, true)
            0

proc handlePrint(args: seq[Argument], config: Config, syncTargets: seq[SyncPackageTarget],
  fullTargets: seq[FullPackageTarget], upgradeCount: int, nodepsCount: int,
  needed: bool, build: bool, noaur: bool, printFormat: string): int =
  let pacmanTargets = fullTargets.filter(f => not f.isAurTargetFull(config.aurRepo))
  let directPacmanTargets = pacmanTargets.map(f => $f.sync.target)

  let (resolveTargetsCode, _, _, pkgInfos, additionalPkgInfos, _) = resolveBuildTargets(config,
    syncTargets, fullTargets, false, true, upgradeCount, true, needed, noaur, build)

  if resolveTargetsCode != 0:
    resolveTargetsCode
  else:
    let (resolveSuccess, _, additionalPacmanTargets, basePackages, _) =
      resolveDependencies(config, pkgInfos, additionalPkgInfos, true,
        nodepsCount, args.assumeInstalled, noaur)

    let code = if directPacmanTargets.len > 0 or
      additionalPacmanTargets.len > 0 or upgradeCount > 0: (block:
        let callPacmanTargets = if resolveSuccess:
            directPacmanTargets & additionalPacmanTargets
          else:
            directPacmanTargets

        # workaround for a strange nim bug, callPacmanTargets.map(...) breaks main.nim
        var callArguments = newSeq[Argument]()
        for t in callPacmanTargets:
          callArguments &= (t, none(string), ArgumentType.target)

        let code = pacmanRun(noPrefix, config.color,
          args.filter(arg => not arg.isTarget) & callArguments)

        if resolveSuccess:
          code
        else:
          1)
      else:
        0

    if code == 0:
      proc printWithFormat(pkgInfo: PackageInfo) =
        echo(printFormat
          .replace("%n", pkgInfo.rpc.name)
          .replace("%v", pkgInfo.rpc.version)
          .replace("%r", config.aurRepo)
          .replace("%s", "0")
          .replace("%l", pkgInfo.rpc.gitUrl))

      for installGroup in basePackages:
        for pkgInfos in installGroup:
          for pkgInfo in pkgInfos:
            printWithFormat(pkgInfo)
      0
    else:
      code

proc resolveAurTargets(config: Config, targets: seq[PackageTarget], printMode: bool, noaur: bool,
  build: bool): (int, seq[SyncPackageTarget], seq[FullPackageTarget]) =
  let (syncTargets, checkAurTargetNames) = withAlpmConfig(config, true, handle, dbs, errors):
    for e in errors: printError(config.color, e)
    findSyncTargets(handle, dbs, targets, config.aurRepo, not build, not build, true)

  let rpcInfos = if not noaur and checkAurTargetNames.len > 0: (block:
      if not printMode:
        printColon(config.color, tr"Resolving build targets...")
        echo(tr"checking AUR database for targets...")

      let (rpcInfos, rerrors) = getRpcPackageInfos(checkAurTargetNames,
        config.aurRepo, config.common.downloadTimeout, config.color)
      for e in rerrors: printError(config.color, e)
      rpcInfos)
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

proc handleSyncInstall*(args: seq[Argument], config: Config): int =
  let printModeArg = args.check(%%%"print")
  let printModeFormat = args.filter(arg => arg.matchOption(%%%"print-format")).optLast
  let printFormat = if printModeArg or printModeFormat.isSome:
      some(printModeFormat.map(arg => arg.value.get).get("%l"))
    else:
      none(string)

  let targets = args.packageTargets(false)
  let wrapUpgrade = targets.len == 0

  let (refreshUpgradeCode, callArgs) = if wrapUpgrade and printFormat.isNone:
      checkAndRefreshUpgrade(config.sudoCommand, config.color, args)
    else:
      checkAndRefresh(config.sudoCommand, config.color, args)

  if refreshUpgradeCode != 0:
    refreshUpgradeCode
  else:
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
        code
      elif printFormat.isSome:
        handlePrint(pacmanArgs, config, syncTargets, fullTargets,
          upgradeCount, nodepsCount, needed, build, noaur, printFormat.unsafeGet)
      else:
        handleInstall(pacmanArgs, config, syncTargets, fullTargets,
          upgradeCount, nodepsCount, wrapUpgrade, noconfirm, needed, build, noaur)
