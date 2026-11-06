import std/[os, osproc, unittest]
import ../src/utils

## `bashEscape` writes values into the makepkg config that bash later sources
## (`PKGDEST=`, `CARCH=`), so the only meaningful check is a round-trip through
## bash: the escaped line must read back as the original value, byte for byte.

proc roundTrip(value: string): string =
  let conf = getTempDir() / "pakku-bashescape-test.conf"
  writeFile(conf, "PKGDEST=" & value.bashEscape & "\n")
  var res = execProcess("/bin/bash",
    args = ["-c", "source " & quoteShell(conf) & "; printf '%s' \"$PKGDEST\""],
    options = {})
  if res.len > 0 and res[^1] == '\n':
    res.setLen(res.len - 1)
  res

suite "bashEscape":
  test "plain paths pass through":
    check roundTrip("/var/cache/pacman/pkg") == "/var/cache/pacman/pkg"

  test "shell metacharacters are preserved literally":
    for value in ["/tmp/a b", "/tmp/a'b", "/tmp/a#b", "/tmp/a;b", "/tmp/a*b",
        "/tmp/a\\b", "/tmp/a`id`b"]:
      check roundTrip(value) == value

  test "'$' is not expanded":
    check roundTrip("/tmp/a$b") == "/tmp/a$b"
    check roundTrip("/tmp/${HOME}") == "/tmp/${HOME}"
    check roundTrip("/tmp/$(id)") == "/tmp/$(id)"

  test "newlines survive":
    check roundTrip("/tmp/a\nb") == "/tmp/a\nb"

  test "bytes outside ASCII survive":
    for value in ["/tmp/caf\xC3\xA9", "/tmp/\x80", "/tmp/a\xFFb", "/tmp/a\x01b"]:
      check roundTrip(value) == value
