## Microbenchmark for src/aurcomments.nim.
import std/[os, strutils, monotimes, times, strformat]
import ../src/aurcomments

var reps = 300
var files: seq[string]
for arg in commandLineParams():
  if arg.startsWith("--reps="):
    try:
      reps = parseInt(arg[7 .. ^1])
    except ValueError:
      echo "invalid --reps value"
      quit(1)
  else: files.add arg
if reps < 1:
  echo "usage: benchaurcomments [--reps=N] page.html [...]"
  quit(1)

for f in files:
  let html = readFile(f)
  var sink = parseAurComments(html).len        # warmup
  var best = high(int64)
  var total = 0'i64
  for _ in 0 ..< reps:
    let start = getMonoTime()
    sink = parseAurComments(html).len
    let elapsed = (getMonoTime() - start).inNanoseconds
    if elapsed < best: best = elapsed
    total += elapsed
  echo &"{f}: {html.len} B, comments={sink}, " &
       &"mean={total div reps} ns, min={best} ns, reps={reps}"
