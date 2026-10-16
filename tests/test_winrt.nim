# test_winrt.nim — the WinRT modules of Windows.winmd (doAssert-based).
# Run: nim r --verbosity:0 tests/test_winrt.nim  (or `nimble test`)

import std/[sequtils, strformat, strutils, tables]
import ../src/winmd/[reader, signatures, model, generator, winrtgen]

# the Windows.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.winmd"
let wa = reader.open(winmd)

# --- signatures ---
for i in 0 ..< wa.rowCount(Field):
  discard decodeFieldSig(wa, wa.field(i).signature)
for i in 0 ..< wa.rowCount(MethodDef):
  discard decodeMethodSig(wa, wa.methodDef(i).signature)
for i in 0 ..< wa.rowCount(TypeSpec):
  discard decodeTypeSpec(wa, i)

# a GENERIC method: its generic parameter count comes first; `!!0 M<T>(!!0)`
let generic = decodeMethodSig(wa, @[0x10'u8, 1, 1, 0x1E, 0, 0x1E, 0])
doAssert generic.params.len == 1 and generic.ret.isMethodVar
doAssert generic.params[0].base == bTypeVar and generic.params[0].isMethodVar

# a CLASS token that is a TypeSpec: `FIELD CLASS <TypeSpec 0>`
let specified = decodeFieldSig(wa, @[0x06'u8, 0x12, 0x06])
let spec0 = decodeTypeSpec(wa, 0)
doAssert specified.base == bGenericInst and specified.rowIdx == spec0.rowIdx
doAssert (specified.ns, specified.name, specified.args.len) ==
  (spec0.ns, spec0.name, spec0.args.len)

# --- generated modules ---
let code = generateWinrtModules(model.build(wa)).mapIt((it.name, it.code)).toTable
for c in code.values:
  doAssert "not mapped" notin c

# winrttypes: every type
let types = code["winrttypes"]
# an enum is an unscoped Win32 enum: its integer, and a const per member
doAssert "  AsyncStatus* {.mdalias.} = int32\n" in types
doAssert "  AsyncStatus_Started*: AsyncStatus = 0'i32\n" in types
doAssert "  FileAttributes* {.mdalias.} = uint32\n" in types
doAssert "  FileAttributes_ReadOnly*: FileAttributes = 1'u32\n" in types
doAssert "{.borrow.}" notin types
# a renamed enum's members follow its name
doAssert "  PackageStatus_2_OK*: PackageStatus_2 = 0'u32\n" in types
doAssert "  Point* {.mdtype.} = object\n    X*: float32\n    Y*: float32\n" in types
# an interface is the object a pointer to it points at; its vtable is its
# namespace's, and the base one is reachable without a cast
doAssert "  IStringable* {.mdinterface.} = object\n    lpVtbl*: ptr IInspectableVtbl\n" in
  types
doAssert "  AsyncActionCompletedHandler* {.mdinterface.} = object\n    lpVtbl*: ptr IUnknownVtbl\n" in
  types
doAssert "  IVector*[T] {.mdinterface.} = object\n    lpVtbl*: ptr IInspectableVtbl\n" in
  types
# a runtime class is its default interface
doAssert "  Uri* {.mdalias.} = IUriRuntimeClass\n" in types
doAssert "  StringMap* {.mdalias.} = IMap[HSTRING, HSTRING]\n" in types
# a struct that mentions an interface is declared with the rest
doAssert "  HttpProgress* {.mdtype.} = object\n" in types
doAssert "    TotalBytesToSend*: ptr IReference[uint64]\n" in types

# a namespace module imports only winrtbase and winrttypes, so namespaces
# that refer to each other in a cycle — Storage and System — need nothing more
for name in ["storage", "system", "foundation"]:
  doAssert "import ./[winrtbase, winrttypes]\n" in code[name]
let foundation = code["foundation"]
let collections = code["foundation_collections"]
doAssert "  RuntimeClass_Windows_Foundation_Uri*: string = \"Windows.Foundation.Uri\"\n" in
  foundation
# a vtable: its base, its slots, the return as a trailing `retval`
doAssert """
  IStringableVtbl* {.mdvtbl.} = object of IInspectableVtbl
    ToString*: proc(this: ptr IStringable, retval: ptr HSTRING): HRESULT {.mdslot.}
""" in
  foundation
doAssert """
  AsyncActionCompletedHandlerVtbl* {.mdvtbl.} = object of IUnknownVtbl
    Invoke*: proc(this: ptr AsyncActionCompletedHandler, asyncInfo: ptr IAsyncAction, asyncStatus: AsyncStatus): HRESULT {.mdslot.}
""" in
  foundation
# an array passed in: size and pointer
doAssert "    CreateInt32Array*: proc(this: ptr IPropertyValueStatics, valueSize: uint32, value: ptr int32, retval: ptr ptr IInspectable): HRESULT {.mdslot.}\n" in
  foundation
# an array the callee allocates: size and pointer, both by pointer
doAssert "    GetInt32Array*: proc(this: ptr IPropertyValue, valueSize: ptr uint32, value: ptr ptr int32): HRESULT {.mdslot.}\n" in
  foundation
doAssert "    GetInputEntities*: proc(this: ptr IActionInvocationContext, retvalSize: ptr uint32, retval: ptr ptr ptr NamedActionEntity): HRESULT {.mdslot.}\n" in
  code["ai_actions"]
# a generic interface's slots use its parameters
doAssert "    GetAt*: proc(this: ptr IVector[T], index: uint32, retval: ptr T): HRESULT {.mdslot.}\n" in
  collections
# an IID, from the GuidAttribute
doAssert "  IID_IStringable*: GUID = guid\"96369f54-8eb6-48f0-abce-c1b211e627c3\"\n" in
  foundation
# overloads are named by OverloadAttribute
doAssert """
    MonthAsFullString*: proc(this: ptr ICalendar, retval: ptr HSTRING): HRESULT {.mdslot.}
    MonthAsString*: proc(this: ptr ICalendar, idealLength: int32, retval: ptr HSTRING): HRESULT {.mdslot.}
""" in
  code["globalization"]

# instantiation IIDs, including ones only their definitions imply
for (name, iid) in [
  ("IVector_HSTRING", "98b9acc1-4b56-532e-ac73-03d5291cca90"),
  ("IAsyncOperation_bool", "cdb5efb3-5788-509d-9be1-71ccb8a3362a"),
  ("IReference_GUID", "7d50f649-632c-51f9-849a-ee49428933ea"),
  ("IMap_HSTRING_IInspectable", "1b0d3570-0877-5ec2-8a2c-3b9539506aca"),
  ("IIterable_IWwwFormUrlDecoderEntry", "876be83b-7218-5bfb-a169-83152ef7e146"),
  ("IVectorView_Uri", "4b8385bd-a2cd-5ff1-bf74-7ea580423e50"),
  ("IReference_Point", "84f14c22-a00a-5272-8d3d-82112e66df00"),
  ("IReference_WebErrorStatus", "f2b26336-6a9d-54de-8eca-00d6c871e469"),
  ("IAsyncOperation_DataPackageOperation", "8b98aea9-64f0-5672-b30e-dfd9c2e4f6fe"),
  ("IIterable_IKeyValuePair_HSTRING_HSTRING", "e9bdaaf0-cbf6-5c72-be90-29cbf3a1319b"),
  ("IIterable_GUID", "f4ca3045-5dd7-54be-982e-d88d8ca0876e"),
  ("AsyncOperationCompletedHandler_StorageFile", "e521c894-2c26-5946-9e61-2b5e188d01ed"),
]:
  doAssert &"  IID_{name}*: GUID = guid\"{iid}\"\n" in code["winrtgenerics"]

# --- over a reference ---
# Windows.Foundation's types as a binding written before, and the rest over
# it: its types named through the alias, not declared again
let whole = model.build(wa)
let (below, above) = (
  Model(types: whole.types.filterIt(it.ns.startsWith "Windows.Foundation")),
  Model(types: whole.types.filterIt(not it.ns.startsWith "Windows.Foundation")),
)
let over = generateWinrtModules(
    above, @[Reference(alias: "winrt", path: "winrt/abi", model: below)]
  )
  .mapIt((it.name, it.code)).toTable
doAssert "winrtbase" notin over and "foundation" notin over
for c in over.values:
  doAssert "not mapped" notin c
  doAssert "import winrt/abi/winrtbase\n" in c
let overTypes = over["winrttypes"]
doAssert "  IStringable* {.mdinterface.}" notin overTypes
doAssert "  StorageFile* {.mdalias.} = IStorageFile\n" in overTypes
doAssert "from winrt/abi/winrttypes as winrt import nil\n" in overTypes
# the reference's types, as its own output names them
doAssert "retval: ptr ptr winrt.IAsyncAction" in over["storage"]
doAssert "retval: ptr ptr winrt.IAsyncOperation[ptr StorageFile]" in over["storage"]
# an instantiation naming one of this output's types is this output's IID;
# one naming only the reference's is the reference's
let overIids = over["winrtgenerics"]
doAssert "  IID_AsyncOperationCompletedHandler_StorageFile*: GUID = " &
  "guid\"e521c894-2c26-5946-9e61-2b5e188d01ed\"\n" in overIids
doAssert "IID_IVector_HSTRING*" notin overIids

echo "test_winrt: all assertions passed"
