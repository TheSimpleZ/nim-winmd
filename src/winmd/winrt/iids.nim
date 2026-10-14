# iids.nim — the IIDs of instantiations (`IVector<String>`), which no winmd carries.

import std/[options, sequtils, strformat, strutils, tables]
import ../[guid, model, signatures, nameplan]
import ./[plan, abitypes]

const pinterfaceNamespace = parseGuid("11f47ad5-7b73-42c0-abae-878b1e16adee")
  ## The namespace instantiation signatures are hashed in.

func instanceIid(signature: string): Guid =
  ## The IID of the instantiation with `signature`.
  uuid5(pinterfaceNamespace, signature)

func iidSignature(g: Guid): string =
  ## `{96369f54-8eb6-48f0-abce-c1b211e627c3}`
  "{" & $g & "}"

func signature(n: Naming, m: Model, t: SigType): string =
  ## The WinRT type signature of `t` (`pinterface({piid};string)`); "" if unknown.
  case t.base
  of bPrim:
    case t.prim
    of pvBoolean: "b1"
    of pvChar: "c2"
    of pvI1: "i1"
    of pvU1: "u1"
    of pvI2: "i2"
    of pvU2: "u2"
    of pvI4: "i4"
    of pvU4: "u4"
    of pvI8: "i8"
    of pvU8: "u8"
    of pvR4: "f4"
    of pvR8: "f8"
    of pvString: "string"
    of pvVoid, pvI, pvU: ""
  of bNamed:
    let name = fullName(t)
    if name in remapped:
      return remapped[name].signature
    let i = n.indexOf(t)
    if i.isNone:
      return ""
    let d = m.types[i.get]
    case d.kind
    of tkEnum, tkUnscopedEnum:
      let backing = if d.underlying.prim == pvU4: "u4" else: "i4"
      fmt"enum({name};{backing})"
    of tkStruct:
      let fields = d.fields.mapIt(signature(n, m, it.ty))
      let list = fields.join(";")
      if "" in fields:
        ""
      else:
        fmt"struct({name};{list})"
    of tkDelegate:
      fmt"delegate({iidSignature(d.guid.get)})"
    of tkInterface:
      if not d.isClass:
        iidSignature(d.guid.get)
      elif d.defaultInterface.isNone: # a static class
        ""
      else:
        fmt"rc({name};{signature(n, m, d.defaultInterface.get)})"
    else:
      ""
  of bGenericInst:
    let args = t.args.mapIt(signature(n, m, it))
    let i = n.indexOf(t)
    if i.isNone or "" in args:
      return ""
    let piid = iidSignature(m.types[i.get].guid.get)
    let list = args.join(";")
    fmt"pinterface({piid};{list})"
  else:
    ""

func hasTypeVar(t: SigType): bool =
  ## True if `t` mentions a generic parameter.
  t.base == bTypeVar or t.args.anyIt(hasTypeVar(it)) or
    (t.inner != nil and hasTypeVar(t.inner[]))

func substitute(t: SigType, args: seq[SigType]): SigType =
  ## `t` with its type variables replaced by `args`.
  if t.base == bTypeVar and not t.isMethodVar and t.varIdx < args.len:
    return args[t.varIdx]
  result = t
  result.args = t.args.mapIt(substitute(it, args))
  if t.inner != nil:
    result.inner = new(SigType)
    result.inner[] = substitute(t.inner[], args)

func instantiations(n: Naming, m: Model): OrderedTable[string, SigType] =
  ## Every instantiation the metadata uses or implies, by signature.
  var pending: seq[SigType]
  for t in m.types:
    pending.add t.interfaces
    pending.add t.fields.mapIt(it.ty)
    for fn in t.methods:
      pending.add fn.ret
      pending.add fn.params.mapIt(it.ty)
  while pending.len > 0:
    let t = pending.pop()
    if t.inner != nil:
      pending.add t.inner[]
    if t.base != bGenericInst:
      continue
    pending.add t.args
    let sig =
      if hasTypeVar(t):
        ""
      else:
        signature(n, m, t)
    if sig.len == 0 or sig in result:
      continue
    result[sig] = t
    let d = m.types[n.indexOf(t).get]
    pending.add d.interfaces.mapIt(substitute(it, t.args))
    for fn in d.methods:
      pending.add substitute(fn.ret, t.args)
      pending.add fn.params.mapIt(substitute(it.ty, t.args))

func argumentName(t: AbiType): string =
  ## `t` in an IID's name: `HSTRING`, `IKeyValuePair_HSTRING_HSTRING`.
  case t.kind
  of akNamed:
    t.name
  of akPointer:
    argumentName(t.target)
  of akInstantiation:
    t.definition & "_" & t.args.map(argumentName).join("_")
  of akVoid, akArray:
    ""

func instanceIids*(n: Naming, m: Model): seq[tuple[name: string, iid: Guid]] =
  ## Every instantiation's IID and its name (`IID_IVector_HSTRING`).
  var taken = n.usedNames
  for sig, t in instantiations(n, m):
    let name = argumentName(abiType(n, t, @[]).get)
    result.add (taken.freshIdent("IID_" & name), instanceIid(sig))
