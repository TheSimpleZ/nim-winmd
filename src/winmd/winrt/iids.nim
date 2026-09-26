# iids.nim — the IIDs no winmd carries: those of the instantiations of
# parameterised interfaces. An instantiation's IID is the version 5 UUID of
# its signature in the WinRT type system (`pinterface({piid};string)` for
# IVector<String>), and its constant is named after it (`IID_IVector_HSTRING`)
# rather than carried by its type: IVectorView<Uri> and
# IVectorView<IUriRuntimeClass> are one Nim type with two IIDs.

import std/[options, sequtils, strformat, strutils, tables]
import ../[guid, model, signatures, nameplan]
import ./[plan, abitypes]

const pinterfaceNamespace = parseGuid("11f47ad5-7b73-42c0-abae-878b1e16adee")
  ## The UUID namespace the Windows Runtime hashes instantiation signatures in.

func instanceIid(signature: string): Guid =
  ## The IID of the instantiation with `signature`.
  uuid5(pinterfaceNamespace, signature)

func iidSignature(g: Guid): string =
  ## How the WinRT type system writes an IID in a signature: in braces,
  ## `{96369f54-8eb6-48f0-abce-c1b211e627c3}`.
  "{" & $g & "}"

func signature(n: Naming, m: Model, t: SigType): string =
  ## The WinRT type system's signature of `t`: `i4`, `string`, `{iid}`,
  ## `enum(Name;u4)`, `struct(Name;field;...)`, `rc(Name;default interface)`,
  ## `pinterface({piid};arg;...)`; "" for one that cannot be spelled.
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
      elif d.defaultInterface.isNone: # a static class, which has no instances
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
  ## True if `t` mentions a generic parameter (VAR or MVAR) anywhere.
  t.base == bTypeVar or t.args.anyIt(hasTypeVar(it)) or
    (t.inner != nil and hasTypeVar(t.inner[]))

func substitute(t: SigType, args: seq[SigType]): SigType =
  ## `t` with the type variables of a generic definition replaced by `args`.
  if t.base == bTypeVar and not t.isMethodVar and t.varIdx < args.len:
    return args[t.varIdx]
  result = t
  result.args = t.args.mapIt(substitute(it, args))
  if t.inner != nil:
    result.inner = new(SigType)
    result.inner[] = substitute(t.inner[], args)

func instantiations(n: Naming, m: Model): OrderedTable[string, SigType] =
  ## Every instantiation the metadata uses (by signature), with the ones its
  ## generic definition implies: IVector<String> requires IIterable<String>,
  ## and its GetView returns IVectorView<String>.
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
  ## How an instantiation's IID constant spells `t`, pointers left out:
  ## `HSTRING`, `IInspectable`, `Uri`, `IKeyValuePair_HSTRING_HSTRING`.
  case t.kind
  of akNamed:
    t.name
  of akPointer:
    argumentName(t.target)
  of akInstantiation:
    t.definition & "_" & t.args.map(argumentName).join("_")
  of akVoid, akArray:
    "" # not the argument of an instantiation

func instanceIids*(n: Naming, m: Model): seq[tuple[name: string, iid: Guid]] =
  ## The IID of every instantiation the metadata uses, with its constant's
  ## name (`IID_IVector_HSTRING`), unique among the names the naming gave out.
  var taken = n.usedNames
  for sig, t in instantiations(n, m):
    # an instantiation with a signature has every argument spelled
    let name = argumentName(abiType(n, t, @[]).get)
    result.add (taken.freshIdent("IID_" & name), instanceIid(sig))
