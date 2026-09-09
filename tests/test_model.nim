# test_model.nim — model building tests (doAssert-based).
# Run: nim r --verbosity:0 test/test_model.nim

import ../src/winmd/reader
import ../src/winmd/model
import ../src/winmd/signatures

# the Windows.Win32.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.Win32.winmd"
let wa = reader.open(winmd)
let m = model.build(wa)

# --- type population (ground truth from direct table scan) ------------------
var nStruct, nHandle, nEnum, nUnscoped, nDelegate, nInterface = 0
for t in m.types:
  case t.kind
  of tkStruct:
    inc nStruct
  of tkHandle:
    inc nHandle
  of tkEnum:
    inc nEnum
  of tkUnscopedEnum:
    inc nUnscoped
  of tkDelegate:
    inc nDelegate
  of tkInterface:
    inc nInterface
echo "structs=",
  nStruct, " handles=", nHandle, " scopedEnum=", nEnum, " unscopedEnum=", nUnscoped,
  " delegates=", nDelegate, " interfaces=", nInterface

# 28027 ValueTypes -> struct or handle (minus any ApiContractAttribute ones)
doAssert nStruct + nHandle > 28000, "too few structs"
doAssert nEnum + nUnscoped == 4748, "enum total off"
doAssert nEnum > 0 and nUnscoped > 0, "expected both scoped and unscoped enums"
doAssert nDelegate == 2167, "delegate count off"
# 4310 interfaces (no attributes/Apis leak in)
doAssert nInterface == 4310, "interface count off"
# the Apis container class stays in the model (counted among interfaces, as
# in the reference); the generator skips emitting it. No attribute types leak
# in as types.
var sawApis = false
for t in m.types:
  if t.name == "Apis":
    doAssert t.kind == tkInterface
    sawApis = true
  doAssert t.name != "ScopedEnumAttribute"
doAssert sawApis

# --- functions ----------------------------------------------------------------
echo "fns=", m.fns.len, " variadicSkipped=", m.skippedVariadic.len
doAssert m.fns.len + m.skippedVariadic.len == 14567

var cwIdx = -1
for i in 0 ..< m.fns.len:
  if m.fns[i].name == "CreateWindowExW":
    cwIdx = i
    break
doAssert cwIdx >= 0, "CreateWindowExW missing"
let cw = m.fns[cwIdx]
doAssert cw.importName == "CreateWindowExW"
doAssert cw.moduleName == "USER32.dll"
doAssert cw.stdcall
doAssert cw.ret.name == "HWND"
doAssert cw.params.len == 12
doAssert cw.params[0].name == "dwExStyle"
doAssert cw.params[1].name == "lpClassName"
doAssert cw.params[11].name == "lpParam"
doAssert cw.params[11].ty.base == bPtr and cw.params[11].ty.isConst

var gleIdx = -1
for i in 0 ..< m.fns.len:
  if m.fns[i].name == "GetLastError":
    gleIdx = i
    break
doAssert gleIdx >= 0
doAssert m.fns[gleIdx].moduleName == "KERNEL32.dll"
doAssert m.fns[gleIdx].params.len == 0

# duplicate exported names must be present as multiple entries
var nAlloc = 0
for f in m.fns:
  if f.name == "AllocateUserPhysicalPages":
    inc nAlloc
doAssert nAlloc >= 2,
  "expected >= 2 AllocateUserPhysicalPages overloads, got " & $nAlloc

# --- handles -------------------------------------------------------------------
var hwndIdx = -1
for i in 0 ..< m.types.len:
  if m.types[i].name == "HWND" and m.types[i].kind == tkHandle:
    hwndIdx = i
    break
doAssert hwndIdx >= 0, "HWND must be a handle"
let h = m.types[hwndIdx]
doAssert h.hasUnderlying
doAssert h.underlying.base == bPtr and h.underlying.inner[].prim == pvVoid,
  "HWND underlying should be void*"

# --- constants -----------------------------------------------------------------
echo "consts=", m.consts.len
doAssert m.consts.len == 80387, "free constant count off"
var mpIdx = -1
for i in 0 ..< m.consts.len:
  if m.consts[i].name == "MAX_PATH":
    mpIdx = i
    break
doAssert mpIdx >= 0, "MAX_PATH missing"
doAssert m.consts[mpIdx].value == 260
doAssert m.consts[mpIdx].ty.prim == pvI4 and m.consts[mpIdx].ty.base == bPrim

# negative constants exist (signed decode, sign-extended into the
# uint64 value). Free negative constants are 64-bit (e.g.
# BG_SIZE_UNKNOWN = -1); negative 32-bit values are enum members.
var foundNeg = false
for c in m.consts:
  if c.value >= 0xFFFFFFFF_00000000'u64 and c.ty.base == bPrim:
    foundNeg = true
    break
doAssert foundNeg, "no negative constants (signed decode broken?)"
var bgu: uint64 = 0
for c in m.consts:
  if c.name == "BG_SIZE_UNKNOWN":
    bgu = c.value
    doAssert c.ty.base == bPrim and c.ty.prim == pvU8
doAssert bgu == 0xFFFFFFFFFFFFFFFF'u64, "BG_SIZE_UNKNOWN must be all-ones"

# --- enums -----------------------------------------------------------------------
# every enum has an underlying integer type; a couple of placeholder enums
# (WS_SECURITY_ALGORITHM_PROPERTY_ID, WS_XML_BUFFER_PROPERTY_ID) have no
# members at all, so fields may be empty but the backing type must exist.
var emptyEnums = 0
for t in m.types:
  if t.kind == tkEnum or t.kind == tkUnscopedEnum:
    doAssert t.hasUnderlying
    doAssert t.underlying.base == bPrim
    if t.fields.len == 0:
      inc emptyEnums
doAssert emptyEnums <= 2, "too many empty enums"

# a specific well-known scoped enum: pick one with a value named by the file
# (structural check) — find any scoped enum whose first value is 0
var zeroEnum = ""
for t in m.types:
  if t.kind == tkEnum and t.fields.len > 0 and t.fields[0].constant == 0:
    zeroEnum = t.name
    break
doAssert zeroEnum.len > 0, "no scoped enum with a zero member"
echo "sample scoped enum with 0 member: ", zeroEnum

echo "test_model: all assertions passed"
