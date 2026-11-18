import
  std/[
    json,
    options,
    os,
    random,
    sequtils,
    sets,
    sugar,
    tables
  ],
  ./package,
  ./utils,
  ./wrapper/curl,
  ./aurcomments,
  ./format

export aurcomments.AurComment

const
  aurUrl* = "https://aur.archlinux.org/"

template gitUrl(base: string): string =
  aurUrl & base & ".git"

proc parseRpcPackageInfo(obj: JsonNode, repo: string): Option[RpcPackageInfo] =
  template optInt64(i: int64): Option[int64] =
    if i > 0: some(i) else: none(int64)

  let base = obj["PackageBase"].getStr
  let name = obj["Name"].getStr
  let version = obj["Version"].getStr
  let descriptionEmpty = obj["Description"].getStr
  let description = if descriptionEmpty.len > 0: some(descriptionEmpty) else: none(string)
  let maintainerEmpty = obj["Maintainer"].getStr
  let maintainer = if maintainerEmpty.len > 0: some(maintainerEmpty) else: none(string)
  let firstSubmitted = obj["FirstSubmitted"].getBiggestInt(0).optInt64
  let lastModified = obj["LastModified"].getBiggestInt(0).optInt64
  let outOfDate = obj["OutOfDate"].getBiggestInt(0).optInt64
  let votes = (int) obj["NumVotes"].getBiggestInt(0)
  let popularity = obj["Popularity"].getFloat(0)

  if base.len > 0 and name.len > 0:
    some((repo, base, name, version, description, maintainer, firstSubmitted, lastModified,
      outOfDate, votes, popularity, gitUrl(base), none(string)))
  else:
    none(RpcPackageInfo)

template withAur*(body: untyped): untyped =
  withCurlGlobal():
    body

proc obtainPkgBaseSrcInfo(base: string, useTimeout: bool): (string, Option[string]) =
  try:
    withAur():
      withCurl(instance):
        let url = aurUrl & "cgit/aur.git/plain/.SRCINFO?h=" &
          instance.escape(base)
        (performString(url, useTimeout), none(string))
  except CurlError:
    ("", some(getCurrentException().msg))

proc getRpcPackageInfosInternal(pkgs: seq[string], repo: string, useTimeout: bool):
  (seq[RpcPackageInfo], Option[string]) =
  let dpkgs = pkgs.deduplicate
  if dpkgs.len == 0:
    (@[], none(string))
  else:
    const maxCount = 100
    let distributed = dpkgs.distribute((dpkgs.len + maxCount - 1) /% maxCount)
    withAur():
      try:
        let responses = distributed.map(pkgs => (block:
          withCurl(instance):
            let url = aurUrl & "rpc/?v=5&type=info&arg[]=" & @pkgs
              .map(u => instance.escape(u))
              .foldl(a & "&arg[]=" & b)
            performString(url, useTimeout)))

        let table = collect(initTable):
          for z in responses:
            for y in parseJson(z)["results"]:
              for x in parseRpcPackageInfo(y,repo):
                {x.name:x}
        ((block:collect(newSeq):
          for p in pkgs:
            for x in table.opt(p):
              x
        ),none(string))
      except CurlError:
        (@[], some(getCurrentException().msg))
      except JsonParsingError:
        (@[], some(tr"failed to parse server response"))
      except CatchableError:
        (@[], some(getCurrentException().msg))

proc getRpcPackageInfos*(pkgs: seq[string], repo: string, useTimeout: bool, configColor: bool):
  (seq[RpcPackageInfo], Option[string]) =
  randomize()
  var rval: (seq[RpcPackageInfo], Option[string])
  for i in 0..2:
    rval = getRpcPackageInfosInternal(pkgs, repo, useTimeout)
    if isNone(rval[1]):
      break
    printError(configColor, rval[1].unsafeGet)
    sleep(rand(2000..3000))

  return (rval)

proc getAurPackageInfos*(pkgs: seq[string], repo: string, arch: string, useTimeout: bool, configColor: bool):
  (seq[PackageInfo], seq[PackageInfo], seq[string]) =
  if pkgs.len == 0:
    (@[], @[], @[])
  else:
    withAur():
      let (rpcInfos, error) = getRpcPackageInfos(pkgs, repo, useTimeout, configColor)

      if error.isSome:
        (@[], @[], @[error.unsafeGet])
      else:
        type
          ParseResult = tuple[
            infos: seq[PackageInfo],
            error: Option[string]
          ]

        let deduplicated = deduplicate:
          collect(newSeq):
            for x in rpcInfos:
              x.base
        
        proc obtainAndParse(base: string, index: int): ParseResult =
          let (srcInfo, operror) = obtainPkgBaseSrcInfo(base, useTimeout)

          if operror.isSome:
            (@[], operror)
          else:
            let pkgInfos = parseSrcInfo(repo, srcInfo, arch,
              gitUrl(base), none(string), rpcInfos)
            (pkgInfos, none(string))

        let parsed = deduplicated.foldl(a & obtainAndParse(b, a.len), newSeq[ParseResult]())
        let infos = collect(newSeq):
          for y in parsed:
            for x in y.infos:
              x
        let errors = collect(newSeq):
          for y in parsed:
            for x in y.error:
              x

        let table = infos.map(i => (i.rpc.name, i)).toTable
        let pkgInfos = collect(newSeq):
          for p in pkgs:
            for x in table.opt(p):
              x

        let names = rpcInfos.map(i => i.name).toHashSet
        let additionalPkgInfos = infos.filter(i => not (i.rpc.name in names))

        (pkgInfos, additionalPkgInfos, errors)

proc findAurPackages*(query: seq[string], repo: string, useTimeout: bool):
  (seq[RpcPackageInfo], Option[string]) =
  if query.len == 0 or query[0].len <= 2:
    (@[], none(string))
  else:
    withAur():
      try:
        withCurl(instance):
          let url = aurUrl & "rpc/?v=5&type=search&by=name-desc&arg=" &
            instance.escape(query[0])

          let response = performString(url, useTimeout)
          let results = parseJson(response)["results"]
          let rpcInfos = collect(newSeq):
            for y in results:
              for x in parseRpcPackageInfo(y,repo):
                x

          let filteredRpcInfos = if query.len > 1: (block:
              let terms = query[1 .. ^1]
              rpcInfos.filter(i => terms.all(q =>
                i.name.containsIgnoreCase(q) or
                i.description.map(d => d.containsIgnoreCase(q)).get(false))))
            else:
              rpcInfos

          (filteredRpcInfos, none(string))
      except JsonParsingError:
        (@[], some(tr"failed to parse server response"))
      except CurlError:
        (@[], some(getCurrentException().msg))


proc downloadAurComments*(base: string): (seq[AurComment], Option[string]) =
  let (content, error) = withAur():
    try:
      withCurl(instance):
        let url = aurUrl & "pkgbase/" & base & "/?comments=all"
        (performString(url, true), none(string))
    except CurlError:
      ("", some(getCurrentException().msg))

  if error.isSome:
    (@[], error)
  else:
    let comments = parseAurComments(content)

    (comments, none(string))
