const
  Version       = "0.16-dev"
  Prefix        = "/usr/local"
  SysConfDir    = "/etc"
  LocalStateDir = "/var"
  BuildTarget   = "release"
  BuildOptimize = "size"
  Copyright     = """2018-2019 kitsunyan
2020-2023 zqqw"""

switch("define", "pakkuVersion=" & Version)
switch("define", "pakkuPrefix=" & Prefix)
switch("define", "SysConfDir=" & SysConfDir)
switch("define", "LocalStateDir=" & LocalStateDir)
switch("define", "pakkuCopyright=" & Copyright)

--mm:arc
--threads:off
--define:buildTarget
#--define:nimPreviewSlimSystem

when defined(release):
  switch("opt", BuildOptimize)
  --passL:"-s"
  --passC:"-s"
  --passL:"-flto"
  --passC:"-flto"
  --hint:"[Conf]:off"
  --hint:"[Processing]:off"
  --hint:"[Link]:off"
  --hint:"[SuccessX]:off"

import std/strutils

task build, "development debug build":
  # propagates custom args
  let nargs = paramCount()
  var extra = newSeq[string]()
  if nargs > 2: # other than `nim build`
    var skippedTask = false
    for i in 1..nargs:
      let arg = paramStr(i)
      if not skippedTask and arg == "build":
        skippedTask = true
        continue
      extra.add arg
  selfExec("c " & extra.join(" ") & " -o:pakku src/main.nim")
