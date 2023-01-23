import
  macros, options, posix, sequtils, sets, strutils, sugar, tables,
  args, config, utils
when not declared(system.stdout): import std/syncio

type
  OpGroup* {.pure.} = enum
    syncInstall, syncSearch, syncQuery, localQuery

  OperationType* {.pure.} = enum
    unknown, invalid, database, files, query,
    remove, sync, deptest, upgrade

  Operation* = tuple[
    pair: OptionPair,
    otype: OperationType
  ]

  CommandOption* = tuple[
    pair: OptionPair,
    hasParam: bool,
    extension: bool,
    groups: set[OpGroup]
  ]

  ConflictingOptions* = tuple[
    left: string,
    right: seq[string]
  ]

proc calculateOptionsWithParameter(opts: seq[CommandOption]): seq[OptionKey] {.compileTime.} =
  proc commandToSeq(co: CommandOption): seq[OptionKey] {.compileTime.} =
    if co.hasParam:
      co.pair.short
        .map(s => @[(s, false), (co.pair.long, true)])
        .get(@[(co.pair.long, true)])
    else:
      @[]

  collect(newSeq):
    for y in opts:
      for x in commandToSeq(y):
        x

proc o(long: string): CommandOption {.compileTime.} =
  ((none(string), long), false, false, {})

proc o(short: string, long: string): CommandOption {.compileTime.} =
  ((some(short), long), false, false, {})

proc `^`(opt: CommandOption): CommandOption {.compileTime.} =
  (opt.pair, not opt.hasParam, opt.extension, opt.groups)

proc `$`(opt: CommandOption): CommandOption {.compileTime.} =
  (opt.pair, opt.hasParam, not opt.extension, opt.groups)

proc `+`(opt: CommandOption, groups: set[OpGroup]): CommandOption {.compileTime.} =
  (opt.pair, opt.hasParam, opt.extension, opt.groups + groups)

macro g(gls: varargs[untyped]): untyped =
  result = newNimNode(nnkCurly, gls)
  for gl in gls:
    add(result, newDotExpr(ident("OpGroup"), gl))

const
  operations*: seq[Operation] = @[
    ((some("D"), "database"), OperationType.database),
    ((some("F"), "files"), OperationType.files),
    ((some("Q"), "query"), OperationType.query),
    ((some("R"), "remove"), OperationType.remove),
    ((some("S"), "sync"), OperationType.sync),
    ((some("T"), "deptest"), OperationType.deptest),
    ((some("U"), "upgrade"), OperationType.upgrade)
  ]

  commonOptions*: seq[CommandOption] = @[
    o("h", "help"),
    ^o("b", "dbpath"),
    ^o("r", "root"),
    o("v", "verbose"),
    ^o("arch"),
    ^o("cachedir"),
    ^o("color"),
    ^o("config"),
    o("debug"),
    o("disable-download-timeout"),
    ^o("gpgdir"),
    ^o("hookdir"),
    ^o("logfile"),
    o("noconfirm"),
    o("confirm"),
    ^o("sysroot"),
    ^o("ask")
  ]

  transactionOptions*: seq[CommandOption] = @[
    o("d", "nodeps"),
    ^o("assume-installed"),
    o("dbonly"),
    o("noprogressbar"),
    o("noscriptlet"),
    o("p", "print"),
    ^o("print-format")
  ]

  upgradeOptions*: seq[CommandOption] = @[
    o("force"),
    o("asdeps"),
    o("asexplicit"),
    ^o("ignore"),
    ^o("ignoregroup"),
    o("needed"),
    ^o("overwrite")
  ]

  queryOptions*: seq[CommandOption] = @[
    o("c", "changelog") + g(localQuery),
    o("d", "deps") + g(localQuery),
    o("e", "explicit") + g(localQuery),
    o("g", "groups"),
    o("i", "info") + g(localQuery),
    o("k", "check") + g(localQuery),
    o("l", "list") + g(localQuery),
    o("m", "foreign") + g(localQuery),
    o("n", "native") + g(localQuery),
    o("o", "owns"),
    o("p", "file"),
    o("q", "quiet") + g(localQuery),
    o("s", "search"),
    o("t", "unrequired") + g(localQuery),
    o("u", "upgrades") + g(localQuery)
  ]

  removeOptions*: seq[CommandOption] = @[
    o("c", "cascade"),
    o("n", "nosave"),
    o("s", "recursive"),
    o("u", "unneeded")
  ]

  syncOptions*: seq[CommandOption] = @[
    o("c", "clean"),
    o("g", "groups"),
    o("i", "info") + g(syncInstall, syncQuery),
    o("l", "list"),
    o("q", "quiet") + g(syncInstall, syncSearch, syncQuery),
    o("s", "search") + g(syncSearch),
    o("u", "sysupgrade") + g(syncInstall),
    o("w", "downloadonly"),
    o("y", "refresh") + g(syncInstall, syncSearch, syncQuery),
    $o("n", "build") + g(syncInstall),
    $(^o("keyserver")) + g(syncInstall),
    $o("noaur") + g(syncInstall),
    $o("z", "source") + g()
  ]

  databaseOptions*: seq[CommandOption] = @[
    o("asdeps"),
    o("asexplicit"),
    o("k", "check")
  ]

  filesOptions*: seq[CommandOption] = @[
    o("y", "refresh"),
    o("l", "list"),
    o("s", "search"),
    o("x", "regex"),
    o("o", "owns"),
    o("q", "quiet"),
    o("machinereadable")
  ]

  allOptions* = commonOptions & transactionOptions &
    upgradeOptions & queryOptions & removeOptions & syncOptions &
    databaseOptions & filesOptions

  optionsWithParameter*: HashSet[OptionKey] =
    calculateOptionsWithParameter(allOptions).toHashSet

  syncConflictingOptions*: seq[ConflictingOptions] = @[
    ("asdeps", @["asexplicit"]),
    ("build", @["clean", "groups", "info", "list", "search", "sysupgrade", "downloadonly"]),
    ("keyserver", @["clean", "groups", "info", "list", "search"]),
    ("source", @["clean", "groups", "info", "list", "search", "sysupgrade", "downloadonly",
      "build", "keyserver", "noaur"])
  ]

  allConflictingOptions = syncConflictingOptions

  noPrefix* = none seq[string]

