# abitypes.nim — how a type of the metadata crosses the ABI, as the SDK's
# MIDL-generated C headers have it:
#   - an interface, delegate or runtime class crosses as a pointer to its
#     object
#   - a parameterised interface is a generic object instantiated with ABI
#     types (`ptr IVector[HSTRING]`)
#   - every method returns HRESULT, takes `this` first, and passes the declared
#     return as a trailing `retval: ptr T`; Windows.Foundation.HResult is
#     HRESULT
#   - a T[] parameter is `<name>Size: uint32, <name>: ptr T`, or, when the
#     callee allocates it (by-ref, or returned), `ptr uint32, ptr ptr T`
#
# Each reference is resolved to the name the plan gave its type (winrt/plan).
# A type this metadata does not define (another winmd's) cannot be spelled: it
# is none, and the vtable slot that uses it stays a `pointer`, which a slot is
# whatever it points to. A struct with a field of such a type has no known
# layout, and a runtime class with such a default interface no known object,
# so they are left out (declarable), and cannot be spelled either.

import std/[options, sequtils, sets, strutils, tables]
import ../[model, signatures, nameplan]
from ../reader import raiseWinmdError
import ./plan

const inheritedSlots = [
  "QueryInterface", "AddRef", "Release", "GetIids", "GetRuntimeClassName",
  "GetTrustLevel",
] ## IUnknown's and IInspectable's methods: the first slots of every vtable.

func named(name: string): AbiType =
  ## The type declared as `name`.
  AbiType(kind: akNamed, name: name)

func pointerTo(target: AbiType): AbiType =
  ## A pointer to `target`.
  AbiType(kind: akPointer, target: target)

func primitiveName(prim: Prim): string =
  ## What winrtbase or the system module calls a primitive.
  case prim
  of pvVoid:
    "void"
  of pvBoolean:
    "bool"
  of pvChar:
    "WCHAR" # winrtbase's uint16, as the SDK headers spell Char16
  of pvI1:
    "int8"
  of pvU1:
    "uint8"
  of pvI2:
    "int16"
  of pvU2:
    "uint16"
  of pvI4:
    "int32"
  of pvU4:
    "uint32"
  of pvI8:
    "int64"
  of pvU8:
    "uint64"
  of pvR4:
    "float32"
  of pvR8:
    "float64"
  of pvString:
    "HSTRING"
  of pvI:
    "int"
  of pvU:
    "uint"

func abiType*(n: Naming, t: SigType, params: seq[string]): Option[AbiType] =
  ## `t` on the ABI; `params` are the generic parameters in scope (for VAR).
  case t.base
  of bPrim:
    some(
      if t.prim == pvVoid:
        AbiType(kind: akVoid)
      else:
        named(primitiveName(t.prim))
    )
  of bNamed:
    if fullName(t) in remapped:
      let r = remapped[fullName(t)]
      some(
        if r.isObject:
          pointerTo(named(r.name))
        else:
          named(r.name)
      )
    else:
      let i = n.indexOf(t)
      if i.isNone:
        none(AbiType)
      elif n.names[i.get].isObject: # an object crosses as a pointer to it
        some(pointerTo(named(n.names[i.get].name)))
      else:
        some(named(n.names[i.get].name))
  of bGenericInst:
    let args = t.args.mapIt(abiType(n, it, params))
    let i = n.indexOf(t)
    if i.isNone or args.anyIt(it.isNone or it.get.kind == akVoid):
      none(AbiType)
    else:
      let definition = n.names[i.get].name
      some(
        pointerTo(
          AbiType(
            kind: akInstantiation, definition: definition, args: args.mapIt(it.get)
          )
        )
      )
  of bTypeVar:
    if t.isMethodVar or t.varIdx >= params.len:
      none(AbiType)
    else:
      some(named(params[t.varIdx]))
  of bPtr, bByRef:
    abiType(n, t.inner[], params).map(pointerTo)
  of bArray:
    let element = abiType(n, t.inner[], params)
    if element.isNone:
      none(AbiType)
    else:
      some(AbiType(kind: akArray, element: element.get, count: t.arrLen))
  of bSzArray:
    none(AbiType) # only a parameter or a return, where it is two (see slotParameters)

