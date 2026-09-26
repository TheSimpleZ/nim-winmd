# test_winrt.nim — WinRT metadata (Windows.winmd) tests (doAssert-based).
# Run: nim r --verbosity:0 tests/test_winrt.nim  (or `nimble test`)

import std/[options, sequtils, strformat, strutils, tables]
import ../src/winmd/[reader, signatures, model, generator, winrtgen]

# the Windows.winmd from the windows-rs submodule
const winmd = "windows-rs/crates/libs/default/Windows.winmd"
let wa = reader.open(winmd)

proc findMethod(wa: Winmd, name, ns, meth: string): MethodSig =
  for m in wa.methodsOf(wa.typeDefsNamed(name, ns)[0]):
    if wa.methodDef(m).name == meth:
      return decodeMethodSig(wa, wa.methodDef(m).signature)
  raiseWinmdError("method not found: " & meth)

# --- signatures ---
for i in 0 ..< wa.rowCount(Field):
  discard decodeFieldSig(wa, wa.field(i).signature)
for i in 0 ..< wa.rowCount(MethodDef):
  discard decodeMethodSig(wa, wa.methodDef(i).signature)
for i in 0 ..< wa.rowCount(TypeSpec):
  discard decodeTypeSpec(wa, i)

# IVector<String> get_FileTypeFilter()
let ftf =
  findMethod(wa, "IFileOpenPicker", "Windows.Storage.Pickers", "get_FileTypeFilter")
doAssert ftf.ret.base == bGenericInst and ftf.ret.name == "IVector`1"
doAssert ftf.ret.args.len == 1 and ftf.ret.args[0].prim == pvString

# T GetAt(UInt32 index)
let getAt = findMethod(wa, "IVector`1", "Windows.Foundation.Collections", "GetAt")
doAssert getAt.ret.base == bTypeVar and getAt.ret.varIdx == 0

# void ReadBytes(UInt8[] value)
let rb = findMethod(wa, "IDataReader", "Windows.Storage.Streams", "ReadBytes")
doAssert rb.params.len == 1 and rb.params[0].base == bSzArray
doAssert rb.params[0].inner[].prim == pvU1

