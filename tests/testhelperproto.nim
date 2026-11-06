import std/[strutils, unittest]
import ../src/helperproto

## Pins the argv contract shared with `lib/tools`: the round-trip must be exact
## and every malformed vector must be refused, because the helper cannot ask the
## parent what it meant.

let command = InstallCommand(
  destination: "/var/cache/pacman/pkg",
  uid: 1000,
  gid: 1000,
  upgrade: @["/usr/bin/pacman", "-U", "--noconfirm"],
  database: @["/usr/bin/pacman", "-D"],
  items: @[InstallItem(name: "foo", file: "/tmp/foo-1.0-1-x86_64.pkg.tar.zst",
      mode: "explicit"),
    InstallItem(name: "bar", file: "/tmp/bar-2.0-1-x86_64.pkg.tar.zst",
      mode: "dependency"),
    InstallItem(name: "baz", file: "/tmp/baz-3.0-1-x86_64.pkg.tar.zst",
      mode: "auto")])

proc refusal(args: seq[string]): string =
  ## The message for a rejected vector, or "" when it was accepted.
  try:
    discard decodeInstall(args)
  except ProtocolError as e:
    result = e.msg

suite "install contract":
  test "round-trip preserves every field":
    check decodeInstall(encodeInstall(command)) == command

  test "the vector starts with the protocol version and a length prefix":
    let args = encodeInstall(command)
    check args[0] == $helperProtocol
    check args[1 .. 4] == @[command.destination, "1000", "1000", "3"]
    check args.len == 6 + command.upgrade.len + command.database.len +
      3 * command.items.len

  test "a version mismatch names the protocol to reinstall":
    var args = encodeInstall(command)
    args[0] = "0"
    let message = refusal(args)
    check "reinstall pakku" in message
    check $helperProtocol in message

  test "a truncated vector is refused":
    check refusal(encodeInstall(command)[0 .. ^2]).len > 0

  test "a non-numeric field is refused":
    var args = encodeInstall(command)
    args[2] = "superuser"
    check refusal(args).len > 0

  test "a count reaching past the vector is refused":
    var args = encodeInstall(command)
    args[4] = "99"
    check refusal(args).len > 0

  test "a partial package triple is refused":
    check refusal(encodeInstall(command) & @["tail"]).len > 0

  test "an empty vector is refused":
    check refusal(@[]).len > 0

  test "an empty command is still valid":
    let empty = InstallCommand(destination: "/tmp", uid: -1, gid: -1)
    check decodeInstall(encodeInstall(empty)) == empty
