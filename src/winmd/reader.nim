## winmd.nim — reader for ECMA-335 `.winmd` metadata files.
##
## Parses PE header -> metadata root -> streams (#Strings, #Blob, #~) -> #~
## table stream, and exposes typed row accessors and helpers

import std/[files, paths, syncio, strformat, sequtils, options, strutils]
export options

type
  ## ECMA-335 table ids (sparse; gaps are reserved).
  TableId* = enum
    Module = 0x00
    TypeRef = 0x01
    TypeDef = 0x02
    Field = 0x04
    MethodDef = 0x06
    MethodParam = 0x08
    InterfaceImpl = 0x09
    MemberRef = 0x0A
    Constant = 0x0B
    CustomAttribute = 0x0C
    FieldMarshal = 0x0D
    DeclSecurity = 0x0E
    ClassLayout = 0x0F
    FieldLayout = 0x10
    StandAloneSig = 0x11
    EventMap = 0x12
    Event = 0x14
    PropertyMap = 0x15
    Property = 0x17
    MethodSemantics = 0x18
    MethodImpl = 0x19
    ModuleRef = 0x1A
    TypeSpec = 0x1B
    ImplMap = 0x1C
    FieldRVA = 0x1D
    Assembly = 0x20
    AssemblyProcessor = 0x21
    AssemblyOS = 0x22
    AssemblyRef = 0x23
    AssemblyRefProc = 0x24
    AssemblyRefOS = 0x25
    File = 0x26
    ExportedType = 0x27
    ManifestResource = 0x28
    NestedClass = 0x29
    GenericParam = 0x2A
    MethodSpec = 0x2B
    GenericParamConstraint = 0x2C

  ## A coded-index column: `kind` = the target table, `row` = 0-based row.
  CodedRef* = object
    kind*: TableId
    row*: int

  ## Kinds of coded-index columns used by the modeled tables.
  CodedKind* = enum
    ckResolutionScope
    ckTypeDefOrRef
    ckMemberRefParent
    ckHasConstant
    ckHasCustomAttribute
    ckAttributeType
    ckMemberForwarded
    ckTypeOrMethodDef
    ckHasSemantics
    ckHasFieldMarshal
    ckMethodDefOrRef
    ckImplementation

  Winmd* = ref object
    data*: seq[byte]
    stringsOff, stringsLen: int
    blobsOff, blobsLen: int
    heapSizes: uint8
    strIdxBytes, blobIdxBytes, guidIdxBytes: int
    valid: uint64
    counts*: array[0 .. 0x2C, int]
    rowOff*: array[0 .. 0x2C, int]
    rowSize*: array[0 .. 0x2C, int]

  # ---- row types -----------------------------------------------------------
  # https://github.com/stakx/ecma-335/blob/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/TABLE_OF_CONTENTS.md?plain=1#L338
  ModuleRow* = object
    generation*: uint16
    name*: string
    mvid*: uint32
    encid*: uint32
    encbaseid*: uint32

  TypeRefRow* = object
    resolutionScope*: CodedRef
    name*, namespace*: string

  TypeDefRow* = object
    flags*: uint32
    name*, namespace*: string
    extends*: CodedRef # isNull for interfaces (value 0)
    fieldsStart*, methodsStart*: int

  FieldRow* = object
    flags*: uint16
    name*: string
    signature*: seq[byte] # blob, compressed-length prefix stripped

  MethodDefRow* = object
    rva*: uint32
    implFlags*: uint16
    flags*: uint16
    name*: string
    signature*: seq[byte]
    paramsStart*: int

  MethodParamRow* = object
    flags*: uint16
    sequence*: uint16
    name*: string # empty unless the param has an explicit name

  InterfaceImplRow* = object
    typedef*: int
    interfaceType*: CodedRef

  MemberRefRow* = object
    parent*: CodedRef
    name*: string
    signature*: seq[byte]

  ConstantRow* = object
    typeTag*: uint8 # ELEMENT_TYPE_* (column stored as 2 bytes)
    parent*: CodedRef # HasConstant: Field=0, MethodParam=1, Property=2
    value*: seq[byte]

  CustomAttributeRow* = object
    parent*: CodedRef # HasCustomAttribute
    ctor*: CodedRef # AttributeType: MethodDef=2, MemberRef=3
    value*: seq[byte] # serialized attribute blob

  ClassLayoutRow* = object
    packing*: uint16
    classSize*: uint32
    typedef*: int

  EventMapRow* = object
    parent*: int # TypeDef
    eventListStart*: int

  EventRow* = object
    ## https://github.com/stakx/ecma-335/blame/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/ii.22.13-event-0x14.md#L1
    eventFlags*: uint16 # TypeDef
    name*: string
    eventType*: CodedRef # TypeDefOrRef

  PropertyMapRow* = object
    parent*: int # TypeDef
    propertyListStart*: int

  PropertyRow* = object
    ## https://github.com/stakx/ecma-335/blame/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/ii.22.34-property-0x17.md#L1
    propertyFlags*: uint16 # TypeDef
    name*: string
    `type`*: seq[byte] # type blob

  MethodSemanticsRow* = object
    semantics*: uint16
    `method`*: int # index into MethodDef
    association*: CodedRef # HasSemantics: Event=0, Property=1

  ModuleRefRow* = object
    name*: string

  TypeSpecRow* = object
    signature*: seq[byte]

  ImplMapRow* = object
    flags*: uint16 # PInvokeAttributes: 0x100 = stdcall, 0x200 = cdecl
    memberForwarded*: CodedRef
    importName*: string
    moduleRef*: int

  AssemblyRow* = object
    major*, minor*, build*, revision*: uint16
    flags*: uint32
    name*, culture*: string
    publicKey*: seq[byte]

  AssemblyRefRow* = object
    major*, minor*, build*, revision*: uint16
    flags*: uint32
    publicKeyToken*: seq[byte]
    name*, culture*: string
    publicKey*: seq[byte]

  NestedClassRow* = object
    innerType*: int # inner type
    enclosingType*: int # outer type

  GenericParamRow* = object
    number*: uint16
    flags*: uint16
    owner*: CodedRef # TypeOrMethodDef: TypeDef=0, MethodDef=1
    name*: string

  MethodImplRow* = object
    ## https://github.com/stakx/ecma-335/blob/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/ii.22.27-methodimpl-0x19.md
    class*: int # TypeDef
    methodBody*: CodedRef # MethodDefOrRef: MethodDef=0, MemberRef=1
    methodDeclaration*: CodedRef # MethodDefOrRef

  ## One argument of a serialized custom attribute. Positional args have
  ## `name == ""` and `namedType == 0`.
  AttributeArg* = object
    name*: string
    namedType*: uint8 # ELEMENT_TYPE_* code, 0 for positional
    value*: seq[byte]

  WinmdError* = object of ValueError

