# signatures.nim — ECMA-335 signature blob decoding for winmd2nim.
# https://ecma-international.org/wp-content/uploads/ECMA-335_6th_edition_june_2012.pdf#%5B%7B%22num%22%3A2749%2C%22gen%22%3A0%7D%2C%7B%22name%22%3A%22XYZ%22%7D%2C87%2C290%2C0%5D
import std/strutils, ./reader

type
  Prim* = enum
    pvVoid
    pvBoolean
    pvChar
    pvI1
    pvU1
    pvI2
    pvU2
    pvI4
    pvU4
    pvI8
    pvU8
    pvR4
    pvR8
    pvString
    pvI
    pvU

  Base* = enum
    ## leaves
    bPrim # `prim` field holds the primitive
    bNamed
      # `ns`/`name` hold a TypeDef or TypeRef (struct, enum, handle,
      # interface, typedef); generic arguments are collapsed away
    ## decorators (wrap an `inner` type)
    bPtr # `inner` is the pointee
    bByRef # `inner` is the referenced type
    bArray # `inner` is the element, `arrLen` the count

  ## A decoded type as a tree: a leaf (bPrim/bNamed) or a decorator
  ## (bPtr/bByRef/bArray) wrapping an `inner` type. `inner` is nil for
  ## leaves; `arrLen` is set for bArray; `isConst` carries the IsConst
  ## custom modifier read at the type's outermost level.
  SigType* = object
    base*: Base
    prim*: Prim
    ns*: string
    name*: string
    ## TypeDef row index for bNamed types referenced by TypeDef (the
    ## winmd has multiple TypeDef rows sharing one name, e.g. anonymous
    ## nested types); -1 for TypeRef references and non-named types
    rowIdx*: int
    inner*: ref SigType
    arrLen*: int
    isConst*: bool

  MethodSig* = object
    flags*: uint8 # raw first byte of the blob
    ret*: SigType
    params*: seq[SigType]

proc badBlob(p: int, what: string): void =
  ## raises: ref WinmdError
  raiseWinmdError("bad signature blob at offset " & $p & ": " & what)

type Cursor = object
  b: seq[byte]
  p: int

proc u8(c: var Cursor): uint8 =
  if c.p >= c.b.len:
    badBlob(c.p, "out of data")
  result = c.b[c.p]
  inc c.p

## Metadata compressed unsigned integer (ECMA-335 II.23.2).
proc compressed(c: var Cursor): int =
  let b0 = int(c.u8())
  case b0 shr 5
  of 0 .. 3:
    b0
  of 4 .. 5:
    let b1 = int(c.u8())
    ((b0 and 0x3F) shl 8) or b1
  else:
    # NB: this winmd dialect has NO 3-byte compressed form (verified against
    # the windows-rs metadata reader: 1/2/4-byte forms only)
    let b1 = int(c.u8())
    let b2 = int(c.u8())
    let b3 = int(c.u8())
    ((b0 and 0x1F) shl 24) or (b1 shl 16) or (b2 shl 8) or b3

# ---------------------------------------------------------------------------
# coded TypeDefOrRef: value = (row + 1) << 2 | tag
# ---------------------------------------------------------------------------

proc resolveNamed(wa: Winmd, v: int, rowIdx: var int): (string, string) =
  ## (ns, name); `rowIdx` is the TypeDef row for tag-0 references, -1 for
  ## TypeRefs (needed to disambiguate names shared by multiple rows)
  let tag = v and 3
  let row = (v shr 2) - 1
  case tag
  of 0:
    let t = wa.typeDef(row)
    rowIdx = row
    result = (t.namespace, t.name)
  of 1:
    let t = wa.typeRef(row)
    rowIdx = -1
    result = (t.namespace, t.name)
  else:
    badBlob(-1, "TypeSpec (tag 2) in signature: not supported")

# ---------------------------------------------------------------------------
# type decoding
# ---------------------------------------------------------------------------