proc getOperation*(args: seq[Argument]): OperationType =
  let matchedOps = args
    .map(arg => operations
      .filter(o => (arg.isShort and some(arg.key) == o.pair.short) or
        (arg.isLong and arg.key == o.pair.long)))
    .filter(ops => ops.len > 0)

  if matchedOps.len == 0:
    OperationType.unknown
  elif matchedOps.len == 1:
    matchedOps[0][0].otype
  else:
    OperationType.invalid

proc filterOptions*(args: seq[Argument], removeMatches: bool, keepTargets: bool,
  includeOperations: bool, opts: varargs[seq[CommandOption]]): seq[Argument] =
  let optsSeq = @opts
  let optsPairSeq = collect(newSeq):
    for y in optsSeq:
      for x in y:
        x.pair

  let work = if includeOperations:
      (optsPairSeq & operations.map(o => o.pair))
    else:
      optsPairSeq

  args.filter(removeMatches, keepTargets, work)

template removeMatchOptions*(args: seq[Argument],
  opts: varargs[seq[CommandOption]]): seq[Argument] =
  filterOptions(args, true, true, true, opts)

template keepOnlyOptions*(args: seq[Argument],
  opts: varargs[seq[CommandOption]]): seq[Argument] =
  filterOptions(args, false, false, false, opts)

proc checkValid*(args: seq[Argument], opts: varargs[seq[CommandOption]]): bool =
  filterOptions(args, true, false, true, opts).len == 0

proc checkOpGroup*(args: seq[Argument], group: OpGroup): bool =
  let toCheck = allOptions
    .filter(o => group in o.groups)
    .map(o => o.pair)

  args.whitelisted(toCheck)

proc `%%%`*(long: string): OptionPair =
  allOptions.filter(o => o.pair.long == long)[0].pair

proc filterExtensions*(args: seq[Argument], removeMatches: bool, keepTargets: bool,
  opts: varargs[seq[CommandOption]]): seq[Argument] =
  let optsSeq = @opts
  let optsFilter = if removeMatches:
      collect(newSeq):
        for y in optsSeq:
          for x in y:
            x
    else: (block:
      let pairs = collect(initHashSet):
        for y in optsSeq:
          for x in y:
            {x.pair}
      collect(newSeq):
        for x in allOptions:
          if not (x.pair in pairs):
            x
      )
  let argsSeq = collect(newSeq):
    for x in optsFilter:
      if x.extension:
        x.pair
  args.filter(removeMatches,keepTargets,argsSeq)