# https://github.com/stakx/ecma-335/blob/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/ii.23.1.16-element-types-used-in-signatures.md?plain=1#L1
const
  ELEMENT_TYPE_END* = 0x00
  ELEMENT_TYPE_VOID* = 0x01
  ELEMENT_TYPE_BOOLEAN* = 0x02
  ELEMENT_TYPE_CHAR* = 0x03
  ELEMENT_TYPE_I1* = 0x04
  ELEMENT_TYPE_U1* = 0x05
  ELEMENT_TYPE_I2* = 0x06
  ELEMENT_TYPE_U2* = 0x07
  ELEMENT_TYPE_I4* = 0x08
  ELEMENT_TYPE_U4* = 0x09
  ELEMENT_TYPE_I8* = 0x0a
  ELEMENT_TYPE_U8* = 0x0b
  ELEMENT_TYPE_R4* = 0x0c
  ELEMENT_TYPE_R8* = 0x0d
  ELEMENT_TYPE_STRING* = 0x0e
  ELEMENT_TYPE_PTR* = 0x0f
  ELEMENT_TYPE_BYREF* = 0x10
  ELEMENT_TYPE_VALUETYPE* = 0x11
  ELEMENT_TYPE_CLASS* = 0x12
  ELEMENT_TYPE_VAR* = 0x13
  ELEMENT_TYPE_ARRAY* = 0x14
  ELEMENT_TYPE_GENERICINST* = 0x15
  ELEMENT_TYPE_TYPEDBYREF* = 0x16
  ELEMENT_TYPE_I* = 0x18
  ELEMENT_TYPE_U* = 0x19
  ELEMENT_TYPE_FNPTR* = 0x1b
  ELEMENT_TYPE_OBJECT* = 0x1c
  ELEMENT_TYPE_SZARRAY* = 0x1d
  ELEMENT_TYPE_MVAR* = 0x1e
  ELEMENT_TYPE_CMOD_REQD* = 0x1f
  ELEMENT_TYPE_CMOD_OPT* = 0x20
  ELEMENT_TYPE_INTERNAL* = 0x21
  ELEMENT_TYPE_MODIFIER* = 0x40
  ELEMENT_TYPE_SENTINEL* = 0x41
  ELEMENT_TYPE_PINNED* = 0x45
  ELEMENT_TYPE_TYPE* = 0x50
  ELEMENT_TYPE_CUSTOM_BOXED* = 0x51
  ELEMENT_TYPE_CUSTOM_FIELD* = 0x53
  ELEMENT_TYPE_CUSTOM_sPROPERTY* = 0x54
  ELEMENT_TYPE_CUSTOM_ENUM* = 0x55

proc raiseWinmdError*(msg: string) {.noreturn.} =
  raise newException(WinmdError, msg)

proc typedRef*(t: TableId, row: int): CodedRef =
  CodedRef(kind: t, row: row)

const nullCoded* = CodedRef(kind: TableId.Module, row: -1)
  ## The "empty" coded value (stored as 0).

proc `[]`*[T](o: Option[T]): T =
  o.get()

# ---------------------------------------------------------------------------
# coded-index conventions for this file format (mirrors the windows-rs
# metadata reader): tag = LOW `bits` bits, row index = (value >> bits) - 1.
# ---------------------------------------------------------------------------

proc codedBits(k: CodedKind): int =
  case k
  of ckResolutionScope: 2
  of ckTypeDefOrRef: 2
  of ckMemberRefParent: 3
  of ckHasConstant: 2
  of ckHasCustomAttribute: 5
  of ckAttributeType: 3
  of ckMemberForwarded: 1
  of ckTypeOrMethodDef: 1
  of ckHasSemantics: 1
  of ckHasFieldMarshal: 2
  of ckMethodDefOrRef: 1
  of ckImplementation: 2

proc codedTables(k: CodedKind): set[TableId] =
  ## Tables in the coded set (their row counts decide the storage width).
  case k
  of ckResolutionScope:
    {Module, ModuleRef, AssemblyRef, TypeRef}
  of ckTypeDefOrRef:
    {TypeDef, TypeRef, TypeSpec}
  of ckMemberRefParent:
    {TypeDef, TypeRef, ModuleRef, MethodDef, TypeSpec}
  of ckHasConstant:
    {Field, MethodParam, Property}
  of ckHasCustomAttribute:
    {
      MethodDef, Field, TypeRef, TypeDef, MethodParam, InterfaceImpl, MemberRef,
      Property, Event, ModuleRef, TypeSpec, Assembly, AssemblyRef, File, ExportedType,
      ManifestResource, GenericParam, GenericParamConstraint, MethodSpec,
    }
  of ckAttributeType:
    {MethodDef, MemberRef}
  of ckMemberForwarded:
    {Field, MethodDef}
  of ckTypeOrMethodDef:
    {TypeDef, MethodDef}
  of ckHasSemantics:
    {Event, Property}
  of ckHasFieldMarshal:
    {Field}
  of ckMethodDefOrRef:
    {MethodDef, MemberRef}
  of ckImplementation:
    {File, AssemblyRef, ExportedType}

proc codedWidth(wa: Winmd, k: CodedKind): int =
  ## 2 if every table in the set has < 2^(16-bits) rows, else 4.
  let threshold = 1 shl (16 - codedBits(k))
  for t in codedTables(k):
    if wa.counts[int(t)] >= threshold:
      return 4
  2

proc codedTag(k: CodedKind, tag: int): TableId =
  case k
  of ckResolutionScope:
    @[Module, ModuleRef, AssemblyRef, TypeRef][tag]
  of ckTypeDefOrRef:
    @[TypeDef, TypeRef, TypeSpec][tag]
  of ckMemberRefParent:
    @[TypeDef, TypeRef, ModuleRef, MethodDef, TypeSpec][tag]
  of ckHasConstant:
    @[Field, MethodParam, Property][tag]
  of ckHasCustomAttribute:
    case tag
    of 0:
      MethodDef
    of 1:
      Field
    of 2:
      TypeRef
    of 3:
      TypeDef
    of 4:
      MethodParam
    of 5:
      InterfaceImpl
    of 6:
      MemberRef
    of 7:
      Property
    of 8:
      Event
    of 13:
      TypeSpec
    of 19:
      GenericParam
    else:
      raiseWinmdError("unknown HasCustomAttribute tag: " & $tag)
  of ckAttributeType:
    case tag
    of 2:
      MethodDef
    of 3:
      MemberRef
    else:
      raiseWinmdError("unknown AttributeType tag: " & $tag)
  of ckMemberForwarded:
    @[Field, MethodDef][tag]
  of ckTypeOrMethodDef:
    @[TypeDef, MethodDef][tag]
  of ckHasSemantics:
    @[Event, Property][tag]
  of ckHasFieldMarshal:
    @[Field][tag]
  of ckMethodDefOrRef:
    @[MethodDef, MemberRef][tag]
  of ckImplementation:
    @[File, AssemblyRef, ExportedType][tag]

