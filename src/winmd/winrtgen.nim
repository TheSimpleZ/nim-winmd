# winrtgen.nim — the WinRT ABI modules of a Model read from WinRT metadata:
# the model is planned (winrt/plan), then rendered (winrt/render).

import std/[sequtils, sets, tables]
import ./[model, generator]
from ./reader import Winmd, TableId, rowCount, typeDef, isWindowsRuntime
import ./winrt/[plan, abitypes, iids, render]
export plan.Reference

func winrtTypes(m: Model): Model =
  ## `m`'s WinRT types, but the ones winrtbase spells.
  Model(types: m.types.filterIt(it.isWinRT and fullName(it) notin remapped))

func declaredAgainst(own, known: Model): seq[ModelType] =
  ## The types of `own` that can be declared, given the types of `known`.
  let names = own.types.mapIt(fullName(it)).toHashSet
  declarable(Model(types: own.types & known.types)).types.filterIt(
    fullName(it) in names
  )

func resolve(m: Model, refs: seq[Reference]): tuple[all: Model, n: Naming, own: int] =
  ## `m`'s declarable types, then every reference's, and the naming of them
  ## all: the first `own` are this output's, named here; a reference's are
  ## named as its own output named them, and spelled with its alias.
  var known: Model
  var knownNames: seq[TypeNames]
  for r in refs:
    # a reference was written against the references before it
    let kept = declaredAgainst(winrtTypes(r.model), known)
    let names = buildNaming(Model(types: kept)).names
    known.types.add kept
    for t in names:
      var q = t
      q.name = r.alias & "." & t.name
      knownNames.add q
  let kept = declaredAgainst(winrtTypes(m), known)
  var n = buildNaming(Model(types: kept))
  for i, t in known.types:
    n.names.add knownNames[i]
    discard n.byName.hasKeyOrPut(fullName(t), kept.len + i)
  (Model(types: kept & known.types), n, kept.len)

func buildPlan*(m: Model, refs: seq[Reference] = @[]): Plan =
  ## The plan of `m`'s WinRT types, but the remapped and undeclarable ones,
  ## naming those of `refs` rather than declaring them.
  let (all, n, own) = resolve(m, refs)
  let mine = Model(types: all.types[0 ..< own])
  let declarations = toSeq(0 ..< own).mapIt(n.declaration(all.types[it], n.names[it]))
  Plan(
    modules: n.placeModules(mine, declarations),
    instantiationIids: n.instanceIids(all, own),
    base:
      if refs.len > 0:
        refs[0].path
      else:
        "",
    qualified: refs.mapIt((it.alias, it.path)),
  )

proc isWinrtMetadata*(wa: Winmd): bool =
  ## True if a type of `wa` is a WinRT type.
  toSeq(0 ..< wa.rowCount(TypeDef)).anyIt(wa.typeDef(it).isWindowsRuntime)

func generateWinrtModules*(m: Model, refs: seq[Reference] = @[]): seq[GenModule] =
  ## The WinRT modules of `m`, over the bindings `refs`.
  renderModules(buildPlan(m, refs))
