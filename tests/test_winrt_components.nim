# test_winrt_components.nim — component and SDK winmds (doAssert-based).
# Run: nim r --verbosity:0 tests/test_winrt_components.nim  (or `nimble test`)

import std/[algorithm, options, os, sequtils, strutils, tables]
import ../src/winmd/[reader, model, generator, winrtgen]

const components = "windows-rs/crates/tools/reactor/winmd/"

proc modules(winmd: string): Table[system.string, system.string] =
  ## The WinRT modules generated from `winmd`, by name.
  generateWinrtModules(model.build(reader.open(winmd)))
    .mapIt((it.name, it.code)).toTable

proc newestSdkFile(pattern: string): system.string =
  ## The newest Windows SDK file matching `pattern`; "" (an error on CI) if none.
  var paths = @[r"C:\Program Files (x86)\Windows Kits\10"]
  for part in pattern.split('/'):
    paths =
      if '*' in part:
        paths.mapIt(toSeq(walkDirs(it / part))).concat
      else:
        paths.mapIt(it / part)
  let found = paths.filterIt(fileExists(it)).sorted
  doAssert found.len > 0 or not existsEnv("CI"), "no Windows SDK file " & pattern
  if found.len == 0:
    echo "not installed, skipped: ", pattern
    ""
  else:
    found[^1]

# --- which metadata is WinRT ---

# by the WindowsRuntime flag, even for a contract-only winmd
doAssert isWinrtMetadata(reader.open(components & "Microsoft.Foundation.winmd"))
doAssert model.build(reader.open(components & "Microsoft.Foundation.winmd")).types.len ==
  0
doAssert not isWinrtMetadata(reader.open(components & "extras.winmd"))

# --- small winmds: coded indexes of 2 bytes ---

# a small winmd: 2-byte coded indexes
let small = reader.open(components & "Microsoft.Windows.AppLifecycle.winmd")
doAssert small.rowCount(MethodDef) < 2048 and small.rowCount(TypeDef) < 2048
doAssert small.rowCount(CustomAttribute) > 0 and small.rowCount(MethodImpl) > 0
for i in 0 ..< small.rowCount(CustomAttribute):
  let attribute = small.customAttribute(i)
  doAssert attribute in small.customAttributesFor(attribute.parent)
for i in 0 ..< small.rowCount(Constant):
  let constant = small.constant(i)
  if constant.parent.kind == Field:
    doAssert small.constantFor(constant.parent.row).get == constant
for i in 0 ..< small.rowCount(MethodImpl):
  let impl = small.methodImpl(i)
  doAssert impl.class < small.rowCount(TypeDef)
  doAssert impl.methodBody.kind == MethodDef
  doAssert impl.methodBody.row < small.rowCount(MethodDef)
  doAssert impl.methodDeclaration.kind in {MethodDef, MemberRef}

# robot.winmd's ImplMap row
let robot = reader.open("windows-rs/crates/samples/robot/component/robot.winmd")
doAssert robot.rowCount(ImplMap) == 1
let exported = robot.implMap(0)
doAssert exported.memberForwarded.kind == MethodDef
doAssert robot.implMapFor(exported.memberForwarded.row).get == exported

# IIDs are found
let lifecycle = modules(components & "Microsoft.Windows.AppLifecycle.winmd")
doAssert "  IID_IAppInstance*: GUID = guid\"75766ae4-0239-5a26-b9da-d5bfc75a4866\"\n" in
  lifecycle["microsoft_windows_applifecycle"]

# --- WinUI: a component that refers to Windows.winmd ---

# structs holding a Windows.winmd TimeSpan are left out; their slots are pointers
let xaml = modules(components & "Microsoft.UI.Xaml.winmd")
doAssert "  Thickness* {.mdtype.} = object\n    Left*: float64\n" in xaml["winrttypes"]
for code in xaml.values:
  doAssert "  Duration* {.mdtype.}" notin code and "  KeyTime* {.mdtype.}" notin code
doAssert toSeq(xaml.values).anyIt(
  "    get_KeyTime*: pointer # signature not mapped\n" in it
)
doAssert toSeq(xaml.values).anyIt(
  "  IID_IUIElement*: GUID = guid\"c3c01020-320c-5cf6-9d24-d396bbfa4d8b\"\n" in it
)

# --- the Windows SDK ---

# MethodImpl rows, and over 65535 MethodDefs
let union = newestSdkFile("UnionMetadata/10.*/Windows.winmd")
if union.len > 0:
  let ua = reader.open(union)
  doAssert ua.rowCount(MethodImpl) > 0 and ua.rowCount(MethodDef) >= 65536
  for i in 0 ..< ua.rowCount(MethodImpl):
    let impl = ua.methodImpl(i)
    doAssert impl.class < ua.rowCount(TypeDef)
    doAssert impl.methodBody.kind == MethodDef
    doAssert impl.methodBody.row < ua.rowCount(MethodDef)
    doAssert impl.methodDeclaration.kind == MemberRef
    doAssert impl.methodDeclaration.row < ua.rowCount(MemberRef)
  for i in 0 ..< ua.rowCount(MethodSemantics):
    doAssert ua.methodSemantics(i).`method` < ua.rowCount(MethodDef)

proc contract(name: string): system.string =
  ## The newest installed winmd of SDK contract `name`, or "".
  newestSdkFile("References/10.*/" & name & "/*/" & name & ".winmd")

# a contract winmd: interfaces, not static classes
let foundationContract = contract("Windows.Foundation.FoundationContract")
if foundationContract.len > 0:
  let foundation = modules(foundationContract)["foundation"]
  doAssert "  IStringable* {.mdinterface.} = object\n    lpVtbl*: ptr IStringableVtbl\n" in
    foundation
  doAssert "  IID_IStringable*: GUID = guid\"96369f54-8eb6-48f0-abce-c1b211e627c3\"\n" in
    foundation

# type forwarders (ExportedType)
let callsPhone = contract("Windows.ApplicationModel.Calls.CallsPhoneContract")
if callsPhone.len > 0:
  doAssert reader.open(callsPhone).rowCount(ExportedType) > 0
  doAssert "winrttypes" in modules(callsPhone)

# a class whose default interface is another contract's is left out
let legacySms = contract("Windows.Devices.Sms.LegacySmsApiContract")
if legacySms.len > 0:
  for code in modules(legacySms).values:
    doAssert "DeleteSmsMessageOperation*" notin code

echo "test_winrt_components: all assertions passed"
