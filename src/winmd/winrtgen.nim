# winrtgen.nim — the WinRT ABI modules of a Model read from WinRT metadata:
# the model is planned (winrt/plan), then rendered (winrt/render).

import std/[sequtils, tables]
import ./[model, generator]
from ./reader import Winmd, TableId, rowCount, typeDef, isWindowsRuntime
import ./winrt/[plan, abitypes, iids, render]

func buildPlan*(m: Model): Plan =
  ## The plan of `m`'s WinRT types, but the remapped and undeclarable ones.
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
  ## True if a type of `wa` is a WinRT type.
  toSeq(0 ..< wa.rowCount(TypeDef)).anyIt(wa.typeDef(it).isWindowsRuntime)

func generateWinrtModules*(m: Model): seq[GenModule] =
  ## The WinRT modules of `m`.
  renderModules(buildPlan(m))
