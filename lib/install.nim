import
  os, posix, sequtils, strutils
import ../src/[helperproto, i18n]
when not declared(system.stdout): import std/syncio

proc perror*(s: cstring): void {.importc, header: "<stdio.h>".}
template perror*: void = perror(cstring(paramStr(0)))

proc runCommand(params: seq[string], inputOutput: bool): int =
  if params.len > 0:
    let pid = fork()
    if pid == 0:
      if not inputOutput:
        discard close(0)
        discard close(1)
        discard open("/dev/null")
        discard open("/dev/null")
      let cexec = allocCStringArray(params)
      let code = execvp(cexec[0], cexec)
      perror()
      deallocCStringArray(cexec)
      quit(code)
    else:
      var status: cint = 1
      discard waitpid(pid, status, 0)
      if WIFEXITED(status):
        WEXITSTATUS(status)
      else:
        discard kill(getpid(), status)
        1
  else:
    0

proc take(params: seq[string], start: int, count: int): (seq[string], int) =
  let res = params[start .. start + count - 1]
  (res, start + count)

proc report(level: string; message: string) =
  try:
    stderr.writeLine(level, message)
    stderr.flushFile()
  except CatchableError:
    discard

proc warn(message: string) =
  ## Reports a non-fatal problem. The helper inherits pakku's streams, so this
  ## appears next to pacman's output instead of aborting the installation. The
  ## prefix comes from pacman's catalogue, matching `printWarning` in the parent.
  report(trp"warning: ", message)

proc fail(message: string) =
  ## Reports a problem that aborts this helper invocation.
  report(trp"error: ", message)

proc isSameFile(a, b: string): bool =
  ## True when both paths exist and refer to the same file. `sameFile` raises
  ## when a path is missing, which is the normal case before the first copy, and
  ## is a side effect under Nim's rules, so this stays a `proc`.
  if not fileExists(a) or not fileExists(b):
    return false
  try:
    sameFile(a, b)
  except CatchableError:
    false

proc copyPreserved(source, dest: string; uid, gid: int): void =
  ## Copies a built archive or its signature sidecar to the preserve
  ## destination. A file that is already in place is left untouched: copying it
  ## onto itself truncates it, because the destination is opened for writing
  ## before the source is read. A missing sidecar is not an error.
  if isSameFile(source, dest):
    return
  if not fileExists(source):
    return
  try:
    copyFile(source, dest)
  except CatchableError as e:
    warn(tr("failed to copy '$#' to '$#': $#") % [source, dest, e.msg])
    return
  discard chown(cstring(dest), (Uid) uid, (Gid) gid)

proc handleInstall*(params: seq[string]): int =
  let command = try:
      decodeInstall(params)
    except ProtocolError as e:
      fail(e.msg)
      return 1

  if command.uid >= 0 and command.gid >= 0:
    for item in command.items:
      let name = item.file.extractFilename
      for (source, target) in [(item.file, name), (item.file & ".sig", name & ".sig")]:
        copyPreserved(source, command.destination / target, command.uid,
          command.gid)

  let explicit = command.items.filterIt(it.mode == "explicit").mapIt(it.name)
  let deps = command.items.filterIt(it.mode == "dependency").mapIt(it.name)

  let installCode = runCommand(command.upgrade & "--" &
    command.items.mapIt(it.file), true)

  let explicitCode = if explicit.len > 0:
      runCommand(command.database & "--asexplicit" & "--" & explicit, false)
    else:
      0

  let depsCode = if deps.len > 0:
      runCommand(command.database & "--asdeps" & "--" & deps, false)
    else:
      0

  if installCode != 0:
    installCode
  elif explicitCode != 0:
    explicitCode
  else:
    depsCode
