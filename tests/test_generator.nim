# test_generator.nim — Phase 4 tests for generator.nim.
#
# Two layers:
#   1. synthetic models — exact rendering of small hand-built Models
#      (escaping, collision suffixing, cstring, distinct handles, unknown
#      stubs, header provenance, determinism)
#   2. the full Windows.Win32 model — structural assertions on the
#      generated source (CreateWindowExW surface, 14567 importc lines,
#      header modules, minimal imports, determinism)

import std/[strutils, tables]
import ../src/winmd/reader
import ../src/winmd/signatures
import ../src/winmd/model
import ../src/winmd/generator
import ../src/winmd/rdlmap

proc prim(p: Prim): SigType =
  result.base = bPrim
  result.prim = p

proc named(ns, name: string): SigType =
  result.base = bNamed
  result.ns = ns
  result.name = name

proc importList(code: string): string =
  ## the contents of a generated module's list import line ("" if none)
  let i = code.find("import ./[")
  if i < 0:
    return ""
  let j = code.find("]", i)
  result = code[i + "import ./[".len ..< j]

# ---------------------------------------------------------------------------
# 1. synthetic models
# ---------------------------------------------------------------------------

# a struct, a handle, a scoped enum, an unscoped enum, a delegate, a
# constant and two functions (one with a keyword name, one returning an
# unknown type)
var m: Model
m.types.add ModelType(
  kind: tkStruct,
  ns: "NS",
  name: "POINT",
  nimName: fixIdent("POINT"),
  fields: @[
    ModelField(name: "x", nimName: fixIdent("x"), ty: prim(pvI4)),
    ModelField(name: "y", nimName: fixIdent("y"), ty: prim(pvI4)),
  ],
)
# HID's underlying is ptr void -> must render as `distinct pointer`
var hidBase: SigType
hidBase.base = bPtr
hidBase.inner = new(SigType)
hidBase.inner[].base = bPrim
hidBase.inner[].prim = pvVoid
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "HID",
  nimName: fixIdent("HID"),
  underlying: hidBase,
  hasUnderlying: true,
)
# a typedef (handle) that is an alias for void (like MENUTEMPLATEA):
# `ptr <name>` must render as the bare `pointer` (Nim forbids `ptr void`)
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "VOIDALIAS",
  nimName: fixIdent("VOIDALIAS"),
  underlying: prim(pvVoid),
  hasUnderlying: true,
)
# a handle whose pointee is a void-alias handle (chain must resolve too)
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "VOIDALIAS2",
  nimName: fixIdent("VOIDALIAS2"),
  underlying: named("NS", "VOIDALIAS"),
  hasUnderlying: true,
)
# a typedef (handle) that is an alias for pointer (ptr void, like
# SC_HANDLE): `ptr <name>` must stay `ptr <name>` (= `ptr pointer`),
# NOT be collapsed to `pointer`
var ptrAliasBase: SigType
ptrAliasBase.base = bPtr
ptrAliasBase.inner = new(SigType)
ptrAliasBase.inner[].base = bPrim
ptrAliasBase.inner[].prim = pvVoid
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "PTRALIAS",
  nimName: fixIdent("PTRALIAS"),
  underlying: ptrAliasBase,
  hasUnderlying: true,
)
# a handle whose pointee is a pointer-alias handle (like LPSC_HANDLE):
# must render `distinct ptr <name>`, not `distinct pointer`
var lpPtrAliasBase: SigType
lpPtrAliasBase.base = bPtr
lpPtrAliasBase.inner = new(SigType)
lpPtrAliasBase.inner[].base = bNamed
lpPtrAliasBase.inner[].ns = "NS"
lpPtrAliasBase.inner[].name = "PTRALIAS"
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "LPPTRALIAS",
  nimName: fixIdent("LPPTRALIAS"),
  underlying: lpPtrAliasBase,
  hasUnderlying: true,
)
# a typedef (handle) that is an alias of a struct (like CERT_BLOB =
# CRYPT_INTEGER_BLOB): `ptr <name>` must stay `ptr <name>`, not be
# collapsed to `pointer` (the struct is already a distinct, non-void type)
m.types.add ModelType(
  kind: tkStruct,
  ns: "NS",
  name: "BLOB",
  nimName: fixIdent("BLOB"),
  fields: @[ModelField(name: "cbData", nimName: fixIdent("cbData"), ty: prim(pvU4))],
)
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "BLOBALIAS",
  nimName: fixIdent("BLOBALIAS"),
  underlying: named("NS", "BLOB"),
  hasUnderlying: true,
)
# a struct with a `ptr` field of the struct-alias handle: the field must
# render `ptr BLOBALIAS`, not `pointer`
var ptrBlobAliasField: SigType
ptrBlobAliasField.base = bPtr
ptrBlobAliasField.inner = new(SigType)
ptrBlobAliasField.inner[].base = bNamed
ptrBlobAliasField.inner[].ns = "NS"
ptrBlobAliasField.inner[].name = "BLOBALIAS"
m.types.add ModelType(
  kind: tkStruct,
  ns: "NS",
  name: "HOLDER",
  nimName: fixIdent("HOLDER"),
  fields: @[ModelField(name: "p", nimName: fixIdent("p"), ty: ptrBlobAliasField)],
)
# a plain `A` alias of another typedef (handle), not a struct: LPFINDREPLACE
# -> LPFINDREPLACEA (a handle aliasing a struct pointer). The alias adds
# nothing, so it must be suppressed and references resolve to LPFINDREPLACEA
m.types.add ModelType(
  kind: tkStruct,
  ns: "NS",
  name: "FINDREPLACEA",
  nimName: fixIdent("FINDREPLACEA"),
  fields: @[ModelField(name: "dwFlags", nimName: fixIdent("dwFlags"), ty: prim(pvU4))],
)
var lpFindReplaceAUnderlying: SigType
lpFindReplaceAUnderlying.base = bPtr
lpFindReplaceAUnderlying.inner = new(SigType)
lpFindReplaceAUnderlying.inner[].base = bNamed
lpFindReplaceAUnderlying.inner[].ns = "NS"
lpFindReplaceAUnderlying.inner[].name = "FINDREPLACEA"
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "LPFINDREPLACEA",
  nimName: fixIdent("LPFINDREPLACEA"),
  underlying: lpFindReplaceAUnderlying,
  hasUnderlying: true,
)
m.types.add ModelType(
  kind: tkHandle,
  ns: "NS",
  name: "LPFINDREPLACE",
  nimName: fixIdent("LPFINDREPLACE"),
  underlying: named("NS", "LPFINDREPLACEA"),
  hasUnderlying: true,
)
m.types.add ModelType(
  kind: tkEnum,
  ns: "NS",
  name: "E",
  nimName: fixIdent("E"),
  fields: @[
    ModelField(
      name: "a", nimName: fixIdent("a"), ty: prim(pvI4), constant: 0, hasConstant: true
    ),
    ModelField(
      name: "b", nimName: fixIdent("b"), ty: prim(pvI4), constant: 1, hasConstant: true
    ),
  ],
  underlying: prim(pvI4),
  hasUnderlying: true,
)
# duplicate enum member name "a" in another enum -> must be suffixed
m.types.add ModelType(
  kind: tkEnum,
  ns: "NS",
  name: "E2",
  nimName: fixIdent("E2"),
  fields: @[
    ModelField(
      name: "a", nimName: fixIdent("a"), ty: prim(pvI4), constant: 7, hasConstant: true
    )
  ],
  underlying: prim(pvI4),
  hasUnderlying: true,
)
m.types.add ModelType(
  kind: tkUnscopedEnum,
  ns: "NS",
  name: "U",
  nimName: fixIdent("U"),
  fields: @[
    ModelField(
      name: "u1",
      nimName: fixIdent("u1"),
      ty: prim(pvU4),
      constant: 5,
      hasConstant: true,
    )
  ],
  underlying: prim(pvU4),
  hasUnderlying: true,
)
m.types.add ModelType(
  kind: tkDelegate,
  ns: "NS",
  name: "CB",
  nimName: fixIdent("CB"),
  fields:
    @[ModelField(name: "arg_1", nimName: fixIdent("arg_1"), ty: named("NS", "HID"))],
  ret: prim(pvI4),
)
m.types.add ModelType(
  kind: tkDelegate, ns: "NS", name: "NOINV", nimName: fixIdent("NOINV"), fields: @[]
)
m.types.add ModelType(
  kind: tkInterface, ns: "NS", name: "IThing", nimName: fixIdent("IThing")
)
# a struct with a fixed-size array field -> `array[<len>, <elem>]`
var arrElem: SigType
arrElem.base = bPrim
arrElem.prim = pvU1
var arrTy: SigType
arrTy.base = bArray
arrTy.arrLen = 4
arrTy.inner = new(SigType)
arrTy.inner[] = arrElem
m.types.add ModelType(
  kind: tkStruct,
  ns: "NS",
  name: "BUF",
  nimName: fixIdent("BUF"),
  fields: @[ModelField(name: "data", nimName: fixIdent("data"), ty: arrTy)],
)
# function: keyword name + szarray char (cstring) + unknown return type
var addrParam: SigType
addrParam.base = bPtr
addrParam.inner = new(SigType)
addrParam.inner[].base = bPrim
addrParam.inner[].prim = pvChar
m.fns.add ModelFn(
  name: "addr",
  nimName: fixIdent("addr"),
  importName: "addr",
  moduleName: "M.dll",
  ret: named("System2", "Mystery"),
  params: @[ModelParam(name: "p", nimName: fixIdent("p"), ty: addrParam)],
)
m.fns.add ModelFn(
  name: "TakeHid",
  nimName: fixIdent("TakeHid"),
  importName: "TakeHid",
  moduleName: "M.dll",
  ret: prim(pvVoid),
  params: @[
    ModelParam(name: "h", nimName: fixIdent("h"), ty: named("NS", "HID")),
    ModelParam(name: "cb", nimName: fixIdent("cb"), ty: named("NS", "CB")),
  ],
)
# a fn taking `ptr` of a void-alias typedef (direct and via a chain):
# both must render as the bare `pointer`, not `ptr <name>`
var voidAliasParam: SigType
voidAliasParam.base = bPtr
voidAliasParam.inner = new(SigType)
voidAliasParam.inner[].base = bNamed
voidAliasParam.inner[].ns = "NS"
voidAliasParam.inner[].name = "VOIDALIAS"
var voidAlias2Param: SigType
voidAlias2Param.base = bPtr
voidAlias2Param.inner = new(SigType)
voidAlias2Param.inner[].base = bNamed
voidAlias2Param.inner[].ns = "NS"
voidAlias2Param.inner[].name = "VOIDALIAS2"
m.fns.add ModelFn(
  name: "TakeVoidAlias",
  nimName: fixIdent("TakeVoidAlias"),
  importName: "TakeVoidAlias",
  moduleName: "M.dll",
  ret: prim(pvVoid),
  params: @[
    ModelParam(name: "p", nimName: fixIdent("p"), ty: voidAliasParam),
    ModelParam(name: "q", nimName: fixIdent("q"), ty: voidAlias2Param),
  ],
)
# a fn taking `ptr` of a pointer-alias typedef (like LPSC_HANDLE):
# must stay `ptr <name>` (= `ptr pointer`), not be collapsed to `pointer`
var ptrAliasParam: SigType
ptrAliasParam.base = bPtr
ptrAliasParam.inner = new(SigType)
ptrAliasParam.inner[].base = bNamed
ptrAliasParam.inner[].ns = "NS"
ptrAliasParam.inner[].name = "PTRALIAS"
m.fns.add ModelFn(
  name: "TakePtrAlias",
  nimName: fixIdent("TakePtrAlias"),
  importName: "TakePtrAlias",
  moduleName: "M.dll",
  ret: prim(pvVoid),
  params: @[ModelParam(name: "p", nimName: fixIdent("p"), ty: ptrAliasParam)],
)
# a fn taking the suppressed `A` alias LPFINDREPLACE: the param must
# resolve to LPFINDREPLACEA (the alias is not emitted)
m.fns.add ModelFn(
  name: "TakeFindReplace",
  nimName: fixIdent("TakeFindReplace"),
  importName: "TakeFindReplace",
  moduleName: "M.dll",
  ret: prim(pvVoid),
  params:
    @[ModelParam(name: "p", nimName: fixIdent("p"), ty: named("NS", "LPFINDREPLACE"))],
)
# function with header provenance: must live in the hd module (with its
# own dynlib statement), not in the DLL module
m.fns.add ModelFn(
  name: "HdFn",
  nimName: fixIdent("HdFn"),
  importName: "HdFn",
  moduleName: "M.dll",
  ret: prim(pvVoid),
  params: @[],
)
# duplicate free-const name
m.consts.add ModelConst(
  ns: "NS", name: "C", nimName: fixIdent("C"), value: 260, ty: prim(pvI4)
)
m.consts.add ModelConst(
  ns: "NS", name: "C", nimName: fixIdent("C"), value: 1, ty: prim(pvI4)
)
# string constant
m.consts.add ModelConst(
  ns: "NS",
  name: "S",
  nimName: fixIdent("S"),
  isStr: true,
  strVal: "say \"hi\"",
  ty: prim(pvVoid),
)
# big u64 constant
m.consts.add ModelConst(
  ns: "NS",
  name: "BIG",
  nimName: fixIdent("BIG"),
  value: 18446744073709551615'u64,
  ty: prim(pvU8),
)
# negative i64 constant
m.consts.add ModelConst(
  ns: "NS",
  name: "NEG",
  nimName: fixIdent("NEG"),
  value: 0xFFFFFFFFFFFFFFFF'u64,
  ty: prim(pvI8),
)
# float constant
m.consts.add ModelConst(
  ns: "NS",
  name: "F",
  nimName: fixIdent("F"),
  isFloat: true,
  floatVal: 0.5,
  ty: prim(pvR4),
)
# a pointer-typed constant with a non-zero value (like MSIDBOPEN_CREATE:
# an integer stored in a pointer-typed typedef): keep the declared type
# and cast the value explicitly, not widened to uint32
m.consts.add ModelConst(
  ns: "NS",
  name: "PCONST",
  nimName: fixIdent("PCONST"),
  value: 3,
  ty: named("NS", "PTRALIAS"),
)
# a pointer-typed constant holding a negative 32-bit value (like
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE: the winmd stores I4
# 0xFFFFFFFD, sign-extended to 0xFFFFFFFF_FFFFFFFD): the cast literal
# must be the 32-bit value, not the 64-bit signed one
m.consts.add ModelConst(
  ns: "NS",
  name: "NEGPCONST",
  nimName: fixIdent("NEGPCONST"),
  value: 0xFFFFFFFF_FFFFFFFD'u64,
  ty: named("NS", "PTRALIAS"),
)

