# generator.nim — emits the Nim modules for a Model: one module per
# defining header (when the provenance map knows the name), one per
# export DLL for the rest, plus win32base for what has no owner.
#
# Per-module layout:
#   1. header comment
#   2. one list import (+ re-export) of the modules it depends on
#   3. opaque stubs for named types referenced in signatures but not
#      defined in this winmd (a stub referenced by several modules
#      lives in the earliest one)
#   4. one `type` section: handles (distinct), enums (scoped as real
#      enums; unscoped as an alias of the backing integer), structs
#      (objects), delegates (proc types), interfaces (opaque objects);
#      architecture-split names get selector aliases between two type
#      zones (types referencing them come after the aliases)
#   5. `const` section: free constants + unscoped-enum members
#   6. functions: each proc sits in its owning module, sorted by DLL
#      then name and grouped per export DLL:
#      `{.push dynlib: "x".} ... {.pop.}` (one push/pop pair per DLL);
#      the dynlib name is lowercased with the .dll suffix stripped;
#      the importc pragma is bare when the emitted name is exactly the
#      C name, and spelled when --lowercase lowercases the first letter;
#      --headers attaches a `header: "stem.h"` pragma to symbols with
#      known provenance
#   7. curated aliases: the LPSTR/PSTR family -> cstring, the wide
#      variants -> ptr UncheckedArray[uint16]; redundant A-suffix
#      aliases (X with X & "A" == target) are not emitted, references
#      resolve to the target
#
# Dependency scanning: every emitted symbol's type references (struct
# fields, handle pointees, fn signatures, const types) yield an edge
# owner(referencing) -> owner(referenced); suppressed aliases and severed
# edges (rendered opaquely) contribute none. Owners come from the
# provenance map (header modules), the referencing DLL as fallback, and
# win32base — closed under references — for the rest. The import graph
# must stay acyclic: every back edge is broken by base-ifying the
# smaller reference closure (the referenced type, or the one that
# references it), then re-closing, until no cycles remain.
#
# Name hygiene: every top-level name goes through `freshName`, which keeps
# the first occurrence and suffixes later duplicates with `_2`, `_3`, ...
# so the output is always valid Nim. Escaping uses backticks for Nim
# keywords / digit-leading names.

import std/[sequtils, strutils, algorithm, sets, tables]
import ./[model, signatures]

# Keywords and reserved names
const NimKeywords = @[
  "addr", "and", "as", "bind", "break", "case", "concept", "const", "continue", "defer",
  "discard", "distinct", "elif", "else", "enum", "except", "export", "finally", "for",
  "from", "if", "in", "include", "interface", "is", "isnot", "iterator", "let", "macro",
  "method", "mixin", "namespace", "nil", "not", "notin", "object", "of", "or", "out",
  "proc", "ptr", "raise", "ref", "return", "static", "template", "try", "tuple", "type",
  "using", "var", "when", "while", "yield", "with", "without", "converter", "mod",
  "asm", "func", "do", "end", "bool", "byte", "char", "int", "int8", "int16", "int32",
  "int64", "uint", "uint8", "uint16", "uint32", "uint64", "float", "float64", "float32",
  "pointer", "ptr",
]

type GenCtx = object
  text: string
  knownTypes: HashSet[string] # type names emitted by section 3
  usedNames: HashSet[string] # every top-level name used so far
  unknownTypes: HashSet[string] # referenced but not emitted -> stubs
  guidUsed: bool # a signature references System.Guid (TypeRef)
  nameMap: Table[string, string] # "ns/name" or "name" -> emitted type name
  dupRowEmit: Table[int, string]
    # TypeDef row -> emitted name, for names shared by multiple rows
    # (anonymous nested types); nameMap alone cannot disambiguate them
  stubNames: Table[string, string] # unknown type name -> emitted stub name
  typePrims: Table[string, Prim] # type name -> base primitive kind
  typePtr: HashSet[string] # type base is a pointer-ish type
  typeKind: Table[string, TypeKind] # type name -> kind (first row wins)
  aAlias: Table[string, string]
    # suppressed A-suffix alias: X -> Y (raw names)
    # a handle X whose underlying type is a named type Y with X & "A" == Y
    # (STARTUPINFOEX -> STARTUPINFOEXA): the emitted alias adds nothing, so
    # it is not emitted and every reference to X resolves to Y's name
  aAliasFinal: Table[string, string] # X -> emitted name references resolve to
  typeHdr: Table[string, string] # symbol name -> defining header stem

  emitHeaders: bool
    # the --headers option: attach `header: "stem.h"`
    # to every type and function with known RDL provenance (the compiler
    # then treats it as declared in the named C header: no C declaration
    # is emitted, and -d:checkAbi can verify the layout against the real
    # headers). Constants get no pragma: `header` implies `nodecl`, so
    # the C code would reference a symbol the named header need not
    # declare
  lowerFirst: bool
    # the --lowercase option: lowercase the first letter
    # of emitted function names (Nim convention); off by default, the
    # importc pragma keeps the real linkage name either way

proc addGrouped[A; B](t: var Table[A, seq[B]], a: A, b: sink B) =
  t.mGetOrPut(a, default(seq[B])).add b

proc line(c: var GenCtx, s: string) =
  c.text.add s
  c.text.add '\n'

## Escape a Nim identifier (backtick keywords / digit-leading names).
proc esc(s: string): string =
  if s.len == 0:
    ""
  elif s in NimKeywords or s[0] in {'0' .. '9'}:
    '`' & s & '`'
  else:
    s

## Register a top-level Nim name (the entry's nimName); on collision
## return `name_2`, `name_3`, ...
proc freshIdent(used: var HashSet[string], nimName: string): string =
  result = nimName

  var n0 = nimIdentNormalize(nimName)
  if n0 in used:
    var n = 2

    while true:
      let candidate = nimIdentNormalize(result & "_" & $n)
      if candidate in used:
        inc n
      else:
        n0 = candidate
        result = result & "_" & $n
        break
  used.incl n0

## Register a top-level name; on collision return `name_2`, `name_3`, ...
proc freshName(c: var GenCtx, nimName: string): string =
  c.usedNames.freshIdent(nimName)

proc renderPragma(pragmas: openArray[string]): string =
  if pragmas.len > 0:
    " {." & pragmas.join(", ") & ".}"
  else:
    ""

proc archSuffix(archs: set[Architecture]): string =
  for arch in archs:
    if result.len > 0:
      result.add '_'
    result.add (
      case arch
      of i386: "I386"
      of amd64: "AMD64"
      of arm64: "ARM64"
    )

## `defined(...)` condition covering an entry's arch set (for the
## `when` blocks of arch-tagged constants).
proc archCond(archs: set[Architecture]): string =
  for arch in archs:
    if result.len > 0:
      result.add " or "

    result.add "defined(" & $arch & ")"

## `header: "stem.h"` pragma expression for a symbol with known RDL
## provenance (the --headers option); "" otherwise. The header pragma
## makes the compiler treat the symbol as declared in the named C header:
## no C declaration is emitted, and with -d:checkAbi a NIM_STATIC_ASSERT
## verifies the Nim layout against the real header. Callers wrap it in
## a ` {. ... .}` block as needed.
proc headerPragma(c: GenCtx, rawName: string): seq[string] =
  if c.emitHeaders and rawName in c.typeHdr:
    @["header: \"" & c.typeHdr[rawName] & ".h\""]
  else:
    @[]

## The header pragma as a standalone ` {.header: "h".}` block ("" when
## unknown) — for emission lines without an existing pragma block.
proc headerBlock(c: GenCtx, rawName: string): string =
  renderPragma(c.headerPragma(rawName))

## Name for an unknown (stubbable) type; falls back to the fixed identifier
## before pass 1 has assigned stub names.
proc stubName(c: var GenCtx, name: string): string =
  if name in c.stubNames:
    esc(c.stubNames[name])
  else:
    esc(fixIdent(name))

## Render a leaf (bPrim/bNamed) SigType; decorators are handled by renderType.
proc renderLeaf(c: var GenCtx, t: SigType): string =
  case t.base
  of bPrim:
    case t.prim
    of pvVoid: "void"
    of pvBoolean: "bool"
    of pvChar: "char"
    of pvI1: "int8"
    of pvU8: "uint64"
    of pvU1: "uint8"
    of pvI2: "int16"
    of pvU2: "uint16"
    of pvI4: "int32"
    of pvU4: "uint32"
    of pvI8: "int64"
    of pvR4: "float32"
    of pvR8: "float64"
    of pvString: "ptr UncheckedArray[uint16]"
    of pvI: "int"
    of pvU: "uint"
  of bNamed:
    if t.rowIdx >= 0 and t.rowIdx in c.dupRowEmit:
      # name shared by multiple TypeDef rows: resolve by row, not name
      esc(c.dupRowEmit[t.rowIdx])
    elif t.name in c.knownTypes:
      let k = t.ns & "/" & t.name
      if k in c.nameMap:
        esc(c.nameMap[k])
      elif t.name in c.nameMap:
        esc(c.nameMap[t.name])
      else:
        esc(fixIdent(t.name))
    elif t.ns == "System":
      case t.name
      of "Object":
        "pointer"
      of "Void":
        "void"
      of "Char":
        "char"
      of "Boolean":
        "bool"
      of "Int32":
        "int32"
      of "UInt32":
        "uint32"
      of "Int64":
        "int64"
      of "UInt64":
        "uint64"
      of "IntPtr":
        "int"
      of "UIntPtr":
        "uint"
      of "Guid":
        # 16-byte struct (TypeRef to mscorlib, not a TypeDef in this
        # winmd): emit the real layout in the base module, not a
        # 0-byte opaque stub
        c.guidUsed = true
        "Guid"
      else:
        c.unknownTypes.incl t.name
        stubName(c, t.name)
    else:
      c.unknownTypes.incl t.name
      stubName(c, t.name)
  else:
    "void" # decorators are dispatched by renderType

proc renderType(c: var GenCtx, t: SigType): string # fwd (mutual recursion)

## Render a fixed-size array element: a by-ref element becomes a pointer
## (`array[var T, N]` is not valid Nim), everything else renders as-is.
proc renderArrElem(c: var GenCtx, e: SigType): string =
  if e.base == bByRef:
    "ptr " & renderType(c, e.inner[])
  else:
    renderType(c, e)

