## Remote comment fields must not inject terminal control sequences.
import std/[os, options, strutils, unittest]
import ../src/aurcomments
import ../src/format

suite "printComments":
  test "strips ANSI and OSC sequences from untrusted fields":
    let path = getTempDir() / "pakku-comment-sanitize.txt"
    let saved = stdout
    var f = open(path, fmWrite)
    try:
      stdout = f
      printComments(false, none(string), @[
        AurComment(
          author: "a\e[31mb",
          date: "\e]52;c;c2VjcmV0\a2026",
          text: "line\e[Hsafe",
          pinned: false
        )
      ])
    finally:
      stdout = saved
      f.close()

    let output = readFile(path)
    removeFile(path)
    check not output.contains("\e")
    check output.contains("ab")
    check output.contains("2026")
    check output.contains("line")
    check output.contains("safe")
