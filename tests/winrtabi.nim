# winrtabi.nim — calls the Windows Runtime through the generated WinRT
# modules: a wrong slot, IID or parameter shape compiles, then calls the
# wrong method (run by `nimble winrtcheck`).
#
# What a call hands out is the caller's to free, as the ABI has it: an HSTRING
# to delete (`take` reads and deletes one), an interface pointer to release
# (`release`), and an array to hand back to CoTaskMemFree.

import foundation, foundation_collections, globalization, winrtgenerics

{.push stdcall, dynlib: "combase.dll", importc.}
proc RoInitialize(initType: int32): HRESULT
proc RoActivateInstance(cls: HSTRING, instance: ptr ptr IInspectable): HRESULT
proc RoGetActivationFactory(cls: HSTRING, iid: ptr GUID, factory: ptr pointer): HRESULT
proc WindowsCreateString(s: WideCString, length: uint32, str: ptr HSTRING): HRESULT
proc WindowsDeleteString(str: HSTRING): HRESULT
proc WindowsGetStringRawBuffer(str: HSTRING, length: ptr uint32): WideCString
{.pop.}

proc CoTaskMemFree(pv: pointer) {.stdcall, dynlib: "ole32.dll", importc.}

proc check(hr: HRESULT) =
  doAssert hr >= 0, "HRESULT 0x" & $cast[uint32](hr)

proc toHstring(s: string): HSTRING =
  let wide = newWideCString(s)
  check WindowsCreateString(wide, uint32(wide.len), addr result)

proc `$`(s: HSTRING): string =
  $WindowsGetStringRawBuffer(s, nil)

proc take(s: HSTRING): string =
  ## The text of `s`, and `s` deleted (WindowsDeleteString always succeeds, so
  ## this is safe where an error must not be raised).
  result = $s
  discard WindowsDeleteString(s)

proc toPointer[T](p: ptr T): pointer =
  p

proc release(objs: varargs[pointer, toPointer]) =
  ## Drop the reference each of `objs` holds.
  for obj in objs:
    let unknown = cast[ptr IUnknown](obj)
    discard unknown.lpVtbl.Release(unknown)

proc activationFactory[T](cls: string, id: GUID): ptr T =
  ## The activation factory of runtime class `cls`, as interface `T`. An IID
  ## is a constant named after its interface (`IID_IStringable`), as in the
  ## SDK headers: the caller pairs it with the type it asks for.
  let name = toHstring(cls)
  check RoGetActivationFactory(name, unsafeAddr id, cast[ptr pointer](addr result))
  discard WindowsDeleteString(name)

proc activate(cls: string): ptr IInspectable =
  ## A new instance of runtime class `cls`, made by its default constructor.
  let name = toHstring(cls)
  check RoActivateInstance(name, addr result)
  discard WindowsDeleteString(name)

proc queryInterface[T](obj: pointer, id: GUID): ptr T =
  ## `obj` as interface `T`, through QueryInterface with `id`.
  let unknown = cast[ptr IUnknown](obj)
  check unknown.lpVtbl.QueryInterface(
    unknown, unsafeAddr id, cast[ptr pointer](addr result)
  )

# the vtables have the C layout: IInspectable's six slots (a delegate's,
# IUnknown's three), then the interface's own, one pointer each
doAssert sizeof(IInspectableVtbl) == 6 * sizeof(pointer)
doAssert offsetOf(IUriRuntimeClassVtbl, get_AbsoluteUri) == 6 * sizeof(pointer)
doAssert offsetOf(IUriRuntimeClassFactoryVtbl, CreateWithRelativeUri) ==
  7 * sizeof(pointer)
doAssert offsetOf(AsyncActionCompletedHandlerVtbl, Invoke) == 3 * sizeof(pointer)

check RoInitialize(1) # RO_INIT_MULTITHREADED

