import
  std/[options, posix, re, sets, strutils, sugar, tables],
  utils
when not declared(system.stdout): import std/syncio

type
  ColorMode* {.pure.} = enum
    colorNever = "never",
    colorAuto = "auto",
    colorAlways = "always"

  PreserveBuilt* {.pure.} = enum
    internal = "Internal",
    user = "User",
    pkgdest = "Pkgdest",
    disabled = "Disabled"

  CleanupPolicy* {.pure.} = enum
    full = "Full",
    worktree = "Worktree",
    none = "None"

  OptionKey {.pure.} = enum
    ## Every key pakku.conf accepts, spelled as pakku.conf(5) documents it.
    userCacheDir = "UserCacheDir",
    tmpDir = "TmpDir",
    packageOutputDir = "PackageOutputDir",
    aurRepo = "AurRepo",
    preBuildCommand = "PreBuildCommand",
    preferredSudoCommand = "PreferredSudoCommand",
    cleanupAfterInstall = "CleanupAfterInstall",
    preserveBuilt = "PreserveBuilt",
    aurComments = "AurComments",
    checkIgnored = "CheckIgnored",
    ignoreArch = "IgnoreArch",
    printAurNotFound = "PrintAurNotFound",
    printLocalIsNewer = "PrintLocalIsNewer",
    sudoExec = "SudoExec",
    viewNoDefault = "ViewNoDefault",
    keepBuildDirOnFailure = "KeepBuildDirOnFailure",
    keepBuiltPackagesOnFailure = "KeepBuiltPackagesOnFailure"

  PakkuOptions = object
    ## Accepted options from pakku.conf: the presence-based ones that are set
    ## truthy, the raw value of each string-valued one, and the messages for
    ## whatever was rejected. Parsing fills this in one pass, so callers read
    ## exactly the value that was checked.
    flags: set[OptionKey]
    values: array[OptionKey, Option[string]]
    errors: seq[string]

  CommonConfig* = object
    dbs*: seq[string]
    arch*: string
    debug*: bool
    progressBar*: bool = true
    chomp*: bool
    verbosePkgLists*: bool
    downloadTimeout*: bool = true
    pgpKeyserver*: Option[string]
    defaultRoot*: bool
    ignorePkgs*: HashSet[string]
    ignoreGroups*: HashSet[string]

  PacmanConfig* = object
    common*: CommonConfig
    sysrootOption*: Option[string]
    rootRelOption*: Option[string]
    dbRelOption*: Option[string]
    cacheRelOption*: Option[string]
    gpgRelOption*: Option[string]
    colorMode*: ColorMode = colorNever

  Config* = object
    common*: CommonConfig
    root*: string
    db*: string
    cache*: string
    userCacheInitial*: string
    userCacheCurrent*: string
    tmpRootInitial*: string
    tmpRootCurrent*: string
    packageOutputDir*: string
    color*: bool
    aurRepo*: string = "aur"
    aurComments*: bool
    checkIgnored*: bool
    ignoreArch*: bool
    printAurNotFound*: bool
    printLocalIsNewer*: bool
    sudoExec*: bool
    viewNoDefault*: bool
    keepBuildDirOnFailure*: bool
    keepBuiltPackagesOnFailure*: bool
    cleanupAfterInstall*: CleanupPolicy = full
    preserveBuilt*: PreserveBuilt = disabled
    preBuildCommand*: Option[string]
    sudoCommand*: seq[string]

func stripComment(line: string; enabled: bool): string =
  ## Drops a trailing comment when `enabled`. A '#' starts a comment only at the
  ## beginning of the line or after whitespace, so values that legitimately
  ## contain '#' (URLs with fragments, paths) survive. pacman.conf keeps its own
  ## semantics: it is parsed with this disabled.
  if not enabled:
    return line
  for index, character in line:
    if character == '#' and (index == 0 or line[index - 1] in Whitespace):
      return line[0 ..< index]
  line

proc readConfigFile*(configFile: string; inlineComments = false):
  (OrderedTable[string, ref Table[string, string]], bool) =
  var file: File
  var table = initOrderedTable[string, ref Table[string, string]]()
  var category: ref Table[string, string]
  var currentCategory = ""

  let wasError = if file.open(configFile):
      try:
        var matches: array[2, string]

        while true:
          let line = stripComment(readLine(file), inlineComments)
            .strip(leading = true, trailing = true)
          if line.len > 0 and line[0] != '#':
            if line.match(re"\[(.*)\]", matches):
              currentCategory = matches[0]
              if table.hasKey(currentCategory):
                category = table[currentCategory]
              else:
                category = newTable[string, string]()
                table[currentCategory] = category
            elif currentCategory.len > 0:
              if line.match(re"(\w+)\ *=\ *(.*)", matches):
                if matches[0] == "IgnorePkg" or matches[0] == "HoldPkg":
                  if category.hasKey(matches[0]):
                    if not isEmptyOrWhitespace(matches[1]): # stop empty lines adding spaces
                      category[matches[0]] = category[matches[0]] & " " & matches[1]
                  else:
                    if not isEmptyOrWhitespace(matches[1]):
                      category[matches[0]] = matches[1]
                else:
                  category[matches[0]]= matches[1]
              else:
                category[line]=""

        false
      except EOFError:
        false
      except IOError:
        true
      finally:
        file.close()
    else:
      true

  (table, wasError)