proc codedTagValue(k: CodedKind, t: TableId): int =
  ## Reverse mapping, used to build search targets.
  case k
  of ckHasConstant:
    case t
    of Field:
      0
    of MethodParam:
      1
    of Property:
      2
    else:
      raiseWinmdError("table not in HasConstant set")
  of ckMemberForwarded:
    case t
    of Field:
      0
    of MethodDef:
      1
    else:
      raiseWinmdError("table not in MemberForwarded set")
  of ckHasCustomAttribute:
    case t
    of MethodDef:
      0
    of Field:
      1
    of TypeRef:
      2
    of TypeDef:
      3
    of MethodParam:
      4
    of InterfaceImpl:
      5
    of MemberRef:
      6
    of Property:
      7
    of Event:
      8
    of TypeSpec:
      13
    of GenericParam:
      19
    else:
      raiseWinmdError("table not in HasCustomAttribute set")
  of ckHasSemantics:
    case t
    of Event:
      0
    of Property:
      1
    else:
      raiseWinmdError("table not in HasSemantics set")
  else:
    raiseWinmdError("codedTagValue: unsupported kind")

proc isNull*(c: CodedRef): bool =
  ## True for the empty coded value (row == -1).
  c.row < 0

# ---------------------------------------------------------------------------
# raw byte access
# ---------------------------------------------------------------------------

proc u8(d: openArray[byte], off: int): uint8 =
  if d.len() < off + 1:
    raiseWinmdError(&"u1 out of bounds: {off} - {d.len} = {off - d.len}")
  d[off]

proc u16(d: openArray[byte], off: int): uint16 =
  if d.len() < off + 2:
    raiseWinmdError(&"u2 out of bounds: {off} - {d.len} = {off - d.len}")
  uint16(d[off]) or (uint16(d[off + 1]) shl 8)

proc u32(d: openArray[byte], off: int): uint32 =
  if d.len() < off + 4:
    raiseWinmdError(&"u4 out of bounds: {off} - {d.len} = {off - d.len}")
  uint32(d.u16(off)) or (uint32(d.u16(off + 2)) shl 16)

proc u64(d: openArray[byte], off: int): uint64 =
  if d.len() < off + 8:
    raiseWinmdError(&"u8 out of bounds: {off} - {d.len} = {off - d.len}")
  uint64(d.u32(off)) or (uint64(d.u32(off + 4)) shl 32)

proc ua(d: openArray[byte], off: int, T: type): ptr UncheckedArray[T] =
  if d.len() < off:
    raiseWinmdError(&"ua out of bounds: {off} - {d.len} = {off - d.len}")
  cast[ptr UncheckedArray[T]](addr d[off])

proc h(d: openArray[byte], off: int, T: type): ptr T =
  if d.len() < off + sizeof(T):
    raiseWinmdError(&"h({sizeof(T)}) out of bounds: {off} - {d.len} = {off - d.len}")
  cast[ptr T](addr d[off])

# ---------------------------------------------------------------------------
# open: PE -> metadata root -> streams -> #~ header/row layout
# ---------------------------------------------------------------------------

# ---- PE / CLR header layout -----------------------------------------------
# Copied from (an early version of) the generated winnt bindings - sizeof must match the
# PE on disk

