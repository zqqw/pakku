import
  os, posix, sequtils, strutils, sugar
when not declared(system.stdout): import std/syncio

proc splitCommands(params: seq[string], index: int, res: seq[seq[string]]): seq[seq[string]] =
  if index < params.len:
    let count = params[index].parseInt
    let args = params[index + 1 .. index + count]
    splitCommands(params, index + count + 1, res & args)
  else:
    res

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

proc warn(message: string): void =
  ## Reports a non-fatal problem. The helper inherits pakku's streams, so this
  ## appears next to pacman's output instead of aborting the installation.
  try:
    stderr.writeLine("warning: " & message)
    stderr.flushFile()
  except CatchableError:
    discard

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
    warn("failed to copy '" & source & "' to '" & dest & "': " & e.msg)
    return
  discard chown(cstring(dest), (Uid) uid, (Gid) gid)

proc handleInstall*(params: seq[string]): int =
  let (head, headIndex) = params.take(0, 3)
  let destination = head[0]
  let uid = head[1].parseInt
  let gid = head[2].parseInt

  let (upgradeCommand, upgradeIndex) = params
    .take(headIndex + 1, params[headIndex].parseInt)
  let (databaseCommand, databaseIndex) = params
    .take(upgradeIndex + 1, params[upgradeIndex].parseInt)

  let packages = params[databaseIndex .. ^1]
  if packages.len /% 3 * 3 != packages.len:
    raise newException(CatchableError, "invalid arguments")

  let install: seq[tuple[name: string, file: string, mode: string]] = packages
    .distribute(packages.len /% 3)
    .map(l => (l[0], l[1], l[2]))

  if uid >= 0 and gid >= 0:
    for pkg in install:
      let index = pkg.file.rfind("/")
      let name = if index >= 0: pkg.file[index + 1 .. ^1] else: pkg.file
      for (source, dest) in [(pkg.file, destination & "/" & name),
          (pkg.file & ".sig", destination & "/" & name & ".sig")]:
        copyPreserved(source, dest, uid, gid)

  let asexplicit = install.filter(p => p.mode == "explicit").map(p => p.name)
  let asdeps = install.filter(p => p.mode == "dependency").map(p => p.name)

  let installCode = runCommand(upgradeCommand & "--" & install.map(p => p.file), true)

  let asexplicitCode = if asexplicit.len > 0:
      runCommand(databaseCommand & "--asexplicit" & "--" & asexplicit, false)
    else:
      0

  let asdepsCode = if asdeps.len > 0:
      runCommand(databaseCommand & "--asdeps" & "--" & asdeps, false)
    else:
      0

  if installCode != 0:
    installCode
  elif asexplicitCode != 0:
    asexplicitCode
  else:
    asdepsCode
