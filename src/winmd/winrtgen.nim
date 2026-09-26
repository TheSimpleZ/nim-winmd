# winrtgen.nim — emits the Nim modules for the Windows Runtime ABI of a
# Model built from WinRT metadata (Windows.winmd): what a call is on the
# wire, as the SDK's MIDL-generated C headers spell it.
#
# It plans the output from the model (winrt/plan, with winrt/abitypes and
# winrt/iids), then renders the plan as Nim (winrt/render), which never sees
# the model.
#
# Modules:
#   winrtbase    GUID, HRESULT, HSTRING, IUnknown and IInspectable, with their
#                vtables and IIDs: what no winmd declares (winrt/winrtbase.nim,
#                written out as it is)
#   winrttypes   every enum, and every struct that mentions no interface
#   winrtgenerics
#                the IIDs of the instantiations the metadata uses (winrt/iids)
#   <namespace>  its interfaces and delegates, each an object whose `lpVtbl`
#                points to its vtable, both in one type section; its runtime
#                classes as aliases of their default interface; the structs
#                that mention an interface; the IID of each interface and its
#                runtime class names (foundation, ...: the namespace without
#                its `Windows` root); namespaces that refer to each other in a
#                cycle share one (winrt/plan)
#
# Every IID is a `GUID` constant named after its type, as the SDK headers
# declare them, and written as text that winrtbase's `guid` turns into a GUID
# at compile time: `IID_IStringable*: GUID = guid"96369f54-..."` for an
# interface or delegate, `IID_IVector` for a parameterised one (its PIID),
# `IID_IVector_HSTRING` for an instantiation. A runtime class has none, and
# answers for its default interface's. An enum is a distinct type over its
# integer (int32, or uint32 for [Flags]), its members `Enum_Member` consts, as
# windows-rs has them: it holds any value Windows returns (a combination of
# flags, or a member newer than the metadata) and is not mistaken for another
# enum. It borrows `==` and `$` from its integer, and a [Flags] enum `or`,
# `and` and `not`, with `contains` to test for a member. How a type crosses
# the ABI is winrt/abitypes'; how Nim spells it, winrt/render's.
#
# Names go through `freshIdent`, as in the Win32 generator. The output is
# types, aliases and consts, and the operations enums borrow (and winrtbase's
# `guid`); what reads an IID off a type, or wraps a runtime class, belongs to
# a library on top.

import std/[sequtils, tables]
import ./[model, generator]
from ./reader import Winmd, TableId, rowCount, typeDef
import ./winrt/[plan, abitypes, iids, render]

func buildPlan*(m: Model): Plan =
  ## What the text is written from: each WinRT type of `m` named, then
  ## declared with every reference resolved, then placed in its module, and
  ## the IIDs of the instantiations. Left out: a type without the
  ## WindowsRuntime flag (a classic COM interface), as a type of another winmd
  ## is; a type spelled with winrtbase's (`remapped`); and a type that cannot
  ## be declared without one of another winmd (`declarable`).
  let winrt = declarable(
    Model(types: m.types.filterIt(it.isWinRT and fullName(it) notin remapped))
  )
  let n = buildNaming(winrt)
  let declarations =
    toSeq(0 ..< winrt.types.len).mapIt(n.declaration(winrt.types[it], n.names[it]))
  Plan(
    modules: n.placeModules(winrt, declarations),
    instantiationIids: n.instanceIids(winrt),
  )

proc isWinrtMetadata*(wa: Winmd): bool =
  ## True if `wa` is WinRT metadata: a type of it carries the WindowsRuntime
  ## flag (TypeAttributes 0x4000), even one the model leaves out (the
  ## ApiContract struct that is all of a contract's own winmd).
  toSeq(0 ..< wa.rowCount(TypeDef)).anyIt((wa.typeDef(it).flags and 0x4000) != 0)

func generateWinrtModules*(m: Model): seq[GenModule] =
  ## winrtbase, winrtgenerics, and the modules of the plan: winrttypes, and one
  ## per namespace with an interface, delegate or runtime class (per group of
  ## them, and a module per namespace of the group that re-exports it).
  renderModules(buildPlan(m))