type
  IMAGE_DOS_HEADER = object
    e_magic: uint16
    e_cblp: uint16
    e_cp: uint16
    e_crlc: uint16
    e_cparhdr: uint16
    e_minalloc: uint16
    e_maxalloc: uint16
    e_ss: uint16
    e_sp: uint16
    e_csum: uint16
    e_ip: uint16
    e_cs: uint16
    e_lfarlc: uint16
    e_ovno: uint16
    e_res: array[4, uint16]
    e_oemid: uint16
    e_oeminfo: uint16
    e_res2: array[10, uint16]
    e_lfanew: int32

  IMAGE_FILE_HEADER = object
    Machine: uint16
    NumberOfSections: uint16
    TimeDateStamp: uint32
    PointerToSymbolTable: uint32
    NumberOfSymbols: uint32
    SizeOfOptionalHeader: uint16
    Characteristics: uint16

  IMAGE_OPTIONAL_HEADER32* {.packed.} = object
    Magic*: uint16
    MajorLinkerVersion*: uint8
    MinorLinkerVersion*: uint8
    SizeOfCode*: uint32
    SizeOfInitializedData*: uint32
    SizeOfUninitializedData*: uint32
    AddressOfEntryPoint*: uint32
    BaseOfCode*: uint32
    BaseOfData*: uint32
    ImageBase*: uint32
    SectionAlignment*: uint32
    FileAlignment*: uint32
    MajorOperatingSystemVersion*: uint16
    MinorOperatingSystemVersion*: uint16
    MajorImageVersion*: uint16
    MinorImageVersion*: uint16
    MajorSubsystemVersion*: uint16
    MinorSubsystemVersion*: uint16
    Win32VersionValue*: uint32
    SizeOfImage*: uint32
    SizeOfHeaders*: uint32
    CheckSum*: uint32
    Subsystem*: uint16
    DllCharacteristics*: uint16
    SizeOfStackReserve*: uint32
    SizeOfStackCommit*: uint32
    SizeOfHeapReserve*: uint32
    SizeOfHeapCommit*: uint32
    LoaderFlags*: uint32
    NumberOfRvaAndSizes*: uint32
    DataDirectory*: array[16, IMAGE_DATA_DIRECTORY]

  IMAGE_OPTIONAL_HEADER64* {.packed.} = object
    Magic*: uint16
    MajorLinkerVersion*: uint8
    MinorLinkerVersion*: uint8
    SizeOfCode*: uint32
    SizeOfInitializedData*: uint32
    SizeOfUninitializedData*: uint32
    AddressOfEntryPoint*: uint32
    BaseOfCode*: uint32
    ImageBase*: uint64
    SectionAlignment*: uint32
    FileAlignment*: uint32
    MajorOperatingSystemVersion*: uint16
    MinorOperatingSystemVersion*: uint16
    MajorImageVersion*: uint16
    MinorImageVersion*: uint16
    MajorSubsystemVersion*: uint16
    MinorSubsystemVersion*: uint16
    Win32VersionValue*: uint32
    SizeOfImage*: uint32
    SizeOfHeaders*: uint32
    CheckSum*: uint32
    Subsystem*: uint16
    DllCharacteristics*: uint16
    SizeOfStackReserve*: uint64
    SizeOfStackCommit*: uint64
    SizeOfHeapReserve*: uint64
    SizeOfHeapCommit*: uint64
    LoaderFlags*: uint32
    NumberOfRvaAndSizes*: uint32
    DataDirectory*: array[16, IMAGE_DATA_DIRECTORY]

  IMAGE_DATA_DIRECTORY* = object
    VirtualAddress: uint32
    Size: uint32

  IMAGE_COR20_HEADER_5* {.union.} = object
    EntryPointToken: uint32
    EntryPointRVA: uint32

  IMAGE_COR20_HEADER* = object
    cb: uint32
    MajorRuntimeVersion: uint16
    MinorRuntimeVersion: uint16
    MetaData: IMAGE_DATA_DIRECTORY
    Flags: uint32
    Anonymous: IMAGE_COR20_HEADER_5
    Resources: IMAGE_DATA_DIRECTORY
    StrongNameSignature: IMAGE_DATA_DIRECTORY
    CodeManagerTable: IMAGE_DATA_DIRECTORY
    VTableFixups: IMAGE_DATA_DIRECTORY
    ExportAddressTableJumps: IMAGE_DATA_DIRECTORY
    ManagedNativeHeader: IMAGE_DATA_DIRECTORY

  IMAGE_SECTION_HEADER* = object
    Name*: array[8, uint8]
    Misc*: IMAGE_SECTION_HEADER_1
    VirtualAddress*: uint32
    SizeOfRawData*: uint32
    PointerToRawData*: uint32
    PointerToRelocations*: uint32
    PointerToLinenumbers*: uint32
    NumberOfRelocations*: uint16
    NumberOfLinenumbers*: uint16
    Characteristics*: uint32

  IMAGE_SECTION_HEADER_1* {.union.} = object
    PhysicalAddress*: uint32
    VirtualSize*: uint32

  # https://github.com/stakx/ecma-335/blob/master/docs/ii.24.2.1-metadata-root.md#L1
  METADATA_HEADER* = object
    Signature: uint32
    MajorVersion: uint16
    MinorVersion: uint16
    Reserved: uint32
    Length: uint32

const
  IMAGE_DOS_SIGNATURE = 23117'u16
  IMAGE_NT_SIGNATURE = 17744'u32
  IMAGE_NT_OPTIONAL_HDR32_MAGIC = 267
  IMAGE_NT_OPTIONAL_HDR64_MAGIC = 523
  IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR = 14
  METADATA_HEADER_SIGNATURE = 0x424A5342'u32

type Section = object
  virtualSize, virtualAddress, rawSize, rawPtr: uint32

proc rvaToOffset(
    d: openArray[byte], sections: openArray[IMAGE_SECTION_HEADER], rva: uint32
): int =
  for s in sections:
    if s.VirtualAddress <= rva and
        rva < s.VirtualAddress + max(s.VirtualAddress, s.SizeOfRawData):
      return int(s.PointerToRawData + (rva - s.VirtualAddress))
  raiseWinmdError("rva 0x" & $(rva) & " not in any section")

const
  tableIds: seq[TableId] = @[
    Module, TypeRef, TypeDef, Field, MethodDef, MethodParam, InterfaceImpl, MemberRef,
    Constant, CustomAttribute, FieldMarshal, DeclSecurity, ClassLayout, FieldLayout,
    StandAloneSig, EventMap, Event, PropertyMap, Property, MethodSemantics, MethodImpl,
    ModuleRef, TypeSpec, ImplMap, FieldRVA, Assembly, AssemblyProcessor, AssemblyOS,
    AssemblyRef, AssemblyRefProc, AssemblyRefOS, File, ExportedType, ManifestResource,
    NestedClass, GenericParam, MethodSpec, GenericParamConstraint,
  ] # ^ fixed ECMA order in which table row data is laid out
  modeledTables = {
    Module, TypeRef, TypeDef, Field, MethodDef, MethodParam, InterfaceImpl, MemberRef,
    Constant, CustomAttribute, FieldMarshal, FieldLayout, ClassLayout, EventMap, Event,
    PropertyMap, Property, MethodSemantics, MethodImpl, ModuleRef, TypeSpec, ImplMap,
    Assembly, AssemblyRef, ExportedType, NestedClass, GenericParam,
  }

proc idxBytes(wa: Winmd, t: TableId): int =
  ## Storage width of a (non-coded) index into table `t`.
  if wa.counts[int(t)] < 65536: 2 else: 4

proc rowSize(wa: Winmd, t: TableId): int =
  let (strW, blobW) = (wa.strIdxBytes, wa.blobIdxBytes)
  case t
  of Module:
    2 + strW + 3 * wa.guidIdxBytes
  of TypeRef:
    wa.codedWidth(ckResolutionScope) + strW + strW
  of TypeDef:
    4 + 2 * strW + wa.codedWidth(ckTypeDefOrRef) + wa.idxBytes(Field) +
      wa.idxBytes(MethodDef)
  of Field:
    2 + strW + blobW
  of MethodDef:
    8 + strW + blobW + wa.idxBytes(MethodParam)
  of MethodParam:
    4 + strW
  of InterfaceImpl:
    wa.idxBytes(TypeDef) + wa.codedWidth(ckTypeDefOrRef)
  of MemberRef:
    wa.codedWidth(ckMemberRefParent) + strW + blobW
  of Constant:
    2 + wa.codedWidth(ckHasConstant) + blobW
  of CustomAttribute:
    wa.codedWidth(ckHasCustomAttribute) + wa.codedWidth(ckAttributeType) + blobW
  of ClassLayout:
    6 + wa.idxBytes(TypeDef)
  of EventMap:
    wa.idxBytes(TypeDef) + wa.idxBytes(Event)
  of Event:
    2 + strW + wa.codedWidth(ckTypeDefOrRef)
  of PropertyMap:
    wa.idxBytes(TypeDef) + wa.idxBytes(Property)
  of Property:
    2 + strW + blobW
  of MethodSemantics:
    2 + wa.idxBytes(MethodDef) + wa.codedWidth(ckHasSemantics)
  of ModuleRef:
    strW
  of TypeSpec:
    blobW
  of ImplMap:
    2 + wa.codedWidth(ckMemberForwarded) + strW + wa.idxBytes(ModuleRef)
  of Assembly:
    16 + blobW + 2 * strW
  of AssemblyRef:
    12 + 2 * blobW + 2 * strW
  of NestedClass:
    wa.idxBytes(TypeDef) * 2
  of GenericParam:
    4 + wa.codedWidth(ckTypeOrMethodDef) + strW
  of FieldMarshal:
    wa.codedWidth(ckHasFieldMarshal) + blobW
  of FieldLayout:
    wa.idxBytes(Field) + 4
  of MethodImpl:
    wa.idxBytes(TypeDef) + 2 * wa.codedWidth(ckMethodDefOrRef)
  of ExportedType: # the type forwarders of an SDK contract whose types moved
    8 + 2 * strW + wa.codedWidth(ckImplementation)
  else:
    0

