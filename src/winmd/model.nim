# model.nim — turns raw winmd tables into a generator-friendly model of the
# Win32 API surface (types, functions, constants).
#
# Classification loosely follows the windows-metadata (Rust) reference:
#   - category from the TypeDef `extends` column:
#       System.Enum -> enum, System.ValueType -> struct/handle,
#       System.MulticastDelegate -> delegate, System.Attribute -> skipped,
#       null -> interface, anything else -> class (only "Apis" exists; it is
#       expanded into fns/consts, not a type)
#   - WinRT types (TypeAttributes 0x4000, Windows.winmd only) fill the
#     `isWinRT` fields of ModelType. A runtime class is an interface by the
#     `extends` rule above; lacking TypeAttributes.Interface (0x20) is what
#     tells it apart.
#   - handles = single-field structs carrying NativeTypedefAttribute
#   - enums are scoped when they carry ScopedEnumAttribute
#   - functions = every ImplMap row
#     stdcall when the ImplMap flags contain 0x100 (CallConvPlatformapi)
#     and not 0x200 (CallConvCdecl); empty import names fall back to the
#     method name.
#   - free constants = non-enum fields that have a Constant row
#     (80387 in Windows.Win32.winmd; enum members are kept on the enum).

import std/[options, sequtils, unicode, tables]
import ./[guid, signatures, reader]
export guid

type
  TypeKind* = enum
    tkStruct
    tkHandle
    tkEnum
    tkUnscopedEnum
    tkDelegate
    tkInterface

  ## The architectures a winmd entry is declared for, from the
  ## SupportedArchitectureAttribute (empty = arch-neutral).
  Architecture* = enum
    i386
    amd64
    arm64

  ModelField* = object
    name*: string # the symbol name as in the winmd
    nimName*: string # fixIdent(name): the entry's Nim identifier
    ty*: SigType
    constant*: uint64 # valid when hasConstant
    hasConstant*: bool

  ModelType* = object
    kind*: TypeKind
    ns*: string
    name*: string # the symbol name as in the winmd
    nimName*: string # fixIdent(name): the entry's Nim identifier
    defRow*: int # TypeDef row index (for nested-type reference resolution)
    fields*: seq[ModelField] # struct/handle members or enum values
    ret*: SigType # Win32 delegates only (a WinRT one has its Invoke in `methods`)
    underlying*: SigType # handles and enums
    hasUnderlying*: bool
    arch*: set[Architecture] # SupportedArchitectureAttribute (empty = arch-neutral)
    isUnion*: bool
      # TypeAttributes.ExplicitLayout (0x10): the
      # struct's fields are overlaid (a C union)
    packSize*: int # ClassLayout packing (1 = packed, 0 = natural)
    alignSize*: int # AlignmentAttribute forced alignment (0 = none)
    isWinRT*: bool # TypeAttributes.WindowsRuntime (0x4000)
    isClass*: bool
      # a WinRT runtime class: a tkInterface without TypeAttributes.Interface
      # (0x20)
    guid*: Option[Guid] # GuidAttribute: the IID of a WinRT interface or delegate
    methods*: seq[ModelFn] # WinRT interfaces and delegates, in vtable order
    defaultInterface*: Option[SigType]
      # a WinRT runtime class's DefaultAttribute interface; none for a static
      # class
    interfaces*: seq[SigType] # WinRT types: the interfaces required or implemented
    genericParameters*: seq[string] # generic types (``IVector`1``)

  ModelParam* = object
    name*: string # the symbol name as in the winmd
    nimName*: string # fixIdent(name): the entry's Nim identifier
    ty*: SigType

  ModelFn* = object
    name*: string # the symbol name as in the winmd
    nimName*: string # fixIdent(name): the entry's Nim identifier
    importName*: string # the C linkage name (importc)
    moduleName*: string
    stdcall*: bool
    ret*: SigType
    params*: seq[ModelParam]
    arch*: set[Architecture] # SupportedArchitectureAttribute (empty = arch-neutral)

  ModelConst* = object
    ns*: string
    name*: string # the symbol name as in the winmd
    nimName*: string # fixIdent(name): the entry's Nim identifier
    value*: uint64
    isFloat*: bool
    floatVal*: float64
    isStr*: bool
    strVal*: string
    wideStr*: bool # string constant with a utf-16 NativeEncodingAttribute
    ty*: SigType
    arch*: set[Architecture] # SupportedArchitectureAttribute (empty = arch-neutral)

  Model* = object
    types*: seq[ModelType]
    fns*: seq[ModelFn]
    consts*: seq[ModelConst]
    skippedVariadic*: seq[string]

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

