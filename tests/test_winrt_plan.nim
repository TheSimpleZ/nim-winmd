# test_winrt_plan.nim — the WinRT plan of models built by hand rather than
# read from metadata, for what no metadata at hand exercises: names that
# clash, types that cannot be declared, structs that move, and the names and
# IIDs of instantiations (doAssert-based).
# Run: nim r --verbosity:0 tests/test_winrt_plan.nim  (or `nimble test`)

import std/[algorithm, options, sequtils, strformat]
import ../src/winmd/[reader, signatures, model, guid, winrtgen]
import ../src/winmd/winrt/[plan, abitypes]

const boxIid = "913337e9-11a1-4345-a3a2-4e7f956e222d"

func prim(p: Prim): SigType =
  ## The primitive `p`.
  SigType(base: bPrim, prim: p)

func named(ns, name: string): SigType =
  ## A reference to the type `ns.name`.
  SigType(base: bNamed, ns: ns, name: name, rowIdx: -1)

func instance(name: string, args: varargs[SigType]): SigType =
  ## An instantiation of the parameterised interface `A.name`.
  SigType(base: bGenericInst, ns: "A", name: name, rowIdx: -1, args: @args)

func szArray(element: SigType): SigType =
  ## An array of `element`s of any length.
  result = SigType(base: bSzArray, inner: new(SigType))
  result.inner[] = element

func fn(name: string, ret: SigType, params: varargs[(string, SigType)]): ModelFn =
  ## A method `name` returning `ret`, with `params`.
  ModelFn(
    name: name,
    nimName: name,
    ret: ret,
    params: params.mapIt(ModelParam(name: it[0], nimName: fixIdent(it[0]), ty: it[1])),
  )

func interfaceType(
    name: string,
    methods: seq[ModelFn] = @[],
    ns = "A",
    isWinRT = true,
    generics: seq[string] = @[],
): ModelType =
  ## An interface with `methods`, with an IID when it is WinRT.
  ModelType(
    kind: tkInterface,
    ns: ns,
    name: name,
    isWinRT: isWinRT,
    guid:
      if isWinRT:
        some(parseGuid(boxIid))
      else:
        none(Guid),
    methods: methods,
    genericParameters: generics,
  )

func classType(name: string, default: Option[SigType]): ModelType =
  ## A runtime class of namespace A, static when it has no `default` interface.
  ModelType(
    kind: tkInterface,
    ns: "A",
    name: name,
    isWinRT: true,
    isClass: true,
    defaultInterface: default,
  )

func structType(name: string, fields: varargs[SigType]): ModelType =
  ## A WinRT struct of namespace A with `fields`, named F1, F2, ...
  ModelType(
    kind: tkStruct,
    ns: "A",
    name: name,
    isWinRT: true,
    fields: toSeq(fields.pairs).mapIt(
        ModelField(name: fmt"F{it[0] + 1}", nimName: fmt"F{it[0] + 1}", ty: it[1])
      ),
  )

func declarationOf(p: Plan, name: string): Declaration =
  ## The declaration of the type `p` names `name`.
  p.modules.mapIt(it.declarations).concat.filterIt(it.name == name)[0]

func declared(k: Module): seq[string] =
  ## The names of what module `k` declares.
  k.declarations.mapIt(it.name)

# --- names ---

# a metadata name is never taken by a suffixed duplicate: Nim reads IFoo_2 as
# IFoo2, so B.IFoo, which comes before A.IFoo2, is named after it
let clash = buildNaming(
  Model(
    types:
      @[interfaceType("IFoo"), interfaceType("IFoo", ns = "B"), interfaceType("IFoo2")]
  )
)
doAssert clash.names.mapIt(it.name) == @["IFoo", "IFoo_3", "IFoo2"]

# a vtable's slots and parameters are named apart: from IUnknown's and
# IInspectable's slots, from `this`, from the `Size` an array adds and the
# `retval` a return adds, and from Nim's keywords; a Char16 is a WCHAR
let collisions = buildPlan(
  Model(
    types: @[
      interfaceType(
        "IColl",
        @[
          fn("Release", prim(pvVoid)),
          fn("Get", prim(pvI4), ("this", prim(pvI4))),
          fn(
            "Put",
            prim(pvVoid),
            ("value", szArray(prim(pvU1))),
            ("valueSize", prim(pvU4)),
          ),
          fn("Take", prim(pvI4), ("retval", prim(pvI4))),
          fn("Keyword", prim(pvVoid), ("type", prim(pvChar))),
        ],
      )
    ]
  )
)
let slots = collisions.declarationOf("IColl").slots
doAssert slots.mapIt(it.name) == @["Release_2", "Get", "Put", "Take", "Keyword"]
doAssert slots.mapIt(it.parameters.get.mapIt(it.name)) ==
  @[
    @["this"],
    @["this", "this_2", "retval"],
    @["this", "valueSize", "value", "valueSize_2"],
    @["this", "retval", "retval_2"],
    @["this", "`type`"],
  ]