# header provenance: every synthetic type comes from header "hd"
var typeHdr: Table[system.string, system.string] =
  initTable[system.string, system.string]()
for n in @[
  "POINT", "HID", "VOIDALIAS", "VOIDALIAS2", "PTRALIAS", "LPPTRALIAS", "BLOB",
  "BLOBALIAS", "HOLDER", "FINDREPLACEA", "LPFINDREPLACEA", "LPFINDREPLACE", "E", "E2",
  "U", "CB", "NOINV", "IThing", "BUF", "HdFn",
]:
  typeHdr[n] = "hd"

let smods = generateModules(m, typeHdr)
doAssert smods[0].name == "win32base"
let sbase = smods[0].code
var hdmod = ""
var mmod = ""
var smod = ""
for gm in smods:
  case gm.name
  of "hd":
    hdmod = gm.code
  of "m":
    mmod = gm.code
  else:
    discard
  if gm.name != "win32base":
    smod.add gm.code
doAssert smod.len > 0

# types live in the module of their defining header: hd
doAssert "POINT* {.completeStruct.} = object" in hdmod
doAssert "x*: int32" in hdmod
doAssert "E* = enum" in hdmod
doAssert "  a = 0" in hdmod
doAssert "  b = 1" in hdmod
# duplicate member "a" in E2 -> suffixed
doAssert "a_2 = 7" in hdmod
# unscoped enum: alias in the hd module + member const
doAssert "U* = uint32" in hdmod
doAssert "u1*: U = 0x5'u32" in hdmod
doAssert "IThing* = distinct object" in hdmod
# fixed-size array field -> `array[<len>, <elem>]` (length first in this build)
doAssert "BUF* {.completeStruct.} = object" in hdmod
doAssert "data*: array[4, uint8]" in hdmod
doAssert "HID* = distinct pointer" in hdmod
# a void-alias typedef renders as a plain `void` alias (not `distinct`);
# a handle whose pointee is a void-alias renders `distinct <name>`
doAssert "VOIDALIAS* = void" in hdmod
doAssert "VOIDALIAS2* = distinct VOIDALIAS" in hdmod
# a pointer-alias typedef renders `distinct pointer`; a handle whose
# pointee is a pointer-alias stays `distinct ptr <name>` (not collapsed)
doAssert "PTRALIAS* = distinct pointer" in hdmod
# a `ptr` of an already-distinct type is itself distinct, so no `distinct`
doAssert "LPPTRALIAS* = ptr PTRALIAS" in hdmod
doAssert "LPPTRALIAS* = distinct ptr PTRALIAS" notin hdmod
doAssert "LPPTRALIAS* = distinct pointer" notin hdmod
# a struct-alias typedef renders as a plain alias of the struct; a `ptr`
# field of it stays `ptr <name>` (not collapsed to `pointer`)
doAssert "BLOBALIAS* = BLOB" in hdmod
doAssert "BLOBALIAS* = distinct BLOB" notin hdmod
doAssert "BLOBALIAS* = void" notin hdmod
doAssert "p*: ptr BLOBALIAS" in hdmod
doAssert "p*: pointer" notin hdmod
# a plain `A` alias of another typedef (handle) is suppressed (like the
# struct A-aliases): only the A-suffixed target is emitted
doAssert "LPFINDREPLACEA* = ptr FINDREPLACEA" in hdmod
doAssert "LPFINDREPLACE*" notin hdmod
doAssert "CB* = proc (arg_1: HID): int32 {.stdcall.}" in hdmod
doAssert "NOINV* = pointer" in hdmod
# unknown type referenced by an M.dll fn -> opaque stub in that fn's
# module (not the base, not the type header)
doAssert "Mystery* = distinct object" notin sbase
doAssert "Mystery* = distinct object" in smod
doAssert "Mystery* = distinct object" notin hdmod
# unmapped primitive-typed constants -> base
doAssert "C*: int32 = 260" in sbase
doAssert "C_2*: int32 = 1" in sbase
doAssert "BIG*: uint64 = 0xffffffffffffffff'u64" in sbase
doAssert "NEG*: int64 = -1'i64" in sbase
doAssert "F*: float32 = 0.5" in sbase
# a pointer-typed constant keeps its declared type and casts the value
# explicitly (not widened to uint32); the VM cannot evaluate a cast to a
# pointer type at compile time, so it is emitted as a template
doAssert "template PCONST*: untyped = cast[PTRALIAS](3)" in hdmod
doAssert "PCONST*: PTRALIAS = cast[PTRALIAS](3)" notin hdmod
doAssert "PCONST*: uint32" notin hdmod
doAssert "template NEGPCONST*: untyped = cast[PTRALIAS](-3)" in hdmod
doAssert "POINT* {.completeStruct.} = object" notin sbase
doAssert "S*: string = \"say \\\"hi\\\"\"" in sbase

