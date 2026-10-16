# plan.nim — what the WinRT generator settles before writing: each type's
# names, declaration and module.

import std/[algorithm, options, sequtils, sets, strformat, strutils, tables]
import ../[guid, model, signatures, nameplan]

type
  EnumMember* = tuple[name, value: string]
    ## An enum member's const: `AsyncStatus_Started`, `0'i32`.

  TypeNames* = object ## The names a type is emitted under; unique, never keywords.
    name*: string
    vtableName*, iidName*: string # interfaces and delegates
    classNameConst*: string # runtime classes: `RuntimeClass_...`
    enumMembers*: seq[EnumMember] # enums
    isObject*: bool # crosses the ABI as a pointer

  Naming* = object ## The names of every type, and how to resolve a reference.
    names*: seq[TypeNames] # one per entry of m.types
    byName*: Table[string, int] # "ns.name" -> m.types index
    usedNames*: HashSet[string] # every top-level name given out

  AbiTypeKind* = enum
    akVoid ## what a `pointer` points to
    akNamed ## `int32`, `HSTRING`, `Uri`, `T`
    akPointer
    akInstantiation ## `IVector[HSTRING]`
    akArray ## fixed length, inline in a struct

  AbiType* = ref object ## A type on the ABI, references resolved to names.
    case kind*: AbiTypeKind
    of akVoid:
      discard
    of akNamed:
      name*: string
    of akPointer:
      target*: AbiType
    of akInstantiation:
      definition*: string # `IVector`
      args*: seq[AbiType]
    of akArray:
      element*: AbiType
      count*: int

  Parameter* = tuple[name: string, ty: AbiType] ## A parameter of a vtable slot.

  VtableSlot* = object ## A method as its vtable holds it.
    name*: string
    parameters*: Option[seq[Parameter]] # none when one cannot be spelled

  DeclarationKind* = enum
    dkEnum
    dkStruct
    dkInterface
    dkDelegate
    dkClass ## a runtime class; a static one has no default interface

  Declaration* = ref object ## A type as the output declares it.
    name*: string
    case kind*: DeclarationKind
    of dkEnum:
      underlying*: AbiType # `int32`, or `uint32` for [Flags]
      isFlags*: bool
      members*: seq[EnumMember]
    of dkStruct:
      fields*: seq[tuple[name: string, ty: AbiType]]
    of dkInterface, dkDelegate:
      genericParameters*: seq[string]
      vtableName*, iidName*: string
      guid*: Guid # its IID, or a parameterised one's PIID
      slots*: seq[VtableSlot] # after IInspectable's
    of dkClass:
      className*: string # `Windows.Foundation.Uri`
      classNameConst*: string
      defaultInterface*: Option[AbiType] # none for a static class

  ModuleKind* = enum
    mkTypes ## winrttypes: every type
    mkNamespace ## a namespace: its vtables, IIDs and class names

  Module* = object ## A module to write (but winrtbase and winrtgenerics).
    kind*: ModuleKind
    name*: string
    namespaces*: seq[string]
    imports*: seq[string] # imported and re-exported
    declarations*: seq[Declaration]

  Plan* = object ## What the output is rendered from.
    modules*: seq[Module]
    instantiationIids*: seq[tuple[name: string, iid: Guid]]
    base*: string
      ## where winrtbase is: "" for one of this output's own, or the path of a
      ## reference's modules, whose winrtbase every binding over it shares
    qualified*: seq[tuple[alias, path: string]]
      ## the references, each imported qualified: `from winrt/abi/winrttypes as
      ## winrt import nil`, its types spelled `winrt.Point`

  Reference* = object
    ## A binding written before this one, whose types this one names rather
    ## than declares: the Windows SDK's, beneath the Windows App SDK's.
    alias*: string # what it is imported as: `winrt`
    path*: string # where its modules are: `winrt/abi`
    model*: Model # the metadata it was written from

const remapped* = {
  "System.Guid": (name: "GUID", isObject: false, signature: "g16"),
  "System.Object":
    (name: "IInspectable", isObject: true, signature: "cinterface(IInspectable)"),
  "Windows.Foundation.HResult": (
    name: "HRESULT", isObject: false, signature: "struct(Windows.Foundation.HResult;i4)"
  ),
}.toTable ## Types spelled with winrtbase's, as in windows-rs, and their signatures.

func fullName*(t: ModelType | SigType): string =
  ## `Windows.Foundation.IStringable`
  fmt"{t.ns}.{t.name}"

func stripArity*(name: string): string =
  ## ``IVector`1`` -> `IVector`
  name.split('`')[0]

