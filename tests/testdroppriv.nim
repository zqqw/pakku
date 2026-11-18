import std/[options, os, strutils, sugar, unittest]
import ../src/utils

## A child started with `dropPrivRedirect` must keep the caller's environment.
##
## `initialUser` is empty when pakku runs as a normal user rather than through
## sudo. Before this was pinned, `execRedirect` still replaced the child's
## environment with the empty table built from that absent user, so `$HOME` and
## every other variable vanished. `resolveEffectivePkgdest` sources makepkg.conf
## through this path, and `PKGDEST=${HOME}/.cache/...` collapsed to a path in
## `/`, silently disabling `PreserveBuilt = Pkgdest` for unprivileged runs.

suite "execRedirect environment":
  test "the child sees the caller's environment":
    if initialUser.isSome:
      skip()
    else:
      const marker = "pakku-env-marker"
      putEnv("PAKKU_ENV_MARKER", marker)
      defer: delEnv("PAKKU_ENV_MARKER")
      discard dropPrivRedirect()
      let (output, code) = forkWaitRedirect(() => (block:
        execRedirect(bashCmd, "-c",
          """printf '%s|%s' "${PAKKU_ENV_MARKER-<unset>}" "${HOME-<unset>}"""")))
      check code == 0
      let fields = output.join("").split("|")
      check fields.len == 2
      check fields[0] == marker
      check fields[1] == getEnv("HOME")
      check fields[1] != "<unset>"

  test "privilege dropping is a no-op without an initial user":
    if initialUser.isSome:
      skip()
    else:
      check dropPrivRedirect() == true
