# test_winrt_components.nim — WinRT metadata other than Windows.winmd: the
# winmds of components in the windows-rs submodule (small ones, whose coded
# indexes take 2 bytes, and WinUI's, which refers to Windows.winmd's types),
# and, when the Windows SDK is installed (on CI it must be), its union metadata
# and contract winmds (doAssert-based).
# Run: nim r --verbosity:0 tests/test_winrt_components.nim  (or `nimble test`)

import std/[algorithm, options, os, sequtils, strutils, tables]
import ../src/winmd/[reader, model, generator, winrtgen]

const components = "windows-rs/crates/tools/reactor/winmd/"

proc modules(winmd: string): Table[system.string, system.string] =
  ## The WinRT modules generated from `winmd`, by name.
  generateWinrtModules(model.build(reader.open(winmd)))
    .mapIt((it.name, it.code)).toTable

proc newestSdkFile(pattern: string): system.string =
  ## The newest file of the Windows SDK that `pattern` names under Windows
  ## Kits\10, a part with a `*` matching folders (`10.*`, a version); "" when
  ## there is none, which on CI, where the SDK is installed, is an error.
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

# by its types' WindowsRuntime flag, even when all it holds is a contract,
# which the model leaves out; classic COM interfaces are not WinRT
doAssert isWinrtMetadata(reader.open(components & "Microsoft.Foundation.winmd"))
doAssert model.build(reader.open(components & "Microsoft.Foundation.winmd")).types.len ==
  0
doAssert not isWinrtMetadata(reader.open(components & "extras.winmd"))

# --- small winmds: coded indexes of 2 bytes ---

# every table of AppLifecycle's winmd has fewer than 2048 rows, so each coded
# index takes 2 bytes; the binary searches read them so
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

# the robot sample's component exports a function: its ImplMap row
let robot = reader.open("windows-rs/crates/samples/robot/component/robot.winmd")
doAssert robot.rowCount(ImplMap) == 1
let exported = robot.implMap(0)
doAssert exported.memberForwarded.kind == MethodDef
doAssert robot.implMapFor(exported.memberForwarded.row).get == exported

# its GuidAttributes are found: every interface has its IID
let lifecycle = modules(components & "Microsoft.Windows.AppLifecycle.winmd")
doAssert "  IID_IAppInstance*: GUID = guid\"75766ae4-0239-5a26-b9da-d5bfc75a4866\"\n" in
  lifecycle["microsoft_windows_applifecycle"]

# --- WinUI: a component that refers to Windows.winmd ---

# a struct of Windows.winmd's types cannot be laid out: Duration and KeyTime
# hold a TimeSpan, so they are left out, and a slot that mentions one is a
# bare pointer; a struct of its own types is declared
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

# the union metadata has MethodImpl rows, and more than 65535 MethodDef rows,
# so a MethodSemantics row's index into them takes 4 bytes
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

# a small contract winmd: its GuidAttributes are found, so an interface is not
# taken for a static class
let foundationContract = contract("Windows.Foundation.FoundationContract")
if foundationContract.len > 0:
  let foundation = modules(foundationContract)["foundation"]
  doAssert "  IStringable* {.mdinterface.} = object\n    lpVtbl*: ptr IStringableVtbl\n" in
    foundation
  doAssert "  IID_IStringable*: GUID = guid\"96369f54-8eb6-48f0-abce-c1b211e627c3\"\n" in
    foundation

# a contract whose types moved to another keeps forwarders to them, in its
# ExportedType table
let callsPhone = contract("Windows.ApplicationModel.Calls.CallsPhoneContract")
if callsPhone.len > 0:
  doAssert reader.open(callsPhone).rowCount(ExportedType) > 0
  doAssert "winrttypes" in modules(callsPhone)

# a runtime class whose default interface is another contract's (IAsyncAction
# is FoundationContract's) is left out, not declared as a static class
let legacySms = contract("Windows.Devices.Sms.LegacySmsApiContract")
if legacySms.len > 0:
  for code in modules(legacySms).values:
    doAssert "DeleteSmsMessageOperation*" notin code

echo "test_winrt_components: all assertions passed"
