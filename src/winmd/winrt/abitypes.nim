# abitypes.nim — how a WinRT type crosses the ABI, as the SDK's C headers have it.

import std/[options, sequtils, sets, strutils, tables]
import ../[model, signatures, nameplan]
from ../reader import raiseWinmdError
import ./plan

const inheritedSlots = [
  "QueryInterface", "AddRef", "Release", "GetIids", "GetRuntimeClassName",
  "GetTrustLevel",
] ## The first slots of every vtable.

func named(name: string): AbiType =
  ## The type named `name`.
  AbiType(kind: akNamed, name: name)

func pointerTo(target: AbiType): AbiType =
  ## A pointer to `target`.
  AbiType(kind: akPointer, target: target)

func primitiveName(prim: Prim): string =
  ## The Nim name of a primitive.
  case prim
  of pvVoid:
    "void"
  of pvBoolean:
    "bool"
  of pvChar:
    "WCHAR" # as in the SDK headers
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
  ## `t` on the ABI, with generic parameters `params`; none if it cannot be spelled.
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
      elif n.names[i.get].isObject:
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
    none(AbiType) # two parameters (slotParameters)

func slotParameters(
    n: Naming, generics: seq[string], name: string, ty: SigType, isRet: bool
): Option[seq[Parameter]] =
  ## The vtable parameters for `name: ty`: an array is a size and a pointer
  ## (both by pointer when the callee allocates it), a return a trailing pointer.
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
  ## The vtable slots of interface or delegate `t`, emitted as `name`.
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
  ## False for a struct or runtime class that needs a type it cannot spell.
  if t.kind in {tkStruct, tkHandle}:
    t.fields.allIt(abiType(n, it.ty, @[]).isSome)
  elif t.defaultInterface.isSome:
    abiType(n, t.defaultInterface.get, @[]).isSome
  else:
    true

func declarable*(m: Model): Model =
  ## `m` without the types that need another winmd's, transitively.
  let n = references(m)
  let kept = m.types.filterIt(n.isDeclarable(it))
  if kept.len == m.types.len:
    m
  else:
    declarable(Model(types: kept))

func declaration*(n: Naming, t: ModelType, names: TypeNames): Declaration =
  ## `t` as the output declares it (`t` is declarable).
  case t.kind
  of tkEnum, tkUnscopedEnum:
    Declaration(
      kind: dkEnum,
      name: names.name,
      isFlags: t.underlying.prim == pvU4, # every [Flags] enum is UInt32
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
        defaultInterface:
          if t.defaultInterface.isSome:
            some(abiType(n, t.defaultInterface.get, @[]).get.target)
          else:
            none(AbiType),
      )
    else:
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
