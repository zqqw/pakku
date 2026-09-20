const
  Version       = "0.16-dev"
  Prefix        = "/usr/local"
  SysConfDir    = "/etc"
  LocalStateDir = "/var"
  Copyright     = """2018-2019 kitsunyan
2020-2023 zqqw"""

switch("define", "pakkuVersion=" & Version)
switch("define", "pakkuPrefix=" & Prefix)
switch("define", "SysConfDir=" & SysConfDir)
switch("define", "LocalStateDir=" & LocalStateDir)
switch("define", "pakkuCopyright=" & Copyright)

--mm:arc
--threads:off
#--define:nimPreviewSlimSystem

when defined(release):
  --opt:"size"
  --passL:"-s"
  --passC:"-s"
  --passL:"-flto=auto"
  --passC:"-flto=auto"
  --hint:"[Conf]:off"
  --hint:"[Processing]:off"
  --hint:"[Link]:off"
  --hint:"[SuccessX]:off"

import std/[os, strutils]

task build, "development debug build":
  # propagates custom args
  let nargs = paramCount()
  var extra = newSeq[string]()
  if nargs > 1:
    var skippedTask = false
    for i in 1..nargs:
      let arg = paramStr(i)
      if not skippedTask and arg == "build":
        skippedTask = true
        continue
      extra.add arg
  selfExec("c " & extra.join(" ") & " -o:pakku src/main.nim")

task testmakefile, "run Makefile smoke tests":
  let destdir = getTempDir() / "pakku-makefile-test"
  let overriddenPrefix = "/usr"
  let pakkuBin = destdir / overriddenPrefix.strip(chars = {'/'}) / "bin" / "pakku"
  if dirExists(destdir): rmDir(destdir)
  for cmd in [
    "make clean",
    "make",
    "make PREFIX='" & overriddenPrefix & "' src/pakku",
    "make PREFIX='" & overriddenPrefix & "' DESTDIR='" & destdir & "' install",
    "'" & pakkuBin & "' -V",
    "make PREFIX='" & overriddenPrefix & "' DESTDIR='" & destdir & "' uninstall",
  ]:
    exec cmd
  if dirExists(destdir):
    quit "DESTDIR still exists after uninstall: " & destdir