func slotParameters(
    n: Naming, generics: seq[string], name: string, ty: SigType, isRet: bool
): Option[seq[Parameter]] =
  ## The vtable parameters for `name: ty` in a method of a type with the
  ## generic parameters `generics`, their names not yet unique: an array is its
  ## size and a pointer to its first element, both by pointer when the callee
  ## allocates it; the return value is a trailing pointer. None when the type
  ## cannot be spelled.
  let calleeAllocates = isRet or ty.base == bByRef
  let arr = if ty.base == bByRef: ty.inner[] else: ty
  if arr.base == bSzArray:
    let element = abiType(n, arr.inner[], generics)
    if element.isNone or element.get.kind == akVoid:
      return none(seq[Parameter])
    let size = named("uint32")
    if calleeAllocates:
      return some(
        @[
          (name: name & "Size", ty: pointerTo(size)),
          (name: name, ty: pointerTo(pointerTo(element.get))),
        ]
      )
    return
      some(@[(name: name & "Size", ty: size), (name: name, ty: pointerTo(element.get))])
  let s = abiType(n, ty, generics)
  if s.isNone or s.get.kind == akVoid:
    none(seq[Parameter])
  else:
    some(
      @[
        (
          name: name,
          ty:
            if isRet:
              pointerTo(s.get)
            else:
              s.get,
        )
      ]
    )

func slots(n: Naming, t: ModelType, name: string): seq[VtableSlot] =
  ## The methods of interface or delegate `t`, declared as `name`, as its
  ## vtable holds them after IUnknown's and IInspectable's, each named uniquely
  ## among them and their parameters among each other.
  let generics = t.genericParameters
  let self =
    if generics.len > 0:
      AbiType(kind: akInstantiation, definition: name, args: generics.map(named))
    else:
      named(name)
  var slotNames = inheritedSlots.map(nimIdentNormalize).toHashSet
  for fn in t.methods:
    var parts =
      fn.params.mapIt(slotParameters(n, generics, it.nimName, it.ty, isRet = false))
    if not (fn.ret.base == bPrim and fn.ret.prim == pvVoid):
      parts.add slotParameters(n, generics, "retval", fn.ret, isRet = true)
    var parameters = none(seq[Parameter])
    if parts.allIt(it.isSome):
      var used = toHashSet(["this"])
      var list = @[(name: "this", ty: pointerTo(self))]
      for (name, ty) in parts.mapIt(it.get).concat:
        list.add (esc(used.freshIdent(name)), ty)
      parameters = some(list)
    result.add VtableSlot(
      name: esc(slotNames.freshIdent(fn.nimName)), parameters: parameters
    )

func isDeclarable(n: Naming, t: ModelType): bool =
  ## False for a struct with a field that cannot be spelled, its size unknown,
  ## and for a runtime class whose default interface cannot be, the object that
  ## crosses the ABI for it unknown.
  if t.kind in {tkStruct, tkHandle}:
    t.fields.allIt(abiType(n, it.ty, @[]).isSome)
  elif t.defaultInterface.isSome:
    abiType(n, t.defaultInterface.get, @[]).isSome
  else:
    true

func declarable*(m: Model): Model =
  ## `m` without the types it cannot declare: a struct with a field of a type it
  ## does not define, or a runtime class with such a default interface, then a
  ## struct with a field of such a struct, and so on.
  let kept = m.types.filterIt(references(m).isDeclarable(it))
  if kept.len == m.types.len:
    m
  else:
    declarable(Model(types: kept))

func declaration*(n: Naming, t: ModelType, names: TypeNames): Declaration =
  ## `t` as the output declares it under `names`, every reference in it
  ## resolved; what it mentions can be spelled (declarable).
  case t.kind
  of tkEnum, tkUnscopedEnum:
    Declaration(
      kind: dkEnum,
      name: names.name,
      isFlags: t.underlying.prim == pvU4, # WinRT makes every [Flags] enum UInt32
      members: names.enumMembers,
      underlying: abiType(n, t.underlying, @[]).get,
    )
  of tkStruct, tkHandle:
    var fieldNames: HashSet[string]
    var fields: seq[tuple[name: string, ty: AbiType]]
    for f in t.fields:
      fields.add (esc(fieldNames.freshIdent(f.nimName)), abiType(n, f.ty, @[]).get)
    Declaration(kind: dkStruct, name: names.name, fields: fields)
  of tkInterface, tkDelegate:
    if t.isClass:
      Declaration(
        kind: dkClass,
        name: names.name,
        className: fullName(t),
        classNameConst: names.classNameConst,
        # the object behind the pointer it crosses as: `IUriRuntimeClass`
        defaultInterface:
          if t.defaultInterface.isSome:
            some(abiType(n, t.defaultInterface.get, @[]).get.target)
          else:
            none(AbiType),
      )
    else:
      # without an IID, calls through it would ask for the wrong interface
      if t.guid.isNone:
        raiseWinmdError(fullName(t) & " is an interface or delegate with no IID")
      let kind: range[dkInterface .. dkDelegate] =
        if t.kind == tkDelegate: dkDelegate else: dkInterface
      Declaration(
        kind: kind,
        name: names.name,
        genericParameters: t.genericParameters,
        vtableName: names.vtableName,
        iidName: names.iidName,
        guid: t.guid.get,
        slots: slots(n, t, names.name),
      )