# unmapped functions live in the m module, which imports only the type
# modules they use (one list import, win32base first)
doAssert "import ./[win32base, hd]" in mmod
doAssert "export win32base, hd" in mmod
# keyword name: keywords are reserved in usedNames, so the Nim name is
# renamed (addr_2) while the import name stays `addr`
doAssert "proc addr_2*(p: ptr char): Mystery {.sideEffect, importc: \"addr\".}" in mmod
doAssert "p: ptr char" in mmod
# by default function names are kept as-is (exactly the C name), so
# bare `importc` suffices
doAssert "proc TakeHid*(h: HID, cb: CB)" in mmod
doAssert "{.sideEffect, importc.}" in mmod
# `ptr` of a void-alias typedef (direct and via a handle chain) renders
# as the bare `pointer` — Nim forbids `ptr void`
doAssert "proc TakeVoidAlias*(p: pointer, q: pointer)" in mmod
doAssert "ptr VOIDALIAS" notin mmod
doAssert "ptr VOIDALIAS2" notin mmod
# `ptr` of a pointer-alias typedef stays `ptr <name>` (= `ptr pointer`),
# not collapsed to `pointer`
doAssert "proc TakePtrAlias*(p: ptr PTRALIAS)" in mmod
doAssert "proc TakePtrAlias*(p: pointer)" notin mmod
# the suppressed `A` alias LPFINDREPLACE resolves to LPFINDREPLACEA in a
# fn signature (the alias itself is not emitted)
doAssert "proc TakeFindReplace*(p: LPFINDREPLACEA)" in mmod
doAssert "LPFINDREPLACE)" notin mmod
# the dynlib name is lowercased and the .dll suffix stripped
doAssert "{.push dynlib: \"m\".}" in mmod
doAssert "{.pop.}" in mmod
# function with header provenance lives in the hd module with its own
# top-level dynlib statement; the DLL module keeps only the unmapped fns
doAssert "proc HdFn*() {.sideEffect, importc.}" in hdmod
doAssert "{.push dynlib: \"m\".}" in hdmod
doAssert "proc HdFn*" notin mmod
doAssert "proc TakeHid*" notin hdmod

