# nameplan.nim — the generator's naming phase: assigns every emitted
# name from the Model alone (types, stubs, arch variants, suppressed
# A-aliases) and collects the name-level reference data the layout phase
# consumes. Pure: no module ownership, no text emission, and rendering
# is a function of the plan, not of mutable shared state.
#
# Passes (in order):
#   0. assign emitted type names in emission order (dedup suffixes,
#      per-arch variants + selector aliases)
#   1. collect the unknown (stubbable) type names referenced in
#      signatures — a pure walk, not a rendering side effect — and
#      assign the stub names
#   2. collect the direct type-name references of every type row, plus
#      which edges are pointer-shaped (severable)
#   3. zone split: color the names that (transitively) reference a
#      split name (they must be emitted after the selector aliases);
#      unsplit any name whose variants cannot be laid out
#   4. suppress the redundant A-suffix aliases and redirect the
#      reference edges through them

import std/[algorithm, sequtils, sets, strutils, tables]
import ./[model, signatures]

type
  ## The generator's naming decisions, computed from the Model alone:
  ## every emitted name, the stub names, the arch variants, the
  ## suppressed A-aliases, and the name-level reference data the layout
  ## phase consumes.
  NamePlan* = object ## emitted type name per m.types index
    typeNames*: seq[string]
    ## emission order: structs, handles, enums, delegates, interfaces
    order*: seq[int]
    ## "ns/name" or "name" -> emitted type name
    nameMap*: Table[string, string]
    ## TypeDef row -> emitted name, for names shared by multiple rows
    ## (anonymous nested types); nameMap alone cannot disambiguate them
    dupRowEmit*: Table[int, string]
    ## type name -> all m.types rows with that name (in model order)
    nameRows*: Table[string, seq[int]]
    ## type name -> first m.types row
    firstIdx*: Table[string, int]
    ## unknown type name -> emitted stub name
    stubNames*: Table[string, string]
    ## split name -> per-arch sets (one per variant row)
    splitInfo*: Table[string, seq[set[Architecture]]]
    ## split name -> emitted variant names
    variantOut*: Table[string, seq[string]]
    ## type row -> variant index (-1 = not a variant row)
    rowVariant*: seq[int]
    ## names that (transitively) reference a split name: emitted after
    ## the selector aliases
    zoneB*: HashSet[string]
    ## suppressed A-suffix alias: X -> Y (raw names); a handle X whose
    ## underlying type is a named type Y with X & "A" == Y
    ## (STARTUPINFOEX -> STARTUPINFOEXA): the emitted alias adds
    ## nothing, so it is not emitted and every reference to X resolves
    ## to Y's name
    aAlias*: Table[string, string]
    ## X -> emitted name references resolve to
    aAliasFinal*: Table[string, string]
    ## type name -> base primitive kind
    typePrims*: Table[string, Prim]
    ## type base is a pointer-ish type
    typePtr*: HashSet[string]
    ## type name -> kind (first row wins)
    typeKind*: Table[string, TypeKind]
    ## type names defined in the model (not stubs)
    knownTypes*: HashSet[string]
    ## direct type-name references of every type row (A-alias redirected)
    typeRefNames*: seq[seq[string]]
    ## pointer-shaped reference edges "srcName/refName" (redirected):
    ## only those can be rendered opaquely (`pointer`) to sever a
    ## dependency edge
    ptrRefs*: Table[string, bool]
    ## a signature references System.Guid (TypeRef)
    guidUsed*: bool
    ## every top-level name used so far; emission keeps allocating from
    ## it (fn names, const names, enum members)
    usedNames*: HashSet[string]

