import
  std/[options, os, sugar],
  utils

const
  LibMakepkgDir = "/usr/share/makepkg"
    ## libmakepkg's install location. `MAKEPKG_LIBRARY` overrides it, the same
    ## way it does for makepkg itself.

  ConfVars = ["PKGDEST", "PKGEXT"]
    ## Variables pakku reads from makepkg's configuration.

proc makepkgConfVar*(name: string): Option[string] =
  ## Returns the value makepkg would use. The layers are loaded by libmakepkg
  ## itself, so the system config, its `<conf>.d` drop-ins, the user overlay
  ## and exported variables keep makepkg's precedence. Returns none when the
  ## variable is unset or libmakepkg cannot be sourced.
  assert name in ConfVars
  let envValue = getEnv(name)
  if envValue.len > 0: return some(envValue)

  let script = "source \"${MAKEPKG_LIBRARY:-" & LibMakepkgDir &
    "}/util/config.sh\" && load_makepkg_config && printf '%s' \"$" & name & "\""
  let (output, code) = forkWaitRedirect(() => (block:
    if dropPrivRedirect():
      execRedirect(bashCmd, "-c", script)
    else:
      quit(1)))
  if code == 0 and output.len > 0: some(output[^1]) else: none(string)

proc resolveEffectivePkgdest*(): string =
  ## Returns the `PKGDEST` makepkg itself would use, or "" when unset.
  makepkgConfVar("PKGDEST").get("")