# --headers option: symbols with known provenance get a header pragma
let shmods = generateModules(m, typeHdr, true)
var shdmod = ""
var shmmod = ""
for gm in shmods:
  case gm.name
  of "hd":
    shdmod = gm.code
  of "m":
    shmmod = gm.code
  else:
    discard
doAssert "POINT* {.completeStruct, header: \"hd.h\".} = object" in shdmod
doAssert "HID* {.header: \"hd.h\".} = distinct pointer" in shdmod
doAssert "E* {.header: \"hd.h\".} = enum" in shdmod
doAssert "U* {.header: \"hd.h\".} = uint32" in shdmod
doAssert "CB* {.header: \"hd.h\".} = proc (arg_1: HID): int32 {.stdcall.}" in shdmod
doAssert "IThing* {.header: \"hd.h\".} = distinct object" in shdmod
# constants do not get the header pragma (header implies nodecl)
doAssert "u1*: U = 0x5'u32" in shdmod
# functions: the header pragma joins the importc pragma list
doAssert "proc HdFn*() {.sideEffect, importc, header: \"hd.h\".}" in shdmod
# unmapped symbols keep their plain form (base module, dll module)
doAssert "C*: int32 = 260" in shmods[0].code
doAssert "header:" notin shmods[0].code
doAssert "proc TakeHid*(h: HID, cb: CB)" in shmmod
doAssert "header:" notin shmmod