proc category(wa: Winmd, t: TypeDefRow): TypeKind =
  if t.extends.isNull:
    return tkInterface
  let (ns, name) =
    if t.extends.kind == TypeDef:
      let e = wa.typeDef(t.extends.row)
      (e.namespace, e.name)
    elif t.extends.kind == TypeRef:
      let e = wa.typeRef(t.extends.row)
      (e.namespace, e.name)
    else:
      raiseWinmdError("TypeSpec in extends column")
  if ns == "System":
    case name
    of "Enum": tkEnum
    of "ValueType": tkStruct
    of "MulticastDelegate": tkDelegate
    else: tkInterface
      # includes System.Attribute (filtered by caller)
  else:
    tkInterface

proc isLiteral(f: FieldRow): bool =
  (f.flags and 0x0040) != 0 # FieldAttributes.Literal

template convert(v, T): untyped =
  var vx: T
  copyMem(addr vx, addr v[0], sizeof(T))
  uint64(vx)

proc constValue(c: ConstantRow): ModelConst =
  result = ModelConst(value: 0)
  case c.typeTag
  of ELEMENT_TYPE_I1:
    result.value = convert(c.value, int8)
  of ELEMENT_TYPE_U1:
    result.value = convert(c.value, uint8)
  of ELEMENT_TYPE_I2:
    result.value = convert(c.value, int16)
  of ELEMENT_TYPE_U2:
    result.value = convert(c.value, uint16)
  of ELEMENT_TYPE_I4:
    result.value = convert(c.value, int32)
  of ELEMENT_TYPE_U4:
    result.value = convert(c.value, uint32)
  of ELEMENT_TYPE_I8, ELEMENT_TYPE_I:
    result.value = convert(c.value, int64)
  of ELEMENT_TYPE_U8, ELEMENT_TYPE_U:
    result.value = convert(c.value, uint64)
  of ELEMENT_TYPE_R4: # R4
    result.isFloat = true
    var f32: float32
    copyMem(addr(f32), addr(c.value[0]), 4)
    result.floatVal = f32
  of ELEMENT_TYPE_R8: # R8
    result.isFloat = true
    var f64: float64
    copyMem(addr(f64), addr(c.value[0]), 8)
    result.floatVal = f64
  of ELEMENT_TYPE_STRING: # STRING (ELEMENT_TYPE_STRING) - UTF-16LE
    result.isStr = true
    var i = 0
    while i + 1 < c.value.len:
      let cp = (int(c.value[i + 1]) shl 8) or int(c.value[i])
      result.strVal.add Rune(cint(cp))
      inc i, 2
  else:
    raiseWinmdError("unsupported constant type tag " & $c.typeTag)

## Nim forbids identifiers with a leading/trailing/repeated underscore
proc fixIdent*(s: string): string =
  # leading underscores are reserved in Nim
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len and s[i] == '_':
    inc i

  if i > 0:
    result.add "X_"

  while i < s.len:
    let ch = s[i]
    if ch == '_' and result.len > 0 and result[^1] == '_':
      inc i
      continue
    result.add ch
    inc i

  if result.len > 0 and result[^1] == '_':
    result.add 'X'

## True when a field's NativeEncodingAttribute says "utf-16" (wide string
## constant); "ansi" or absent is false. Blob: prolog(2) + u8 len + bytes
## + named-count(2).
proc nativeEncodingWide(
    wa: Winmd, attrs: seq[CustomAttributeRow], owners: seq[int]
): bool =
  for a in attrs:
    if wa.ctorTypeName(a, owners) == "NativeEncodingAttribute":
      let b = a.value
      if b.len >= 5:
        let slen = int(b[2])
        if b.len >= 3 + slen + 2:
          var enc = ""
          for i in 3 ..< 3 + slen:
            enc.add chr(b[i])
          return enc == "utf-16"
  false