## Open a .winmd file and parse its PE + metadata structure.
proc open*(path: string): Winmd =
  if not fileExists(Path(path)):
    raiseWinmdError("no such file: " & path)
  # NB: Nim 2's readFile(path) decodes UTF-8 text and silently corrupts
  # arbitrary binary bytes (observed 0x14 -> 0x20), so read via syncio.
  let fh = syncio.open(string(Path(path)), fmRead)
  defer:
    syncio.close(fh)
  let n = syncio.getFileSize(fh).int
  var d = newSeqUninit[byte](n)
  if syncio.readBytes(fh, d, 0, n) != n:
    raiseWinmdError("short read for " & path)

  let idh = d.h(0, IMAGE_DOS_HEADER)
  if idh.e_magic != IMAGE_DOS_SIGNATURE.uint16 or
      d.u32(int(idh.e_lfanew)) != IMAGE_NT_SIGNATURE:
    raiseWinmdError("not a PE file")

  let
    ifhOff = idh.e_lfanew.int + 4
    ifh = d.h(ifhOff, IMAGE_FILE_HEADER)
    iohOff = ifhOff + sizeof(IMAGE_FILE_HEADER)
    ns = int(ifh.NumberOfSections)

    (comRva, sections) =
      case d.u16(iohOff)
      of IMAGE_NT_OPTIONAL_HDR32_MAGIC:
        static:
          doAssert(sizeof(IMAGE_OPTIONAL_HEADER32) == 224)
        let ioh32 = d.h(iohOff, IMAGE_OPTIONAL_HEADER32)
        (
          ioh32.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress,
          ua(d, iohOff + sizeof(IMAGE_OPTIONAL_HEADER32), IMAGE_SECTION_HEADER),
        )
      of IMAGE_NT_OPTIONAL_HDR64_MAGIC:
        static:
          doAssert(sizeof(IMAGE_OPTIONAL_HEADER64) == 240)
        let ioh64 = d.h(iohOff, IMAGE_OPTIONAL_HEADER64)
        (
          ioh64.DataDirectory[IMAGE_DIRECTORY_ENTRY_COM_DESCRIPTOR].VirtualAddress,
          ua(d, iohOff + sizeof(IMAGE_OPTIONAL_HEADER64), IMAGE_SECTION_HEADER),
        )
      else:
        raiseWinmdError("Unkown optional header")

    comOff = rvaToOffset(d, sections.toOpenArray(0, ns - 1), comRva)
    cor = d.h(comOff, IMAGE_COR20_HEADER)

  if cor.cb != sizeof(IMAGE_COR20_HEADER).uint32:
    raiseWinmdError("bad IMAGE_COR20_HEADER cb: " & $(cor.cb))

  let mdOff =
    rvaToOffset(d, sections.toOpenArray(0, ns - 1), cor.MetaData.VirtualAddress)
  let md = d.h(mdOff, METADATA_HEADER)
  if md.Signature != METADATA_HEADER_SIGNATURE:
    raiseWinmdError("bad metadata signature (expected BSJB)")

  let verLen = int(md.Length)
  let nStreams = int(d.u16(mdOff + sizeof(METADATA_HEADER) + verLen + 2))

  var cur = mdOff + 16 + verLen + 4
  var tildeOff, tildeLen = 0

  result = new Winmd
  for i in 0 ..< nStreams.int:
    let (so, sl) = (int(d.u32(cur)), int(d.u32(cur + 4)))
    var j = cur + 8
    while d[j] != 0:
      inc j
    let name = d.toOpenArrayChar(cur + 8, j - 1).substr()
    case name
    of "#Strings":
      result.stringsOff = mdOff + so
      result.stringsLen = sl
    of "#Blob":
      result.blobsOff = mdOff + so
      result.blobsLen = sl
    of "#GUID":
      discard
    of "#~":
      tildeOff = mdOff + so
      tildeLen = sl
    else:
      # unknown streams (#US, #WindowsRuntime, ...) are not needed
      discard
    let used = (j - cur) + 1
    cur += used + (4 - used mod 4) mod 4
  if tildeOff == 0:
    raiseWinmdError("no #~ stream found")

  result.heapSizes = d.u8(tildeOff + 6)
  result.valid = d.u64(tildeOff + 8)
  # (sorted u64 at +16 is ignored)
  result.strIdxBytes = if (result.heapSizes and 1) != 0: 4 else: 2
  result.guidIdxBytes = if ((result.heapSizes shr 1) and 1) != 0: 4 else: 2
  result.blobIdxBytes = if ((result.heapSizes shr 2) and 1) != 0: 4 else: 2
  var countOff = tildeOff + 24
  for i in 0 .. 0x2c:
    if ((result.valid shr i) and 1) != 0:
      result.counts[i] = int(d.u32(countOff))
      countOff += 4
  if result.valid shr 0x2d != 0:
    raiseWinmdError("unsupported table ids above 0x2c present")

  var rowCursor = countOff
  for t in tableIds:
    let c = result.counts[int(t)]
    if c == 0:
      continue

    if t notin modeledTables:
      raiseWinmdError(
        "table 0x" & $toHex(byte(t)) & " has " & $c &
          " rows but is not modeled by this reader"
      )
    result.rowOff[int(t)] = rowCursor
    result.rowSize[int(t)] = rowSize(result, t)
    rowCursor += result.rowSize[int(t)] * c
  if rowCursor > tildeOff + tildeLen:
    raiseWinmdError("table row data overruns the #~ stream")

  result.data = d

