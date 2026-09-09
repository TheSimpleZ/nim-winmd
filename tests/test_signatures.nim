# test_signatures.nim — signature blob decoding tests (doAssert-based).
# Run: nim r --verbosity:0 test/test_signatures.nim

import ../src/winmd/reader
import ../src/winmd/signatures

# the Windows.Win32.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.Win32.winmd"
let wa = reader.open(winmd)

# --- helpers ----------------------------------------------------------------

func isVoid(t: SigType): bool =
  t.base == bPrim and t.prim == pvVoid

func isPtrVoid(t: SigType): bool =
  t.base == bPtr and t.inner[].base == bPrim and t.inner[].prim == pvVoid

func named(t: SigType): string =
  doAssert t.base == bNamed
  t.name

proc findMethod(wa: Winmd, name: string): int =
  for t in 0 ..< wa.rowCount(TypeDef):
    for m in wa.methodsOf(t):
      if wa.methodDef(m).name == name:
        return m
  raiseWinmdError("method not found: " & name)

proc findType(wa: Winmd, name, ns: string): int =
  let rows = wa.typeDefsNamed(name, ns)
  doAssert rows.len == 1, "expected exactly one " & ns & "." & name
  rows[0]

# --- field signatures ---------------------------------------------------------

# Handles are single-field typedefs over void* (verified with the Rust
# windows-metadata crate: HWND.Value == PtrMut(Void, 1)).
let hwndRow = findType(wa, "HWND", "Windows.Win32")
let fo = wa.fieldsOf(hwndRow)
doAssert fo.len == 1, "HWND should have exactly 1 field: " & $fo.len
let f = wa.field(fo.a)
doAssert f.name == "Value"
let fty = decodeFieldSig(wa, f.signature)
doAssert fty.isPtrVoid, "HWND.Value should be void*, got " & $fty

# POINT {x, y}: two I4 fields
let pointRow = findType(wa, "POINT", "Windows.Win32")
let p = wa.fieldsOf(pointRow)
doAssert p.len == 2, "POINT should have 2 fields"
for i in 0 .. 1:
  let pf = wa.field(p.a + i)
  let pt = decodeFieldSig(wa, pf.signature)
  doAssert pt.base == bPrim and pt.prim == pvI4, "POINT field " & $i & " should be I4"

# MAX_PATH: field signature is I4 (matches its Constant row type tag 8)
let apisRow = findType(wa, "Apis", "Windows.Win32")
var maxPath = -1
for fi in wa.fieldsOf(apisRow):
  if wa.field(fi).name == "MAX_PATH":
    maxPath = fi
    break
doAssert maxPath >= 0
let mpt = decodeFieldSig(wa, wa.field(maxPath).signature)
doAssert mpt.base == bPrim and mpt.prim == pvI4, "MAX_PATH should be I4"

# --- method signatures --------------------------------------------------------

# CreateWindowExW: ret HWND; 12 params (verified with the Rust crate)
let cwIdx = findMethod(wa, "CreateWindowExW")
let cw = decodeMethodSig(wa, wa.methodDef(cwIdx).signature)
doAssert cw.ret.base == bNamed and cw.ret.name == "HWND",
  "CreateWindowExW must return HWND"
doAssert cw.params.len == 12
doAssert cw.params[0].prim == pvU4 and cw.params[0].base == bPrim
doAssert cw.params[1].named == "PCWSTR"
doAssert cw.params[2].named == "PCWSTR"
doAssert cw.params[3].prim == pvU4 and cw.params[3].base == bPrim
for i in 4 .. 7:
  doAssert cw.params[i].base == bPrim and cw.params[i].prim == pvI4
doAssert cw.params[8].named == "HWND"
doAssert cw.params[9].named == "HMENU"
doAssert cw.params[10].named == "HINSTANCE"
doAssert cw.params[11].isPtrVoid and cw.params[11].isConst,
  "lpParam must be const void*"

# Param names (1-based list semantics, verified against the Rust crate)
let co = wa.paramsOf(cwIdx)
doAssert co.len == 12
let wantNames = @[
  "dwExStyle", "lpClassName", "lpWindowName", "dwStyle", "X", "Y", "nWidth", "nHeight",
  "hWndParent", "hMenu", "hInstance", "lpParam",
]
for i in 0 ..< co.len:
  doAssert wa.methodParam(co.a + i).name == wantNames[i],
    "param " & $i & ": " & wa.methodParam(co.a + i).name

# GetLastError: no params, returns U4
let gleIdx = findMethod(wa, "GetLastError")
let gle = decodeMethodSig(wa, wa.methodDef(gleIdx).signature)
doAssert gle.params.len == 0
doAssert gle.ret.base == bPrim and gle.ret.prim == pvU4,
  "GetLastError should return U32"

# CertCreateContext: const-pointer params with a non-void pointer target
# (verified bytes: ret 1f 87 d9 0f 01, p2 1f 87 d9 0f 05,
#  p5 1f 87 d9 0f 11 8b 45)
let cccIdx = findMethod(wa, "CertCreateContext")
let ccc = decodeMethodSig(wa, wa.methodDef(cccIdx).signature)
doAssert ccc.ret.isPtrVoid and ccc.ret.isConst
doAssert ccc.params.len == 6
doAssert ccc.params[2].isConst and ccc.params[2].base == bPtr and
  ccc.params[2].inner[].base == bPrim and ccc.params[2].inner[].prim == pvU1
doAssert ccc.params[5].isConst and ccc.params[5].base == bPtr and
  ccc.params[5].inner[].base == bNamed

echo "test_signatures: all assertions passed"