## Render a full SigType as a Nim type expression (walks the decorator tree).
proc renderType(c: var GenCtx, t: SigType): string =
  case t.base
  of bPrim, bNamed:
    renderLeaf(c, t)
  of bPtr:
    let s = renderType(c, t.inner[])
    # `ptr void` is not a legal Nim type; a pointee that is an alias for
    # *void* (a handle typedef whose resolved base primitive is pvVoid,
    # e.g. MENUTEMPLATEA) must render as the bare `pointer` too. A pointee
    # that is an alias for *pointer* (a `ptr void` typedef, e.g. SC_HANDLE)
    # is in typePtr and must stay `ptr <name>` (= `ptr pointer`), not be
    # collapsed to `pointer`
    if s == "void" or (
      t.inner[].base == bNamed and t.inner[].name in c.typePrims and
      c.typePrims[t.inner[].name] == pvVoid and t.inner[].name notin c.typePtr
    ):
      "pointer"
    else:
      "ptr " & s
  of bByRef:
    "var " & renderType(c, t.inner[])
  of bArray:
    "array[" & $t.arrLen & ", " & renderArrElem(c, t.inner[]) & "]"

## True if the rendered form of `t` is already a unique/distinct type, so a
## handle aliasing it (or a pointer to it) needs no `distinct` keyword. A
## pointer is unique iff its pointee is: a `ptr` of an already-distinct type
## is itself distinct (like `ptr SomeObject`, objects being implicitly
## distinct). Objects, stubs, scoped enums and distinct handles are unique;
## primitives, `pointer`, void-aliases and unscoped enums are shared.
proc isUniqueType(c: GenCtx, t: SigType): bool =
  case t.base
  of bPrim:
    false
  of bNamed:
    let n = t.name
    if n in c.stubNames:
      true
    elif n in c.typeKind:
      case c.typeKind[n]
      of tkStruct, tkInterface, tkEnum, tkDelegate:
        true
      of tkUnscopedEnum:
        false
      of tkHandle:
        # a handle is unique unless it is a void-alias (a plain `void`
        # alias, shared)
        not (n in c.typePrims and c.typePrims[n] == pvVoid and n notin c.typePtr)
    else:
      true # unknown -> stub (`distinct object`)
  of bPtr:
    isUniqueType(c, t.inner[])
  of bByRef, bArray:
    false

## True if `t`'s rendered form is a pointer type: an anonymous `ptr ...`
## or bare `pointer`, `cstring`, or a named typedef whose base is a
## pointer. A non-zero value on such a type renders as a cast, which the
## VM cannot evaluate at compile time (so the const becomes a template).
proc renderedIsPtr(c: var GenCtx, t: SigType): bool =
  var et = t
  # constants on handle typedefs carry pvVoid; recover the base kind
  if t.name.len > 0 and t.name in c.typePrims:
    et.prim = c.typePrims[t.name]
  let tyS = renderType(c, et)
  tyS.len > 3 and tyS[0 .. 3] == "ptr " or tyS == "pointer" or
    (t.name.len > 0 and t.name in c.typePtr)

# ---------------------------------------------------------------------------
# value rendering
# ---------------------------------------------------------------------------

const HexDigits = "0123456789abcdef"

proc toHex(v: uint64): string =
  if v == 0:
    result = "0"
    return
  var x = v
  while x > 0:
    result.insert($HexDigits[int(x and 0x0F)], 0)
    x = x shr 4

## Render an integer constant with a typed literal suffix where the
## bare decimal form would get the wrong default type (int64).
proc renderIntConst(ty: Prim, v: uint64): string =
  case ty
  of pvU1:
    "0x" & toHex(v) & "'u8"
  of pvI1:
    $cast[int8](v) & "'i8"
  of pvU2:
    "0x" & toHex(v) & "'u16"
  of pvI2:
    $cast[int16](v) & "'i16"
  of pvU4:
    "0x" & toHex(v) & "'u32"
  of pvI4:
    $cast[int32](v) & "'i32"
  of pvU8:
    "0x" & toHex(v) & "'u64"
  of pvI8:
    $cast[int64](v) & "'i64"
  of pvI:
    # no suffix: the bare literal is signed by default
    $cast[int](v)
  of pvU:
    "0x" & toHex(v) & "'u"
  else:
    $cast[int64](v)

## Default zero-initialized literal for a type expression.
proc defaultLit(
    c: var GenCtx, m: Model, firstIdx: Table[string, int], ty: SigType
): string =
  if ty.base == bArray:
    # fixed array: zero-initialized value (array[<len>, <elem>] order)
    return "array[" & $ty.arrLen & ", " & renderArrElem(c, ty.inner[]) & "]()"
  if ty.base == bPtr or ty.base == bByRef or (ty.base == bPrim and ty.prim == pvString):
    "nil"
  elif ty.base == bNamed:
    if ty.name in c.aAlias:
      # suppressed alias: not emitted, the value is the target's
      # zero literal
      esc(c.aAliasFinal[ty.name]) & "()"
    elif c.typeKind.getOrDefault(ty.name, tkStruct) == tkHandle and ty.name in c.typeKind and
        c.typeKind[ty.name] == tkHandle:
      # distinct base: wrap the base type's default
      let j = firstIdx.getOrDefault(ty.name, -1)
      if j >= 0:
        esc(m.types[j].nimName) & "(" & defaultLit(
          c, m, firstIdx, m.types[j].underlying
        ) & ")"
      else:
        esc(fixIdent(ty.name)) & "()"
    else:
      esc(fixIdent(ty.name)) & "()"
  else:
    case ty.prim
    of pvBoolean: "false"
    of pvR4, pvR8: "0.0"
    else: "0"

## Render a constant value literal for a type of the given kind.
proc renderConstValue(ty: SigType, c: ModelConst): string =
  if c.isStr:
    return escape(c.strVal)

  if c.isFloat:
    result = $(c.floatVal)
    # an integer-valued float (e.g. "2") needs a decimal point or a
    # float literal will be an int literal in Nim
    if result.find('.') < 0 and result.find('e') < 0 and result.find('E') < 0 and
        result.find('n') < 0 and result.find('i') < 0:
      result.add ".0"
    return

  renderIntConst(ty.prim, c.value)

# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

type
  GenModule* = object
    name*: string # module name without the .nim extension
    code*: string

  FnModule = tuple[dll: string, modName: string, code: string]

## DFS over the module dependency graph; records every back edge.
## Every cycle contains at least one DFS back edge, so base-ifying the
## referenced types of all of them breaks every cycle in one batch
## (breaking one cycle per pass is far too slow for ~600 modules).
## Returns false with empty outEdges when the graph is a DAG.
# a back edge plus the tree edges from its target up to its source
# (the cycle it closes)
type CycleEdge* =
  tuple[
    to: int,
    refName: string,
    srcName: string,
    pathSrc: seq[string],
    pathRef: seq[string],
  ]

proc allBackEdges(
    n: int,
    adj: seq[seq[tuple[to: int, refName: string, srcName: string]]],
    outEdges: var seq[CycleEdge],
): bool =
  var edges: seq[CycleEdge]
  var color = newSeq[int](n)
  var stack: seq[int]
  proc dfs(u: int) =
    color[u] = 1
    stack.add u
    for e in adj[u]:
      if color[e.to] == 1:
        # cycle: e plus the tree path from e.to up to u
        var ps: seq[string]
        var pr: seq[string]
        var k = stack.len - 1
        while stack[k] != e.to:
          # collect the tree edge stack[k-1] -> stack[k]
          for e2 in adj[stack[k - 1]]:
            if e2.to == stack[k]:
              ps.add e2.srcName
              pr.add e2.refName
              break
          dec k
        edges.add (e.to, e.refName, e.srcName, ps, pr)
      elif color[e.to] == 0:
        dfs(e.to)
    stack.del(stack.len - 1)
    color[u] = 2

  for i in 0 ..< n:
    if color[i] == 0:
      dfs(i)
  outEdges = edges
  edges.len > 0

## The module identifier of a (possibly path-shaped) module name:
## windows/win32 -> win32 (path imports bind the last segment)
proc modStem(nm: string): string =
  let i = nm.rfind('/')
  if i >= 0:
    nm[i + 1 .. nm.high]
  else:
    nm

## Sanitize a DLL file name into a Nim module name:
## KERNEL32.dll -> kernel32, WINSPOOL.DRV -> winspool, WS2_32.dll -> ws2_32
proc dllModuleName(dll: string): string =
  var s = dll.toLower()
  if s.endsWith(".dll"):
    s = s[0 ..< s.len - 4]

  s