# ---------------------------------------------------------------------------
# heaps
# ---------------------------------------------------------------------------

## Decode a #Strings heap entry: `idx` is the byte offset into the heap, the
## string runs to the next NUL.
proc string*(wa: Winmd, idx: int): string =
  let start = wa.stringsOff + idx
  var i = start
  let stop = wa.stringsOff + wa.stringsLen
  while i < stop and wa.data[i] != 0:
    inc i
  wa.data.toOpenArrayChar(start, i - 1).substr()

proc compressedLen(b: openArray[byte], p: int): (int, int) =
  ## (value, bytes consumed) for a metadata compressed integer.
  ## https://github.com/stakx/ecma-335/blob/f181e4696eebcbbc7c2b1e5d0a2ee289f2884d2d/docs/ii.24.2.4-us-and-blob-heaps.md
  let b0 = b[p]
  case b0 shr 5
  of 0 .. 3:
    (int(b0 and 0x7F), 1)
  of 4 .. 5:
    (int(b0 and 0x3F) shl 8 or int(b[p + 1]), 2)
  else:
    (
      (int(b0 and 0x1F) shl 24) or (int(b[p + 1]) shl 16) or int(b[p + 2]) shl 8 or
        int(b[p + 3]),
      4,
    )

## Decode a #Blob heap entry: `idx` points at a compressed-length prefix
## followed by the blob bytes (prefix stripped in the result).
proc blob*(wa: Winmd, idx: int): seq[byte] =
  let off = wa.blobsOff + idx
  let (n, len) = compressedLen(wa.data, off)
  wa.data[off + len ..< off + len + n]

## True if the #Strings heap contains the exact string `s` (i.e. some string
## entry equals `s`, followed by a NUL).
proc containsString*(wa: Winmd, needle: string): bool =
  let start = wa.stringsOff
  # NB: the stream's declared length can overrun the file by a byte;
  # clamp to the actual data.
  let stop = min(wa.stringsOff + wa.stringsLen, wa.data.len)
  var i = 0
  while i + needle.len <= stop - start:
    let off = start + i
    if wa.data.toOpenArrayChar(off, off + needle.len - 1) == needle:
      # NB: `or` does not short-circuit in this build — guard the
      # out-of-bounds read explicitly.
      if off + needle.len == stop:
        return true
      if wa.data[off + needle.len] == 0:
        return true
    inc i

# ---------------------------------------------------------------------------
# row access
# ---------------------------------------------------------------------------

proc rowCount*(wa: Winmd, t: TableId): int =
  ## Number of rows in table `t` (0 if the table is absent).
  wa.counts[int(t)]

## Row cursor. Holds a *pointer* to the Winmd: a seq is a value type in
## Nim, so copying the Winmd object deep-copies the 13MB file image on
## every row access (measured: 15ms per copy).
type RowReader* = object
  wa*: Winmd
  off*: int

proc rowReader*(wa: Winmd, t: TableId, i: int): RowReader =
  let base = wa.rowOff[int(t)] + i * wa.rowSize[int(t)]
  result.wa = wa
  result.off = base

proc u16*(self: var RowReader): uint16 =
  let v = u16(self.wa.data, self.off)
  inc self.off, 2
  v

proc u32*(self: var RowReader): uint32 =
  let v = u32(self.wa.data, self.off)
  inc self.off, 4
  v

proc rawIdx(self: var RowReader, width: int): int =
  if width == 2:
    int(self.u16())
  else:
    int(self.u32())

proc strIdx(self: var RowReader): int =
  self.rawIdx(self.wa.strIdxBytes)

proc `string`*(self: var RowReader): string =
  self.wa.`string`(self.strIdx())

proc blobIdx(self: var RowReader): int =
  self.rawIdx(self.wa.blobIdxBytes)

proc blob(self: var RowReader): seq[byte] =
  self.wa.blob(self.blobIdx())

proc rowIdx(self: var RowReader, t: TableId): int =
  ## 1-based table index column -> 0-based row (0 for the "no row" value 0).
  let w = if self.wa.rowCount(t) < 65536: 2 else: 4
  let v = self.rawIdx(w)
  if v == 0:
    0
  else:
    v - 1

proc coded*(self: var RowReader, k: CodedKind): CodedRef =
  let v = uint32(self.rawIdx(self.wa.codedWidth(k)))
  if v == 0:
    return nullCoded
  let bits = codedBits(k)
  let tag = int(v) and ((1 shl bits) - 1)
  result.kind = codedTag(k, tag)
  result.row = int(v shr bits) - 1

proc moduleRow*(wa: Winmd, i: int): ModuleRow =
  var r = rowReader(wa, Module, i)
  result.generation = r.u16()
  result.name = r.`string`()
  result.mvid = r.u32()
  result.encid = r.u32()
  result.encbaseid = r.u32()

proc typeRef*(wa: Winmd, i: int): TypeRefRow =
  var r = rowReader(wa, TypeRef, i)
  result.resolutionScope = r.coded(ckResolutionScope)
  result.name = r.`string`()
  result.namespace = r.`string`()

proc typeDef*(wa: Winmd, i: int): TypeDefRow =
  var r = rowReader(wa, TypeDef, i)
  result.flags = r.u32()
  result.name = r.`string`()
  result.namespace = r.`string`()
  result.extends = r.coded(ckTypeDefOrRef)
  result.fieldsStart = r.rowIdx(Field)
  result.methodsStart = r.rowIdx(MethodDef)

proc field*(wa: Winmd, i: int): FieldRow =
  var r = rowReader(wa, Field, i)
  result.flags = r.u16()
  result.name = r.`string`()
  result.signature = r.blob()

proc methodDef*(wa: Winmd, i: int): MethodDefRow =
  var r = rowReader(wa, MethodDef, i)
  result.rva = r.u32()
  result.implFlags = r.u16()
  result.flags = r.u16()
  result.name = r.`string`()
  result.signature = r.blob()
  result.paramsStart = r.rowIdx(MethodParam)

proc methodParam*(wa: Winmd, i: int): MethodParamRow =
  var r = rowReader(wa, MethodParam, i)
  result.flags = r.u16()
  result.sequence = r.u16()
  result.name = r.`string`()

proc interfaceImpl*(wa: Winmd, i: int): InterfaceImplRow =
  var r = rowReader(wa, InterfaceImpl, i)
  result.typedef = r.rowIdx(TypeDef)
  result.interfaceType = r.coded(ckTypeDefOrRef)

