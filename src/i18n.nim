## Translation primitives, shared by `src/` and the helpers in `lib/`.
##
## Separate from `utils` as helpers are spawned as separate processes and
## must not inherit pakku's runtime state. `utils` resolves the current user
## with `getpwuid` at module initialisation, which a copy helper has no
## business doing.
import std/strutils

proc dgettext(domain: cstring, s: cstring): cstring
  {.cdecl, importc: "dgettext".}

proc gettext(domain: string, s: string): string =
  let translated = dgettext(domain, s)
  if translated != nil: $translated else: s

proc gettextHandle(domain: string, s: string): string =
  ## Messages borrowed from pacman, libalpm and libc carry printf placeholders
  ## and a trailing newline that the printer supplies; normalise both.
  let res = gettext(domain, s).replace("%s", "$#").replace("%c", "$#")
  if res.len > 0 and res[^1 .. ^1] == "\n": res[0 .. ^2] else: res

template tr*(s: string): string =
  gettext("pakku", s)

template trp*(s: string): string =
  gettextHandle("pacman", s)

template tra*(s: string): string =
  gettextHandle("libalpm", s)

template trc*(s: string): string =
  gettextHandle("libc", s)