proc readType(wa: Winmd, c: var Cursor): SigType =
  # leading custom modifiers (0x1F/0x20 + coded TypeDefOrRef); only IsConst
  # is semantically meaningful for code generation
  while c.p < c.b.len and c.b[c.p] in {0x1F, 0x20}:
    inc c.p
    var modRow = -1
    let (ns, name) = resolveNamed(wa, c.compressed(), modRow)
    if name == "IsConst":
      result.isConst = true
  if c.p < c.b.len and c.b[c.p] == 0x10: # BYREF: wraps a referenced type
    inc c.p
    result.base = bByRef
    result.inner = new(SigType)
    result.inner[] = readType(wa, c)
    return
  if c.p < c.b.len and c.b[c.p] == 0x1D: # SZARRAY: elemtype + length
    inc c.p
    let e = readType(wa, c)
    result.base = bArray
    result.arrLen = c.compressed()
    result.inner = new(SigType)
    result.inner[] = e
    return
  if c.p < c.b.len and c.b[c.p] == 0x0F: # PTR: wraps a pointee (recurse for
    # further pointer layers / other decorators)
    inc c.p
    result.base = bPtr
    result.inner = new(SigType)
    result.inner[] = readType(wa, c)
    return
  let code = c.u8()
  case code
  of ELEMENT_TYPE_VOID:
    result.base = bPrim
    result.prim = pvVoid
  of ELEMENT_TYPE_BOOLEAN:
    result.base = bPrim
    result.prim = pvBoolean
  of ELEMENT_TYPE_CHAR:
    result.base = bPrim
    result.prim = pvChar
  of ELEMENT_TYPE_I1:
    result.base = bPrim
    result.prim = pvI1
  of ELEMENT_TYPE_U1:
    result.base = bPrim
    result.prim = pvU1
  of ELEMENT_TYPE_I2:
    result.base = bPrim
    result.prim = pvI2
  of ELEMENT_TYPE_U2:
    result.base = bPrim
    result.prim = pvU2
  of ELEMENT_TYPE_I4:
    result.base = bPrim
    result.prim = pvI4
  of ELEMENT_TYPE_U4:
    result.base = bPrim
    result.prim = pvU4
  of ELEMENT_TYPE_I8:
    result.base = bPrim
    result.prim = pvI8
  of ELEMENT_TYPE_U8:
    result.base = bPrim
    result.prim = pvU8
  of ELEMENT_TYPE_R4:
    result.base = bPrim
    result.prim = pvR4
  of ELEMENT_TYPE_R8:
    result.base = bPrim
    result.prim = pvR8
  of ELEMENT_TYPE_STRING:
    result.base = bPrim
    result.prim = pvString
  of ELEMENT_TYPE_I:
    result.base = bPrim
    result.prim = pvI
  of ELEMENT_TYPE_U:
    result.base = bPrim
    result.prim = pvU
  of ELEMENT_TYPE_VALUETYPE, ELEMENT_TYPE_CLASS:
    var row = -1
    let (ns, name) = resolveNamed(wa, c.compressed(), row)
    result.base = bNamed
    result.ns = ns
    result.name = name
    result.rowIdx = row
  of ELEMENT_TYPE_VAR:
    discard c.u8()
    var row = -1
    let (ns, name) = resolveNamed(wa, c.compressed(), row)
    let n = c.compressed()
    for _ in 0 ..< n:
      discard readType(wa, c)
    result.base = bNamed
    result.ns = ns
    result.name = name
    result.rowIdx = row
  of ELEMENT_TYPE_OBJECT: # OBJECT
    result.base = bNamed
    result.ns = "System"
    result.name = "Object"
    result.rowIdx = -1
  of ELEMENT_TYPE_ARRAY:
    let elem = readType(wa, c)
    let rank = c.compressed()
    let nSizes = c.compressed()
    var sizes = newSeq[int](nSizes)
    for i in 0 ..< nSizes:
      sizes[i] = c.compressed()
    let nLbs = c.compressed()
    for _ in 0 ..< nLbs:
      discard c.compressed()
    # rank-1 fixed array -> `array[elem, size]`; multi-dim / zero-size
    # falls back to an opaque pointer
    var fixed = false
    if rank == 1 and nSizes == 1:
      fixed = sizes[0] > 0
    if fixed:
      result.base = bArray
      result.arrLen = sizes[0]
      result.inner = new(SigType)
      result.inner[] = elem
    else:
      # multi-dim / zero-size: opaque pointer to void
      result.base = bPtr
      result.inner = new(SigType)
      result.inner[].base = bPrim
      result.inner[].prim = pvVoid
  else:
    badBlob(c.p - 1, "unsupported element type 0x" & toHex(code))

# ---------------------------------------------------------------------------
# public entry points
# ---------------------------------------------------------------------------

## Decode a field signature blob (prolog 0x06 + type).
proc decodeFieldSig*(wa: Winmd, blob: seq[byte]): SigType =
  var c: Cursor
  c.b = blob
  if c.u8() != 0x06:
    badBlob(0, "field signature blob missing 0x06 prolog")
  readType(wa, c)

## The named leaf of a type tree (through pointer / by-ref / array
## decorators).
proc namedLeaf*(ty: SigType): SigType =
  var cur = ty
  while cur.base == bPtr or cur.base == bByRef or cur.base == bArray:
    cur = cur.inner[]
  cur

## The named type at the leaf of a type tree (through pointer/by-ref/array
## decorators); "" when the leaf is a primitive.
proc leafNamed*(ty: SigType): string =
  let cur = namedLeaf(ty)
  if cur.base == bNamed: cur.name else: ""

## Decode a method signature blob: flags, param count, return type, params.
proc decodeMethodSig*(wa: Winmd, blob: seq[byte]): MethodSig =
  var c: Cursor
  c.b = blob
  result.flags = c.u8()
  # NB: first byte is the MethodCallAttributes flags (0x20 = HASTHIS, 0x10 =
  # GENERIC, 0x05 = VARARG, 0x01 = EXPLICITTHIS). No extra prolog byte: the
  # next compressed integer is the param count (mirrors the windows-rs reader;
  # this file has no generic methods).
  let n = c.compressed()
  result.ret = readType(wa, c)
  result.params = newSeq[SigType](n)
  for i in 0 ..< n:
    result.params[i] = readType(wa, c)
  if c.p != c.b.len:
    badBlob(c.p, "trailing bytes in method signature blob")