proc memberRef*(wa: Winmd, i: int): MemberRefRow =
  var r = rowReader(wa, MemberRef, i)
  result.parent = r.coded(ckMemberRefParent)
  result.name = r.`string`()
  result.signature = r.blob()

proc constant*(wa: Winmd, i: int): ConstantRow =
  var r = rowReader(wa, Constant, i)
  result.typeTag = uint8(u16(wa.data, r.off) and 0xFF)
  inc r.off, 2
  result.parent = r.coded(ckHasConstant)
  result.value = r.blob()

proc customAttribute*(wa: Winmd, i: int): CustomAttributeRow =
  var r = rowReader(wa, CustomAttribute, i)
  result.parent = r.coded(ckHasCustomAttribute)
  result.ctor = r.coded(ckAttributeType)
  result.value = r.blob()

proc classLayout*(wa: Winmd, i: int): ClassLayoutRow =
  var r = rowReader(wa, ClassLayout, i)
  result.packing = r.u16()
  result.classSize = r.u32()
  result.typedef = r.rowIdx(TypeDef)

proc eventMap*(wa: Winmd, i: int): EventMapRow =
  var r = rowReader(wa, EventMap, i)
  result.parent = r.rowIdx(TypeDef)
  result.eventListStart = r.rowIdx(Event)

proc event*(wa: Winmd, i: int): EventRow =
  var r = rowReader(wa, Event, i)
  result.eventFlags = r.u16()
  result.name = r.`string`()
  result.eventType = r.coded(ckTypeDefOrRef)

proc propertyMap*(wa: Winmd, i: int): PropertyMapRow =
  var r = rowReader(wa, PropertyMap, i)
  result.parent = r.rowIdx(TypeDef)
  result.propertyListStart = r.rowIdx(Property)

proc property*(wa: Winmd, i: int): PropertyRow =
  var r = rowReader(wa, Property, i)
  result.propertyFlags = r.u16()
  result.name = r.`string`()
  result.`type` = r.blob()

proc methodSemantics*(wa: Winmd, i: int): MethodSemanticsRow =
  var r = rowReader(wa, MethodSemantics, i)
  result.semantics = r.u16()
  result.`method` = r.rowIdx(MethodDef)
  result.association = r.coded(ckHasSemantics)

proc moduleRef*(wa: Winmd, i: int): ModuleRefRow =
  var r = rowReader(wa, ModuleRef, i)
  result.name = r.`string`()

proc typeSpec*(wa: Winmd, i: int): TypeSpecRow =
  var r = rowReader(wa, TypeSpec, i)
  result.signature = r.blob()

proc implMap*(wa: Winmd, i: int): ImplMapRow =
  var r = rowReader(wa, ImplMap, i)
  result.flags = r.u16()
  result.memberForwarded = r.coded(ckMemberForwarded)
  result.importName = r.`string`()
  result.moduleRef = r.rowIdx(ModuleRef)

proc assembly*(wa: Winmd, i: int): AssemblyRow =
  var r = rowReader(wa, Assembly, i)
  discard r.u32() # hash algorithm id
  result.major = r.u16()
  result.minor = r.u16()
  result.build = r.u16()
  result.revision = r.u16()
  result.flags = r.u32()
  result.publicKey = r.blob()
  result.name = r.`string`()
  result.culture = r.`string`()

proc assemblyRef*(wa: Winmd, i: int): AssemblyRefRow =
  var r = rowReader(wa, AssemblyRef, i)
  result.major = r.u16()
  result.minor = r.u16()
  result.build = r.u16()
  result.revision = r.u16()
  result.flags = r.u32()
  result.publicKeyToken = r.blob()
  result.name = r.`string`()
  result.culture = r.`string`()
  result.publicKey = r.blob()

proc nestedClass*(wa: Winmd, i: int): NestedClassRow =
  var r = rowReader(wa, NestedClass, i)
  result.innerType = r.rowIdx(TypeDef)
  result.enclosingType = r.rowIdx(TypeDef)

proc genericParam*(wa: Winmd, i: int): GenericParamRow =
  var r = rowReader(wa, GenericParam, i)
  result.number = r.u16()
  result.flags = r.u16()
  result.owner = r.coded(ckTypeOrMethodDef)
  result.name = r.`string`()

proc methodImpl*(wa: Winmd, i: int): MethodImplRow =
  var r = rowReader(wa, MethodImpl, i)
  result.class = r.rowIdx(TypeDef)
  result.methodBody = r.coded(ckMethodDefOrRef)
  result.methodDeclaration = r.coded(ckMethodDefOrRef)

# ---------------------------------------------------------------------------
# lookups
# ---------------------------------------------------------------------------

## All TypeDef rows with the given (ns, name). `ns` defaults to "" (empty
## namespace).
proc typeDefsNamed*(wa: Winmd, name: string, ns: string = ""): seq[int] =
  for i in 0 ..< wa.rowCount(TypeDef):
    let t = wa.typeDef(i)
    if t.name == name and t.namespace == ns:
      result.add(i)

## ECMA list semantics for TypeDef.Fields =
## [a, b), where b is the next row's start or the table end.
proc fieldsOf*(wa: Winmd, i: int): Slice[int] =
  let b =
    if i + 1 < wa.rowCount(TypeDef):
      wa.typeDef(i + 1).fieldsStart
    else:
      wa.rowCount(Field)
  result.a = wa.typeDef(i).fieldsStart
  result.b = b - 1

## ECMA list semantics for TypeDef.Methods
proc methodsOf*(wa: Winmd, i: int): Slice[int] =
  let b =
    if i + 1 < wa.rowCount(TypeDef):
      wa.typeDef(i + 1).methodsStart
    else:
      wa.rowCount(MethodDef)
  result.a = wa.typeDef(i).methodsStart
  result.b = b - 1

## ECMA list semantics for MethodDef.Param
proc paramsOf*(wa: Winmd, i: int): Slice[int] =
  let b =
    if i + 1 < wa.rowCount(MethodDef):
      wa.methodDef(i + 1).paramsStart
    else:
      wa.rowCount(MethodParam)
  result.a = wa.methodDef(i).paramsStart
  result.b = b - 1

## ECMA list semantics for EventMap.eventList
proc eventsOf*(wa: Winmd, i: int): Slice[int] =
  let b =
    if i + 1 < wa.rowCount(EventMap):
      wa.eventMap(i + 1).eventListStart
    else:
      wa.rowCount(Event)
  result.a = wa.eventMap(i).eventListStart
  result.b = b - 1

