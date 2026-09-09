# test_winmd.nim — reader tests (doAssert-based) for src/winmd2nim/winmd.nim
# Run: nim r --verbosity:0 tests/test_winmd.nim  (or `nimble test`)

import std/os
import ../src/winmd/reader

# the Windows.Win32.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.Win32.winmd"
doAssert fileExists(winmd), "winmd not found: " & winmd
let wa = reader.open(winmd)

# --- table row counts (ground truth from the windows-metadata reference) ---
doAssert wa.rowCount(Module) == 1
doAssert wa.rowCount(TypeRef) == 23388
doAssert wa.rowCount(TypeDef) == 39265
doAssert wa.rowCount(Field) == 206150
doAssert wa.rowCount(MethodDef) == 42804
doAssert wa.rowCount(MethodParam) == 104897
doAssert wa.rowCount(InterfaceImpl) == 4281
doAssert wa.rowCount(MemberRef) == 15
doAssert wa.rowCount(Constant) == 119944
doAssert wa.rowCount(CustomAttribute) == 48398
doAssert wa.rowCount(ClassLayout) == 1182
doAssert wa.rowCount(ModuleRef) == 226
doAssert wa.rowCount(ImplMap) == 14567
doAssert wa.rowCount(Assembly) == 1
doAssert wa.rowCount(NestedClass) == 2634
doAssert wa.rowCount(FieldLayout) == 0
doAssert wa.rowCount(TypeSpec) == 0

# --- strings heap sanity ---
doAssert wa.containsString("CreateWindowExW")
doAssert wa.containsString("USER32.dll")
doAssert wa.containsString("Windows.Win32")

# --- assembly row ---
let asmRow = wa.assembly(0)
doAssert asmRow.name.len > 0, "assembly name empty"
echo "assembly: ", asmRow.name

# --- TypeDefs of interest ---
let hwnds = wa.typeDefsNamed("HWND", "Windows.Win32")
doAssert hwnds.len >= 1, "no Windows.Win32.HWND typedef"
let hwnd = wa.typeDef(hwnds[0])
doAssert not hwnd.extends.isNull
doAssert wa.typeName(hwnd.extends) == "ValueType",
  "HWND should extend System.ValueType (found: " & wa.typeName(hwnd.extends) & ")"

let apisTypes = wa.typeDefsNamed("Apis", "Windows.Win32")
doAssert apisTypes.len == 1, "expected 1 Windows.Win32.Apis type, got " & $apisTypes.len

# --- total imported functions == 14567 (= ImplMap row count) ---
# (14566 live on the Apis type, 1 on Windows.Win32.AsyncIAdviseSink)
doAssert wa.rowCount(ImplMap) == 14567

# --- find the CreateWindowExW MethodDef and check its ImplMap ---
var cwIdx = -1
let a0 = wa.methodsOf(apisTypes[0])
for m in a0:
  if wa.methodDef(m).name == "CreateWindowExW":
    cwIdx = m
    break
doAssert cwIdx >= 0, "CreateWindowExW method not found"
let cw = wa.methodDef(cwIdx)
doAssert cw.signature.len > 0
doAssert (cw.flags and 0x0010'u16) != 0, "CreateWindowExW should be static"
let im = wa.implMapFor(cwIdx)
doAssert im.isSome, "no ImplMap for CreateWindowExW"
doAssert im.get().importName == "CreateWindowExW"
doAssert wa.moduleRef(im.get().moduleRef).name == "USER32.dll"
doAssert (im.get().flags and 0x0100'u16) != 0,
  "expected stdcall (0x100) in ImplMap flags"

# GetLastError lives in KERNEL32
var gleIdx = -1
for m in a0:
  if wa.methodDef(m).name == "GetLastError":
    gleIdx = m
    break
doAssert gleIdx >= 0, "GetLastError method not found"
let gleIm = wa.implMapFor(gleIdx)
doAssert gleIm.isSome and wa.moduleRef(gleIm.get().moduleRef).name == "KERNEL32.dll"

# --- MAX_PATH constant (lives on the Apis type as a static literal field) ---
var maxPathField = -1
for f in wa.fieldsOf(apisTypes[0]):
  if wa.field(f).name == "MAX_PATH":
    maxPathField = f
    break
doAssert maxPathField >= 0, "MAX_PATH field not found"
let mp = wa.field(maxPathField)
doAssert mp.signature[0] == 0x06, "field signature blob must start with prolog 0x06"
let mpConst = wa.constantFor(maxPathField)
doAssert mpConst.isSome, "no Constant row for MAX_PATH"
doAssert mpConst.get().typeTag == 8, "MAX_PATH constant tag should be I4 (8)"
doAssert mpConst.get().value.len == 4 and
  (
    int(mpConst.get().value[0]) or (int(mpConst.get().value[1]) shl 8) or
    (int(mpConst.get().value[2]) shl 16) or (int(mpConst.get().value[3]) shl 24)
  ) == 260, "MAX_PATH should be 260"

# --- params list semantics: CreateWindowExW has 12 named params ---
let po = wa.paramsOf(cwIdx)
doAssert po.len == 12, "CreateWindowExW should have 12 params, got " & $po.len
var named = 0
for p in po:
  let pr = wa.methodParam(p)
  if pr.name.len > 0:
    named += 1
doAssert named == 12, "all 12 params should be named, got " & $named

# --- custom attributes: ScopedEnumAttribute exists on some TypeDef ---
let owners = wa.methodOwnerMap()
var foundScopedEnum = false
for i in 0 ..< wa.rowCount(TypeDef):
  let attrs = wa.customAttributesFor(reader.typedRef(TypeDef, i))
  if wa.attributeNamed(attrs, "ScopedEnumAttribute", owners).isSome:
    foundScopedEnum = true
    break
doAssert foundScopedEnum, "no ScopedEnumAttribute found on any TypeDef"

echo "test_winmd: all assertions passed"