# --lowercase option: the first letter is lowercased and the importc
# pragma spells the real linkage name (the emitted name differs)
let lmods = generateModules(m, typeHdr, false, true)
var lmod = ""
for gm in lmods:
  if gm.name == "m":
    lmod = gm.code
doAssert "proc takeHid*(h: HID, cb: CB)" in lmod
doAssert "{.sideEffect, importc: \"TakeHid\".}" in lmod
doAssert "proc addr_2*(p: ptr char): Mystery {.sideEffect, importc: \"addr\".}" in lmod

# determinism
let smods2 = generateModules(m, typeHdr)
var ssame = smods.len == smods2.len
if ssame:
  for j in 0 ..< smods.len:
    if smods[j].name != smods2[j].name or smods[j].code != smods2[j].code:
      ssame = false
      break
doAssert ssame, "generation must be deterministic"

echo "synthetic generator tests passed"

# ---------------------------------------------------------------------------
# 2. full model
# ---------------------------------------------------------------------------

# the Windows.Win32.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.Win32.winmd"
let wa = reader.open(winmd)
let full = model.build(wa)
# header provenance map: read the per-header RDL snapshot directly
# (same source the CLI uses when given a directory argument)
const rdl = "windows-rs/metadata"
typeHdr = rdlmap.readRdlMap(@[rdl])
doAssert typeHdr.len > 100000, "type header map missing or truncated"