## ECMA list semantics for EventMap.eventList
proc propertiesOf*(wa: Winmd, i: int): Slice[int] =
  let b =
    if i + 1 < wa.rowCount(PropertyMap):
      wa.propertyMap(i + 1).propertyListStart
    else:
      wa.rowCount(Property)
  result.a = wa.propertyMap(i).propertyListStart
  result.b = b - 1

proc codedAt(wa: Winmd, k: CodedKind, off: int): uint32 =
  ## The coded index of kind `k` stored at `off`: 2 bytes wide when every
  ## table of its set is small (codedWidth), as in a small winmd, else 4.
  if wa.codedWidth(k) == 2:
    uint32(u16(wa.data, off))
  else:
    u32(wa.data, off)

## The ImplMap row forwarded to `methodDefIdx` (ImplMap column 1 is sorted by
## the MemberForwarded coded value; binary search).
proc implMapFor*(wa: Winmd, methodDefIdx: int): Option[ImplMapRow] =
  let target = (uint32(methodDefIdx + 1) shl 1) or 1'u32 # MethodDef tag = 1
  let (base, w) = (wa.rowOff[int(ImplMap)], wa.rowSize[int(ImplMap)])
  var lo = 0
  var hi = wa.rowCount(ImplMap) - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    let v = wa.codedAt(ckMemberForwarded, base + mid * w + 2)
    if v < target:
      lo = mid + 1
    elif v > target:
      hi = mid - 1
    else:
      return some(wa.implMap(mid))
  return none[ImplMapRow]()

## The Constant row for `fieldIdx` (Constant is not sorted by parent;
## linear scan — fine at winmd sizes).
proc constantFor*(wa: Winmd, fieldIdx: int): Option[ConstantRow] =
  let target = uint32(fieldIdx + 1) shl 2 # HasConstant: Field tag = 0
  let (base, w) = (wa.rowOff[int(Constant)], wa.rowSize[int(Constant)])
  for i in 0 ..< wa.rowCount(Constant):
    if wa.codedAt(ckHasConstant, base + i * w + 2) == target:
      return some(wa.constant(i))
  return none[ConstantRow]()

## All CustomAttribute rows whose parent column equals `parent` (column 0 is
## sorted by the HasCustomAttribute coded value; binary search).
proc customAttributesFor*(wa: Winmd, parent: CodedRef): seq[CustomAttributeRow] =
  let tag = uint32(codedTagValue(ckHasCustomAttribute, parent.kind))
  let target = (uint32(parent.row + 1) shl 5) or tag
  let (base, w) = (wa.rowOff[int(CustomAttribute)], wa.rowSize[int(CustomAttribute)])
  var lo = 0
  var hi = wa.rowCount(CustomAttribute) - 1
  while lo <= hi:
    let mid = (lo + hi) shr 1
    let v = wa.codedAt(ckHasCustomAttribute, base + mid * w)
    if v < target:
      lo = mid + 1
    elif v > target:
      hi = mid - 1
    else:
      var first = mid
      while first > 0 and
          wa.codedAt(ckHasCustomAttribute, base + (first - 1) * w) == target:
        dec first
      var last = mid
      while last + 1 <= hi and
          wa.codedAt(ckHasCustomAttribute, base + (last + 1) * w) == target:
        inc last
      for i in first .. last:
        result.add(wa.customAttribute(i))
      return
  result = @[]

## Name of the type a CodedRef points at (TypeDef/TypeRef); "" for anything
## else (e.g. TypeSpec).
proc typeName*(wa: Winmd, t: CodedRef): string =
  case t.kind
  of TypeDef:
    wa.typeDef(t.row).name
  of TypeRef:
    wa.typeRef(t.row).name
  else:
    ""

## Map from MethodDef row -> owning TypeDef row (-1 if none). O(total).
proc methodOwnerMap*(wa: Winmd): seq[int] =
  result = newSeqWith(wa.rowCount(MethodDef), -1)
  for t in 0 ..< wa.rowCount(TypeDef):
    for m in wa.methodsOf(t):
      result[m] = t

## Name of the type that owns a custom attribute's ctor: for a MemberRef ctor
## that is the parent type's name; for a MethodDef ctor the containing
## type's name (needs the owning type of the method).
proc ctorTypeName*(wa: Winmd, attr: CustomAttributeRow, owners: seq[int]): string =
  case attr.ctor.kind
  of MethodDef:
    let owner = owners[attr.ctor.row]
    if owner >= 0:
      wa.typeDef(owner).name
    else:
      ""
  of MemberRef:
    let m = wa.memberRef(attr.ctor.row)
    wa.typeName(m.parent)
  else:
    ""

## First attribute in `attrs` whose ctor's parent type is named `name`.
proc attributeNamed*(
    wa: Winmd, attrs: seq[CustomAttributeRow], name: string, owners: seq[int]
): Option[CustomAttributeRow] =
  for a in attrs:
    if ctorTypeName(wa, a, owners) == name:
      return some(a)
  return none[CustomAttributeRow]()

## Decode the serialized attribute blob of `attr` into positional + named
## arguments. `nPositional` is the ctor's parameter count (0 for the common
## argumentless attributes like ScopedEnumAttribute; the count comes from the
## ctor signature, which is decoded in a later phase).
proc attributeArgs*(
    wa: Winmd, attr: CustomAttributeRow, nPositional: int = 0
): seq[AttributeArg] =
  let b = attr.value
  if b.len < 2:
    raiseWinmdError("attribute blob too short")
  let prolog = uint16(b[0]) or (uint16(b[1]) shl 8)
  if prolog != 1:
    raiseWinmdError("bad custom attribute prolog: 0x" & $(prolog))
  var p = 2
  for i in 0 ..< nPositional:
    let (n, used) = compressedLen(b, p)
    p += used
    result.add AttributeArg(name: "", namedType: 0, value: b[p ..< p + n])
    p += n
  let (nNamed, namedUsed) = compressedLen(b, p)
  p += namedUsed
  for i in 0 ..< nNamed:
    discard b[p] # reserved name hash, unused
    let ty = b[p + 1]
    p += 2
    let (nameLen, u1) = compressedLen(b, p)
    p += u1
    let name = b.toOpenArrayChar(p, p + nameLen - 1).substr()
    p += nameLen
    let (valLen, u2) = compressedLen(b, p)
    p += u2
    result.add AttributeArg(name: name, namedType: ty, value: b[p ..< p + valLen])
    p += valLen