## The entry's SupportedArchitectureAttribute, or an empty sequence if
## absent. The attribute's value blob is prolog(2) + one I32(4) +
## named-count(2); the I32 is an arch bitmask (1=i386, 2=amd64, 4=arm64).
proc supportedArchs(
    wa: Winmd, attrs: seq[CustomAttributeRow], owners: seq[int]
): set[Architecture] =
  for a in attrs:
    if wa.ctorTypeName(a, owners) == "SupportedArchitectureAttribute":
      let b = a.value
      if b.len == 8:
        let bits =
          int(b[2]) or (int(b[3]) shl 8) or (int(b[4]) shl 16) or (int(b[5]) shl 24)
        if (bits and 1) != 0:
          result.incl i386
        if (bits and 2) != 0:
          result.incl amd64
        if (bits and 4) != 0:
          result.incl arm64

func guidOf(wa: Winmd, attrs: seq[CustomAttributeRow], owners: seq[int]): Option[Guid] =
  ## The GUID of the first GuidAttribute among `attrs`, if any. The
  ## attribute's value blob is prolog(2) + the 16 bytes + named-count(2).
  let a =
    attrs.findIt(wa.ctorTypeName(it, owners) == "GuidAttribute" and it.value.len == 20)
  if a == -1:
    return
  some(guidFromMemory(attrs[a].value.toOpenArray(2, 17)))

func namedType(r: TypeDefRow | TypeRefRow): SigType =
  ## A reference to the type row `r` defines or names.
  SigType(base: bNamed, ns: r.namespace, name: r.name, rowIdx: -1)

## Map: TypeDef index -> ClassLayout packing (0 if no ClassLayout row).
proc classLayoutPackingMap(wa: Winmd): seq[int] =
  result = newSeq[int](wa.rowCount(TypeDef))
  for i in 0 ..< wa.rowCount(ClassLayout):
    let cl = wa.classLayout(i)
    if cl.typedef >= 0 and cl.typedef < result.len:
      result[cl.typedef] = int(cl.packing)

## Forced alignment from a TypeDef's AlignmentAttribute, or 0 if absent.
## The attribute's value blob is prolog(2) + one I32(4) + named-count(2).
proc alignmentOf(wa: Winmd, attrs: seq[CustomAttributeRow], owners: seq[int]): int =
  for a in attrs:
    if wa.ctorTypeName(a, owners) == "AlignmentAttribute":
      let b = a.value
      if b.len == 8:
        return
          int(b[2]) or (int(b[3]) shl 8) or (int(b[4]) shl 16) or (int(b[5]) shl 24)
  0

## O(total fields) map: field index -> owning TypeDef index (-1 if none).
proc fieldOwnerMap(wa: Winmd): seq[int] =
  result = newSeq[int](wa.rowCount(Field))
  for i in 0 ..< result.len:
    result[i] = -1
  for t in 0 ..< wa.rowCount(TypeDef):
    for f in wa.fieldsOf(t):
      result[f] = t

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

proc typeNs(wa: Winmd, enclosing: seq[int], t: int): string =
  ## Namespace of (possibly nested) TypeDef `t`. Nested types have an empty
  ## namespace of their own; they inherit the enclosing type's namespace.
  if wa.typeDef(t).namespace.len > 0:
    return wa.typeDef(t).namespace
  var o = enclosing[t]
  while o >= 0:
    let on = wa.typeDef(o).namespace
    if on.len > 0:
      return on
    o = enclosing[o]
  ""