let mods = generateModules(full, typeHdr)
doAssert mods.len > 600, "expected hundreds of header/dll modules, got " & $mods.len

var winuser: GenModule
var winbase: GenModule
var libloaderapi: GenModule
var stimod: GenModule
var shlobj: GenModule
var windefmod: GenModule
var minwindefmod: GenModule
var winntmod: GenModule
var winsvcmod: GenModule
var cryptxmlmod: GenModule
var wincryptmod: GenModule
var commdlgmod: GenModule
var msiquerymod: GenModule
var totalFns = 0
var hasWin32base = false
for gm in mods:
  if gm.name == "win32base":
    hasWin32base = true
  case gm.name
  of "winuser":
    winuser = gm
  of "winbase":
    winbase = gm
  of "libloaderapi":
    libloaderapi = gm
  of "sti":
    stimod = gm
  of "shlobj":
    shlobj = gm
  of "windef":
    windefmod = gm
  of "minwindef":
    minwindefmod = gm
  of "winnt":
    winntmod = gm
  of "winsvc":
    winsvcmod = gm
  of "cryptxml":
    cryptxmlmod = gm
  of "wincrypt":
    wincryptmod = gm
  of "commdlg":
    commdlgmod = gm
  of "msiquery":
    msiquerymod = gm
  else:
    discard
  var j = 0
  while true:
    # both forms: `importc: "Name"` and bare `importc`
    let k = gm.code.find("importc", j)
    if k < 0:
      break
    inc totalFns
    j = k + 1
# the base module is empty for the real winmd (stubs now live in their
# referencing module and the preamble aliases are gone) so it is not emitted
doAssert not hasWin32base
doAssert winuser.code.len > 0 and winbase.code.len > 0
doAssert libloaderapi.code.len > 0 and stimod.code.len > 0
doAssert shlobj.code.len > 0 and windefmod.code.len > 0
doAssert minwindefmod.code.len > 0
doAssert winntmod.code.len > 0
doAssert winsvcmod.code.len > 0
doAssert totalFns == 14567, "expected 14567 importc lines, got " & $totalFns

