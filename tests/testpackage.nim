import std/[options, sequtils, tables, unittest]
import ../src/package

suite "splitVersionConstraint":
  # contract mirrors libalpm's `alpm_dep_from_string` (deps.c): operator is
  # selected from the whole string with `<` preferred over `>` over `=`; the
  # two-char form wins when `=` directly follows; name and version are
  # captured verbatim (spaces included) and may be empty.

  test "simple operators":
    check "name>=1.2".splitVersionConstraint ==
      ("name", some(ConstraintOperation.ge), "1.2")
    check "name<2.0".splitVersionConstraint ==
      ("name", some(ConstraintOperation.lt), "2.0")
    check "foo = bar baz".splitVersionConstraint ==
      ("foo ", some(ConstraintOperation.eq), " bar baz")

  test "'<' outranks '>' and '=' wherever it occurs":
    check "a=b<c".splitVersionConstraint ==
      ("a=b", some(ConstraintOperation.lt), "c")

  test "two-char forms only when '=' directly follows":
    check "name >= 1.2-3".splitVersionConstraint ==
      ("name ", some(ConstraintOperation.ge), " 1.2-3")
    check "n<=0.1".splitVersionConstraint ==
      ("n", some(ConstraintOperation.le), "0.1")

  test "empty name and empty version are legal":
    check ">=1.2".splitVersionConstraint ==
      ("", some(ConstraintOperation.ge), "1.2")
    check "=".splitVersionConstraint == ("", some(ConstraintOperation.eq), "")
    check "name >=".splitVersionConstraint.operation.get ==
      ConstraintOperation.ge

  test "no constraint keeps the input as the name":
    for s in ["plainname", "--flag", "", ".", "junk:name"]:
      let (n, op, v) = s.splitVersionConstraint()
      check op.isNone
      check n == s
      check v == ""

suite "parseSrcInfoLine":
  # accepts makepkg's emitted shape (identifier key, ` = `, verbatim rest) and,
  # like parse_ini, any spacing around the `=`
  test "accepted shapes":
    let kv = parseSrcInfoLine("\tx_1 = V W").unsafeGet
    check kv.key == "x_1"
    check kv.value == "V W"
    check parseSrcInfoLine("pkgbase = core").unsafeGet.value == "core"
    check parseSrcInfoLine("_custom_flag = yes").unsafeGet.key == "_custom_flag"

  test "lenient like every .SRCINFO reader: spacing around '=' is trimmed":
    for s in ["k= v", "k  = v"]:
      let kv = parseSrcInfoLine(s).unsafeGet
      check kv.key == "k"
      check kv.value == "v"

  test "leading separators and missing pieces":
    check parseSrcInfoLine("= novalue").isNone
    check parseSrcInfoLine("bad-key= x").isNone

suite "parseSrcInfoKeys":
  const srcInfo = """
pkgbase = pakku
pkgname = pakku
depends = glibc
makedepends = nim
pkgname = libpakku
depends = musl
"""
  test "splits sections per pkgname":
    let parsed = srcInfo.parseSrcInfoKeys()
    check toSeq(keys(parsed.table)) == @["pakku", "libpakku"]
    check parsed.baseSeq[].filterIt(it.key == "pkgbase")[0].value == "pakku"

  test "per-package directives land in their own section":
    let parsed = srcInfo.parseSrcInfoKeys()
    let first = parsed.table["pakku"][]
    let second = parsed.table["libpakku"][]
    check first.anyIt(it.key == "makedepends" and it.value == "nim")
    check second.anyIt(it.key == "depends" and it.value == "musl")

suite "parsePackageReference":
  # consumer of `splitVersionConstraint`; `": "` is the description separator
  # (two characters, so an epoch colon is not mistaken for one), and the
  # constraint fields stay verbatim exactly as libalpm copies them.

  test "a bare name has no constraint":
    check "foo".parsePackageReference(withDescription = false) ==
      ("foo", none(string), none(VersionConstraint))

  test "operators become constraints":
    check "foo>=1.2".parsePackageReference(withDescription = false) ==
      ("foo", none(string), some((ConstraintOperation.ge, "1.2", false)))
    check "foo<2.0".parsePackageReference(withDescription = false) ==
      ("foo", none(string), some((ConstraintOperation.lt, "2.0", false)))

  test "'<'-first selection survives the call site":
    check "a=b<c".parsePackageReference(withDescription = false) ==
      ("a=b", none(string), some((ConstraintOperation.lt, "c", false)))

  test "a description is split at ': ' when asked for":
    check "foo>1.2: some text".parsePackageReference(withDescription = true) ==
      ("foo", some("some text"), some((ConstraintOperation.gt, "1.2", false)))

  test "an epoch colon is not a description":
    check "foo=1:1.2".parsePackageReference(withDescription = true) ==
      ("foo", none(string), some((ConstraintOperation.eq, "1:1.2", false)))

  test "the description is kept in the name when not asked for":
    check "foo: text".parsePackageReference(withDescription = false) ==
      ("foo: text", none(string), none(VersionConstraint))

  test "spaces around the operator are part of the fields, as in libalpm":
    check "foo >= 1.2".parsePackageReference(withDescription = false) ==
      ("foo ", none(string), some((ConstraintOperation.ge, " 1.2", false)))
