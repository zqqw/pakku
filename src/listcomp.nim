import macros

type ListComprehension = object
var lc* : ListComprehension

template `|`*(lc: ListComprehension, comp: untyped): untyped = lc

macro `[]`*(lc: ListComprehension, comp, typ: untyped): untyped =
  ## List comprehension, returns a sequence. `comp` is the actual list
  ## comprehension, for example ``x | (x <- 1..10, x mod 2 == 0)``. `typ` is
  ## the type that will be stored inside the result seq.
  ##
  ## .. code-block:: nim
  ##
  ##   echo lc[x | (x <- 1..10, x mod 2 == 0), int]
  ##
  ##   const n = 20
  ##   echo lc[(x,y,z) | (x <- 1..n, y <- x..n, z <- y..n, x*x + y*y == z*z),
  ##           tuple[a,b,c: int]]

  expectLen(comp, 3)
  expectKind(comp, nnkInfix)
  assert($comp[0] == "|")

  result = newCall(
    newDotExpr(
      newIdentNode("result"),
      newIdentNode("add")),
    comp[1])

  for i in countdown(comp[2].len-1, 0):
    let x = comp[2][i]
    expectMinLen(x, 1)
    if x[0].kind == nnkIdent and x[0].strVal == "<-":
      expectLen(x, 3)
      result = newNimNode(nnkForStmt).add(x[1], x[2], result)
    else:
      result = newIfStmt((x, result))

  result = newNimNode(nnkCall).add(
    newNimNode(nnkPar).add(
      newNimNode(nnkLambda).add(
        newEmptyNode(),
        newEmptyNode(),
        newEmptyNode(),
        newNimNode(nnkFormalParams).add(
          newNimNode(nnkBracketExpr).add(
            newIdentNode("seq"),
            typ)),
        newEmptyNode(),
        newEmptyNode(),
        newStmtList(
          newAssignment(
            newIdentNode("result"),
            newNimNode(nnkPrefix).add(
              newIdentNode("@"),
              newNimNode(nnkBracket))),
          result))))


when isMainModule:
  var a = lc[x | (x <- 1..10, x mod 2 == 0), int]
  assert a == @[2, 4, 6, 8, 10]

  const n = 20
  var b = lc[(x,y,z) | (x <- 1..n, y <- x..n, z <- y..n, x*x + y*y == z*z),
             tuple[a,b,c: int]]
  assert b == @[(a: 3, b: 4, c: 5), (a: 5, b: 12, c: 13), (a: 6, b: 8, c: 10),
(a: 8, b: 15, c: 17), (a: 9, b: 12, c: 15), (a: 12, b: 16, c: 20)]
