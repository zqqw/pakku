## argv contract between pakku and the helpers in `lib/tools`.
##
## Both ends of a helper invocation encode and decode through this module, so
## the layout has one definition, the version cannot drift away from it, and a
## vector that does not match is reported instead of being sliced into garbage.
##
## A helper is a separate process because it runs with different privileges
## (`install`) or because `git bisect run` executes it once per commit
## (`bisect`), so the contract has to survive a stale binary in `PKGLIBDIR`:
## that is what `helperProtocol` is for.
import std/strutils
import i18n

const helperProtocol* = 1
  ## Bumped whenever a helper argv layout changes. The helpers ship as one
  ## binary (`lib/tools` plus symlinks), so one number covers all of them.

type
  InstallItem* = object
    ## One package handed to the install helper.
    name*: string
    file*: string
    mode*: string

  InstallCommand* = object
    ## Everything the install helper needs: where to keep built archives, whose
    ## ownership they take, the two pacman invocations and the packages.
    destination*: string
    uid*: int
    gid*: int
    upgrade*: seq[string]
    database*: seq[string]
    items*: seq[InstallItem]

  ProtocolError* = object of CatchableError
    ## An argv vector that does not match `helperProtocol`.

  ArgReader = object
    ## Walks an argv vector in order and refuses to read past its end.
    args: seq[string]
    index: int

func encodeInstall*(command: InstallCommand): seq[string] =
  ## Wire form of `command`: version, destination, uid, gid, then a
  ## count-prefixed vector twice, then `name`/`file`/`mode` triples.
  result = newSeqOfCap[string](6 + command.upgrade.len + command.database.len +
    3 * command.items.len)
  result.add [$helperProtocol, command.destination, $command.uid, $command.gid,
    $command.upgrade.len]
  result.add command.upgrade
  result.add $command.database.len
  result.add command.database
  for item in command.items:
    result.add [item.name, item.file, item.mode]

func rest(reader: ArgReader): int =
  ## Arguments still ahead, so a caller can check the vector ended where the
  ## layout says it should.
  reader.args.len - reader.index

func take(reader: var ArgReader): string =
  if reader.rest == 0:
    raise newException(ProtocolError,
      tr"helper arguments end in the middle of the command")
  result = reader.args[reader.index]
  inc reader.index

func takeInt(reader: var ArgReader): int =
  let value = reader.take
  try:
    value.parseInt
  except ValueError:
    raise newException(ProtocolError,
      tr("helper argument '$#' is not a number" % value))

func takeVector(reader: var ArgReader): seq[string] =
  ## A length followed by that many arguments. A negative length, or one
  ## reaching past the vector, is refused rather than sliced.
  let count = reader.takeInt
  if count < 0 or count > reader.rest:
    raise newException(ProtocolError,
      tr("helper argument count $# does not fit the vector" % $count))
  result = reader.args[reader.index ..< reader.index + count]
  reader.index += count

func decodeInstall*(args: seq[string]): InstallCommand =
  ## Inverse of `encodeInstall`. Raises `ProtocolError` for a version mismatch,
  ## a truncated or overlong vector, a non-numeric argument, a partial package
  ## triple or trailing arguments.
  let version = if args.len > 0: args[0] else: ""
  if version != $helperProtocol:
    raise newException(ProtocolError,
      tr("install helper speaks protocol $#, pakku sent '$#'; reinstall pakku") %
      [$helperProtocol, version])

  var reader = ArgReader(args: args, index: 1)
  result.destination = reader.take
  result.uid = reader.takeInt
  result.gid = reader.takeInt
  result.upgrade = reader.takeVector
  result.database = reader.takeVector
  if reader.rest mod 3 != 0:
    raise newException(ProtocolError,
      tr"install helper arguments end in the middle of a package")
  while reader.rest > 0:
    result.items.add InstallItem(name: reader.take, file: reader.take,
      mode: reader.take)