# header provenance: AASHELLMENUFILENAME lives in shlobj
doAssert "AASHELLMENUFILENAME* {.completeStruct.} = object" in shlobj.code
doAssert "LPAASHELLMENUFILENAME* = ptr AASHELLMENUFILENAME" in shlobj.code
# HFILE and MAX_PATH live in minwindef
doAssert "HFILE* = distinct int32" in minwindefmod.code
doAssert "MAX_PATH*: int32 = 260" in minwindefmod.code
# header provenance: the common handles live with their defining headers
doAssert "POINT* {.completeStruct.} = object" in windefmod.code
doAssert "HWND* = distinct pointer" in windefmod.code
doAssert "HINSTANCE* = distinct pointer" in minwindefmod.code
# functions live in their defining header, not the DLL module:
# CreateWindowExW: 12 params, stdcall, USER32.dll; the emitted name is
# exactly the C name, so the importc pragma is bare
doAssert "dynlib: \"user32\"" in winuser.code
let cw = winuser.code.find("proc CreateWindowExW*(")
doAssert cw >= 0
let cwline = winuser.code[cw ..< winuser.code.find("\n", cw)]
doAssert cwline.endswith(": HWND {.sideEffect, importc, stdcall.}"), cwline
doAssert "lpParam: pointer" in winuser.code
doAssert "hInstance: HINSTANCE" in winuser.code
# MENUTEMPLATEA is a typedef for void: a fn taking `ptr MENUTEMPLATEA`
# must render the param as the bare `pointer` (Nim forbids `ptr void`)
doAssert "MENUTEMPLATEA* = void" in winuser.code
doAssert "proc LoadMenuIndirectA*(lpMenuTemplate: pointer): HMENU" in winuser.code
doAssert "proc LoadMenuIndirectW*(lpMenuTemplate: pointer): HMENU" in winuser.code
doAssert "ptr MENUTEMPLATEA" notin winuser.code
doAssert "ptr MENUTEMPLATEW" notin winuser.code
# SC_HANDLE is a typedef for pointer (ptr void): a `ptr SC_HANDLE`
# (LPSC_HANDLE) must stay `distinct ptr SC_HANDLE` (= `ptr pointer`),
# NOT be collapsed to `distinct pointer`
doAssert "SC_HANDLE* = distinct pointer" in winsvcmod.code
# a `ptr` of an already-distinct type is itself distinct, so no `distinct`
doAssert "LPSC_HANDLE* = ptr SC_HANDLE" in winsvcmod.code
doAssert "LPSC_HANDLE* = distinct ptr SC_HANDLE" notin winsvcmod.code
doAssert "LPSC_HANDLE* = distinct pointer" notin winsvcmod.code
# CERT_BLOB is a typedef for a struct (CRYPT_INTEGER_BLOB): a `ptr
# CERT_BLOB` field must stay `ptr CERT_BLOB`, not be collapsed to
# `pointer` (the struct is already a distinct, non-void type)
doAssert "CERT_BLOB* = CRYPT_INTEGER_BLOB" in wincryptmod.code
doAssert "rgCertificate*: ptr CERT_BLOB" in cryptxmlmod.code
doAssert "rgCertificate*: pointer" notin cryptxmlmod.code
# LPFINDREPLACE is a plain `A` alias of the typedef LPFINDREPLACEA (a
# handle, not a struct): like the struct A-aliases it is suppressed, and
# only the A-suffixed target is emitted
doAssert "LPFINDREPLACEA* = ptr FINDREPLACEA" in commdlgmod.code
doAssert "LPFINDREPLACE*" notin commdlgmod.code
# MSIDBOPEN_* are integers stored in a pointer-typed (LPCTSTR) constant:
# the declared type is kept and the value is cast explicitly; the VM
# cannot evaluate a cast to a pointer type at compile time, so the
# non-zero const is emitted as a template (the zero one stays a const)
doAssert "template MSIDBOPEN_CREATE*: untyped = cast[LPCTSTR](3)" in msiquerymod.code
doAssert "MSIDBOPEN_CREATE*: LPCTSTR = cast[LPCTSTR](3)" notin msiquerymod.code
doAssert "MSIDBOPEN_CREATE*: uint32" notin msiquerymod.code
doAssert "MSIDBOPEN_READONLY*: LPCTSTR = LPCTSTR(nil)" in msiquerymod.code
# GetProcAddress lives in libloaderapi (its defining header)
doAssert "proc GetProcAddress*" in libloaderapi.code
doAssert "proc GetProcAddress*" notin winuser.code
# GetLastError lives in its defining header (sti per the provenance map)
doAssert "proc GetLastError*(): uint32 {.sideEffect, importc, stdcall.}" in stimod.code
# curated string-pointer aliases (README: LPSTR/PSTR family)
doAssert "PSTR* = cstring" in winntmod.code
doAssert "PCSTR* = cstring" in winntmod.code
doAssert "PWSTR* = ptr UncheckedArray[uint16]" in winntmod.code
doAssert "PCWSTR* = ptr UncheckedArray[uint16]" in winntmod.code
# a header module's functions may span several export DLLs: winbase has
# one dynlib group per DLL (kernel32 among them)
doAssert "{.push dynlib: \"kernel32\".}" in winbase.code
doAssert winbase.code.count("{.push dynlib:") > 1
# minimal imports: winuser imports only modules its signatures reference
# (HMENU lives in windef, so winuser must import and re-export it)
doAssert "windef" in importList(winuser.code)
let exp = winuser.code.find("export ")
doAssert exp >= 0 and "windef" in winuser.code[exp .. winuser.code.find('\n', exp)]
# minimal imports: shlobj needs shtypes (PWSTR/COLORREF) but not kernel32
doAssert "shtypes" in importList(shlobj.code)
doAssert "kernel32" notin importList(shlobj.code)
doAssert winuser.code.find("{.pop.}") > 0

