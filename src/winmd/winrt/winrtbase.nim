## What every generated WinRT module builds on and no winmd declares: GUID,
## HRESULT, HSTRING, WCHAR, IUnknown and IInspectable with their vtables and
## IIDs, and `guid`, which turns an IID's text into a GUID at compile time.
## winrtgen writes this module out as it is.

import std/strutils

{.pragma: mdtype, pure, bycopy, completeStruct.}
{.pragma: mdvtbl, pure, inheritable.}
{.pragma: mdalias.}
{.pragma: mdinterface.}

type
  GUID* {.mdtype.} = object
    Data1*: uint32
    Data2*: uint16
    Data3*: uint16
    Data4*: array[8, uint8]

  HRESULT* {.mdalias.} = int32

  HSTRING_PRIVATE* {.mdtype.} = object
  HSTRING* {.mdalias.} = ptr HSTRING_PRIVATE

  WCHAR* {.mdalias.} = uint16 ## a Char16, as the SDK headers spell it

  TrustLevel* = distinct int32
    ## what GetTrustLevel answers; a distinct integer, as every WinRT enum, so
    ## it holds any value an object returns

  IUnknownVtbl* {.mdvtbl.} = object
    QueryInterface*:
      proc(this: pointer, riid: ptr GUID, ppvObject: ptr pointer): HRESULT {.stdcall.}
    AddRef*: proc(this: pointer): uint32 {.stdcall.}
    Release*: proc(this: pointer): uint32 {.stdcall.}

  IUnknown* {.mdinterface.} = object
    lpVtbl*: ptr IUnknownVtbl

  IInspectableVtbl* {.mdvtbl.} = object of IUnknownVtbl
    GetIids*:
      proc(this: pointer, iidCount: ptr uint32, iids: ptr ptr GUID): HRESULT {.stdcall.}
    GetRuntimeClassName*:
      proc(this: pointer, className: ptr HSTRING): HRESULT {.stdcall.}
    GetTrustLevel*: proc(this: pointer, trustLevel: ptr TrustLevel): HRESULT {.stdcall.}

  IInspectable* {.mdinterface.} = object
    lpVtbl*: ptr IInspectableVtbl

func guid*(s: string): GUID =
  ## The GUID `s` spells, `guid"96369f54-8eb6-48f0-abce-c1b211e627c3"`; in a
  ## const, at compile time.
  let h = s.replace("-", "")
  doAssert h.len == 32, "not a GUID: " & s
  result.Data1 = fromHex[uint32](h[0 .. 7])
  result.Data2 = fromHex[uint16](h[8 .. 11])
  result.Data3 = fromHex[uint16](h[12 .. 15])
  for i in 0 .. 7:
    result.Data4[i] = fromHex[uint8](h[16 + 2 * i .. 17 + 2 * i])

func `==`*(a, b: TrustLevel): bool {.borrow.}
func `$`*(a: TrustLevel): string {.borrow.}

const
  TrustLevel_BaseTrust*: TrustLevel = TrustLevel(0'i32)
  TrustLevel_PartialTrust*: TrustLevel = TrustLevel(1'i32)
  TrustLevel_FullTrust*: TrustLevel = TrustLevel(2'i32)
  IID_IUnknown*: GUID = guid"00000000-0000-0000-c000-000000000046"
  IID_IInspectable*: GUID = guid"af86e2e0-b12d-4c6a-9c5a-d7aa65101e90"