proc generateCore(
    m: Model,
    typeHdr: Table[string, string],
    emitHeaders: bool,
    lowerFirst: bool = false,
): tuple[base: string, mods: seq[FnModule], baseEmitted: bool] =
  var c = GenCtx(emitHeaders: emitHeaders, typeHdr: typeHdr, lowerFirst: lowerFirst)

  # ---- pass 0: assign emitted type names in emission order ---------------
  # On a conservative-name collision, whoever is assigned first keeps the
  # plain name. Order: structs first (signatures reference struct names),
  # then handles, enums, delegates, interfaces.
  var order: seq[int]
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkStruct:
      order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkHandle:
      order.add i
  for i in 0 ..< m.types.len:
    let k = m.types[i].kind
    if k == tkEnum or k == tkUnscopedEnum:
      order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkDelegate:
      order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkInterface and m.types[i].name != "Apis":
      order.add i

  for r in NimKeywords:
    c.usedNames.incl r

  # names from implicitly-imported modules (system etc): a local declaration
  # shadows them, but an *imported* one makes every reference ambiguous
  for r in ["File", "Fileinfo"]:
    c.usedNames.incl nimIdentNormalize(r)

  var firstIdx: Table[string, int]
  var rowCount: Table[string, int]
  var nameRows: Table[string, seq[int]]
  for i in 0 ..< m.types.len:
    let nm0 = m.types[i].name
    if nm0 notin firstIdx:
      firstIdx[nm0] = i
    rowCount[nm0] = rowCount.getOrDefault(nm0, 0) + 1
    nameRows.addGrouped(nm0, i)

  # ---- arch variants ------------------------------------------------------
  # A name whose duplicate winmd rows each carry a distinct, non-zero
  # SupportedArchitectureAttribute bitmask is a per-arch variant: the
  # winmd keeps one row per arch set, and each row is emitted under a
  # per-arch variant name (X_AMD64, X_I386, ...) while the plain name
  # becomes a `when defined(...)` selector alias. The attribute is also
  # present on km-merge chain sub-types (X_0, X_0_1, ...), so those split
  # independently; variantName still names a chain after its split parent
  # (X_AMD64_0_1), which is valid because the winmd keeps a parent and its
  # chains in the same per-arch row order (variant i of both is the same
  # arch set).
  ## Sort rank of a const row: narrowest arch set first (untagged rows
  ## would sort last; no emitted `when` group contains any).
  proc rowArchRank(cc: ModelConst): int =
    if cc.arch.len == 0: 99 else: cc.arch.len

  var splitInfo: Table[string, seq[set[Architecture]]]
  var rowVariant: seq[int] = newSeq[int](m.types.len)
  for i in 0 ..< m.types.len:
    rowVariant[i] = -1
  for nm in nameRows.keys:
    let rows = nameRows[nm]
    if rows.len < 2:
      continue
    # only kinds whose per-arch definitions can differ meaningfully
    let k = m.types[rows[0]].kind
    if k != tkStruct and k != tkHandle and k != tkDelegate:
      continue
    # every row must carry a distinct, non-empty arch set
    var ok = true
    for i in 0 ..< rows.len:
      if m.types[rows[i]].arch.len == 0:
        ok = false
        break
      for j in i + 1 ..< rows.len:
        if m.types[rows[i]].arch == m.types[rows[j]].arch:
          ok = false
          break
      if not ok:
        break
    if ok:
      var sets: seq[set[Architecture]]
      for i in 0 ..< rows.len:
        sets.add m.types[rows[i]].arch
        rowVariant[rows[i]] = i
      splitInfo[nm] = sets

  var variantOut: Table[string, seq[string]]
  # every variant — including km-merge chain sub-types — is named after
  # its OWN arch set (X_AMD64, X_0_ARM64, ...). A chain's variant count
  # can differ from its parent's (an arch may have no sub-struct for a
  # given member), so the name must not be inherited from the parent.
  proc variantName(nm: string, vi: int): string =
    m.types[nameRows[nm][0]].nimName & "_" & archSuffix(splitInfo[nm][vi])

  var spairs: seq[tuple[nm: string, l: seq[set[Architecture]]]]
  for (nm, l) in splitInfo.pairs:
    spairs.add (nm, l)
  for (nm, l) in spairs:
    for vi in 0 ..< l.len:
      let v = c.freshName(variantName(nm, vi))
      variantOut.addGrouped(nm, v)

    let aliasN = m.types[nameRows[nm][0]].nimName
    c.usedNames.incl nimIdentNormalize(aliasN)
    c.nameMap[aliasN] = aliasN

  var typeNames: seq[string] = newSeq[string](m.types.len)

  for idx in order:
    let t = m.types[idx]

    c.knownTypes.incl t.name

    let assigned =
      if rowVariant[idx] >= 0:
        # arch variant row: its unique per-arch name (no dedup suffix)
        c.usedNames.incl nimIdentNormalize(t.nimName)
        variantOut[t.name][rowVariant[idx]]
      else:
        c.freshName(t.nimName)
    typeNames[idx] = assigned

    if rowCount.getOrDefault(t.name, 0) > 1:
      # keyed by the raw TypeDef row (model.resolveNested pins references
      # to rows, not to m.types indices)
      c.dupRowEmit[t.defRow] = assigned

    if rowVariant[idx] >= 0:
      # split names resolve through their selector alias (set above),
      # not through a variant row
      discard
    else:
      c.nameMap[t.ns & "/" & t.name] = assigned
      c.nameMap[t.name] = assigned

    # base primitive kind, following the named-type chain of handles
    if t.kind == tkHandle or t.kind == tkUnscopedEnum:
      var cur: SigType = t.underlying
      var guard = 0
      # stop at the first non-named leaf: a `ptr T` (bPtr) base makes the
      # typedef pointer-like regardless of T. A chain that reaches an object
      # (struct/interface) has no base primitive (a struct's `underlying`
      # is the default SigType), so do not record one: such a typedef is an
      # alias of an object, not of void (e.g. CERT_BLOB = CRYPT_INTEGER_BLOB)
      var baseIsObject = false
      while cur.base == bNamed and guard < 16:
        let j = firstIdx.getOrDefault(cur.name, -1)
        if j < 0:
          break
        if m.types[j].kind in {tkStruct, tkInterface}:
          baseIsObject = true
          break
        cur = m.types[j].underlying
        inc guard
      if not baseIsObject:
        c.typePrims[t.name] = cur.prim
      if cur.base == bPtr:
        c.typePtr.incl t.name
    if t.name notin c.typeKind:
      c.typeKind[t.name] = t.kind

  # ---- pass 1: sweep every signature reference to collect unknown names --
  for i in 0 ..< m.types.len:
    let t = m.types[i]
    if t.kind == tkHandle or t.kind == tkUnscopedEnum:
      discard renderType(c, t.underlying)
    for f in t.fields:
      discard renderType(c, f.ty)
    if t.kind == tkDelegate:
      discard renderType(c, t.ret)
  for cc in m.consts:
    discard renderType(c, cc.ty)
  for f in m.fns:
    for p in f.params:
      discard renderType(c, p.ty)
    discard renderType(c, f.ret)

  var stubList = toSeq(c.unknownTypes)
  stubList.sort() # stable freshname

  for n in stubList:
    c.stubNames[n] = c.freshName(fixIdent(n))

  # ---- module ownership -----------------------------------------------------
  # module keys: every export DLL (order of first appearance of its
  # functions), plus one per defining header (created lazily by
  # headerOwnerKey). moduleIdx is filled from fnOwner below.
  var moduleOrder: seq[string]
  var moduleIdx: Table[string, seq[int]]
  for i in 0 ..< m.fns.len:
    let dn =
      if m.fns[i].moduleName.len > 0:
        m.fns[i].moduleName
      else:
        "misc"
    if dn notin moduleIdx:
      moduleIdx[dn] = @[]
      moduleOrder.add dn
  var modulePos: Table[string, int]
  for k in 0 ..< moduleOrder.len:
    modulePos[moduleOrder[k]] = k

  # sanitized module names (parallel to moduleOrder), collision-suffixed
  var dllNames: seq[string]
  var usedDll: HashSet[string]
  for dn in moduleOrder:
    var sn = dllModuleName(dn)
    if sn.len == 0 or sn == "win32" or sn == "win32base":
      sn = sn & "_m"
    dllNames.add usedDll.freshIdent(sn)

  # header provenance: typeHdr maps raw winmd names to the stem of the
  # SDK header that declares them (data/type_headers.txt, derived from the
  # per-header RDL snapshot that Windows.Win32.winmd was compiled from).
  # A stem that sanitizes to an existing DLL module name merges into that
  # module (header d3d11 + DLL d3d11.dll -> one file); every other stem
  # becomes its own module, created lazily.
  var hdrKeyCache: Table[string, string]
  # every header stem that occurs in the map (to detect numbered
  # km-merge header variants: d2d1_1 only merges into d2d1 when d2d1
  # is itself a mapped header)
  var hdrStems: Table[string, bool]
  for (k, v) in typeHdr.pairs:
    hdrStems[v] = true
  # DLL stems exported by the winmd (lowercase, suffix stripped):
  # a numbered header stem that matches one (d3d10_1.dll) is a real
  # SDK header, not a snapshot split
  var dllStems: Table[string, bool]
  for f in m.fns:
    if f.moduleName.len > 0:
      let dot = f.moduleName.rfind('.')
      let ds =
        if dot >= 0:
          f.moduleName[0 ..< dot]
        else:
          f.moduleName
      dllStems[ds.toLower()] = true

  proc headerOwnerKey(stem: string): string =
    if stem in hdrKeyCache:
      return hdrKeyCache[stem]

    # numbered km-merge header variants (d2d1_1.rdl, d3d11_2.rdl, ...)
    # are snapshot splits of the parent header: when the parent stem is
    # itself mapped AND no DLL named after the variant exists in the
    # winmd (d3d10_1.dll is real), merge into the parent's module.
    # Stems with no mapped parent (dxgi1_2, bits1_5, ...) keep their
    # own module.
    var s = stem
    if s notin dllStems:
      var i2 = s.len - 1
      while i2 >= 0 and s[i2] in '0' .. '9':
        dec i2
      if i2 >= 1 and s[i2] == '_':
        let base = s[0 ..< i2]
        if base in hdrStems:
          s = base

    var sn = dllModuleName(s)
    if sn.len == 0 or sn == "win32" or sn == "win32base":
      sn = sn & "_m"
    var found = ""
    for k in 0 ..< moduleOrder.len:
      if dllNames[k] == sn:
        found = moduleOrder[k]
    if found.len > 0:
      result = found
    else:
      moduleOrder.add s
      modulePos[s] = moduleOrder.len - 1
      moduleIdx[s] = @[]
      dllNames.add usedDll.freshIdent(sn)
      result = s
    hdrKeyCache[stem] = result

  # function ownership: the defining header if the provenance map knows
  # the name, else the export DLL module (every function has an ImplMap,
  # so this always resolves to a real module)
  var fnOwner: seq[string] = newSeq[string](m.fns.len)
  for i in 0 ..< m.fns.len:
    let n = m.fns[i].name
    if n in typeHdr:
      fnOwner[i] = headerOwnerKey(typeHdr[n])
    else:
      fnOwner[i] =
        if m.fns[i].moduleName.len > 0:
          m.fns[i].moduleName
        else:
          "misc"
  # functions live in their owning module (not the DLL module): fill
  # moduleIdx from fnOwner
  for i in 0 ..< m.fns.len:
    moduleIdx[fnOwner[i]].add i

  # direct type-name references of every model type, plus which refs
  # are pointer-shaped (nPtr > 0 or a pointer-alias type): only those
  # can be rendered opaquely (`pointer`) to sever a dependency edge
  var typeRefNames: seq[seq[string]] = newSeq[seq[string]](m.types.len)
  var ptrRefs: Table[string, bool]
  # the named type at the leaf of a type tree (through pointer/by-ref/array
  # decorators); "" when the leaf is a primitive
  proc leafNamed(ty: SigType): string =
    var cur = ty
    while cur.base == bPtr or cur.base == bByRef or cur.base == bArray:
      cur = cur.inner[]
    if cur.base == bNamed: cur.name else: ""

  # collect the referenced type name from a field/param SigType; the edge is
  # pointer-shaped (severable) when the field's outermost decoration is a
  # pointer, or the field is a direct handle alias
  proc addRefs(i: int, ty: SigType, ownerName: string) =
    let ln = leafNamed(ty)
    if ln.len > 0:
      typeRefNames[i].add ln
      if ty.base == bPtr or
          (ty.base == bNamed and c.typeKind.getOrDefault(ty.name, tkStruct) == tkHandle):
        ptrRefs[ownerName & "/" & ln] = true

  for i in 0 ..< m.types.len:
    let t = m.types[i]
    case t.kind
    of tkStruct:
      for f in t.fields:
        addRefs(i, f.ty, t.name)
    of tkHandle:
      let ln = leafNamed(t.underlying)
      if ln.len > 0:
        typeRefNames[i].add ln
        # a pointer alias is pointer-shaped: the edge can be severed by
        # rendering the alias opaquely (`distinct pointer`)
        ptrRefs[t.name & "/" & ln] = true
    of tkDelegate:
      for f in t.fields:
        addRefs(i, f.ty, t.name)
      addRefs(i, t.ret, t.name)
    else:
      discard

  # zone split: a type that (transitively) references a split name must be
  # emitted after the selector aliases (Nim resolves identifiers
  # textually; a type section cannot forward-reference a later section)
  # while variants must come before the aliases. Names referenced by a
  # variant that themselves reference split names cannot be laid out —
  # drop those from splitting (fallback: first row keeps the name, the
  # rest get the usual _2 suffixes)
  # zone B = names that (transitively) reference a split name. Computed
  # by monotone fixed-point coloring: split names are the seeds and the
  # color propagates backwards along reference edges. Fixed-point
  # propagation handles reference cycles correctly (the memoized DFS
  # mis-classified names in cycles such as IRP <-> IRP_4).
  var zoneB: HashSet[string]
  var allNames0: seq[string]
  for (nm, l) in nameRows.pairs:
    allNames0.add nm

  proc recolor() =
    zoneB.clear()

    for (nm, l) in splitInfo.pairs:
      zoneB.incl(nm)

    var changedC = true
    while changedC:
      changedC = false
      for nm in allNames0:
        if nm in zoneB:
          continue

        var hit = false
        for ri in nameRows[nm]:
          for r in typeRefNames[ri]:
            if r in zoneB:
              hit = true
              break
          if hit:
            break
        if hit:
          zoneB.incl nm
          changedC = true

  recolor()

  # a variant may only reference zone A names (or other variants of the
  # same split names): if a name referenced — directly or transitively —
  # by a variant row lives in zone B, the layout is impossible and the
  # name falls back to plain duplicate handling
  proc unsplit(nm: string) =
    if nm in splitInfo:
      splitInfo.del nm
    for i in 0 ..< m.types.len:
      if m.types[i].name == nm:
        if rowVariant[i] >= 0:
          rowVariant[i] = -1
          # the per-arch name was consumed in pass 0; reassign with the
          # usual dedup suffix. The firstIdx row gets the plain name
          # back: it was reserved for the selector alias, so no other
          # type can hold it
          let base0 = m.types[i].nimName
          var assigned = base0
          if i != firstIdx[nm]:
            if nimIdentNormalize(assigned) in c.usedNames:
              var i2 = 2
              while nimIdentNormalize(base0 & "_" & $i2) in c.usedNames:
                inc i2
              assigned = base0 & "_" & $i2
          c.usedNames.incl nimIdentNormalize(assigned)
          typeNames[i] = assigned
          c.nameMap[nm] = assigned
          # keep the row-keyed reference map in sync with the reassignment
          if rowCount.getOrDefault(nm, 0) > 1:
            c.dupRowEmit[m.types[i].defRow] = assigned
    recolor()

  var changed = true
  while changed:
    changed = false
    var splitNames2: seq[string]
    for (nm, l) in splitInfo.pairs:
      splitNames2.add nm
    for nm in splitNames2:
      var bad = false
      # a reference from a variant row to another split name is only
      # rewritable if that name has a variant with the same arch set; the
      # winmd arch sets do not always partition cleanly (IMAGE_RUNTIME_
      # FUNCTION_ENTRY [i386,amd64] points at _IMAGE_RUNTIME_FUNCTION_
      # ENTRY [amd64] / [i386,arm64]). When no variant matches, the
      # reference falls back to the plain name — a forward ref to the
      # selector alias, which a variant (zone A) cannot make — so the
      # name must be unsplit.
      for ri in nameRows.getOrDefault(nm, @[]):
        let aSet = m.types[ri].arch
        for r in typeRefNames[ri]:
          if r in splitInfo:
            var matched = false
            for rs in splitInfo[r]:
              if rs == aSet:
                matched = true
            if not matched:
              bad = true
              break
        if bad:
          break
      # every name this variant's closure reaches through non-split names
      # (skipped when the arch-match check already flagged a conflict)
      var seen: HashSet[string]
      var stack: seq[string]
      for ri in nameRows.getOrDefault(nm, @[]):
        for r in typeRefNames[ri]:
          if r notin splitInfo and r notin seen:
            stack.add r
      while stack.len > 0 and not bad:
        let r = stack[stack.len - 1]
        stack.setLen(stack.len - 1)
        if r in seen or r in splitInfo:
          continue
        seen.incl r
        if r in zoneB:
          bad = true
          break
        let ri = firstIdx.getOrDefault(r, -1)
        if ri >= 0:
          for r2 in typeRefNames[ri]:
            if r2 notin splitInfo and r2 notin seen:
              stack.add r2
      if bad:
        unsplit nm
        changed = true
        break

  # ---- A-suffix alias suppression --------------------------------------------
  # Runs after the unsplit loop: typeNames / nameMap / dupRowEmit are final.
  # A handle whose emitted line is a plain alias `X = Y` with X & "A" == Y
  # exactly is a pure ANSI/Unicode wrapper (STARTUPINFOEX -> STARTUPINFOEXA):
  # the alias adds nothing, so it is suppressed and every reference to X
  # resolves to Y's emitted name. Names whose emitted form does not match
  # exactly (dedup suffixes, fixIdent changes: OFNOTIFY = OFNOTIFYA_2,
  # TRUSTEE_X = TRUSTEE_A, HW_PROFILE_INFO_2 = HW_PROFILE_INFOA_2) keep
  # their alias. Only plain aliases qualify: the target must already be a
  # unique type (an object, a distinct handle, a scoped enum, or a stub —
  # e.g. LPFINDREPLACE -> LPFINDREPLACEA, a handle aliasing a struct
  # pointer), so the alias is redundant, and X's name must be single-row
  # (row-pinned references cannot be redirected).
  for i in 0 ..< m.types.len:
    let t = m.types[i]

    if t.kind != tkHandle:
      continue

    let u = t.underlying
    if u.base != bNamed:
      continue

    if rowCount.getOrDefault(t.name, 0) != 1:
      continue

    # the target's emitted name, as renderLeaf would resolve an unpinned
    # (or row-pinned) reference to it
    var target = ""
    if u.rowIdx >= 0 and u.rowIdx in c.dupRowEmit:
      target = c.dupRowEmit[u.rowIdx]
    else:
      let k = u.ns & "/" & u.name
      if k in c.nameMap:
        target = c.nameMap[k]
      elif u.name in c.nameMap:
        target = c.nameMap[u.name]
      else:
        target = c.stubNames.getOrDefault(u.name, fixIdent(u.name))

    if typeNames[i] & "A" != target:
      continue

    # only plain aliases: the target must already be a unique type (an
    # object, a distinct handle, a scoped enum, or a stub), so the alias
    # is redundant; a shared target (primitive, pointer, void-alias,
    # unscoped enum) would make `X = distinct Y`, which is not redundant
    if not isUniqueType(c, u):
      continue

    c.aAlias[t.name] = u.name # graph redirection (raw names)
    c.aAliasFinal[t.name] = target # rendered name references resolve to
    c.nameMap[t.ns & "/" & t.name] = target
    c.nameMap[t.name] = target

  # the reference graph was collected before the suppression: redirect its
  # edges (a suppressed name's only reference is its target, so the
  # transitive closure is unchanged — zone/unsplit decisions already made
  # above are unaffected)
  for i in 0 ..< m.types.len:
    for ri in 0 ..< typeRefNames[i].len:
      let r = typeRefNames[i][ri]
      if r in c.aAlias:
        typeRefNames[i][ri] = c.aAlias[r]

  if c.aAlias.len > 0:
    var ptrRefs2: Table[string, bool]
    for (k, v) in ptrRefs.pairs:
      let slash = k.rfind('/')
      var k2 = k
      let refName = k[slash + 1 ..< k.len]
      if refName in c.aAlias:
        k2 = k[0 ..< slash] & "/" & c.aAlias[refName]
      ptrRefs2[k2] = v
    ptrRefs = ptrRefs2

  # direct type-name references of every const: the declared type plus,
  # for struct-typed consts, the field types
  var constRefs: seq[seq[string]] = newSeq[seq[string]](m.consts.len)
  for ci in 0 ..< m.consts.len:
    var tn = leafNamed(m.consts[ci].ty)
    if tn.len > 0:
      if tn in c.aAlias:
        tn = c.aAlias[tn]
      constRefs[ci].add tn
      if c.typeKind.hasKey(tn) and c.typeKind[tn] == tkStruct:
        for f in m.types[firstIdx[tn]].fields:
          let fr = leafNamed(f.ty)
          if fr.len > 0:
            constRefs[ci].add fr

  # direct type-name references of every fn signature, and which DLLs
  # reference each type (fallback owner for unmapped types)
  var fnRefNames: seq[seq[string]] = newSeq[seq[string]](m.fns.len)
  var referencedBy: Table[string, seq[string]]
  for fi in 0 ..< m.fns.len:
    var rs: seq[string]
    for p in m.fns[fi].params:
      var pn = leafNamed(p.ty)
      if pn.len > 0:
        if pn in c.aAlias:
          pn = c.aAlias[pn]
        rs.add pn
    var rn = leafNamed(m.fns[fi].ret)
    if rn.len > 0:
      if rn in c.aAlias:
        rn = c.aAlias[rn]
      rs.add rn
    fnRefNames[fi] = rs

    for r in rs:
      if r in firstIdx: # only types defined in this winmd
        if r notin referencedBy:
          referencedBy[r] = @[]
        let dn =
          if m.fns[fi].moduleName.len > 0:
            m.fns[fi].moduleName
          else:
            "misc"
        var found = false
        for x in referencedBy[r]:
          if x == dn:
            found = true
        if not found:
          referencedBy[r].add dn

  # a type lives in the module of its defining header; km-merge
  # versioned names (X_12, X_1_0) inherit the header of their stem; the
  # remaining unmapped types fall back to the (single) DLL that
  # references them, or win32base
  var hdrLookup: Table[string, string]
  for i in 0 ..< m.types.len:
    let n = m.types[i].name
    if n in hdrLookup:
      continue
    if n in typeHdr:
      hdrLookup[n] = typeHdr[n]
    else:
      var hit = ""
      # strip trailing _digit groups (km merge versions, X_1_0 etc.)
      # until the stem is mapped
      var stem = n
      var tries = 0
      while stem.len > 0 and tries < 5:
        var i2 = stem.len - 1
        while i2 >= 0 and stem[i2] in '0' .. '9':
          dec i2
        if i2 < 1 or stem[i2] != '_':
          break
        let base = stem[0 ..< i2]
        if base in typeHdr:
          hit = typeHdr[base]
          break
        stem = base
        inc tries
      hdrLookup[n] = hit

  var ownerOf: Table[string, string]
  for t in m.types:
    let n {.cursor.} = t.name
    if hdrLookup[n] != "":
      ownerOf[n] = headerOwnerKey(hdrLookup[n])
    elif n in referencedBy and referencedBy[n].len == 1:
      ownerOf[n] = referencedBy[n][0]
    else:
      ownerOf[n] = ""

  # win32base is closed under type references: a base type (or base
  # constant, including struct-const field types) may only reference
  # base types
  var clOwnerKey: seq[string]
  var clRefs: seq[seq[string]]
  for i in 0 ..< m.types.len:
    # suppressed aliases are not emitted: their references do not exist
    if m.types[i].name in c.aAlias:
      continue
    clOwnerKey.add m.types[i].name
    clRefs.add typeRefNames[i]
  for ci in 0 ..< m.consts.len:
    var tn = m.consts[ci].ty.name
    if tn.len > 0 and tn in c.aAlias:
      tn = c.aAlias[tn]
    if tn.len > 0:
      clOwnerKey.add tn
      var rs: seq[string]
      if c.typeKind.hasKey(tn) and c.typeKind[tn] == tkStruct:
        rs.add tn
        for f in m.types[firstIdx[tn]].fields:
          if f.ty.name.len > 0:
            rs.add f.ty.name
      clRefs.add rs

  var keyToItems: Table[string, seq[int]]
  for ki in 0 ..< clOwnerKey.len:
    keyToItems.addGrouped(clOwnerKey[ki], ki)

  # severed: "srcName/refName" pairs rendered opaquely (`ptr pointer`)
  # to cut a dependency edge without moving any type out of its header
  var severed: HashSet[string]
  var baseSeen: HashSet[string]
  var baseWork: seq[int]
  for ki in 0 ..< clOwnerKey.len:
    if ownerOf.getOrDefault(clOwnerKey[ki], "") == "" and clOwnerKey[ki] notin baseSeen:
      baseSeen.incl clOwnerKey[ki]
      for j in keyToItems[clOwnerKey[ki]]:
        baseWork.add j

  proc runClosure() =
    while baseWork.len > 0:
      let ki = baseWork[baseWork.len - 1]
      baseWork.del(baseWork.len - 1)
      for r in clRefs[ki]:
        # a base handle with a module pointee renders opaquely
        # (`distinct pointer`) and therefore does not reference it
        if ki < m.types.len and m.types[ki].kind == tkHandle and
            m.types[ki].name in ownerOf and ownerOf[m.types[ki].name] == "" and
            r == m.types[ki].underlying.name:
          continue
        # severed references render opaquely and do not reference
        if ki < m.types.len and (m.types[ki].name & "/" & r) in severed:
          continue
        if r in ownerOf and ownerOf[r] != "" and r notin baseSeen:
          baseSeen.incl r
          ownerOf[r] = ""
          for j in keyToItems[r]:
            baseWork.add j

  runClosure()

  # where a constant lives: its own header if the map knows the name,
  # else with the module of its declared type (empty -> base)
  proc constOwner(cc: ModelConst): string =
    if cc.name in typeHdr:
      return headerOwnerKey(typeHdr[cc.name])
    var tn = cc.ty.name
    if tn.len > 0 and tn in c.aAlias:
      tn = c.aAlias[tn]
    if tn.len > 0:
      return ownerOf.getOrDefault(tn, "")
    result = ""

  # force every header module a const may need into existence before the
  # cycle loop allocates per-module arrays (headerOwnerKey creates lazily)
  for ci in 0 ..< m.consts.len:
    discard constOwner(m.consts[ci])

  # the module dependency graph must stay acyclic: base-ify the referenced
  # type of every back edge, re-close, repeat. For each back edge the
  # smaller side is base-ified: the referenced type, or the type that
  # references it — an alias like PIO_SECURITY_CONTEXT has a deep
  # reference closure (it follows the pointee chain), so breaking the
  # cycle on the referencing side usually base-ifies far fewer types.
  var cycleEdges: seq[CycleEdge]
  proc closureSize(start: string): int =
    if start notin firstIdx:
      return 0

    var seen: HashSet[string]
    var q: seq[int] = @[firstIdx[start]]
    seen.incl start
    while q.len > 0:
      let idx = q[q.len - 1]
      q.del(q.len - 1)
      if ownerOf.getOrDefault(m.types[idx].name, "") == "":
        continue
      inc result
      for r in typeRefNames[idx]:
        if r in firstIdx and r notin seen:
          seen.incl r
          q.add firstIdx[r]

  while true:
    var adj: seq[seq[tuple[to: int, refName: string, srcName: string]]] =
      newSeq[seq[tuple[to: int, refName: string, srcName: string]]](moduleOrder.len)
    for i in 0 ..< m.types.len:
      # suppressed aliases are not emitted: no module edge from them
      if m.types[i].name in c.aAlias:
        continue
      let o1 = ownerOf[m.types[i].name]
      for r in typeRefNames[i]:
        let o2 = ownerOf.getOrDefault(r, "")
        # base handles with a module pointee render opaquely: no edge
        if o1 == "" and m.types[i].kind == tkHandle and r == m.types[i].underlying.name and
            o2 != "":
          continue
        # severed references render opaquely: no edge
        if (m.types[i].name & "/" & r) in severed:
          continue
        if o2 != "" and o2 != o1 and o2 in modulePos:
          adj[modulePos[o1]].add (modulePos[o2], r, m.types[i].name)
    for fi in 0 ..< m.fns.len:
      let fo = fnOwner[fi]
      if fo notin modulePos:
        continue
      for r in fnRefNames[fi]:
        let o2 = ownerOf.getOrDefault(r, "")
        if o2 != "" and o2 != fo and o2 in modulePos:
          adj[modulePos[fo]].add (modulePos[o2], r, "")
    for ci in 0 ..< m.consts.len:
      let co = constOwner(m.consts[ci])
      if co == "" or co notin modulePos:
        continue
      for r in constRefs[ci]:
        let o2 = ownerOf.getOrDefault(r, "")
        if o2 != "" and o2 != co and o2 in modulePos:
          adj[modulePos[co]].add (modulePos[o2], r, "")

    cycleEdges.setLen(0)
    if not allBackEdges(moduleOrder.len, adj, cycleEdges):
      break

    # pass 1 (pre-pass): sever every severable edge on the cycles
    # first and re-detect — cutting any edge of a cycle dissolves it
    # and keeps both types in their defining headers (the reference
    # renders opaquely); base-ification only breaks what cannot be
    # severed
    var didSever = false
    for e in cycleEdges:
      for j in 0 ..< e.pathSrc.len:
        let s = e.pathSrc[j]
        let key = s & "/" & e.pathRef[j]
        if s.len > 0 and key in ptrRefs and key notin severed:
          severed.incl key
          didSever = true
      let key0 = e.srcName & "/" & e.refName
      if e.srcName.len > 0 and key0 in ptrRefs and key0 notin severed:
        severed.incl key0
        didSever = true
    if didSever:
      continue

    # pass 2: nothing left to sever — base-ify
    for e in cycleEdges:
      var pick = e.refName
      if e.srcName.len > 0 and closureSize(e.srcName) < closureSize(e.refName):
        pick = e.srcName
      # prefer base-ifying the type a pointer alias points at over the
      # alias itself: a struct's reference closure is its fields, while
      # an alias is just its pointee — the pointee's header then keeps
      # the real type and only the alias is rendered opaquely in base
      if pick in firstIdx and m.types[firstIdx[pick]].kind == tkHandle and
          m.types[firstIdx[pick]].underlying.name.len > 0:
        let pt = m.types[firstIdx[pick]].underlying.name
        # only while the pointee is still in a module — if it is
        # already base, fall back to base-ifying the alias itself
        # (rendered opaquely), otherwise the loop never converges
        if pt in firstIdx and ownerOf.getOrDefault(pt, "") != "" and
            m.types[firstIdx[pt]].kind notin {tkHandle, tkUnscopedEnum}:
          pick = pt
      if ownerOf.getOrDefault(pick, "") != "":
        ownerOf[pick] = ""

    var ownerSnap: seq[tuple[nm: string, o: string]]
    for (nm, o) in ownerOf.pairs:
      ownerSnap.add (nm, o)
    for (nm, o) in ownerSnap:
      if o == "" and nm notin baseSeen:
        baseSeen.incl nm
        for j in keyToItems.getOrDefault(nm, @[]):
          baseWork.add j
    runClosure()

  # opaque stubs (referenced in signatures, not defined in this winmd)
  # have no dependencies of their own: place each in the module that
  # references it. A stub referenced by several modules goes to the
  # earliest one (moduleOrder) and the rest import it — since a stub
  # references nothing, this cannot create a cycle.
  var stubsByModule: Table[string, seq[string]]
  for n in c.unknownTypes:
    var mods: seq[string]
    proc addMod(x: string) =
      if x.len > 0 and not contains(mods, x):
        mods.add x

    for fi in 0 ..< m.fns.len:
      for r in fnRefNames[fi]:
        if r == n:
          addMod(fnOwner[fi])
    for i in 0 ..< m.types.len:
      for r in typeRefNames[i]:
        if r == n:
          addMod(ownerOf[m.types[i].name])
    for ci in 0 ..< m.consts.len:
      for r in constRefs[ci]:
        if r == n:
          addMod(constOwner(m.consts[ci]))
    if mods.len > 0:
      var pick = mods[0]
      for x in mods:
        if x in modulePos and pick in modulePos and modulePos[x] < modulePos[pick]:
          pick = x
      ownerOf[n] = pick

      stubsByModule.addGrouped(pick, n)

  # group types / constants by owning module
  var typesByModule: Table[string, seq[int]]
  for idx in order:
    # suppressed aliases are not emitted: they do not keep a module alive
    if m.types[idx].name in c.aAlias:
      continue
    let o = ownerOf[m.types[idx].name]
    if o != "":
      typesByModule.addGrouped(o, idx)

  var constsByModule: Table[string, seq[int]]
  for ci in 0 ..< m.consts.len:
    let o = constOwner(m.consts[ci])
    if o != "":
      constsByModule.addGrouped(o, ci)

  # constant name -> all rows with that name (in m.consts order); rows with
  # an arch tag are emitted as one const with a `when` block
  var constGroups: Table[string, seq[int]]
  for ci in 0 ..< m.consts.len:
    constGroups.addGrouped(m.consts[ci].name, ci)

  # names whose arch-`when` const has already been emitted (once per group)
  var constGroupEmitted: Table[string, bool]
  var membersByModule: Table[string, seq[int]]
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkUnscopedEnum:
      let o = ownerOf[m.types[i].name]
      if o != "":
        membersByModule.addGrouped(o, i)

  # module -> modules it depends on
  var moduleDeps: Table[string, seq[string]]
  proc addDep(a, b: string) =
    if a == b:
      return
    if a notin moduleDeps:
      moduleDeps[a] = @[]
    if not contains(moduleDeps[a], b):
      moduleDeps[a].add b

  for i in 0 ..< m.types.len:
    # suppressed aliases are not emitted: no module dep from them
    if m.types[i].name in c.aAlias:
      continue
    let o1 = ownerOf[m.types[i].name]
    if o1 == "":
      continue
    for r in typeRefNames[i]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "" and (m.types[i].name & "/" & r) notin severed:
        addDep(o1, o2)
  for fi in 0 ..< m.fns.len:
    for r in fnRefNames[fi]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "":
        addDep(fnOwner[fi], o2)

  # constants reference their declared type (and field types for structs)
  for ci in 0 ..< m.consts.len:
    let co = constOwner(m.consts[ci])
    if co == "":
      continue
    for r in constRefs[ci]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "":
        addDep(co, o2)
  for v in moduleDeps.mvalues():
    v.sort()

  # ---- header ---------------------------------------------------------------
  c.text.add "# generated by winmd2nim from Windows.Win32.winmd — do not edit\n"
  c.text.add "# types=" & $(c.knownTypes.len) & " fns=" & $m.fns.len & " consts=" &
    $m.consts.len & "\n\n"

  # ---- types -------------------------------------------------------------------
  # Every module gets one single `type` section of its own: forward
  # references resolve within the section and across modules via imports
  # (the module dependency graph is a DAG by construction).
  # reference resolution while emitting an arch variant row: refs to
  # other split names resolve to the SAME variant's row (X_AMD64 may
  # contain Y_AMD64, not the Y selector alias)
  # the arch set of the variant currently being emitted (empty = not in a
  # variant). References to split types are rewritten to the variant whose
  # arch set matches — not by index, because a km-merge chain sub-type can
  # have fewer variants than its parent (an arch with no sub-struct for a
  # member simply has no row for that member).
  var variantCtx: set[Architecture]
  proc renderRef(t: SigType): string =
    # walk pointer layers to the leaf named type (an array / by-ref in
    # between prevents the rewrite)
    var leaf = t
    var nPtr = 0
    while leaf.base == bPtr:
      inc nPtr
      leaf = leaf.inner[]
    if variantCtx.len > 0 and nPtr <= 2 and leaf.base == bNamed and
        leaf.name in splitInfo:
      var matched = -1
      let sets = splitInfo[leaf.name]
      for i in 0 ..< sets.len:
        if sets[i] == variantCtx:
          matched = i
          break
      if matched >= 0:
        let v = variantOut[leaf.name][matched]
        if nPtr == 0:
          v
        elif nPtr == 1:
          "ptr " & v
        else:
          "ptr ptr " & v
      else:
        renderType(c, t)
    else:
      renderType(c, t)

  proc emitType(c: var GenCtx, m: Model, i: int, name: string) =
    let t = m.types[i]
    case t.kind
    of tkStruct:
      if t.fields.len == 0:
        c.line "  " & name & "* = object"
      else:
        # layout comes from the winmd type attributes (the Rust reference
        # uses the same): ExplicitLayout (0x10) means the fields are
        # overlaid — a C union — so emit {.union.}; a ClassLayout packing
        # emits {.packed.}.
        # TODO AlignmentAttribute is read into alignSize but
        #     not emitted)
        var pragmas: seq[string] = @["completeStruct"]
        if t.isUnion:
          pragmas.add "union"
        if t.packSize > 0:
          pragmas.add "packed"
        pragmas.add c.headerPragma(t.name)

        let pragma = renderPragma(pragmas)
        c.line "  " & name & "*" & pragma & " = object"
        var fUsed: HashSet[string]
        for f in t.fields:
          let
            fn = fUsed.freshIdent(f.nimName)
            fldRef = leafNamed(f.ty)

          if fldRef.len > 0 and (t.name & "/" & fldRef) in severed:
            c.line "    " & esc(fn) & "*: pointer"
          else:
            c.line "    " & esc(fn) & "*: " & renderRef(f.ty)
    of tkHandle:
      # curated string-pointer aliases (README: the LPSTR/PSTR family
      # maps to the idiomatic Nim string pointer types — same ABI)
      case t.name
      of "PSTR", "PCSTR", "LPSTR", "LPCSTR":
        c.line "  " & name & "* = cstring"
        return
      of "PWSTR", "PCWSTR", "LPWSTR", "LPCWSTR":
        # the wide variant: same ABI as LPWSTR / ptr uint16
        c.line "  " & name & "* = ptr UncheckedArray[uint16]"
        return
      else:
        discard

      var base = renderRef(t.underlying)

      # base handles with a module pointee, or a pointee edge that the
      # cycle resolver severed: render opaquely
      let undRef = leafNamed(t.underlying)
      # the graph keys use the redirected name for suppressed aliases
      var undRefG = undRef
      if undRefG.len > 0 and undRefG in c.aAlias:
        undRefG = c.aAlias[undRefG]
      let isSevered = undRefG.len > 0 and (t.name & "/" & undRefG) in severed
      if isSevered:
        base = "pointer #[" & base & "]#"

      # a base that is already a unique type (an object, a distinct handle,
      # a scoped enum, or a pointer to one) keeps its identity without
      # `distinct`; a shared base (primitive, pointer, void-alias, unscoped
      # enum) needs `distinct` to stay a separate type. A void-alias handle
      # is a plain `void` alias, and a severed pointee renders opaquely as
      # `pointer` (shared)
      let hp = c.headerBlock(t.name)
      if isSevered or (not isUniqueType(c, t.underlying) and base != "void"):
        c.line "  " & name & "*" & hp & " = distinct " & base
      else:
        c.line "  " & name & "*" & hp & " = " & base
    of tkEnum:
      c.line "  " & name & "*" & c.headerBlock(t.name) & " = enum"
      for f in t.fields:
        if f.hasConstant:
          let member = esc(c.freshName(f.nimName))
          c.line "    " & member & " = " & $f.constant
    of tkUnscopedEnum:
      let base = renderType(c, t.underlying)
      c.line "  " & name & "*" & c.headerBlock(t.name) & " = " & base
    of tkDelegate:
      if t.fields.len == 0:
        c.line "  " & name & "* = pointer"
      else:
        var s = "proc ("
        var pUsed: HashSet[string]
        for k in 0 ..< t.fields.len:
          if k > 0:
            s.add ", "
          let
            pn = pused.freshIdent(t.fields[k].nimName)
            ft = t.fields[k].ty

          var ftRef = leafNamed(ft)
          # the graph keys use the redirected name for suppressed aliases
          if ftRef.len > 0 and ftRef in c.aAlias:
            ftRef = c.aAlias[ftRef]
          if ftRef.len > 0 and (t.name & "/" & ftRef) in severed:
            s.add esc(pn) & ": ptr pointer"
          else:
            s.add esc(pn) & ": " & renderRef(ft)
        var retRef = leafNamed(t.ret)
        if retRef.len > 0 and retRef in c.aAlias:
          retRef = c.aAlias[retRef]
        if retRef.len > 0 and (t.name & "/" & retRef) in severed:
          s.add "): pointer"
        else:
          s.add "): " & renderRef(t.ret)
        c.line "  " & name & "*" & c.headerBlock(t.name) & " = " & s & " {.stdcall.}"
    of tkInterface:
      c.line "  " & name & "*" & c.headerBlock(t.name) & " = distinct object"

  var kindSeen = false
  proc emitKind(kind: TypeKind, idxList: seq[int], label: string) =
    var has = false
    for idx in idxList:
      if m.types[idx].kind == kind and m.types[idx].name notin c.aAlias:
        has = true
        break

    if not has:
      return

    if kindSeen:
      c.line ""
    c.line "  # " & label
    for idx in idxList:
      if m.types[idx].kind == kind and m.types[idx].name notin c.aAlias:
        if rowVariant[idx] >= 0:
          variantCtx = splitInfo[m.types[idx].name][rowVariant[idx]]
        else:
          variantCtx = {}
        emitType(c, m, idx, esc(typeNames[idx]))
        variantCtx = {}
    kindSeen = true

  proc emitKinds(idxList: seq[int]) =
    emitKind(tkStruct, idxList, "structs")
    emitKind(tkHandle, idxList, "typdefs")
    emitKind(tkEnum, idxList, "scoped enums")
    emitKind(tkUnscopedEnum, idxList, "unscoped enums ")
    emitKind(tkDelegate, idxList, "delegates")
    emitKind(tkInterface, idxList, "interfaces")

  # selector-alias blocks: one when/elif/else per split name — each
  # name's variant conditions differ from the others, so the chains
  # cannot be shared
  proc emitAliasBlocks(nameSet: seq[string]) =
    for n in nameSet:
      var conds: seq[set[Architecture]]
      for a in splitInfo[n]:
        var found = false
        for b in conds:
          if a == b:
            found = true
            break
        if not found:
          conds.add a
      var bi = 0
      for a in conds:
        let hdr = if bi == 0: "when " else: "elif "
        let cond = archCond(a)
        c.line hdr & cond & ":"
        for vi in 0 ..< splitInfo[n].len:
          if a == splitInfo[n][vi]:
            c.line "  type " & esc(m.types[nameRows[n][0]].nimName) & "* = " &
              variantOut[n][vi]
            break
        inc bi
      c.line "else:"
      c.line "  type " & esc(m.types[nameRows[n][0]].nimName) & "* = " & variantOut[n][
        0
      ]

  var baseTypeIdxs: seq[int]
  for idx in order:
    # suppressed aliases are not emitted: they do not keep the base alive
    if m.types[idx].name in c.aAlias:
      continue
    if ownerOf[m.types[idx].name] == "":
      baseTypeIdxs.add idx

  var baseA: seq[int]
  var baseB: seq[int]
  for idx in baseTypeIdxs:
    let nm = m.types[idx].name
    # split names always zone A: their rows are the per-arch variants,
    # which must precede the selector aliases
    if nm notin splitInfo and nm in zoneB:
      baseB.add idx
    else:
      baseA.add idx

  var baseSplitNames: seq[string]
  var seenSplit: Table[string, bool]
  var baseSplitList: seq[string]
  for (n, l) in splitInfo.pairs:
    baseSplitList.add n

  for n in baseSplitList:
    if ownerOf.getOrDefault(n, "") == "" and n notin seenSplit:
      baseSplitNames.add n
      seenSplit[n] = true

  c.line "type"
  if c.guidUsed:
    # System.Guid is a TypeRef to mscorlib in this winmd (no TypeDef):
    # emit the 16-byte C GUID layout so by-value fields keep the ABI
    c.line "  # System.Guid (TypeRef to mscorlib): 16-byte C GUID layout"
    c.line "  Guid* {.inheritable, pure, completeStruct.} = object"
    c.line "    Data1*: uint32"
    c.line "    Data2*: uint16"
    c.line "    Data3*: uint16"
    c.line "    Data4*: array[8, uint8]"
    c.line ""

  emitKinds(baseA)
  c.line ""
  emitAliasBlocks(baseSplitNames)
  if baseSplitNames.len > 0:
    c.line ""
  if baseB.len > 0:
    c.line "type"
    emitKinds(baseB)
    c.line ""

  # ---- constants -------------------------------------------------------------
  ## True when the const rows of this name are emitted as a standalone
  ## `when` block (a `const` section cannot contain `when` statements).
  proc constIsWhen(ci: int): bool =
    let group = constGroups[m.consts[ci].name]
    if group.len <= 1:
      return false
    let v0 = m.consts[group[0]]
    var sameVal = true
    var anyArch = false
    for ci2 in group:
      let r = m.consts[ci2]
      if r.arch.len > 0:
        anyArch = true
      if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
          r.wideStr != v0.wideStr:
        sameVal = false
    anyArch and not sameVal

  ## True when the const's value is a cast to a pointer type: the VM
  ## cannot evaluate `cast[T](int)` for a pointer T at compile time, so
  ## the const is emitted as a standalone `template` declaration (a
  ## `const` section cannot hold templates either).
  proc constIsCastPtr(ci: int): bool =
    let cc = m.consts[ci]
    if cc.isStr or cc.value == 0:
      return false
    # a same-value group emits one const from its first row (the rest
    # are deduped); every other case emits one const per row
    let group = constGroups[cc.name]
    var ci2 = ci
    if group.len > 1:
      let v0 = m.consts[group[0]]
      var sameVal = true
      for ci3 in group:
        let r = m.consts[ci3]
        if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
            r.wideStr != v0.wideStr:
          sameVal = false
          break
      if sameVal:
        ci2 = group[0]
    renderedIsPtr(c, m.consts[ci2].ty)

  ## Emits one const; returns true when it emitted a standalone block
  ## (a `when` or a pointer-cast `template`, which ends the surrounding
  ## `const` section).
  proc emitFreeConst(ci: int): bool =
    let cc = m.consts[ci]

    # constant rows sharing a name:
    #  - all rows carry the same value -> one plain const (skip the rest)
    #  - rows carry an arch tag and differ -> one const per arch set in a
    #    `when` block, each branch with an explicit arch condition
    #  - otherwise -> one const per row, deduped by freshName
    let group = constGroups[cc.name]
    var sameVal = true
    var anyArch = false
    let v0 = m.consts[group[0]]
    for ci2 in group:
      let r = m.consts[ci2]
      if r.arch.len > 0:
        anyArch = true
      if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
          r.wideStr != v0.wideStr:
        sameVal = false
    var singleConst = group.len > 1 and (sameVal or anyArch)
    if singleConst:
      if constGroupEmitted.getOrDefault(cc.name, false):
        return # the group's const was already emitted
      constGroupEmitted[cc.name] = true

    let name = esc(c.freshName(cc.nimName))

    # wide (utf-16) string constants: not translated for now — a comment
    # with the name, the value and a TODO
    if cc.isStr and cc.wideStr:
      c.line "  # " & name & " = " & escape(cc.strVal) &
        "  # TODO: wide string constant (utf-16)"
      return false

    # value pipeline for one row: (type string, value string, value is a
    # cast to a pointer type — the VM cannot evaluate it at compile time,
    # so the const is emitted as a template)
    proc renderRow(ci2: int): (string, string, bool) =
      let cc2 = m.consts[ci2]
      var et = cc2.ty
      # constants on handle typedefs carry pvVoid; recover the base kind
      if cc2.ty.name.len > 0 and cc2.ty.name in c.typePrims:
        et.prim = c.typePrims[cc2.ty.name]
      var tyS =
        if cc2.isStr:
          "string"
        else:
          renderType(c, et)
      var val = renderConstValue(et, cc2)
      var isCast = false
      let isPtrTy = renderedIsPtr(c, cc2.ty)
      if not cc2.isStr and cc2.value == 0 and isPtrTy:
        val = "nil"
      elif not cc2.isStr and cc2.value != 0 and isPtrTy:
        val = "cast[" & tyS & "](" & renderIntConst(cc2.ty.prim, cc2.value) & ")"
        isCast = true

      # struct-typed constants (e.g. DEVPKEY_*: only the trailing propId is
      # in the metadata): emit a struct literal with defaults + last field
      if not cc2.isStr and cc2.ty.name.len > 0 and
          c.typeKind.getOrDefault(cc2.ty.name, tkStruct) == tkStruct and
          cc2.ty.name in c.typeKind and c.typeKind[cc2.ty.name] == tkStruct:
        var stype = m.types[firstIdx[cc2.ty.name]]
        if stype.fields.len > 0:
          var init = esc(typeNames[firstIdx[cc2.ty.name]]) & "("
          for k in 0 ..< stype.fields.len:
            if k > 0:
              init.add ", "
            let f = stype.fields[k]
            init.add esc(f.nimName) & ": "
            if k == stype.fields.len - 1:
              var uty = f.ty
              if uty.name.len > 0 and uty.name in c.typePrims:
                uty.prim = c.typePrims[uty.name]
              var lit = renderIntConst(uty.prim, cc2.value)
              # distinct base types need an explicit conversion
              if f.ty.base == bNamed and
                  c.typeKind.getOrDefault(f.ty.name, tkStruct) == tkHandle and
                  c.typeKind.hasKey(f.ty.name):
                let tn2 =
                  if f.ty.name in c.aAlias:
                    c.aAliasFinal[f.ty.name]
                  else:
                    fixIdent(f.ty.name)
                lit = esc(tn2) & "(" & lit & ")"
              init.add lit
            else:
              init.add defaultLit(c, m, firstIdx, f.ty)
          init.add ")"
          val = init

      # unsigned constant whose target type is signed (e.g. HRESULT =
      # distinct int32): render the wrapped two's-complement value
      if not cc2.isStr and tyS != "uint32":
        if et.prim == pvI4 and cc2.value > 2147483647 and tyS != "uint32":
          val = $(cast[int32](cc2.value)) & "'i32"
        elif et.prim == pvI2 and cc2.value > 32767 and tyS != "uint16":
          val = $(cast[int16](cc2.value)) & "'i16"
        elif et.prim == pvI1 and cc2.value > 127 and tyS != "uint8":
          val = $(cast[int8](cc2.value)) & "'i8"

      # this compiler never converts implicitly to distinct types:
      # wrap the literal in an explicit conversion (a value that is
      # already an explicit cast is left as-is)
      if not cc2.isStr and cc2.ty.name.len > 0 and c.typeKind.hasKey(cc2.ty.name) and
          c.typeKind[cc2.ty.name] == tkHandle and tyS != "uint32" and
          not val.startsWith("cast["):
        let tname = esc(c.nameMap.getOrDefault(cc2.ty.name, fixIdent(cc2.ty.name)))
        val = tname & "(" & val & ")"
      result = (tyS, val, isCast)

    if singleConst and sameVal:
      let (tyS, val, isCast) = renderRow(group[0])
      if isCast:
        # the VM cannot evaluate a cast to a pointer type at compile
        # time: emit a template instead of a const (a `const` section
        # cannot hold templates, so this ends the surrounding section).
        # No header pragma: a template emits no C declaration of its own
        c.line "template " & name & "*: untyped = " & val
      else:
        c.line "  " & name & "*: " & tyS & " = " & val
      return false
    elif singleConst:
      # narrowest arch set first (stable); untagged rows (if any) sort
      # last and become the `else` default. Rows can carry different
      # field types (e.g. U32 on x86 / U64 on x64), so the `when`
      # surrounds the whole declaration (name, type and value)
      var sorted = group
      for i in 1 ..< sorted.len:
        var j = i
        while j > 0 and
            rowArchRank(m.consts[sorted[j]]) < rowArchRank(m.consts[sorted[j - 1]]):
          swap(sorted[j], sorted[j - 1])
          dec j
      var rowVals: seq[(string, string, bool)]
      for ci2 in sorted:
        rowVals.add renderRow(ci2)
      # column 0: a `const` section only ends on a dedent, so the
      # `when` block must sit outside the section's indentation
      for i in 0 ..< sorted.len:
        # every branch has an explicit arch condition (no `else`): each
        # branch is a separate const declaration, so on archs no row
        # covers the const is simply not declared
        let cond =
          if i == 0:
            "when " & archCond(m.consts[sorted[i]].arch)
          else:
            "elif " & archCond(m.consts[sorted[i]].arch)
        c.line cond & ":"
        let (tyS, val, isCast) = rowVals[i]
        if isCast:
          # a cast to a pointer type: a template, not a const (the VM
          # cannot evaluate it at compile time)
          c.line "  template " & name & "*: untyped = " & val
        else:
          c.line "  const " & name & "*: " & tyS & " = " & val
      return true
    let (tyS, val, isCast) = renderRow(ci)
    if isCast:
      c.line "template " & name & "*: untyped = " & val
    else:
      c.line "  " & name & "*: " & tyS & " = " & val

  proc emitMembers(enumIdx: int) =
    let t = m.types[enumIdx]
    let baseName = esc(typeNames[enumIdx])
    for f in t.fields:
      if f.hasConstant:
        let member = esc(c.freshName(f.nimName))
        c.line "  " & member & "*: " & baseName & " = " &
          renderIntConst(t.underlying.prim, f.constant)

  ## Wide string consts emit a comment line only — a `const` section with
  ## no real entries would not parse.
  proc constIsWide(ci: int): bool =
    let cc = m.consts[ci]
    cc.isStr and cc.wideStr

  ## A `const` section cannot contain `when` statements or `template`
  ## declarations: arch-`when` consts and pointer-cast consts are emitted
  ## as standalone blocks and the section header is (re-)emitted around
  ## them.
  proc emitConstBlock(constIdxs: seq[int], memberIdxs: seq[int]) =
    if constIdxs.len == 0 and memberIdxs.len == 0:
      return
    var inSection = false
    var constComment = false
    for ci in constIdxs:
      if constIsWhen(ci) or constIsCastPtr(ci):
        if inSection:
          c.line ""
          inSection = false
        discard emitFreeConst(ci)
      elif constIsWide(ci):
        discard emitFreeConst(ci)
      else:
        if not inSection:
          c.line "const"
          inSection = true
        if not constComment:
          c.line "  # free constants"
          constComment = true
        discard emitFreeConst(ci)
    if memberIdxs.len > 0:
      if inSection:
        c.line ""
      else:
        c.line "const"
        inSection = true
      c.line "  # unscoped enum members"
      for i in memberIdxs:
        emitMembers(i)
      c.line ""
    elif inSection:
      c.line ""

  var baseConstIdxs: seq[int]
  for ci in 0 ..< m.consts.len:
    if constOwner(m.consts[ci]) == "":
      baseConstIdxs.add ci

  var baseMemberIdxs: seq[int]
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkUnscopedEnum and ownerOf[m.types[i].name] == "":
      baseMemberIdxs.add i
  emitConstBlock(baseConstIdxs, baseMemberIdxs)

  # the base module is emitted only when it still has content (stubs now
  # live in their referencing module and the preamble aliases are gone,
  # so this is normally empty)
  var baseEmitted =
    baseTypeIdxs.len > 0 or baseSplitNames.len > 0 or baseConstIdxs.len > 0 or
    baseMemberIdxs.len > 0 or c.guidUsed

  # ---- functions + per-module assembly ---------------------------------------
  # header-only modules can end up empty after base-closure / cycle
  # resolution — drop them and any dep edge pointing at them
  var emitted: Table[string, bool]
  for k in 0 ..< moduleOrder.len:
    let dn = moduleOrder[k]
    emitted[dn] =
      moduleIdx[dn].len > 0 or dn in typesByModule or dn in constsByModule or
      dn in membersByModule or dn in stubsByModule
  result.mods = @[]
  for k in 0 ..< moduleOrder.len:
    let dn = moduleOrder[k]
    if not emitted[dn]:
      continue

    var t = newStringOfCap(96 * moduleIdx[dn].len)
    t.add "# generated by winmd2nim from Windows.Win32.winmd — " & dn &
      " (do not edit)\n"

    # list import: win32base first, then the scanned dependencies
    var deps: seq[string]
    if baseEmitted:
      deps.add "win32base"

    for k2 in 0 ..< moduleOrder.len:
      let d = moduleOrder[k2]
      if d != dn and emitted.getOrDefault(d, false) and
          contains(moduleDeps.getOrDefault(dn, @[]), d):
        deps.add dllNames[k2]

    if deps.len > 0:
      let deps = deps.join(", ")
      t.add "import ./[" & deps & "]\n"
      t.add "export " & deps & "\n"
    t.add "\n"

    if dn in stubsByModule:
      t.add "type\n\n"
      t.add "  # opaque stubs: referenced in signatures, not defined in this winmd\n"
      for n in stubsByModule[dn]:
        let name = esc(c.stubNames[n])
        t.add "  " & name & "* = distinct object\n"
      t.add "\n"

    if dn in typesByModule:
      let l0 = c.text.len
      var mA: seq[int]
      var mB: seq[int]
      for idx in typesByModule[dn]:
        let nm = m.types[idx].name
        if nm notin splitInfo and nm in zoneB:
          mB.add idx
        else:
          mA.add idx

      var mSplit: seq[string]
      var seenS: HashSet[string]
      for idx in typesByModule[dn]:
        let n = m.types[idx].name
        if n in splitInfo and n notin seenS:
          mSplit.add n
          seenS.incl n

      proc nonEmpty(s: string): bool =
        for line in s.split('\n'):
          let st = line.strip()
          if st.len > 0 and st != "type" and not st.startsWith("#"):
            return true
        return false

      # zone A: types that do not reference split names (before aliases)
      var sA = ""
      if mA.len > 0:
        c.line "type"
        emitKinds(mA)
        c.line ""
        sA = c.text[l0 ..< c.text.len]
        c.text.setLen(l0)
        if not nonEmpty(sA):
          sA = ""

      # selector aliases for this module's split names
      emitAliasBlocks(mSplit)
      var sAl = c.text[l0 ..< c.text.len]
      c.text.setLen(l0)
      if mSplit.len > 0:
        c.line ""

      # zone B: types that reference split names (after aliases)
      var sB = ""
      if mB.len > 0:
        c.line "type"
        emitKinds(mB)
        c.line ""
        sB = c.text[l0 ..< c.text.len]
        c.text.setLen(l0)
        if not nonEmpty(sB):
          sB = ""
      if sA.len > 0:
        t.add sA
      if sAl.len > 0:
        t.add sAl
      if sB.len > 0:
        t.add sB

    if dn in constsByModule or dn in membersByModule:
      let l0 = c.text.len
      emitConstBlock(
        constsByModule.getOrDefault(dn, @[]), membersByModule.getOrDefault(dn, @[])
      )
      t.add c.text[l0 ..< c.text.len]
      c.text.setLen(l0)

    if moduleIdx[dn].len > 0:
      # procs are grouped per export DLL (a header module's functions
      # may span several DLLs); the DLL module has exactly one group.
      # Sort by DLL, then by name, so each DLL appears in one
      # contiguous block and gets a single push/pop pair
      var fns: seq[tuple[dl, name: string, idx: int]]
      for i in moduleIdx[dn]:
        let f = m.fns[i]
        var dl = if f.moduleName.len > 0: f.moduleName else: "misc"
        # Nim resolves the dynlib name per target OS: lowercase and
        # strip the .dll suffix (user32, not USER32.dll); other
        # extensions (.drv, .cpl) are kept
        dl = dl.toLowerAscii()
        if dl.len > 4 and dl[dl.len - 4 .. dl.high] == ".dll":
          dl.setLen(dl.len - 4)
        fns.add (dl, f.name, i)
      fns.sort

      var curDll = ""
      for e in fns:
        let dl = e.dl
        let f = m.fns[e.idx]
        if dl != curDll:
          if curDll.len > 0:
            t.add "{.pop.}\n"
          t.add "{.push dynlib: \"" & dl & "\".}\n"
          curDll = dl
        var fn = c.freshName(f.nimName)

        # the --lowercase option: Nim convention is that proc names
        # start with a lowercase letter; the importc pragma keeps the
        # real linkage name. The normalized (case-insensitive) name is
        # unchanged, so no new collisions are introduced
        if c.lowerFirst and fn.len > 0 and fn[0] in {'A' .. 'Z'}:
          fn[0] = fn[0].toLowerAscii()

        let name = esc(fn)
        var s = "proc " & name & "*("
        var pUsed: HashSet[string]
        for pi in 0 ..< f.params.len:
          if pi > 0:
            s.add ", "

          let pn = pUsed.freshIdent(f.params[pi].nimName)

          s.add esc(pn) & ": " & renderType(c, f.params[pi].ty)
        s.add ")"
        let ret = renderType(c, f.ret)
        if ret != "void":
          s.add ": " & ret
        # Not all windows functions have side effects but we have no way of
        # knowing (or do we?)
        # when the emitted name is exactly the C name, bare `importc`
        # suffices (it imports under the symbol's own name)

        var pragmas = @["sideEffect"]
        if fn == f.importName:
          pragmas.add "importc"
        else:
          pragmas.add "importc: \"" & f.importName & "\""

        if f.stdcall:
          pragmas.add "stdcall"

        pragmas.add c.headerPragma(f.name)

        s.add renderPragma(pragmas) & "\n"
        t.add s
      t.add "{.pop.}\n"
    var fm: FnModule
    fm.dll = dn
    fm.modName = dllNames[k]
    fm.code = t
    result.mods.add fm
  result.base = c.text
  result.baseEmitted = baseEmitted

## Multi-module layout: a shared base module (unmapped types, stubs),
## one module per defining header (types + constants + functions with
## header provenance) and one per export DLL (functions without header
## provenance, wrapped in the DLL's dynlib statement); each module
## imports/exports only the modules its items reference.
proc generateModules*(
    m: Model,
    typeHdr: Table[string, string],
    emitHeaders: bool = false,
    lowerFirst: bool = false,
): seq[GenModule] =
  let core = generateCore(m, typeHdr, emitHeaders, lowerFirst)
  if core.baseEmitted:
    var gm: GenModule
    gm.name = "win32base"
    gm.code = core.base
    result.add gm

  for k in 0 ..< core.mods.len:
    var gm2: GenModule
    gm2.name = core.mods[k].modName
    gm2.code = core.mods[k].code
    result.add gm2