# Keywords and reserved names
const NimKeywords* = @[
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

## System types that render to a Nim builtin (not stubs)
const SystemBuiltins* = @[
  "Object", "Void", "Char", "Boolean", "Int32", "UInt32", "Int64", "UInt64", "IntPtr",
  "UIntPtr", "Guid",
]

const HexDigits = "0123456789abcdef"

template addGrouped*[A; B](t: var Table[A, seq[B]], a: A, b: sink B) =
  t.mGetOrPut(a, default(seq[B])).add b

## Escape a Nim identifier (backtick keywords / digit-leading names).
proc esc*(s: string): string =
  if s.len == 0:
    ""
  elif s in NimKeywords or s[0] in {'0' .. '9'}:
    '`' & s & '`'
  else:
    s

## Register a top-level Nim name (the entry's nimName); on collision
## return `name_2`, `name_3`, ...
proc freshIdent*(used: var HashSet[string], nimName: string): string =
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

## Register a top-level name in the plan; on collision return
## `name_2`, `name_3`, ...
proc freshName*(p: var NamePlan, nimName: string): string =
  p.usedNames.freshIdent(nimName)

## Suffix for a per-arch variant name (X_AMD64, ...)
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

# ---------------------------------------------------------------------------
# rendering: pure functions of the plan
# ---------------------------------------------------------------------------

## Render a leaf (bPrim/bNamed) SigType; decorators are handled by renderType.
proc renderLeaf(p: NamePlan, t: SigType): string =
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
    if t.rowIdx >= 0 and t.rowIdx in p.dupRowEmit:
      # name shared by multiple TypeDef rows: resolve by row, not name
      esc(p.dupRowEmit[t.rowIdx])
    elif t.name in p.knownTypes:
      let k = t.ns & "/" & t.name
      if k in p.nameMap:
        esc(p.nameMap[k])
      elif t.name in p.nameMap:
        esc(p.nameMap[t.name])
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
        "Guid"
      else:
        esc(p.stubNames.getOrDefault(t.name, fixIdent(t.name)))
    else:
      esc(p.stubNames.getOrDefault(t.name, fixIdent(t.name)))
  else:
    "void" # decorators are dispatched by renderType

proc renderType*(p: NamePlan, t: SigType): string # fwd (mutual recursion)

## Render a fixed-size array element: a by-ref element becomes a pointer
## (`array[var T, N]` is not valid Nim), everything else renders as-is.
proc renderArrElem(p: NamePlan, e: SigType): string =
  if e.base == bByRef:
    "ptr " & renderType(p, e.inner[])
  else:
    renderType(p, e)

## Render a full SigType as a Nim type expression (walks the decorator tree).
proc renderType*(p: NamePlan, t: SigType): string =
  case t.base
  of bPrim, bNamed:
    let s = renderLeaf(p, t)
    # COM interfaces are always passed by pointer in the C ABI, but the
    # winmd encodes the `This` param (and other interface refs) by-value —
    # add the missing `ptr` (windows-rs renders the same param as a
    # pointer; see unknwnbase.h: `IUnknown *This`)
    if t.base == bNamed and t.name in p.typeKind and p.typeKind[t.name] == tkInterface:
      "ptr " & s
    else:
      s
  of bPtr:
    let s = renderType(p, t.inner[])
    # `ptr void` is not a legal Nim type; a pointee that is an alias for
    # *void* (a handle typedef whose resolved base primitive is pvVoid,
    # e.g. MENUTEMPLATEA) must render as the bare `pointer` too. A pointee
    # that is an alias for *pointer* (a `ptr void` typedef, e.g. SC_HANDLE)
    # is in typePtr and must stay `ptr <name>` (= `ptr pointer`), not be
    # collapsed to `pointer`. (A `ptr <Interface>` pointee recurses to
    # `ptr <Interface>` via the bNamed arm, so a pointer-to-interface
    # renders as `ptr ptr <Interface>` — the C `IUnknown **`.)
    if s == "void" or (
      t.inner[].base == bNamed and t.inner[].name in p.typePrims and
      p.typePrims[t.inner[].name] == pvVoid and t.inner[].name notin p.typePtr
    ):
      "pointer"
    else:
      "ptr " & s
  of bByRef:
    "var " & renderType(p, t.inner[])
  of bArray:
    "array[" & $t.arrLen & ", " & renderArrElem(p, t.inner[]) & "]"
  of bSzArray, bGenericInst, bTypeVar:
    "pointer" # not in Win32 metadata; the WinRT generator spells its own

## The unknown (stubbable) type name referenced by `t`, if any: a named
## leaf that is not a model type and not a System builtin.
proc unknownName(p: NamePlan, t: SigType): string =
  let leaf = namedLeaf(t)
  if leaf.base != bNamed:
    return
  if leaf.rowIdx >= 0 and leaf.rowIdx in p.dupRowEmit:
    return
  if leaf.name in p.knownTypes:
    return
  if leaf.ns == "System" and leaf.name in SystemBuiltins:
    return
  result = leaf.name

## True if the rendered form of `t` is already a unique type, so a plain
## handle alias `X = Y` of it is redundant (a plain alias of a unique type
## adds no new name). A pointer is unique iff its pointee is: a `ptr` of an
## already-unique type is itself unique (like `ptr SomeObject`, objects
## being implicitly unique). Objects, stubs and scoped enums are unique;
## primitives, `pointer`, void-aliases and unscoped enums are shared. A
## handle is a plain alias of its base, so it resolves to the base's
## uniqueness (`seen` guards handle-alias cycles).
proc isUniqueType(p: NamePlan, m: Model, t: SigType, seen: var HashSet[string]): bool =
  case t.base
  of bPrim:
    result = false
  of bNamed:
    let n = t.name
    if n in p.stubNames:
      result = true
    elif n in p.typeKind:
      case p.typeKind[n]
      of tkStruct, tkInterface, tkEnum, tkDelegate:
        result = true
      of tkUnscopedEnum:
        result = false
      of tkHandle:
        # a handle is a plain alias of its base: resolve transitively
        if n in seen:
          result = false
        else:
          seen.incl n
          for t2 in m.types:
            if t2.name == n and t2.kind == tkHandle:
              result = isUniqueType(p, m, t2.underlying, seen)
              break
    else:
      result = true # unknown -> stub (opaque object)
  of bPtr:
    result = isUniqueType(p, m, t.inner[], seen)
  of bByRef, bArray, bSzArray, bGenericInst, bTypeVar:
    result = false

## True if `t`'s rendered form is a pointer type: an anonymous `ptr ...`
## or bare `pointer`, `cstring`, or a named typedef whose base is a
## pointer. A non-zero value on such a type renders as a cast, which the
## VM cannot evaluate at compile time (so the const becomes a template).
proc renderedIsPtr*(p: NamePlan, t: SigType): bool =
  var et = t
  # constants on handle typedefs carry pvVoid; recover the base kind
  if t.name.len > 0 and t.name in p.typePrims:
    et.prim = p.typePrims[t.name]
  let tyS = renderType(p, et)
  tyS.len > 3 and tyS[0 .. 3] == "ptr " or tyS == "pointer" or
    (t.name.len > 0 and t.name in p.typePtr)

# ---------------------------------------------------------------------------
# value rendering
# ---------------------------------------------------------------------------

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
proc renderIntConst*(ty: Prim, v: uint64): string =
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

proc skipAAlias*(p: NamePlan, name: string): string =
  p.aAlias.getOrDefault(name, name)

func isTypeKind*(p: NamePlan, name: string, tk: TypeKind): bool =
  name in p.typeKind and p.typeKind[name] == tk

## Default zero-initialized literal for a type expression.
proc defaultLit*(p: NamePlan, m: Model, ty: SigType): string =
  if ty.base == bArray:
    # fixed array: zero-initialized value (array[<len>, <elem>] order)
    return "array[" & $ty.arrLen & ", " & renderArrElem(p, ty.inner[]) & "]"
  if ty.base == bPtr or ty.base == bByRef or (ty.base == bPrim and ty.prim == pvString):
    "nil"
  elif ty.base == bNamed:
    if ty.name in p.aAlias:
      # suppressed alias: not emitted, the value is the target's
      # zero literal
      esc(p.aAliasFinal[ty.name]) & "()"
    elif p.typeKind.getOrDefault(ty.name, tkStruct) == tkHandle and ty.name in p.typeKind and
        p.typeKind[ty.name] == tkHandle:
      # handle: wrap the base type's default
      let j = p.firstIdx.getOrDefault(ty.name, -1)
      if j >= 0:
        esc(m.types[j].nimName) & "(" & defaultLit(p, m, m.types[j].underlying) & ")"
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
proc renderConstValue*(ty: SigType, c: ModelConst): string =
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
# build
# ---------------------------------------------------------------------------

proc buildNamePlan*(m: Model): NamePlan =
  var p: NamePlan

  # ---- pass 0: assign emitted type names in emission order ---------------
  # On a conservative-name collision, whoever is assigned first keeps the
  # plain name. Order: structs first (signatures reference struct names),
  # then handles, enums, delegates, interfaces.
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkStruct:
      p.order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkHandle:
      p.order.add i
  for i in 0 ..< m.types.len:
    let k = m.types[i].kind
    if k == tkEnum or k == tkUnscopedEnum:
      p.order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkDelegate:
      p.order.add i
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkInterface and m.types[i].name != "Apis":
      p.order.add i

  for r in NimKeywords:
    p.usedNames.incl r

  # names from implicitly-imported modules (system etc): a local declaration
  # shadows them, but an *imported* one makes every reference ambiguous
  for r in ["File", "Fileinfo"]:
    p.usedNames.incl nimIdentNormalize(r)

  var rowCount: Table[string, int]
  for i in 0 ..< m.types.len:
    let nm0 = m.types[i].name
    if nm0 notin p.firstIdx:
      p.firstIdx[nm0] = i
    rowCount[nm0] = rowCount.getOrDefault(nm0, 0) + 1
    p.nameRows.addGrouped(nm0, i)

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
  p.rowVariant = newSeq[int](m.types.len)
  for i in 0 ..< m.types.len:
    p.rowVariant[i] = -1
  for nm in p.nameRows.keys:
    let rows = p.nameRows[nm]
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
        p.rowVariant[rows[i]] = i
      p.splitInfo[nm] = sets

  var variantOut: Table[string, seq[string]]
  # every variant — including km-merge chain sub-types — is named after
  # its OWN arch set (X_AMD64, X_0_ARM64, ...). A chain's variant count
  # can differ from its parent's (an arch may have no sub-struct for a
  # given member), so the name must not be inherited from the parent.
  proc variantName(nm: string, vi: int): string =
    m.types[p.nameRows[nm][0]].nimName & "_" & archSuffix(p.splitInfo[nm][vi])

  var spairs: seq[tuple[nm: string, l: seq[set[Architecture]]]]
  for (nm, l) in p.splitInfo.pairs:
    spairs.add (nm, l)
  for (nm, l) in spairs:
    for vi in 0 ..< l.len:
      let v = p.freshName(variantName(nm, vi))
      variantOut.addGrouped(nm, v)

    let aliasN = m.types[p.nameRows[nm][0]].nimName
    p.usedNames.incl nimIdentNormalize(aliasN)
    p.nameMap[aliasN] = aliasN

  p.typeNames = newSeq[string](m.types.len)

  for idx in p.order:
    let t = m.types[idx]

    p.knownTypes.incl t.name

    let assigned =
      if p.rowVariant[idx] >= 0:
        # arch variant row: its unique per-arch name (no dedup suffix)
        p.usedNames.incl nimIdentNormalize(t.nimName)
        variantOut[t.name][p.rowVariant[idx]]
      else:
        p.freshName(t.nimName)
    p.typeNames[idx] = assigned

    if rowCount.getOrDefault(t.name, 0) > 1:
      # keyed by the raw TypeDef row (model.resolveNested pins references
      # to rows, not to m.types indices)
      p.dupRowEmit[t.defRow] = assigned

    if p.rowVariant[idx] >= 0:
      # split names resolve through their selector alias (set above),
      # not through a variant row
      discard
    else:
      p.nameMap[t.ns & "/" & t.name] = assigned
      p.nameMap[t.name] = assigned

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
        let j = p.firstIdx.getOrDefault(cur.name, -1)
        if j < 0:
          break
        if m.types[j].kind in {tkStruct, tkInterface}:
          baseIsObject = true
          break
        cur = m.types[j].underlying
        inc guard
      if not baseIsObject:
        p.typePrims[t.name] = cur.prim
      if cur.base == bPtr:
        p.typePtr.incl t.name
    if t.name notin p.typeKind:
      p.typeKind[t.name] = t.kind

  # ---- pass 1: collect the unknown (stubbable) names ----------------------
  # a pure walk over every signature reference (the same set the emitted
  # code renders); no rendering side effects
  var unknown: HashSet[string]
  proc sweep(ty: SigType) =
    let u = unknownName(p, ty)
    if u.len > 0:
      unknown.incl u
    else:
      let leaf = namedLeaf(ty)
      if leaf.base == bNamed and leaf.ns == "System" and leaf.name == "Guid":
        p.guidUsed = true

  for i in 0 ..< m.types.len:
    let t = m.types[i]
    if t.kind == tkHandle or t.kind == tkUnscopedEnum:
      sweep(t.underlying)
    for f in t.fields:
      sweep(f.ty)
    if t.kind == tkDelegate:
      sweep(t.ret)
  for cc in m.consts:
    sweep(cc.ty)
  for f in m.fns:
    for param in f.params:
      sweep(param.ty)
    sweep(f.ret)

  var stubList = toSeq(unknown)
  stubList.sort() # stable freshname

  for n in stubList:
    p.stubNames[n] = p.freshName(fixIdent(n))

  # ---- pass 2: name-level reference data -----------------------------------
  # direct type-name references of every model type, plus which refs
  # are pointer-shaped (nPtr > 0 or a pointer-alias type): only those
  # can be rendered opaquely (`pointer`) to sever a dependency edge
  p.typeRefNames = newSeq[seq[string]](m.types.len)
  proc addRefs(i: int, ty: SigType, ownerName: string) =
    let ln = leafNamed(ty)
    if ln.len > 0:
      p.typeRefNames[i].add ln
      if ty.base == bPtr or
          (ty.base == bNamed and p.typeKind.getOrDefault(ty.name, tkStruct) == tkHandle):
        p.ptrRefs[ownerName & "/" & ln] = true

  for i in 0 ..< m.types.len:
    let t = m.types[i]
    case t.kind
    of tkStruct:
      for f in t.fields:
        addRefs(i, f.ty, t.name)
    of tkHandle:
      let ln = leafNamed(t.underlying)
      if ln.len > 0:
        p.typeRefNames[i].add ln
        # a pointer alias is pointer-shaped: the edge can be severed by
        # rendering the alias opaquely (`pointer`)
        p.ptrRefs[t.name & "/" & ln] = true
    of tkDelegate:
      for f in t.fields:
        addRefs(i, f.ty, t.name)
      addRefs(i, t.ret, t.name)
    else:
      discard

  # ---- pass 3: zone split ---------------------------------------------------
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
  var allNames0: seq[string]
  for (nm, l) in p.nameRows.pairs:
    allNames0.add nm

  proc recolor() =
    p.zoneB.clear()

    for (nm, l) in p.splitInfo.pairs:
      p.zoneB.incl(nm)

    var changedC = true
    while changedC:
      changedC = false
      for nm in allNames0:
        if nm in p.zoneB:
          continue

        var hit = false
        for ri in p.nameRows[nm]:
          for r in p.typeRefNames[ri]:
            if r in p.zoneB:
              hit = true
              break
          if hit:
            break
        if hit:
          p.zoneB.incl nm
          changedC = true

  recolor()

  # a variant may only reference zone A names (or other variants of the
  # same split names): if a name referenced — directly or transitively —
  # by a variant row lives in zone B, the layout is impossible and the
  # name falls back to plain duplicate handling
  proc unsplit(nm: string) =
    if nm in p.splitInfo:
      p.splitInfo.del nm
    for i in 0 ..< m.types.len:
      if m.types[i].name == nm:
        if p.rowVariant[i] >= 0:
          p.rowVariant[i] = -1
          # the per-arch name was consumed in pass 0; reassign with the
          # usual dedup suffix. The firstIdx row gets the plain name
          # back: it was reserved for the selector alias, so no other
          # type can hold it
          let base0 = m.types[i].nimName
          var assigned = base0
          if i != p.firstIdx[nm]:
            if nimIdentNormalize(assigned) in p.usedNames:
              var i2 = 2
              while nimIdentNormalize(base0 & "_" & $i2) in p.usedNames:
                inc i2
              assigned = base0 & "_" & $i2
          p.usedNames.incl nimIdentNormalize(assigned)
          p.typeNames[i] = assigned
          p.nameMap[nm] = assigned
          # keep the row-keyed reference map in sync with the reassignment
          if rowCount.getOrDefault(nm, 0) > 1:
            p.dupRowEmit[m.types[i].defRow] = assigned
    recolor()

  var changed = true
  while changed:
    changed = false
    var splitNames2: seq[string]
    for (nm, l) in p.splitInfo.pairs:
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
      for ri in p.nameRows.getOrDefault(nm, @[]):
        let aSet = m.types[ri].arch
        for r in p.typeRefNames[ri]:
          if r in p.splitInfo:
            var matched = false
            for rs in p.splitInfo[r]:
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
      for ri in p.nameRows.getOrDefault(nm, @[]):
        for r in p.typeRefNames[ri]:
          if r notin p.splitInfo and r notin seen:
            stack.add r
      while stack.len > 0 and not bad:
        let r = stack[stack.len - 1]
        stack.setLen(stack.len - 1)
        if r in seen or r in p.splitInfo:
          continue
        seen.incl r
        if r in p.zoneB:
          bad = true
          break
        let ri = p.firstIdx.getOrDefault(r, -1)
        if ri >= 0:
          for r2 in p.typeRefNames[ri]:
            if r2 notin p.splitInfo and r2 notin seen:
              stack.add r2
      if bad:
        unsplit nm
        changed = true
        break

  # ---- pass 4: A-suffix alias suppression -----------------------------------
  # Runs after the unsplit loop: typeNames / nameMap / dupRowEmit are final.
  # A handle whose emitted line is a plain alias `X = Y` with X & "A" == Y
  # exactly is a pure ANSI/Unicode wrapper (STARTUPINFOEX -> STARTUPINFOEXA):
  # the alias adds nothing, so it is suppressed and every reference to X
  # resolves to Y's emitted name. Names whose emitted form does not match
  # exactly (dedup suffixes, fixIdent changes: OFNOTIFY = OFNOTIFYA_2,
  # TRUSTEE_X = TRUSTEE_A, HW_PROFILE_INFO_2 = HW_PROFILE_INFOA_2) keep
  # their alias. Only plain aliases qualify: the target must already be a
  # unique type (an object, a scoped enum, or a stub —
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
    if u.rowIdx >= 0 and u.rowIdx in p.dupRowEmit:
      target = p.dupRowEmit[u.rowIdx]
    else:
      let k = u.ns & "/" & u.name
      if k in p.nameMap:
        target = p.nameMap[k]
      elif u.name in p.nameMap:
        target = p.nameMap[u.name]
      else:
        target = p.stubNames.getOrDefault(u.name, fixIdent(u.name))

    if p.typeNames[i] & "A" != target:
      continue

    # only plain aliases: the target must already be a unique type (an
    # object, a scoped enum, or a stub), so the alias is redundant; a
    # shared target (primitive, pointer, void-alias, unscoped enum, or a
    # handle aliasing one) would make `X = Y` a new name, which is not
    # redundant
    var seen: HashSet[string]
    if not isUniqueType(p, m, u, seen):
      continue

    p.aAlias[t.name] = u.name # graph redirection (raw names)
    p.aAliasFinal[t.name] = target # rendered name references resolve to
    p.nameMap[t.ns & "/" & t.name] = target
    p.nameMap[t.name] = target

  # the reference graph was collected before the suppression: redirect its
  # edges (a suppressed name's only reference is its target, so the
  # transitive closure is unchanged — zone/unsplit decisions already made
  # above are unaffected)
  for i in 0 ..< m.types.len:
    for ri in 0 ..< p.typeRefNames[i].len:
      let r = p.typeRefNames[i][ri]
      if r in p.aAlias:
        p.typeRefNames[i][ri] = p.aAlias[r]

  if p.aAlias.len > 0:
    var ptrRefs2: Table[string, bool]
    for (k, v) in p.ptrRefs.pairs:
      let slash = k.rfind('/')
      var k2 = k
      let refName = k[slash + 1 ..< k.len]
      if refName in p.aAlias:
        k2 = k[0 ..< slash] & "/" & p.aAlias[refName]
      ptrRefs2[k2] = v
    p.ptrRefs = ptrRefs2

  p.variantOut = variantOut
  p