# a class through its factory; HSTRING in and out
let uriFactory = activationFactory[IUriRuntimeClassFactory](
  RuntimeClass_Windows_Foundation_Uri, IID_IUriRuntimeClassFactory
)
var uri: ptr Uri
let url = "https://nim-lang.org/docs/?a=1&b=two"
let urlString = toHstring(url)
check uriFactory.lpVtbl.CreateUri(uriFactory, urlString, addr uri)
discard WindowsDeleteString(urlString)
var s: HSTRING
check uri.lpVtbl.get_Host(uri, addr s)
doAssert take(s) == "nim-lang.org"
check uri.lpVtbl.GetRuntimeClassName(uri, addr s)
doAssert take(s) == RuntimeClass_Windows_Foundation_Uri
var trust: TrustLevel # a distinct integer, as an enum of the metadata
check uri.lpVtbl.GetTrustLevel(uri, addr trust)
doAssert trust in [TrustLevel_BaseTrust, TrustLevel_PartialTrust, TrustLevel_FullTrust]
var decoder: ptr WwwFormUrlDecoder
check uri.lpVtbl.get_QueryParsed(uri, addr decoder)
let b = toHstring("b")
check decoder.lpVtbl.GetFirstValueByName(decoder, b, addr s)
discard WindowsDeleteString(b)
doAssert take(s) == "two"
let stringable = queryInterface[IStringable](uri, IID_IStringable)
check stringable.lpVtbl.ToString(stringable, addr s)
doAssert take(s) == url
release(stringable, decoder, uri, uriFactory)

# structs of 8 and 16 bytes by value, an enum, pass and receive arrays
let values = activationFactory[IPropertyValueStatics](
  RuntimeClass_Windows_Foundation_PropertyValue, IID_IPropertyValueStatics
)
var boxed: ptr IInspectable
check values.lpVtbl.CreatePoint(values, Point(X: 1.5, Y: -2.0), addr boxed)
var value = queryInterface[IPropertyValue](boxed, IID_IPropertyValue)
var kind: PropertyType
check value.lpVtbl.get_Type(value, addr kind)
doAssert kind == PropertyType_Point
var point: Point
check value.lpVtbl.GetPoint(value, addr point)
doAssert point == Point(X: 1.5, Y: -2.0)
release(value, boxed)

# a Char16 is a WCHAR
check values.lpVtbl.CreateChar16(values, WCHAR('x'), addr boxed)
value = queryInterface[IPropertyValue](boxed, IID_IPropertyValue)
var character: WCHAR
check value.lpVtbl.GetChar16(value, addr character)
doAssert character == WCHAR('x')
release(value, boxed)

let rect = Rect(X: 1, Y: 2, Width: 30, Height: 40)
check values.lpVtbl.CreateRect(values, rect, addr boxed)
value = queryInterface[IPropertyValue](boxed, IID_IPropertyValue)
var rectBack: Rect
check value.lpVtbl.GetRect(value, addr rectBack)
doAssert rectBack == rect
release(value, boxed)

