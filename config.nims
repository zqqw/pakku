import std/[os, strutils]

const
  # The only hand-maintained number; keep it equal to the git tag
  # (`make releasecheck` verifies this). Everything else is derived.
  Version       = "0.18"
  Prefix        = "/usr/local"
  SysConfDir    = "/etc"
  LocalStateDir = "/var"
  Copyright     = """2018-2019 kitsunyan
2020-2023 zqqw
2026 ZoomRmc"""

const
  # A release must be asked for; `-d:pakkuDev` forces a development build even
  # then, for testing a tagged tree without claiming a release.
  IsRelease = defined(release) and not defined(pakkuDev)

  # Resolved here rather than in the Makefile so `nim c` and `make` agree.
  # Empty without git metadata (release tarball, shallow clone).
  GitDescribe = staticExec("git describe --tags --always --dirty 2>/dev/null").strip

  Dirty = GitDescribe.endsWith("-dirty")
  Clean = block:
    var s = GitDescribe
    if s.endsWith("-dirty"):
      s.setLen(s.len - "-dirty".len)
    if s.len > 0 and s[0] == 'v':
      s[1 .. ^1]
    else:
      s

  # "v0.18-3-g3d1b0a0" -> "0.18.r3.g3d1b0a0". Deliberately the same shape the AUR
  # -git PKGBUILD derives, so `pakku -V` and `pkgver` never disagree.
  DescribeVersion = block:
    var parts = Clean.split('-')
    if parts.len >= 3:
      parts[^2] = "r" & parts[^2]
      parts.join(".")
    elif Clean.len > 0 and Clean.contains('.'):
      Clean
    else:
      ""   # bare commit hash carries no version

  # Final version, by mode:
  #
  #   release               0.18                 Version, ignoring git
  #   tagged, dev           0.18-dev             on the tag but not a release
  #   tagged, dirty         0.18-dev-dirty       same, uncommitted changes
  #   ahead of tag          0.18.r3.g3d1b0a0     commit identity from git
  #   ahead of tag, dirty   0.18.r3.g3d1b0a0.dirty
  #   no git metadata       0.18-dev             tarball or shallow clone
  #
  # Release builds ignore git entirely: the `pakku` tarball has no .git, so
  # Version must be sufficient on its own.
  AppVersion =
    if IsRelease:
      Version
    elif Clean.len == 0 or DescribeVersion.len == 0:
      Version & "-dev"
    elif DescribeVersion == Version:
      Version & "-dev" & (if Dirty: "-dirty" else: "")
    elif Dirty:
      DescribeVersion & ".dirty"
    else:
      DescribeVersion

switch("define", "pakkuVersion=" & AppVersion)
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

task version, "print the version the build would stamp":
  echo AppVersion

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