proc obtainConflictsPairs(conflicts: seq[ConflictingOptions]): Table[string, seq[OptionPair]] =
  let all = collect(newSeq):
    for y in conflicts:
      for x in (y.left & y.right):
        x
  all.map(c => (c, allOptions.filter(o => o.pair.long == c)
    .map(o => o.pair).deduplicate)).toTable

static:
  # conflicting options test
  for name, pairs in allConflictingOptions.obtainConflictsPairs:
    if pairs.len != 1:
      raise newException(CatchableError,
        "invalid conflicts definition: " & name & " " & $pairs)

proc checkConflicts*(args: seq[Argument],
  conflicts: seq[ConflictingOptions]): Option[(string, string)] =
  let table = conflicts.obtainConflictsPairs
  template full(s: string): OptionPair = table[s][0]

  when NimVersion >= "1.3.5":
    optFirst:
      collect(newSeq):
        for c in conflicts:
          if args.check(c.left.full):
            for w in c.right:
              if args.check(w.full):
                (c.left,w)
  else:
    optFirst:
      var tmp = newSeq[(string,string)]()
      for c in conflicts:
        if args.check(c.left.full):
          for w in c.right:
            if args.check(w.full):
              tmp.add((c.left,w))
      tmp

proc pacmanParams*(color: bool, args: varargs[Argument]): seq[string] =
  let colorStr = if color: "always" else: "never"
  let argsSeq = ("color", some(colorStr), ArgumentType.long) &
    @args.filter(arg => not arg.matchOption(%%%"color"))
  collect(newSeq):
    for y in argsSeq:
      for x in y.collectArg:
        x

proc pacmanExecInternal(prefix: Option[seq[string]], params: varargs[string]): int =
  var cmd = newSeq[string]()
  if prefix.isSome:
    cmd.add prefix.get()
  cmd.add pacmanCmd
  execResult(cmd & @params)

proc pacmanExec*(prefix: Option[seq[string]], color: bool, args: varargs[Argument]): int =
  let params = pacmanParams(color, args)
  if prefix.isSome() and getuid() != 0:
    pacmanExecInternal(prefix, params)
  else:
    pacmanExecInternal(noPrefix, params)

proc pacmanRun*(prefix: Option[seq[string]], color: bool, args: varargs[Argument]): int =
  let argsSeq = @args
  forkWait(() => pacmanExec(prefix, color, argsSeq))

proc pacmanValidateAndThrow(args: varargs[tuple[arg: Argument, pass: bool]]): void =
  let argsSeq = @args
  when NimVersion >= "1.3.5":
    let collectedArgs = collect(newSeq):
      for y in argsSeq:
        if y.pass:
          for x in y.arg.collectArg:
            x
  else:
    let collectedArgs = block:
      var tmp = newSeq[string]()
      for y in argsSeq:
       if y.pass:
         for x in y.arg.collectArg:
           tmp.add(x)
      tmp
  let code = forkWait(() => pacmanExecInternal(noPrefix, "-T" & collectedArgs))
  if code != 0:
    raise haltError(code)

proc getMachineName: Option[string] =
  var utsname: Utsname
  let length = if uname(utsname) == 0: utsname.machine.find('\0') else: -1
  if length > 0: some(utsname.machine.toString(some(length))) else: none(string)

proc createConfigFromTable(table: Table[string, string], dbs: seq[string]): PacmanConfig =
  let rootRel = table.opt("RootDir")
  let dbRel = table.opt("DBPath")
  let cacheRel = table.opt("CacheDir")
  let gpgRel = table.opt("GPGDir")
  let color = if table.hasKey("Color"): ColorMode.colorAuto else: ColorMode.colorNever
  let chomp = table.hasKey("ILoveCandy")
  let verbosePkgLists = table.hasKey("VerbosePkgLists")
  let downloadTimeout = not table.hasKey("DisableDownloadTimeout")
  let arch = table.opt("Architecture").get("auto")
  let ignorePkgs = table.opt("IgnorePkg").get("").splitWhitespace.toHashSet
  let ignoreGroups = table.opt("IgnoreGroup").get("").splitWhitespace.toHashSet

  let archFinal = if arch.len == 0 or arch == "auto": getMachineName().get(arch) else: arch
  if archFinal.len == 0 or archFinal == "auto":
    raise commandError(tr"can not get the architecture",
      colorNeeded = some(color.get))

  ((dbs, archFinal, false, true, chomp, verbosePkgLists, downloadTimeout, none(string), true,
    ignorePkgs, ignoreGroups), none(string), rootRel, dbRel, cacheRel, gpgRel, color)