const flagKeys: set[OptionKey] = {
  OptionKey.aurComments, OptionKey.checkIgnored, OptionKey.ignoreArch,
  OptionKey.printAurNotFound, OptionKey.printLocalIsNewer, OptionKey.sudoExec,
  OptionKey.viewNoDefault, OptionKey.keepBuildDirOnFailure,
  OptionKey.keepBuiltPackagesOnFailure}

func enumFromString[T: enum](value: string): Option[T] =
  ## `strutils.parseEnum` cannot express an absent member: it either raises or
  ## falls back to a caller-supplied default. It also folds case and drops
  ## underscores - `FULL` and `Disabled_` match while the lowercase spelling of
  ## a value does not - so it would accept spellings pakku.conf(5) never lists.
  ## Comparing `$` keeps the accepted values exactly the documented ones.
  for item in T:
    if $item == value:
      return some(item)
  none(T)

func booleanValue(value: string): Option[bool] =
  ## A flag written without a value is enabled, so an empty value means true.
  ## The false forms must disable the option rather than leave it enabled.
  ## `strutils.parseBool` raises instead of returning an option and also accepts
  ## `on`/`off`/`y`/`n`, which pakku.conf(5) does not list.
  case value
    of "", "true", "yes", "1": some(true)
    of "false", "no", "0": some(false)
    else: none(bool)

func valueValid(key: OptionKey; value: string): bool =
  ## Paths and commands take any string. The enum-valued options must name a
  ## member as spelled in the manual.
  case key
    of OptionKey.cleanupAfterInstall: enumFromString[CleanupPolicy](value).isSome
    of OptionKey.preserveBuilt: enumFromString[PreserveBuilt](value).isSome
    else: true

func invalidValueMessage(value: string; key: OptionKey;
    configFile: string): string =
  tr("invalid value '$#' for '$#'\n") % [value, $key, configFile]

func parseOptions(raw: Table[string, string];
    configFile: string): PakkuOptions =
  ## This does not let an unknown value fall back to the default.
  for key, value in raw.pairs:
    let option = enumFromString[OptionKey](key)
    if option.isNone:
      result.errors.add(tr("unknown option '$#' in '$#'\n") % [key, configFile])
      continue
    let name = option.unsafeGet
    if name in flagKeys:
      let flag = booleanValue(value)
      if flag.isNone:
        result.errors.add(invalidValueMessage(value, name, configFile))
      elif flag.unsafeGet:
        result.flags.incl name
    elif name.valueValid(value):
      result.values[name] = some(value)
    else:
      result.errors.add(invalidValueMessage(value, name, configFile))

func contains(options: PakkuOptions; key: OptionKey): bool =
  ## A presence-based option is enabled when the file set it truthy.
  key in options.flags

func `[]`(options: PakkuOptions; key: OptionKey): Option[string] =
  options.values[key]

func get[T: enum](options: PakkuOptions; key: OptionKey; default: T): T =
  ## An absent enum-valued option resolves to `default`. An invalid one never
  ## lands here because `parseOptions` reports it instead of storing it.
  enumFromString[T](options.values[key].get("")).get(default)

proc ignored*(config: Config, name: string, groups: openArray[string]): bool =
  name in config.common.ignorePkgs or (config.common.ignoreGroups * groups.toHashSet).len > 0

proc get*(colorMode: ColorMode): bool =
  case colorMode:
    of ColorMode.colorNever: false
    of ColorMode.colorAlways: true
    of ColorMode.colorAuto: isatty(1) == 1

proc pacmanRootRel*(config: PacmanConfig): string =
  config.rootRelOption.get("/")

proc pacmanDbRel*(config: PacmanConfig): string =
  if config.dbRelOption.isSome:
    config.dbRelOption.unsafeGet
  else:
    let root = config.pacmanRootRel
    let workRoot = if root == "/": "" else: root
    workRoot & LocalStateDir & "/lib/pacman/"