proc build*(wa: Winmd): Model =
  let nTypes = wa.rowCount(TypeDef)
  let owners = wa.methodOwnerMap()
  let fowners = fieldOwnerMap(wa)
  let clPacking = classLayoutPackingMap(wa)

  # TypeDef row -> enclosing TypeDef row (-1 if top-level), from NestedClass.
  var enclosing = newSeq[int](nTypes)
  for i in 0 ..< nTypes:
    enclosing[i] = -1
  for i in 0 ..< wa.rowCount(NestedClass):
    let nc = wa.nestedClass(i)
    enclosing[nc.innerType] = nc.enclosingType

  # field index -> constant row
  var fieldConst: seq[Option[ConstantRow]] =
    newSeq[Option[ConstantRow]](wa.rowCount(Field))

  for i in 0 ..< wa.rowCount(Constant):
    let c = wa.constant(i)
    if c.parent.kind == Field:
      fieldConst[c.parent.row] = some(c)

  # (enclosing TypeDef row, inner name) -> inner TypeDef row. The winmd
  # names anonymous nested types generically (many rows share one name),
  # and references to them go through TypeRef rows; the NestedClass table
  # is the only thing that pins a reference to the right row. Pairs are
  # unique (verified: no enclosing type has two children with one name).
  var nestedTarget: Table[system.string, int] = initTable[system.string, int]()
  for i in 0 ..< wa.rowCount(NestedClass):
    let nc = wa.nestedClass(i)
    nestedTarget[$nc.enclosingType & "/" & wa.typeDef(nc.innerType).name] = nc.innerType

  ## Pin a TypeRef reference to the nested TypeDef row it names, when that
  ## name is shared by multiple rows (anonymous nested types).
  proc resolveNested(ty: var SigType, parentRow: int) =
    if ty.base == bNamed and ty.rowIdx < 0:
      let k = $parentRow & "/" & ty.name
      if k in nestedTarget:
        ty.rowIdx = nestedTarget[k]
    if ty.inner != nil:
      resolveNested(ty.inner[], parentRow)

  # ---- WinRT -----------------------------------------------------------------
  # TypeDef row -> the names of its generic parameters (the rows are in
  # parameter order)
  var genericParameters: Table[int, seq[system.string]]
  for i in 0 ..< wa.rowCount(GenericParam):
    let gp = wa.genericParam(i)
    if gp.owner.kind == TypeDef:
      genericParameters.mgetOrPut(gp.owner.row, @[]).add gp.name

  # WinRT TypeDef row -> the interfaces it requires or implements, and the one
  # that carries DefaultAttribute: a runtime class's default interface
  var interfaces: Table[int, seq[SigType]]
  var defaultInterface: Table[int, SigType]
  for i in 0 ..< wa.rowCount(InterfaceImpl):
    let impl = wa.interfaceImpl(i)
    if (wa.typeDef(impl.typedef).flags and 0x4000) == 0:
      continue # a COM interface's base: the Win32 generator does not use it
    let iface = impl.interfaceType
    # a TypeSpec spells out a parameterised interface, IMap<String, String>
    let ty =
      case iface.kind
      of TypeSpec:
        decodeTypeSpec(wa, iface.row)
      of TypeDef:
        namedType(wa.typeDef(iface.row))
      else:
        namedType(wa.typeRef(iface.row))
    interfaces.mgetOrPut(impl.typedef, @[]).add ty
    let attrs = wa.customAttributesFor(typedRef(InterfaceImpl, i))
    if wa.attributeNamed(attrs, "DefaultAttribute", owners).isSome:
      defaultInterface[impl.typedef] = ty

  proc methodsFor(t: int, only = ""): seq[ModelFn] =
    ## The methods of TypeDef `t` (only the one named `only`, when given),
    ## each named as the ABI names it (an overload by its OverloadAttribute, as
    ## the SDK headers do) and each parameter by the Param row with its
    ## Sequence (1 is the first parameter, 0 the return value), or `arg_<n>`
    ## when it has none.
    for md in wa.methodsOf(t):
      let mr = wa.methodDef(md)
      if only.len > 0 and mr.name != only:
        continue
      let sig = decodeMethodSig(wa, mr.signature)
      var name = mr.name
      let attrs = wa.customAttributesFor(typedRef(MethodDef, md))
      let overload = wa.attributeNamed(attrs, "OverloadAttribute", owners)
      if overload.isSome:
        let arg = wa.attributeArgs(overload.get, 1)[0].value
        name = arg.toOpenArrayChar(0, arg.high).substr()
      var names = (1 .. sig.params.len).mapIt("arg_" & $it)
      for pi in wa.paramsOf(md):
        let pr = wa.methodParam(pi)
        if int(pr.sequence) in 1 .. names.len and pr.name.len > 0:
          names[pr.sequence - 1] = pr.name
      var fn = ModelFn(name: name, nimName: fixIdent(name), ret: sig.ret)
      for i, ty in sig.params:
        fn.params.add ModelParam(name: names[i], nimName: fixIdent(names[i]), ty: ty)
      result.add fn

  # ---- types -----------------------------------------------------------------
  for t in 0 ..< nTypes:
    let td = wa.typeDef(t)
    let ns = wa.typeNs(enclosing, t)
    if ns.len == 0:
      continue
    let attrs = wa.customAttributesFor(typedRef(TypeDef, t))
    let scoped = wa.attributeNamed(attrs, "ScopedEnumAttribute", owners).isSome
    let native = wa.attributeNamed(attrs, "NativeTypedefAttribute", owners).isSome
    let apiContract = wa.attributeNamed(attrs, "ApiContractAttribute", owners).isSome
    let kind = wa.category(td)
    let arch = wa.supportedArchs(attrs, owners)
    let isUnion = (td.flags and 0x10) != 0 # TypeAttributes.ExplicitLayout
    let packSize = clPacking[t]
    let alignSize = wa.alignmentOf(attrs, owners)
    let isWinRT = (td.flags and 0x4000) != 0 # TypeAttributes.WindowsRuntime
    # the IID of a WinRT interface or delegate (COM IIDs are not used yet)
    let guid =
      if isWinRT:
        wa.guidOf(attrs, owners)
      else:
        none(Guid)

    case kind
    of tkInterface:
      let aname =
        if td.extends.isNull:
          ""
        elif td.extends.kind == TypeDef:
          wa.typeDef(td.extends.row).name
        else:
          wa.typeRef(td.extends.row).name
      if aname == "Attribute" or aname == "Apis" or aname == "<Module>":
        continue
      result.types.add ModelType(
        kind: tkInterface,
        ns: ns,
        name: td.name,
        nimName: fixIdent(td.name),
        defRow: t,
        arch: arch,
        isUnion: isUnion,
        packSize: packSize,
        alignSize: alignSize,
        isWinRT: isWinRT,
        isClass: isWinRT and (td.flags and 0x20) == 0,
        guid: guid,
        # a runtime class's own methods implement its interfaces' (MethodImpl)
        methods:
          if guid.isSome:
            methodsFor(t)
          else:
            @[],
        defaultInterface:
          if t in defaultInterface:
            some(defaultInterface[t])
          else:
            none(SigType),
        interfaces: interfaces.getOrDefault(t),
        genericParameters: genericParameters.getOrDefault(t),
      )
    of tkEnum:
      var m = ModelType(
        kind: if scoped: tkEnum else: tkUnscopedEnum,
        ns: ns,
        name: td.name,
        nimName: fixIdent(td.name),
        defRow: t,
        arch: arch,
        isUnion: isUnion,
        packSize: packSize,
        alignSize: alignSize,
        isWinRT: isWinRT,
      )
      for f in wa.fieldsOf(t):
        let fr = wa.field(f)
        var fty = decodeFieldSig(wa, fr.signature)
        resolveNested(fty, t)
        let cc = fieldConst[f]
        if cc.isSome:
          m.fields.add ModelField(
            name: fr.name,
            nimName: fixIdent(fr.name),
            ty: fty,
            constant: constValue(cc[]).value,
            hasConstant: true,
          )
        else:
          m.underlying = fty # sole non-literal field = backing integer
          m.hasUnderlying = true
      result.types.add m
    of tkStruct:
      if apiContract:
        continue
      var m = ModelType(
        kind: tkStruct,
        ns: ns,
        name: td.name,
        nimName: fixIdent(td.name),
        defRow: t,
        fields: @[],
        arch: arch,
        isUnion: isUnion,
        packSize: packSize,
        alignSize: alignSize,
        isWinRT: isWinRT,
      )
      for f in wa.fieldsOf(t):
        let fr = wa.field(f)
        var fty = decodeFieldSig(wa, fr.signature)
        resolveNested(fty, t)
        m.fields.add ModelField(name: fr.name, nimName: fixIdent(fr.name), ty: fty)
      if native and m.fields.len == 1:
        m.kind = tkHandle
        m.underlying = m.fields[0].ty
        m.hasUnderlying = true
      result.types.add m
    of tkHandle, tkUnscopedEnum:
      raiseWinmdError("unexpected type kind")
    of tkDelegate:
      var m = ModelType(
        kind: tkDelegate,
        ns: ns,
        name: td.name,
        nimName: fixIdent(td.name),
        defRow: t,
        arch: arch,
        isUnion: isUnion,
        packSize: packSize,
        alignSize: alignSize,
        isWinRT: isWinRT,
        guid: guid,
        genericParameters: genericParameters.getOrDefault(t),
      )
      if isWinRT:
        # a WinRT delegate is a COM interface with one method, Invoke
        m.methods = methodsFor(t, only = "Invoke")
      else:
        for md in wa.methodsOf(t):
          let mr = wa.methodDef(md)
          if mr.name == "Invoke":
            var sig = decodeMethodSig(wa, mr.signature)
            resolveNested(sig.ret, t)
            for i in 0 ..< sig.params.len:
              resolveNested(sig.params[i], t)
            m.ret = sig.ret
            for i in 0 ..< sig.params.len:
              let an = "arg_" & $(i + 1)
              m.fields.add ModelField(
                name: an, nimName: fixIdent(an), ty: sig.params[i]
              )
            break
      result.types.add m

  # ---- functions ----------------------------------------------------------------
  for i in 0 ..< wa.rowCount(ImplMap):
    let im = wa.implMap(i)
    if im.memberForwarded.kind != MethodDef:
      continue
    let m = im.memberForwarded.row
    let mr = wa.methodDef(m)
    let sig = decodeMethodSig(wa, mr.signature)
    if (sig.flags and 0x40) != 0:
      result.skippedVariadic.add mr.name
      continue
    var fn = ModelFn(
      name: mr.name,
      nimName: fixIdent(mr.name),
      importName: if im.importName.len > 0: im.importName else: mr.name,
      moduleName: wa.moduleRef(im.moduleRef).name,
      stdcall: (im.flags and 0x0100) != 0 and (im.flags and 0x0200) == 0,
      ret: sig.ret,
      arch: wa.supportedArchs(wa.customAttributesFor(typedRef(MethodDef, m)), owners),
    )
    let p = wa.paramsOf(m)
    fn.params = newSeq[ModelParam](sig.params.len)
    for i2 in 0 ..< sig.params.len:
      let pname =
        if p.a + i2 <= p.b:
          wa.methodParam(p.a + i2).name
        else:
          ""
      let pnm =
        if pname.len > 0:
          pname
        else:
          "arg_" & $(i2 + 1)
      fn.params[i2] = ModelParam(name: pnm, nimName: fixIdent(pnm), ty: sig.params[i2])
    result.fns.add fn

  # ---- free constants -------------------------------------------------------------
  for f in 0 ..< wa.rowCount(Field):
    let cc = fieldConst[f]
    if cc.isNone:
      continue
    let owner = fowners[f]
    if owner < 0:
      continue
    let kind = category(wa, wa.typeDef(owner))
    if kind == tkEnum:
      continue # enum members stay on the enum
    let cv = constValue(cc[])
    let fty = decodeFieldSig(wa, wa.field(f).signature)
    let fattrs = wa.customAttributesFor(typedRef(Field, f))
    result.consts.add ModelConst(
      ns: wa.typeDef(owner).namespace,
      name: wa.field(f).name,
      nimName: fixIdent(wa.field(f).name),
      value: cv.value,
      isFloat: cv.isFloat,
      floatVal: cv.floatVal,
      isStr: cv.isStr,
      strVal: cv.strVal,
      wideStr: wa.nativeEncodingWide(fattrs, owners),
      ty: fty,
      arch: wa.supportedArchs(fattrs, owners),
    )
