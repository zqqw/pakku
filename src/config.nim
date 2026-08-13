import
  std/[options, posix, re, sequtils, sets, strutils, sugar, tables],
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

proc readConfigFile*(configFile: string):
  (OrderedTable[string, ref Table[string, string]], bool) =
  var file: File
  var table = initOrderedTable[string, ref Table[string, string]]()
  var category: ref Table[string, string]
  var currentCategory = ""

  let wasError = if file.open(configFile):
      try:
        var matches: array[2, string]

        while true:
          let line = readLine(file).strip(leading = true, trailing = true)
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

proc obtainConfig*(config: PacmanConfig): Config =
  ## Builds the pakku runtime configuration by layering the pacman config with
  ## user-specified options from the pakku.conf options section.
  let (configTable, _) = readConfigFile(SysConfDir & "/pakku.conf")
  let options = configTable.opt("options").map(t => t[]).get(initTable[string, string]())

  let root = config.pacmanRootRel.extendRel(config.sysrootOption)
  let db = config.pacmanDbRel.extendRel(config.sysrootOption)
  let cache = config.pacmanCacheRel.extendRel(config.sysrootOption)
  let color = config.colorMode.get

  proc handleDirPattern(dirPattern: string, user: User): string =
    dirPattern
      .replace("${UID}", $user.uid)
      .replace("${USER}", user.name)
      .replace("${HOME}", user.home)
      .replace("$$", "$")

  proc obtainUserCacheDir(user: User): string =
    options.opt("UserCacheDir").get("${HOME}/.cache/pakku").handleDirPattern(user)

  proc obtainTmpDir(user: User): string =
    options.opt("TmpDir").get("/tmp/pakku-${USER}").handleDirPattern(user)

  let
    initialOrCurrentUser = initialUser.get(currentUser)
    userCacheInitial = obtainUserCacheDir(initialOrCurrentUser)
    userCacheCurrent = obtainUserCacheDir(currentUser)
    tmpRootInitial = obtainTmpDir(initialOrCurrentUser)
    tmpRootCurrent = obtainTmpDir(currentUser)
    aurRepo = options.opt("AurRepo").get("aur")

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
    packageOutputDir: options.opt("PackageOutputDir").get("").handleDirPattern(initialOrCurrentUser),
    color: color,
    aurRepo: aurRepo,
    aurComments: options.hasKey("AurComments"),
    checkIgnored: options.hasKey("CheckIgnored"),
    ignoreArch: options.hasKey("IgnoreArch"),
    printAurNotFound: options.hasKey("PrintAurNotFound"),
    printLocalIsNewer: options.hasKey("PrintLocalIsNewer"),
    sudoExec: options.hasKey("SudoExec"),
    viewNoDefault: options.hasKey("ViewNoDefault"),
    keepBuildDirOnFailure: options.hasKey("KeepBuildDirOnFailure"),
    keepBuiltPackagesOnFailure: options.hasKey("KeepBuiltPackagesOnFailure"),
    cleanupAfterInstall: toSeq(enumerate[CleanupPolicy]())
      .filterIt(some($it) == options.opt("CleanupAfterInstall"))
      .optLast.get(CleanupPolicy.full),
    preserveBuilt: toSeq(enumerate[PreserveBuilt]())
      .filterIt(some($it) == options.opt("PreserveBuilt"))
      .optLast.get(PreserveBuilt.disabled),
    preBuildCommand: options.opt("PreBuildCommand"),
    sudoCommand: options.opt("PreferredSudoCommand").getSudoPrefix(),
  )

template withAlpmConfig*(config: Config, passDbs: bool,
  handle: untyped, alpmDbs: untyped, errors: untyped, body: untyped): untyped =
  withAlpm(cstring(config.root), config.db, if passDbs: config.common.dbs
    else: newSeq[string](), cstring(config.common.arch), handle, alpmDbs, errors, body)