# dll modules have at most two type sections (zone A before the arch
# selector aliases, zone B after them), no `import *` anywhere
for gm in mods:
  doAssert "import *" notin gm.code
  if gm.name == "win32base":
    continue
  var ntype = 0
  var j = 0
  while true:
    let k = gm.code.find("\ntype", j)
    if k < 0:
      break
    inc ntype
    j = k + 1
  doAssert ntype <= 2, gm.name & " has " & $ntype & " type sections"

# --headers option on the real model: provenance attaches the real header
let hdrMods = generateModules(full, typeHdr, true)
var windefHdr: GenModule
for gm in hdrMods:
  if gm.name == "windef":
    windefHdr = gm
doAssert "POINT* {.completeStruct, header: \"windef.h\".} = object" in windefHdr.code
doAssert "HWND* {.header: \"windef.h\".} = distinct pointer" in windefHdr.code

# no duplicate top-level proc names across all modules
var procNames: Table[system.string, int] = initTable[system.string, int]()
for gm in mods:
  for line in gm.code.split('\n'):
    if line.startsWith("proc "):
      let nm = line["proc ".len ..< line.find("*(")]
      procNames[nm] = procNames.getOrDefault(nm) + 1
for nm in procNames.keys:
  doAssert procNames[nm] == 1, "duplicate proc name: " & nm

# determinism
let mods2 = generateModules(full, typeHdr)
var same = mods.len == mods2.len
if same:
  for j in 0 ..< mods2.len:
    if mods[j].name != mods2[j].name or mods[j].code != mods2[j].code:
      same = false
      break
doAssert same, "generateModules must be deterministic"

# ---- arch variants (winmd SupportedArchitectureAttribute) --------------
# KEXCEPTION_FRAME is declared once per arch; the winmd keeps both rows,
# each carrying a SupportedArchitectureAttribute (amd64 / arm64). The
# rows must be emitted as per-arch variants plus a `when defined(...)`
# selector alias, each row matched to its arch by its own attribute — no
# RDL tree is needed, the arch info comes from the winmd itself.
block archTest:
  let archMods = generateModules(full, typeHdr)
  var ntddk: GenModule
  for gm in archMods:
    if gm.name == "ntddk":
      ntddk = gm
  doAssert "KEXCEPTION_FRAME_ARM64* {.completeStruct.} = object" in ntddk.code,
    "arm64 variant of KEXCEPTION_FRAME missing"
  doAssert "KEXCEPTION_FRAME_AMD64* {.completeStruct.} = object" in ntddk.code,
    "amd64 variant of KEXCEPTION_FRAME missing"
  doAssert "defined(arm64)" in ntddk.code
  doAssert "defined(amd64)" in ntddk.code
  # the plain name is a selector alias to one of the variants
  doAssert "type KEXCEPTION_FRAME* = KEXCEPTION_FRAME_" in ntddk.code
  # the arm64 variant has the X0..X28 registers, the amd64 one the R*
  # / Xmm registers — the per-row attribute must not swap them
  var armIdx = ntddk.code.find("KEXCEPTION_FRAME_ARM64* {.completeStruct.} = object")
  var amdIdx = ntddk.code.find("KEXCEPTION_FRAME_AMD64* {.completeStruct.} = object")
  doAssert armIdx >= 0 and amdIdx >= 0
  let armBody = ntddk.code[armIdx ..< armIdx + 400]
  let amdBody = ntddk.code[amdIdx ..< amdIdx + 400]
  doAssert "X19*: uint64" in armBody, "arm64 KEXCEPTION_FRAME content wrong"
  doAssert "P1Home*: uint64" in amdBody, "amd64 KEXCEPTION_FRAME content wrong"
  echo "arch-variant tests passed"

var totBytes = 0
for gm in mods:
  totBytes += gm.code.len
echo "full-model generator tests passed (" & $totBytes & " bytes total)"
