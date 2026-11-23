import
  std/[options, os, osproc, streams, strtabs, strutils, unittest],
  ../src/makepkg,
  ../src/utils

## makepkg owns the config precedence. pakku only reads `PKGDEST` and `PKGEXT`
## out of that config, through libmakepkg, and scans its output directory for
## the archives. Both halves are pinned here.

suite "makepkgConfVar":
  test "an exported value wins":
    putEnv("PKGEXT", ".pkg.tar.exported")
    defer: delEnv("PKGEXT")
    check makepkgConfVar("PKGEXT") == some(".pkg.tar.exported")

  test "values come through libmakepkg":
    let root = getTempDir() / "pakku-makepkgconf-loader"
    defer: removeDir(root)
    createDir(root / "util")
    writeFile(root / "util/config.sh", """
load_makepkg_config() {
  PKGDEST=/probe/loaded
  PKGEXT=.pkg.tar.loaded
}
""")
    putEnv("MAKEPKG_LIBRARY", root)
    delEnv("PKGDEST")
    delEnv("PKGEXT")
    defer:
      delEnv("MAKEPKG_LIBRARY")
      delEnv("PKGDEST")
      delEnv("PKGEXT")
    check makepkgConfVar("PKGDEST") == some("/probe/loaded")
    check makepkgConfVar("PKGEXT") == some(".pkg.tar.loaded")
    check resolveEffectivePkgdest() == "/probe/loaded"

  test "an unavailable libmakepkg leaves the value unset":
    let root = getTempDir() / "pakku-makepkgconf-empty"
    defer: removeDir(root)
    createDir(root)
    putEnv("MAKEPKG_LIBRARY", root)
    delEnv("PKGDEST")
    defer:
      delEnv("MAKEPKG_LIBRARY")
      delEnv("PKGDEST")
    check makepkgConfVar("PKGDEST").isNone
    check resolveEffectivePkgdest() == ""

suite "makepkg config layers":
  test "a partial user overlay still sees the system config":
    if initialUser.isSome or currentUser.uid == 0 or findExe("makepkg") == "":
      skip()
    elif not fileExists("/etc/makepkg.conf"):
      skip()
    else:
      let root = getTempDir() / "pakku-makepkgconf-overlay"
      defer: removeDir(root)
      createDir(root)
      writeFile(root / "PKGBUILD",
        "pkgname=demo\npkgver=1\npkgrel=1\narch=(any)\n")
      createDir(root / "xdg/pacman")
      writeFile(root / "xdg/pacman/makepkg.conf", "OPTIONS+=(!strip)\n")
      createDir(root / "out")

      let env = newStringTable(modeCaseSensitive)
      for (key, value) in envPairs(): env[key] = value
      env["XDG_CONFIG_HOME"] = root / "xdg"
      env["PKGDEST"] = root / "out"
      env.del("MAKEPKG_CONF")

      let makepkg = startProcess("makepkg", workingDir = root,
        args = ["--packagelist"],
        env = env, options = {poUsePath})
      let output = makepkg.outputStream.readAll()
      let code = makepkg.waitForExit()
      makepkg.close()

      check code == 0
      check output.contains(root / "out/demo-1-1-any.pkg.tar")

      let probe = startProcess(bashCmd, workingDir = root,
        args = ["-c",
          "source \"${MAKEPKG_LIBRARY:-/usr/share/makepkg}/util/config.sh\" && " &
          "load_makepkg_config && printf '%s' \"${OPTIONS[*]}\""],
        env = env, options = {poUsePath})
      let options = probe.outputStream.readAll()
      check probe.waitForExit() == 0
      probe.close()

      check options.contains("!strip")

  test "a build writes where the environment points":
    if initialUser.isSome or currentUser.uid == 0 or
        findExe("makepkg") == "" or findExe("fakeroot") == "":
      skip()
    elif not fileExists("/etc/makepkg.conf"):
      skip()
    else:
      let root = getTempDir() / "pakku-makepkgconf-build"
      defer: removeDir(root)
      createDir(root / "out")
      writeFile(root / "PKGBUILD", """
pkgname=demo
pkgver=1
pkgrel=1
arch=(any)
package() {
  install -Dm644 /dev/null "$pkgdir/usr/share/demo"
}
""")

      let env = newStringTable(modeCaseSensitive)
      for (key, value) in envPairs(): env[key] = value
      env["PKGDEST"] = root / "out"
      env["CARCH"] = execCmdEx("uname -m").output.strip
      env.del("MAKEPKG_CONF")

      # The extension is read by the test process as well, so both sides must
      # resolve the same config file.
      let savedConf = getEnv("MAKEPKG_CONF")
      delEnv("MAKEPKG_CONF")
      defer:
        if savedConf.len > 0: putEnv("MAKEPKG_CONF", savedConf)

      let makepkg = startProcess("makepkg", workingDir = root,
        args = ["--nodeps", "--noconfirm"],
        env = env, options = {poUsePath})
      discard makepkg.outputStream.readAll()
      let code = makepkg.waitForExit()
      makepkg.close()
      check code == 0

      # The scan pakku does after a build, with the extension read the same way.
      let ext = makepkgConfVar("PKGEXT").get(".pkg.tar.zst")
      let archive = root / "out" / ("demo-1-1-any" & ext)
      check ext.startsWith(".pkg.tar")
      check fileExists(archive)
      check getFileSize(archive) > 0
