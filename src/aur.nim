import
  std/[
    json,
    options,
    re,
    sequtils,
    sets,
    strutils,
    sugar,
    tables,
    terminal,
    strscans,
    htmlparser,
    xmltree,
    wordwrap
  ],
  ./package,
  ./utils,
  ./wrapper/curl

type
  AurComment* = tuple[
    author: string,
    date: string,
    text: string
  ]

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

proc getRpcPackageInfos*(pkgs: seq[string], repo: string, useTimeout: bool):
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

proc getAurPackageInfos*(pkgs: seq[string], repo: string, arch: string, useTimeout: bool):
  (seq[PackageInfo], seq[PackageInfo], seq[string]) =
  if pkgs.len == 0:
    (@[], @[], @[])
  else:
    withAur():
      let (rpcInfos, error) = getRpcPackageInfos(pkgs, repo, useTimeout)

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
              let queryLow = query[1 .. ^1].map(q => q.toLowerAscii)
              rpcInfos.filter(i => queryLow.map(q => i.name.toLowerAscii.contains(q) or
                i.description.map(d => d.toLowerAscii.contains(q)).get(false)).foldl(a and b)))
            else:
              rpcInfos

          (filteredRpcInfos, none(string))
      except CurlError:
        (@[], some(getCurrentException().msg))

proc formatHtml(content: XmlNode): string =
  ## Transforms a HTML tree into a pleasant looking string to be printed
  ## on the terminal
  ($content).multiReplace(
    # force line break
      ("<br />", "\n"),
    # paragraphs look like 2 line breaks
      ("<p>", "\n\n"),
      ("</p>", "\n\n"),
    # replace mnemonics
      ("&lt;", "<"),
      ("&gt;", ">"),
      ("&quot;", "\""),
      ("&amp;", "&"),
      ("&apos;", "'"),
    )
    # remove tags
    .replace(re"<.*?>", "")
    # multiple spaces become 1 space
    .replace(re"\ {2,}", " ")
    # strip and wrap lines
    .strip
    .split("\n")
    .map(s => s.strip.wrapWords(maxLineWidth = terminalWidth()))
    .foldl(a & "\n" & b)
    .strip
    # don't allow more than 2 line breaks
    .replace(re"\n{2,}", "\n\n")

proc parseComments(content: XmlNode): seq[AurComment] =
  ## Scraps the `content` tree to find comments. This assumes two things:
  ##
  ## * `h4` headers contain a comment author and date with the format
  ##   "<author> commented on <date>"
  ## * The content of a comment is inside a `div` with a class attribute
  ##   containing "article-content"
  ##
  ## If any of this two suppositions is no longer valid, the parsing won't work.
  var meta = newSeq[(string, string)]()

  for a in content.findAll "h4":
    var name, date: string
    if a.innerText.scanf("$* commented on $*", name, date):
      date = date.replace(re"\s{2,}", " ")
      meta.add (strip name, strip date)

  var data = newSeq[string]()
  for a in content.findAll "div":
    if "article-content" in a.attr("class"):
      data.add(formatHtml a)

  for (m, d) in zip(meta, data):
    result.add (m[0], m[1], d)

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
    let
      tree = parseHtml(content)
      comments = parseComments(tree)

    (comments, none(string))