proc pacmanCacheRel*(config: PacmanConfig): string =
  config.cacheRelOption.get(LocalStateDir & "/cache/pacman/pkg")

proc simplifyConfigPath(path: string): string =
  if path.find("//") >= 0:
    simplifyConfigPath(path.replace("//", "/"))
  else:
    path

proc extendRel*(pathRel: string, sysroot: Option[string]): string =
  sysroot.map(s => (s & "/" & pathRel).simplifyConfigPath).get(pathRel)

proc obtainConfig*(config: PacmanConfig;
    configFile = SysConfDir & "/pakku.conf"): Config =
  ## Builds the pakku runtime configuration by layering the pacman config with
  ## user-specified options from the pakku.conf options section.
  ## `configFile` used by tests
  let
    (configTable, _) = readConfigFile(configFile, inlineComments = true)
    rawOptions = configTable.opt("options")
      .map(t => t[]).get(initTable[string, string]())

  let
    root = config.pacmanRootRel.extendRel(config.sysrootOption)
    db = config.pacmanDbRel.extendRel(config.sysrootOption)
    cache = config.pacmanCacheRel.extendRel(config.sysrootOption)
    color = config.colorMode.get

  let options = parseOptions(rawOptions, configFile)
  if options.errors.len > 0:
    raise commandError(options.errors.join, colorNeeded = some(color))

  proc handleDirPattern(dirPattern: string, user: User): string =
    dirPattern
      .replace("${UID}", $user.uid)
      .replace("${USER}", user.name)
      .replace("${HOME}", user.home)
      .replace("$$", "$")

  proc obtainUserCacheDir(user: User): string =
    options[OptionKey.userCacheDir]
      .get("${HOME}/.cache/pakku").handleDirPattern(user)

  proc obtainTmpDir(user: User): string =
    options[OptionKey.tmpDir]
      .get("/tmp/pakku-${USER}").handleDirPattern(user)

  let
    initialOrCurrentUser = initialUser.get(currentUser)
    userCacheInitial = obtainUserCacheDir(initialOrCurrentUser)
    userCacheCurrent = obtainUserCacheDir(currentUser)
    tmpRootInitial = obtainTmpDir(initialOrCurrentUser)
    tmpRootCurrent = obtainTmpDir(currentUser)
    aurRepo = options[OptionKey.aurRepo].get("aur")

  if config.common.dbs.find(aurRepo) >= 0:
    raise commandError(tr"repo '$#' can not be used as fake AUR repository" % [aurRepo],
      colorNeeded = some(color))

  if aurRepo.find('/') >= 0:
    raise commandError(trp("could not register '%s' database (%s)\n") %
      [aurRepo, tra"wrong or NULL argument passed"], colorNeeded = some(color))

  let common = block:
    var c = config.common
    c.defaultRoot = c.defaultRoot and config.sysrootOption.isNone
    c

  Config(
    common: common,
    root: root,
    db: db,
    cache: cache,
    userCacheInitial: userCacheInitial,
    userCacheCurrent: userCacheCurrent,
    tmpRootInitial: tmpRootInitial,
    tmpRootCurrent: tmpRootCurrent,
    packageOutputDir: options[OptionKey.packageOutputDir]
      .get("").handleDirPattern(initialOrCurrentUser),
    color: color,
    aurRepo: aurRepo,
    aurComments: OptionKey.aurComments in options,
    checkIgnored: OptionKey.checkIgnored in options,
    ignoreArch: OptionKey.ignoreArch in options,
    printAurNotFound: OptionKey.printAurNotFound in options,
    printLocalIsNewer: OptionKey.printLocalIsNewer in options,
    sudoExec: OptionKey.sudoExec in options,
    viewNoDefault: OptionKey.viewNoDefault in options,
    keepBuildDirOnFailure: OptionKey.keepBuildDirOnFailure in options,
    keepBuiltPackagesOnFailure: OptionKey.keepBuiltPackagesOnFailure in options,
    cleanupAfterInstall: options.get(OptionKey.cleanupAfterInstall,
      CleanupPolicy.full),
    preserveBuilt: options.get(OptionKey.preserveBuilt, PreserveBuilt.disabled),
    preBuildCommand: options[OptionKey.preBuildCommand],
    sudoCommand: options[OptionKey.preferredSudoCommand].getSudoPrefix(),
  )

template withAlpmConfig*(config: Config, passDbs: bool,
  handle: untyped, alpmDbs: untyped, errors: untyped, body: untyped): untyped =
  withAlpm(cstring(config.root), config.db, if passDbs: config.common.dbs
    else: newSeq[string](), cstring(config.common.arch), handle, alpmDbs, errors, body)