func moduleName*(ns: string): string =
  ## Windows.Foundation.Collections -> foundation_collections
  var name = ns
  name.removePrefix("Windows.")
  name.toLowerAscii.replace('.', '_')

func indexOf*(n: Naming, t: SigType): Option[int] =
  ## The m.types index of what `t` refers to; none for another winmd's type.
  let name = fullName(t)
  if name in n.byName:
    some(n.byName[name])
  else:
    none(int)

func enumMembers(t: ModelType, name: string): seq[EnumMember] =
  ## The members of enum `t`, emitted as `name`; names not yet unique.
  let unsigned = t.underlying.prim == pvU4
  for f in t.fields:
    let bits = uint32(f.constant and 0xFFFF_FFFF'u64)
    let signed = cast[int32](bits)
    let value =
      if unsigned:
        fmt"{bits}'u32"
      else:
        fmt"{signed}'i32"
    result.add (fixIdent(fmt"{name}_{f.name}"), value)

# ---------------------------------------------------------------------------
# which module declares what
# ---------------------------------------------------------------------------

func placeModules*(n: Naming, m: Model, declarations: seq[Declaration]): seq[Module] =
  ## winrttypes, which declares every type, then a module per namespace with
  ## its interfaces' vtables and IIDs and its classes' names; `declarations`
  ## has one entry per m.types.
  ##
  ## An interface is declared in winrttypes, beside every enum and struct, as
  ## the object a pointer to it points at. A vtable then names only types from
  ## winrttypes, so no namespace module imports another, and a namespace that
  ## refers to another in a cycle — Windows.Storage and Windows.System do —
  ## costs nothing.
  var types = Module(kind: mkTypes, name: "winrttypes", imports: @["winrtbase"])
  var spaces: Table[string, Module]
  for i, t in m.types:
    types.declarations.add declarations[i]
    if t.kind in {tkInterface, tkDelegate}:
      spaces.mgetOrPut(
        t.ns,
        Module(
          kind: mkNamespace,
          name: moduleName(t.ns),
          namespaces: @[t.ns],
          imports: @["winrtbase", "winrttypes"],
        ),
      ).declarations.add declarations[i]
  result.add types
  for ns in sorted(toSeq(spaces.keys)):
    result.add spaces[ns]

# ---------------------------------------------------------------------------
# what each type is called
# ---------------------------------------------------------------------------

func references*(m: Model): Naming =
  ## Enough of a Naming to resolve references, without the names.
  result.names =
    m.types.mapIt(TypeNames(isObject: it.kind in {tkInterface, tkDelegate}))
  for i, t in m.types:
    result.byName[fullName(t)] = i

func buildNaming*(m: Model): Naming =
  ## The names of every type of `m`.
  var taken = NimKeywords.toHashSet
  # winrtbase's names, and system's that would make a reference ambiguous
  taken.incl [
    "GUID", "HRESULT", "HSTRING", "HSTRING_PRIVATE", "WCHAR", "IUnknown",
    "IUnknownVtbl", "IInspectable", "IInspectableVtbl", "IID_IUnknown",
    "IID_IInspectable", "guid", "TrustLevel", "TrustLevel_BaseTrust",
    "TrustLevel_PartialTrust", "TrustLevel_FullTrust", "File", "Fileinfo",
  ].map(nimIdentNormalize).toHashSet
  var n = references(m)
  # duplicates are suffixed after every metadata name is given out: Nim reads
  # `IFoo_2` as `IFoo2`, which may be a type of its own
  let wanted = m.types.mapIt(fixIdent(stripArity(it.name)))
  var later: seq[int]
  for i, t in m.types:
    if nimIdentNormalize(wanted[i]) in taken:
      later.add i
    else:
      n.names[i].name = taken.freshIdent(wanted[i])
  for i in later:
    n.names[i].name = taken.freshIdent(wanted[i])
  # derived names come last, so they give way on a clash
  for i, t in m.types:
    if t.isClass:
      let constName = "RuntimeClass_" & fullName(t).replace('.', '_')
      n.names[i].classNameConst = taken.freshIdent(constName)
    elif t.kind in {tkInterface, tkDelegate}:
      n.names[i].vtableName = taken.freshIdent(n.names[i].name & "Vtbl")
      n.names[i].iidName = taken.freshIdent("IID_" & n.names[i].name)
  for i, t in m.types:
    if t.kind in {tkEnum, tkUnscopedEnum}:
      var members = enumMembers(t, n.names[i].name)
      for member in members.mitems:
        member.name = taken.freshIdent(member.name)
      n.names[i].enumMembers = members
  n.usedNames = taken
  n
