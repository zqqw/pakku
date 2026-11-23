import
  os,
  ../src/helperproto,
  bisect, install

when not declared(system.stdout): import std/syncio

let paramsFull = commandLineParams()

if paramsFull.len == 1 and paramsFull[0] == helperProtocolArg:
  # `helperToolCommand` asks this before it runs a helper. Keep the arm free of
  # side effects.
  echo helperProtocol
  programResult = 0
else:
  let fileName = paramStr(0).splitFile().name
  let appName = getAppFilename().splitFile().name

  let (tool, params) = if fileName == appName:
      (paramsFull[0], paramsFull[1 .. ^1])
    else:
      (fileName, paramsFull)

  programResult = case tool:
    of "bisect":
      handleBisect(params)
    of "install":
      handleInstall(params)
    else:
      1