doAssert slots[4].parameters.get[1].ty.name == "WCHAR"

# --- what is declared ---

# a struct with a field of a type the metadata does not define has no known
# layout, and a runtime class with such a default interface no known object:
# both are left out, and so is a struct with a field of the one left out; a
# static class, which has no default interface, stays
let partial = declarable(
  Model(
    types: @[
      structType("Missing", named("Other", "Rect")),
      structType("Outer", named("A", "Missing")),
      structType("Point", prim(pvR4), prim(pvR4)),
      classType("Hollow", some(named("Other", "IAsyncAction"))),
      classType("Static", none(SigType)),
      interfaceType("IReal"),
      classType("Real", some(named("A", "IReal"))),
    ]
  )
)
doAssert partial.types.mapIt(it.name) == @["Point", "Static", "IReal", "Real"]

# what mentions a type left out cannot be spelled: its slot is a bare pointer
let hollow = buildPlan(
  Model(
    types: @[
      classType("Hollow", some(named("Other", "IAsyncAction"))),
      interfaceType("IUser", @[fn("GetHollow", named("A", "Hollow"))]),
    ]
  )
)
doAssert hollow.declarationOf("IUser").slots[0].parameters.isNone

# a classic COM interface is not WinRT, and left out; a WinRT one with no IID
# is an error, not a runtime class
doAssert buildPlan(Model(types: @[interfaceType("IClassic", isWinRT = false)])).modules
  .allIt(it.declarations.len == 0)
var noIid = interfaceType("INoIid")
noIid.guid = none(Guid)
doAssertRaises(WinmdError):
  discard buildPlan(Model(types: @[noIid]))

# Windows.Foundation.HResult is spelled HRESULT: the struct is not declared
var hresultStruct = structType("HResult", prim(pvI4))
hresultStruct.ns = "Windows.Foundation"
let hresult = buildPlan(
  Model(
    types:
      @[hresultStruct, structType("Status", named("Windows.Foundation", "HResult"))]
  )
)
doAssert hresult.modules[0].declared == @["Status"]
doAssert hresult.declarationOf("Status").fields[0].ty.name == "HRESULT"

# --- where it is declared ---

# a struct that mentions an interface moves beside the interfaces, and then so
# does a struct that mentions a moved one; the others stay in winrttypes
let moved = buildPlan(
  Model(
    types: @[
      interfaceType("IThing"),
      structType("Holder", named("A", "IThing")),
      structType("Nested", named("A", "Holder")),
      structType("Plain", prim(pvI4)),
    ]
  )
)
doAssert moved.modules.mapIt(it.name) == @["winrttypes", "a"]
doAssert moved.modules[0].declared == @["Plain"]
doAssert moved.modules[1].declared == @["IThing", "Holder", "Nested"]

# --- instantiations ---

# each instantiation's IID is named after its arguments as Nim spells them, a
# Char16 (WCHAR) apart from a UInt16, and named apart from the metadata's
# names; its GUID is the version 5 UUID of its signature, a remapped
# argument's included
let pinterface = parseGuid("11f47ad5-7b73-42c0-abae-878b1e16adee")
let box = interfaceType("IBox`1", generics = @["T"])
let user = interfaceType(
  "IUser",
  @[
    fn("GetChar", instance("IBox`1", prim(pvChar))),
    fn("GetWord", instance("IBox`1", prim(pvU2))),
    fn("GetInt", instance("IBox`1", prim(pvI4))),
    fn("GetResult", instance("IBox`1", named("Windows.Foundation", "HResult"))),
  ],
)
let iids = buildPlan(Model(types: @[box, user, interfaceType("IID_IBox_int32")])).instantiationIids
doAssert iids.mapIt(it.name).sorted ==
  @["IID_IBox_HRESULT", "IID_IBox_WCHAR", "IID_IBox_int32_2", "IID_IBox_uint16"]
for (name, argument) in [
  ("IID_IBox_WCHAR", "c2"),
  ("IID_IBox_uint16", "u2"),
  ("IID_IBox_int32_2", "i4"),
  ("IID_IBox_HRESULT", "struct(Windows.Foundation.HResult;i4)"),
]:
  let iid = iids.filterIt(it.name == name)[0].iid
  doAssert iid == uuid5(pinterface, &"pinterface({{{boxIid}}};{argument})")

echo "test_winrt_plan: all assertions passed"