var ints = [3'i32, 1, 4, 1, 5]
check values.lpVtbl.CreateInt32Array(values, uint32(ints.len), addr ints[0], addr boxed)
value = queryInterface[IPropertyValue](boxed, IID_IPropertyValue)
var count: uint32
var intsBack: ptr int32 # allocated by the callee
check value.lpVtbl.GetInt32Array(value, addr count, addr intsBack)
doAssert count == 5 and cast[ptr array[5, int32]](intsBack)[] == ints
CoTaskMemFree(intsBack)
release(value, boxed)

# a parameterised interface, reached without the IID of its instantiation:
# Calendar.Languages is an IVectorView<String>; a runtime class has no IID
# and answers for its default interface's
var obj = activate(RuntimeClass_Windows_Globalization_Calendar)
let calendar = queryInterface[Calendar](obj, IID_ICalendar)
var languages: ptr IVectorView[HSTRING]
check calendar.lpVtbl.get_Languages(calendar, addr languages)
var resolved: HSTRING
check calendar.lpVtbl.get_ResolvedLanguage(calendar, addr resolved)
var languageCount, index: uint32
var found: bool
check languages.lpVtbl.get_Size(languages, addr languageCount)
check languages.lpVtbl.IndexOf(languages, resolved, addr index, addr found)
doAssert found and index < languageCount
check languages.lpVtbl.GetAt(languages, index, addr s)
doAssert take(s) == take(resolved)
release(languages, calendar, obj)

# a delegate implemented here, and instantiations reached by their IIDs:
# PropertySet raises MapChanged from Insert, on this thread
const IID_IAgileObject = guid"94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90"
# guid"" fills the fields as the SDK headers' DEFINE_GUID does
static:
  doAssert IID_IAgileObject ==
    GUID(
      Data1: 0x94ea2b94'u32,
      Data2: 0xe9cc'u16,
      Data3: 0x49e0'u16,
      Data4: [0xc0'u8, 0xff, 0xee, 0x64, 0xca, 0x8f, 0x5b, 0x90],
    )
var handlerVtbl: MapChangedEventHandlerVtbl[HSTRING, ptr IInspectable]
var handler =
  MapChangedEventHandler[HSTRING, ptr IInspectable](lpVtbl: addr handlerVtbl)
var handlerRefs: uint32
var changes: seq[(string, CollectionChange)]
handlerVtbl.QueryInterface = proc(
    this: pointer, riid: ptr GUID, ppvObject: ptr pointer
): HRESULT {.stdcall.} =
  let answers =
    [IID_IUnknown, IID_IAgileObject, IID_MapChangedEventHandler_HSTRING_IInspectable]
  if riid[] notin answers:
    ppvObject[] = nil
    return cast[HRESULT](0x80004002'u32) # E_NOINTERFACE
  ppvObject[] = this
  inc handlerRefs
handlerVtbl.AddRef = proc(this: pointer): uint32 {.stdcall.} =
  inc handlerRefs
  handlerRefs
handlerVtbl.Release = proc(this: pointer): uint32 {.stdcall.} =
  dec handlerRefs
  handlerRefs
handlerVtbl.Invoke = proc(
    this: ptr MapChangedEventHandler[HSTRING, ptr IInspectable],
    sender: ptr IObservableMap[HSTRING, ptr IInspectable],
    event: ptr IMapChangedEventArgs[HSTRING],
): HRESULT {.stdcall.} =
  # an error must not unwind into the caller: record what arrived, checked
  # below
  var key: HSTRING
  var change: CollectionChange
  if event.lpVtbl.get_Key(event, addr key) >= 0:
    let name = take(key)
    if event.lpVtbl.get_CollectionChange(event, addr change) >= 0:
      changes.add (name, change)

obj = activate(RuntimeClass_Windows_Foundation_Collections_PropertySet)
let observable = queryInterface[IObservableMap[HSTRING, ptr IInspectable]](
  obj, IID_IObservableMap_HSTRING_IInspectable
)
let map =
  queryInterface[IMap[HSTRING, ptr IInspectable]](obj, IID_IMap_HSTRING_IInspectable)
var token: EventRegistrationToken
check observable.lpVtbl.add_MapChanged(observable, addr handler, addr token)
check values.lpVtbl.CreateInt32(values, 42, addr boxed)
let answer = toHstring("answer")
var replaced: bool
check map.lpVtbl.Insert(map, answer, boxed, addr replaced)
doAssert not replaced and changes == @[("answer", CollectionChange_ItemInserted)]
check observable.lpVtbl.remove_MapChanged(observable, token)
check map.lpVtbl.Insert(map, answer, boxed, addr replaced)
doAssert replaced and changes.len == 1 and handlerRefs == 0
discard WindowsDeleteString(answer)
release(boxed, map, observable, obj, values)

echo "winrtabi: all calls passed"