proc obtainPacmanConfig*(args: seq[Argument]): PacmanConfig =
  proc getAll(pair: OptionPair): seq[string] =
    args.filter(arg => arg.matchOption(pair)).map(arg => arg.value.get)

  let sysroot = args.filter(a => a.matchOption(%%%"sysroot")).optFirst.map(a => a.value).flatten

  let configFileRel = getAll(%%%"config").optLast.get(sysConfDir & "/pacman.conf")
  let (configTable, wasError) = readConfigFile(configFileRel.extendRel(sysroot))

  let options = configTable.opt("options").map(t => t[]).get(initTable[string, string]())
  let dbs = toSeq(configTable.keys).filter(k => k != "options")
  let defaultConfig = createConfigFromTable(options, dbs)

  if wasError:
    pacmanValidateAndThrow((("sysroot", sysroot, ArgumentType.long), sysroot.isSome),
      (("config", some(configFileRel), ArgumentType.long), true))
    raise haltError(1)

  proc getColor(color: string): ColorMode =
    let colors = toSeq(enumerate[ColorMode]())
    colors.filter(c => $c == color).optLast.get(ColorMode.colorNever)

  let downloadTimeout = not args.check(%%%"disable-download-timeout")
  let rootRel = getAll(%%%"root").optLast.orElse(defaultConfig.rootRelOption)
  let dbRel = getAll(%%%"dbpath").optLast.orElse(defaultConfig.dbRelOption)
  let cacheRel = getAll(%%%"cachedir").optLast.orElse(defaultConfig.cacheRelOption)
  let gpgRel = getAll(%%%"gpgdir").optLast.orElse(defaultConfig.gpgRelOption)
  let arch = getAll(%%%"arch").optLast.get(defaultConfig.common.arch)
  let colorStr = getAll(%%%"color").optLast.get($defaultConfig.colorMode)
  let color = getColor(colorStr)

  let debug = args.check(%%%"debug")
  let progressBar = not args.check(%%%"noprogressbar")
  let ignorePkgs = collect(initHashSet):
    for y in getAll(%%%"ignore"):
      for x in y.split(','):
        {x}
  let ignoreGroups = collect(initHashSet):
    for y in getAll(%%%"ignoregroup"):
      for x in y.split(','):
        {x}

  let hasKeyserver = forkWaitRedirect(() => (block:
    if dropPrivRedirect():
      execRedirect(gpgConfCmd, "--list-options", "gpg")
    else:
      quit(1)))
    .output
    .filter(s => s.len > 10 and s[0 .. 9] == "keyserver:" and not (s[^2] == ':'))
    .len > 0

  let pgpKeyserver = if hasKeyserver:
      none(string)
    else: (block:
      let argPgpKeyserver = getAll(%%%"keyserver").optLast
      if argPgpKeyserver.isSome:
        argPgpKeyserver
      else:
        var pgpKeyserver = none(string)
        var file: File
        if file.open(gpgRel.get(sysConfDir & "/pacman.d/gnupg").extendRel(sysroot) & "/gpg.conf"):
          try:
            while true:
              let line = file.readLine()
              if line.len > 10 and line[0 .. 9] == "keyserver ":
                pgpKeyserver = some(line[9 .. ^1].strip)
          except CatchableError:
            discard
          finally:
            file.close()
        pgpKeyserver)

  let defaultRootRel = defaultConfig.rootRelOption.get("/")
  let argsRootRel = rootRel.get("/")
  let defaultRoot = defaultRootRel == argsRootRel

  let config: PacmanConfig = ((defaultConfig.common.dbs, arch, debug, progressBar, defaultConfig.common.chomp,
    defaultConfig.common.verbosePkgLists, defaultConfig.common.downloadTimeout and downloadTimeout,
    pgpKeyserver, defaultRoot, ignorePkgs + defaultConfig.common.ignorePkgs,
    ignoreGroups + defaultConfig.common.ignoreGroups),
    sysroot, rootRel, dbRel, cacheRel, gpgRel, color)

  pacmanValidateAndThrow((("sysroot", sysroot, ArgumentType.long), sysroot.isSome),
    (("root", some(config.pacmanRootRel), ArgumentType.long), not defaultRoot),
    (("dbpath", some(config.pacmanDbRel), ArgumentType.long), true),
    (("arch", some(config.common.arch), ArgumentType.long), true),
    (("color", some(colorStr), ArgumentType.long), true))

  config