# a generic method (none in WinRT): its generic parameter count comes before
# its parameter count; `!!0 M<T>(!!0)`
let generic = decodeMethodSig(wa, @[0x10'u8, 1, 1, 0x1E, 0, 0x1E, 0])
doAssert generic.params.len == 1 and generic.ret.isMethodVar
doAssert generic.params[0].base == bTypeVar and generic.params[0].isMethodVar

# a CLASS whose token is a TypeSpec (tag 2) is the type the TypeSpec spells:
# a field of the first TypeSpec, `FIELD CLASS ((0 + 1) << 2 | 2)`
let specified = decodeFieldSig(wa, @[0x06'u8, 0x12, 0x06])
let spec0 = decodeTypeSpec(wa, 0)
doAssert specified.base == bGenericInst and specified.rowIdx == spec0.rowIdx
doAssert (specified.ns, specified.name, specified.args.len) ==
  (spec0.ns, spec0.name, spec0.args.len)

# --- model ---
let m = model.build(wa)
let byName = m.types.mapIt((it.ns & "." & it.name, it)).toTable
# every type of WinRT metadata carries the WindowsRuntime flag, enums and
# structs too; a runtime class is told apart by its flags, not its GUID
doAssert m.types.allIt(it.isWinRT)
doAssert byName["Windows.Foundation.Uri"].isClass
doAssert not byName["Windows.Foundation.IStringable"].isClass
doAssert byName["Windows.Foundation.IStringable"].guid.isSome
doAssert byName["Windows.Foundation.AsyncActionCompletedHandler"].methods.len == 1

# --- generated modules ---
let code = generateWinrtModules(m).mapIt((it.name, it.code)).toTable
for c in code.values:
  doAssert "not mapped" notin c

proc nsCode(name: string): string =
  ## The code behind namespace module `name`: its own, or the group module it
  ## re-exports when its namespace shares one with a cycle of others.
  result = code[name]
  for line in result.splitLines:
    if line.startsWith("import ./") and line.endsWith("_group"):
      return code[line["import ./".len .. ^1]]

# winrttypes holds the enums and the structs; the interfaces sit beside their
# vtables, so `lpVtbl` is typed
let types = code["winrttypes"]
# an enum is a distinct integer, its members consts, as in windows-rs: it
# holds any value, a [Flags] combination or a name shared with another, and
# borrows what it needs from its integer
doAssert "  AsyncStatus* = distinct int32\n" in types
doAssert "  AsyncStatus_Started*: AsyncStatus = AsyncStatus(0'i32)\n" in types
doAssert "func `==`*(a, b: AsyncStatus): bool {.borrow.}\n" in types
doAssert "func `or`*(a, b: AsyncStatus)" notin types
doAssert "  FileAttributes* = distinct uint32\n" in types
doAssert "  FileAttributes_ReadOnly*: FileAttributes = FileAttributes(1'u32)\n" in types
doAssert "func `or`*(a, b: FileAttributes): FileAttributes {.borrow.}\n" in types
doAssert "func contains*(a, b: FileAttributes): bool =\n" in types
doAssert "  BluetoothMinorClass_ComputerDesktop*: BluetoothMinorClass = BluetoothMinorClass(1'i32)\n" in
  types
doAssert "  BluetoothMinorClass_PhoneCellular*: BluetoothMinorClass = BluetoothMinorClass(1'i32)\n" in
  types
doAssert " = enum\n" notin types
# the members of an enum renamed for a clash are named after it
doAssert "  PackageStatus_2_OK*: PackageStatus_2 = PackageStatus_2(0'u32)\n" in types
doAssert "  Point* {.mdtype.} = object\n    X*: float32\n    Y*: float32\n" in types
doAssert "lpVtbl" notin types and "mdinterface" notin types
for c in code.values:
  doAssert "interfaceId: \"" notin c # an IID is a constant, not carried by its type

# a vtable: its base, then the methods in slot order, the declared return a
# trailing out-parameter
let foundation = code["foundation"]
doAssert nsCode("foundation") == foundation # in no cycle: its own module
doAssert "  IStringable* {.mdinterface.} = object\n    lpVtbl*: ptr IStringableVtbl\n" in
  foundation
doAssert "  Uri* {.mdalias.} = IUriRuntimeClass\n" in foundation
let collections = nsCode("foundation_collections")
doAssert "  IVector*[T] {.mdinterface.} = object\n    lpVtbl*: ptr IVectorVtbl[T]\n" in
  collections
doAssert "  StringMap* {.mdalias.} = IMap[HSTRING, HSTRING]\n" in collections

# Windows.Storage and Windows.System refer to each other: they share one
# module, which each of them re-exports
doAssert code["storage"].splitLines.anyIt(
  it.startsWith("import ./") and it.endsWith("_group")
)
doAssert nsCode("storage") == nsCode("system")
doAssert "  IStorageFile* {.mdinterface.} = object\n    lpVtbl*: ptr IStorageFileVtbl\n" in
  nsCode("storage")
# a struct that mentions an interface lives beside the interfaces: HttpProgress
# has IReference<UInt64> fields
doAssert "  HttpProgress* {.mdtype.} = object\n" notin types
doAssert "  HttpProgress* {.mdtype.} = object\n" in nsCode("web_http")
doAssert "    TotalBytesToSend*: ptr IReference[uint64]\n" in nsCode("web_http")
doAssert """
  IStringableVtbl* {.mdvtbl.} = object of IInspectableVtbl
    ToString*: proc(this: ptr IStringable, retval: ptr HSTRING): HRESULT {.stdcall.}
""" in
  foundation
doAssert """
  AsyncActionCompletedHandlerVtbl* {.mdvtbl.} = object of IUnknownVtbl
    Invoke*: proc(this: ptr AsyncActionCompletedHandler, asyncInfo: ptr IAsyncAction, asyncStatus: AsyncStatus): HRESULT {.stdcall.}
""" in
  foundation
# an array the caller passes: its size and a pointer to its elements
doAssert "    CreateInt32Array*: proc(this: ptr IPropertyValueStatics, valueSize: uint32, value: ptr int32, retval: ptr ptr IInspectable): HRESULT {.stdcall.}\n" in
  foundation
# an array the callee allocates, by-ref or returned: its size and its
# elements, both by pointer
doAssert "    GetInt32Array*: proc(this: ptr IPropertyValue, valueSize: ptr uint32, value: ptr ptr int32): HRESULT {.stdcall.}\n" in
  foundation
doAssert "    GetInputEntities*: proc(this: ptr IActionInvocationContext, retvalSize: ptr uint32, retval: ptr ptr ptr NamedActionEntity): HRESULT {.stdcall.}\n" in
  nsCode("ai_actions")
# a Char16 is a WCHAR, as in the SDK headers
doAssert "    GetChar16*: proc(this: ptr IPropertyValue, retval: ptr WCHAR): HRESULT {.stdcall.}\n" in
  foundation
# a generic interface's slots, in terms of its parameters
doAssert "    GetAt*: proc(this: ptr IVector[T], index: uint32, retval: ptr T): HRESULT {.stdcall.}\n" in
  collections
# the IID of an interface, and of a parameterised one (its PIID), as
# constants beside their vtables
doAssert "  IID_IStringable*: GUID = guid\"96369f54-8eb6-48f0-abce-c1b211e627c3\"\n" in
  foundation
doAssert "  IID_IVector*: GUID = guid\"913337e9-11a1-4345-a3a2-4e7f956e222d\"\n" in
  collections
doAssert "PIID_" notin collections
# Windows.Foundation.HResult is HRESULT, not a struct of its own
doAssert "    get_ErrorCode*: proc(this: ptr IAsyncInfo, retval: ptr HRESULT): HRESULT {.stdcall.}\n" in
  foundation
# overloads are named by their OverloadAttribute, as in the SDK headers
doAssert """
    MonthAsFullString*: proc(this: ptr ICalendar, retval: ptr HSTRING): HRESULT {.stdcall.}
    MonthAsString*: proc(this: ptr ICalendar, idealLength: int32, retval: ptr HSTRING): HRESULT {.stdcall.}
""" in
  nsCode("globalization")

# instantiation IIDs as the SDK headers declare them, one per kind of type
# argument (each enum its own Nim type, IAsyncOperation[DataPackageOperation]),
# and two only their definitions imply: IVectorView<Guid> requires
# IIterable<Guid>, and IAsyncOperation<StorageFile> takes its completion
# handler
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
  ("IAsyncOperation_CastingPlaybackTypes", "dff10e53-4c5e-5dba-9269-cd61881bb8b3"),
  ("IIterable_IKeyValuePair_HSTRING_HSTRING", "e9bdaaf0-cbf6-5c72-be90-29cbf3a1319b"),
  ("IIterable_GUID", "f4ca3045-5dd7-54be-982e-d88d8ca0876e"),
  ("AsyncOperationCompletedHandler_StorageFile", "e521c894-2c26-5946-9e61-2b5e188d01ed"),
]:
  doAssert &"  IID_{name}*: GUID = guid\"{iid}\"\n" in code["winrtgenerics"]

echo "test_winrt: all assertions passed"
