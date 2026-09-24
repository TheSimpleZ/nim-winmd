# generator.nim — emits the Nim modules for a Model: one module per
# defining header (when the provenance map knows the name), one per
# export DLL for the rest, plus win32base for what has no owner.
#
# Per-module layout:
#   1. header comment
#   2. one list import (+ re-export) of the modules it depends on
#   3. opaque stubs for named types referenced in signatures but not
#      defined in this winmd (a stub referenced by several modules
#      lives in the earliest one)
#   4. one `type` section: handles (plain aliases), enums (scoped as real
#      enums; unscoped as an alias of the backing integer), structs
#      (objects), delegates (proc types), interfaces (opaque objects);
#      architecture-split names get selector aliases between two type
#      zones (types referencing them come after the aliases)
#   5. file-level pragmas: `{.pragma: mdmethod, sideEffect.}` bundles
#      the pragmas shared by all of the module's functions; mdtype
#      (which includes completeStruct, part of every struct) and
#      mdalias cover the structs (objects, incl. opaque stubs) and
#      the aliases (handles, enums, unscoped enums, delegates)
#      respectively, and mdinterface the interfaces — a struct emits
#      only its per-struct pragmas (union / packed) plus mdtype. With
#      --headers, a `when defined(checkAbi) or defined(mdheaders):`
#      block defines `{.pragma: mdheader, header: "stem.h".}` (empty in
#      the else branch) for the module's defining header, and
#      mdmethod/mdtype/mdalias/mdinterface include mdheader; a header
#      that cannot be included directly in the C file (noDirectInclude,
#      e.g. winnt.h) is replaced by headerIncludeOverride (winnt ->
#      windef) or gets no mdheader at all
#   6. `const` section: free constants + unscoped-enum members
#   7. functions: each proc sits in its owning module, sorted by DLL
#      then name; one `{.push dynlib: "x".} ...` `{.pop.}` pair per DLL
#      (a single header module may span several export DLLs, so the
#      dynlib never moves into the file-level pragmas); the dynlib name
#      is lowercased with the .dll suffix stripped; the importc pragma
#      is bare when the emitted name is exactly the C name, and spelled
#      when --lowercase lowercases the first letter; every fn uses
#      mdmethod
#   8. curated aliases: the LPSTR/PSTR family -> cstring, the wide
#      variants -> ptr UncheckedArray[uint16]; redundant A-suffix
#      aliases (X with X & "A" == target) are not emitted, references
#      resolve to the target
#
# Dependency scanning: every emitted symbol's type references (struct
# fields, handle pointees, fn signatures, const types) yield an edge
# owner(referencing) -> owner(referenced); suppressed aliases and severed
# edges (rendered opaquely) contribute none. Owners come from the
# provenance map (header modules), the referencing DLL as fallback, and
# win32base — closed under references — for the rest. The import graph
# must stay acyclic: every back edge is broken by base-ifying the
# smaller reference closure (the referenced type, or the one that
# references it), then re-closing, until no cycles remain.
#
# Name hygiene: every top-level name goes through `freshName`, which keeps
# the first occurrence and suffixes later duplicates with `_2`, `_3`, ...
# so the output is always valid Nim. Escaping uses backticks for Nim
# keywords / digit-leading names.
#
# The naming phase (emitted names, stubs, arch variants, suppressed
# aliases, name-level reference data) lives in nameplan.nim and produces
# the NamePlan this file lays out and renders.

import std/[strutils, algorithm, sets, tables]
import ./[model, signatures, nameplan]

type GenCtx = object
  text: string
  typeHdr: Table[string, string] # symbol name -> defining header stem

  lowerFirst: bool
    # the --lowercase option: lowercase the first letter
    # of emitted function names (Nim convention); off by default, the
    # importc pragma keeps the real linkage name either way

proc line(c: var GenCtx, s: string) =
  c.text.add s
  c.text.add '\n'

proc renderPragma(pragmas: openArray[string]): string =
  if pragmas.len > 0:
    " {." & pragmas.join(", ") & ".}"
  else:
    ""

## `defined(...)` condition covering an entry's arch set (for the
## `when` blocks of arch-tagged constants).
proc archCond(archs: set[Architecture]): string =
  for arch in archs:
    if result.len > 0:
      result.add " or "

    result.add "defined(" & $arch & ")"

# Headers that cannot be included directly in the generated C file
# (their preprocessor state clashes with the Nim runtime C file). Keep
# the list short; for each, headerIncludeOverride names the replacement
# header to include instead ("" = no header pragma at all).
const noDirectInclude = @["winnt"]

## The header to include instead of a header in noDirectInclude
## (winnt.h -> windef.h); "" when there is no replacement.
proc headerIncludeOverride(stem: string): string =
  case stem
  of "winnt": "minwindef"
  else: ""

# ---------------------------------------------------------------------------
# generate
# ---------------------------------------------------------------------------

type
  GenModule* = object
    name*: string # module name without the .nim extension
    code*: string

  FnModule = tuple[dll: string, modName: string, code: string]

## DFS over the module dependency graph; records every back edge.
## Every cycle contains at least one DFS back edge, so base-ifying the
## referenced types of all of them breaks every cycle in one batch
## (breaking one cycle per pass is far too slow for ~600 modules).
## Returns false with empty outEdges when the graph is a DAG.
# a back edge plus the tree edges from its target up to its source
# (the cycle it closes)
type CycleEdge* =
  tuple[
    to: int,
    refName: string,
    srcName: string,
    pathSrc: seq[string],
    pathRef: seq[string],
  ]

proc allBackEdges(
    n: int,
    adj: seq[seq[tuple[to: int, refName: string, srcName: string]]],
    outEdges: var seq[CycleEdge],
): bool =
  var edges: seq[CycleEdge]
  var color = newSeq[int](n)
  var stack: seq[int]
  proc dfs(u: int) =
    color[u] = 1
    stack.add u
    for e in adj[u]:
      if color[e.to] == 1:
        # cycle: e plus the tree path from e.to up to u
        var ps: seq[string]
        var pr: seq[string]
        var k = stack.len - 1
        while stack[k] != e.to:
          # collect the tree edge stack[k-1] -> stack[k]
          for e2 in adj[stack[k - 1]]:
            if e2.to == stack[k]:
              ps.add e2.srcName
              pr.add e2.refName
              break
          dec k
        edges.add (e.to, e.refName, e.srcName, ps, pr)
      elif color[e.to] == 0:
        dfs(e.to)
    stack.del(stack.len - 1)
    color[u] = 2

  for i in 0 ..< n:
    if color[i] == 0:
      dfs(i)
  outEdges = edges
  edges.len > 0

## The module identifier of a (possibly path-shaped) module name:
## windows/win32 -> win32 (path imports bind the last segment)
proc modStem(nm: string): string =
  let i = nm.rfind('/')
  if i >= 0:
    nm[i + 1 .. nm.high]
  else:
    nm

## Sanitize a DLL file name into a Nim module name:
## KERNEL32.dll -> kernel32, WINSPOOL.DRV -> winspool, WS2_32.dll -> ws2_32
proc dllModuleName(dll: string): string =
  var s = dll.toLower()
  if s.endsWith(".dll"):
    s = s[0 ..< s.len - 4]

  s

proc generateCore(
    m: Model, typeHdr: Table[string, string], emitHeaders: bool, lowerFirst: bool
): tuple[base: string, mods: seq[FnModule], baseEmitted: bool] =
  # ---- naming phase (nameplan.nim) ----------------------------------------
  # emitted names, stubs, arch variants, suppressed aliases and the
  # name-level reference data, computed from the Model alone
  var c = GenCtx(typeHdr: typeHdr)
  var np = buildNamePlan(m) # TODO make let

  # ---- module ownership -----------------------------------------------------
  # module keys: every export DLL (order of first appearance of its
  # functions), plus one per defining header (created lazily by
  # headerOwnerKey). moduleIdx is filled from fnOwner below.
  var moduleOrder: seq[string]
  var moduleIdx: Table[string, seq[int]]
  for i in 0 ..< m.fns.len:
    let dn =
      if m.fns[i].moduleName.len > 0:
        m.fns[i].moduleName
      else:
        "misc"
    if dn notin moduleIdx:
      moduleIdx[dn] = @[]
      moduleOrder.add dn
  var modulePos: Table[string, int]
  for k in 0 ..< moduleOrder.len:
    modulePos[moduleOrder[k]] = k

  # sanitized module names (parallel to moduleOrder), collision-suffixed
  var dllNames: seq[string]
  var usedDll: HashSet[string]
  for dn in moduleOrder:
    var sn = dllModuleName(dn)
    if sn.len == 0 or sn == "win32" or sn == "win32base":
      sn = sn & "_m"
    dllNames.add usedDll.freshIdent(sn)

  # header provenance: typeHdr maps raw winmd names to the stem of the
  # SDK header that declares them (data/type_headers.txt, derived from the
  # per-header RDL snapshot that Windows.Win32.winmd was compiled from).
  # A stem that sanitizes to an existing DLL module name merges into that
  # module (header d3d11 + DLL d3d11.dll -> one file); every other stem
  # becomes its own module, created lazily.
  var hdrKeyCache: Table[string, string]
  # every header stem that occurs in the map (to detect numbered
  # km-merge header variants: d2d1_1 only merges into d2d1 when d2d1
  # is itself a mapped header)
  var hdrStems: Table[string, bool]
  for (k, v) in typeHdr.pairs:
    hdrStems[v] = true
  # DLL stems exported by the winmd (lowercase, suffix stripped):
  # a numbered header stem that matches one (d3d10_1.dll) is a real
  # SDK header, not a snapshot split
  var dllStems: Table[string, bool]
  for f in m.fns:
    if f.moduleName.len > 0:
      let dot = f.moduleName.rfind('.')
      let ds =
        if dot >= 0:
          f.moduleName[0 ..< dot]
        else:
          f.moduleName
      dllStems[ds.toLower()] = true

  proc headerOwnerKey(stem: string): string =
    if stem in hdrKeyCache:
      return hdrKeyCache[stem]

    # numbered km-merge header variants (d2d1_1.rdl, d3d11_2.rdl, ...)
    # are snapshot splits of the parent header: when the parent stem is
    # itself mapped AND no DLL named after the variant exists in the
    # winmd (d3d10_1.dll is real), merge into the parent's module.
    # Stems with no mapped parent (dxgi1_2, bits1_5, ...) keep their
    # own module.
    var s = stem
    if s notin dllStems:
      var i2 = s.len - 1
      while i2 >= 0 and s[i2] in '0' .. '9':
        dec i2
      if i2 >= 1 and s[i2] == '_':
        let base = s[0 ..< i2]
        if base in hdrStems:
          s = base

    var sn = dllModuleName(s)
    if sn.len == 0 or sn == "win32" or sn == "win32base":
      sn = sn & "_m"
    var found = ""
    for k in 0 ..< moduleOrder.len:
      if dllNames[k] == sn:
        found = moduleOrder[k]
    if found.len > 0:
      result = found
    else:
      moduleOrder.add s
      modulePos[s] = moduleOrder.len - 1
      moduleIdx[s] = @[]
      dllNames.add usedDll.freshIdent(sn)
      result = s
    hdrKeyCache[stem] = result

  # function ownership: the defining header if the provenance map knows
  # the name, else the export DLL module (every function has an ImplMap,
  # so this always resolves to a real module)
  var fnOwner: seq[string] = newSeq[string](m.fns.len)
  for i in 0 ..< m.fns.len:
    let n = m.fns[i].name
    if n in typeHdr:
      fnOwner[i] = headerOwnerKey(typeHdr[n])
    else:
      fnOwner[i] =
        if m.fns[i].moduleName.len > 0:
          m.fns[i].moduleName
        else:
          "misc"
  # functions live in their owning module (not the DLL module): fill
  # moduleIdx from fnOwner
  for i in 0 ..< m.fns.len:
    moduleIdx[fnOwner[i]].add i

  # ---- arch variants (fns) ----------------------------------------------
  # A fn name whose duplicate winmd rows each carry a distinct, non-empty
  # SupportedArchitectureAttribute is a per-arch variant (like the type
  # rows): the rows are emitted as one `when defined(...)` block with one
  # declaration per arch set under a shared name. The rows of a split name
  # must share a module and a DLL (so the block sits inside one dynlib
  # group); otherwise they fall back to the usual dedup suffix.
  var fnNameRows: Table[string, seq[int]]
  for i in 0 ..< m.fns.len:
    fnNameRows.mGetOrPut(m.fns[i].name).add i
  var fnSplitFirst: Table[int, seq[int]] # group's first row -> all rows
  var fnSplitSkip: HashSet[int] # the group's remaining rows
  for nm in fnNameRows.keys:
    var rows = fnNameRows[nm]
    if rows.len < 2:
      continue
    var ok = true
    for i in 0 ..< rows.len:
      # every row must carry a distinct, non-empty arch set
      if m.fns[rows[i]].arch.len == 0:
        ok = false
        break
      for j in i + 1 ..< rows.len:
        if m.fns[rows[i]].arch == m.fns[rows[j]].arch:
          ok = false
          break
      if not ok:
        break
    if ok:
      # every row must live in one module and one DLL group
      for i in 1 ..< rows.len:
        if fnOwner[rows[i]] != fnOwner[rows[0]] or
            m.fns[rows[i]].moduleName != m.fns[rows[0]].moduleName:
          ok = false
          break
    if not ok:
      continue
    # narrowest arch set first (stable), like the const blocks
    for i in 1 ..< rows.len:
      var j = i
      while j > 0 and m.fns[rows[j]].arch.len < m.fns[rows[j - 1]].arch.len:
        swap(rows[j], rows[j - 1])
        dec j
    var first = rows[0]
    for r in rows:
      if r < first:
        first = r
    fnSplitFirst[first] = rows
    for r in rows:
      if r != first:
        fnSplitSkip.incl r

  # direct type-name references of every const: the declared type plus,
  # for struct-typed consts, the field types
  var constRefs: seq[seq[string]] = newSeq[seq[string]](m.consts.len)
  for ci in 0 ..< m.consts.len:
    var tn = np.skipAAlias(leafNamed(m.consts[ci].ty))
    if tn.len > 0:
      constRefs[ci].add tn
      if np.isTypeKind(tn, tkStruct):
        for f in m.types[np.firstIdx[tn]].fields:
          let fr = leafNamed(f.ty)
          if fr.len > 0:
            constRefs[ci].add fr

  # direct type-name references of every fn signature, and which DLLs
  # reference each type (fallback owner for unmapped types)
  var fnRefNames: seq[seq[string]] = newSeq[seq[string]](m.fns.len)
  var referencedBy: Table[string, seq[string]]
  for fi in 0 ..< m.fns.len:
    var rs: seq[string]
    for p in m.fns[fi].params:
      var pn = leafNamed(p.ty)
      if pn.len > 0:
        rs.add np.skipAAlias(pn)
    block:
      var rn = leafNamed(m.fns[fi].ret)
      if rn.len > 0:
        rs.add np.skipAAlias(rn)
      fnRefNames[fi] = rs

    for r in rs:
      if r in np.firstIdx: # only types defined in this winmd
        if r notin referencedBy:
          referencedBy[r] = @[]
        let dn =
          if m.fns[fi].moduleName.len > 0:
            m.fns[fi].moduleName
          else:
            "misc"
        var found = false
        for x in referencedBy[r]:
          if x == dn:
            found = true
        if not found:
          referencedBy[r].add dn

  # a type lives in the module of its defining header; km-merge
  # versioned names (X_12, X_1_0) inherit the header of their stem; the
  # remaining unmapped types fall back to the (single) DLL that
  # references them, or win32base
  var hdrLookup: Table[string, string]
  for i in 0 ..< m.types.len:
    let n = m.types[i].name
    if n in hdrLookup:
      continue
    if n in typeHdr:
      hdrLookup[n] = typeHdr[n]
    else:
      var hit = ""
      # strip trailing _digit groups (km merge versions, X_1_0 etc.)
      # until the stem is mapped
      var stem = n
      var tries = 0
      while stem.len > 0 and tries < 5:
        var i2 = stem.len - 1
        while i2 >= 0 and stem[i2] in '0' .. '9':
          dec i2
        if i2 < 1 or stem[i2] != '_':
          break
        let base = stem[0 ..< i2]
        if base in typeHdr:
          hit = typeHdr[base]
          break
        stem = base
        inc tries
      hdrLookup[n] = hit

  var ownerOf: Table[string, string]
  for t in m.types:
    let n {.cursor.} = t.name
    if hdrLookup[n] != "":
      ownerOf[n] = headerOwnerKey(hdrLookup[n])
    elif n in referencedBy and referencedBy[n].len == 1:
      ownerOf[n] = referencedBy[n][0]
    else:
      ownerOf[n] = ""

  # win32base is closed under type references: a base type (or base
  # constant, including struct-const field types) may only reference
  # base types
  var clOwnerKey: seq[string]
  var clRefs: seq[seq[string]]
  for i in 0 ..< m.types.len:
    # suppressed aliases are not emitted: their references do not exist
    if m.types[i].name in np.aAlias:
      continue
    clOwnerKey.add m.types[i].name
    clRefs.add np.typeRefNames[i]
  for ci in 0 ..< m.consts.len:
    let tn = np.skipAAlias(m.consts[ci].ty.name)

    if tn.len > 0:
      clOwnerKey.add tn
      var rs: seq[string]
      if np.isTypeKind(tn, tkStruct):
        rs.add tn
        for f in m.types[np.firstIdx[tn]].fields:
          if f.ty.name.len > 0:
            rs.add f.ty.name
      clRefs.add rs

  var keyToItems: Table[string, seq[int]]
  for ki in 0 ..< clOwnerKey.len:
    keyToItems.addGrouped(clOwnerKey[ki], ki)

  # severed: "srcName/refName" pairs rendered opaquely (`ptr pointer`)
  # to cut a dependency edge without moving any type out of its header
  var severed: HashSet[string]
  var baseSeen: HashSet[string]
  var baseWork: seq[int]
  for ki in 0 ..< clOwnerKey.len:
    if ownerOf.getOrDefault(clOwnerKey[ki], "") == "" and clOwnerKey[ki] notin baseSeen:
      baseSeen.incl clOwnerKey[ki]
      for j in keyToItems[clOwnerKey[ki]]:
        baseWork.add j

  proc runClosure() =
    while baseWork.len > 0:
      let ki = baseWork[baseWork.len - 1]
      baseWork.del(baseWork.len - 1)
      for r in clRefs[ki]:
        # a base handle with a module pointee renders opaquely
        # (`pointer`) and therefore does not reference it
        if ki < m.types.len and m.types[ki].kind == tkHandle and
            m.types[ki].name in ownerOf and ownerOf[m.types[ki].name] == "" and
            r == m.types[ki].underlying.name:
          continue
        # severed references render opaquely and do not reference
        if ki < m.types.len and (m.types[ki].name & "/" & r) in severed:
          continue
        if r in ownerOf and ownerOf[r] != "" and r notin baseSeen:
          baseSeen.incl r
          ownerOf[r] = ""
          for j in keyToItems[r]:
            baseWork.add j

  runClosure()

  # where a constant lives: its own header if the map knows the name,
  # else with the module of its declared type (empty -> base)
  proc constOwner(cc: ModelConst): string =
    if cc.name in typeHdr:
      return headerOwnerKey(typeHdr[cc.name])
    let tn = np.skipAAlias(cc.ty.name)

    if tn.len > 0:
      return ownerOf.getOrDefault(tn, "")
    result = ""

  # force every header module a const may need into existence before the
  # cycle loop allocates per-module arrays (headerOwnerKey creates lazily)
  for ci in 0 ..< m.consts.len:
    discard constOwner(m.consts[ci])

  # the module dependency graph must stay acyclic: base-ify the referenced
  # type of every back edge, re-close, repeat. For each back edge the
  # smaller side is base-ified: the referenced type, or the type that
  # references it — an alias like PIO_SECURITY_CONTEXT has a deep
  # reference closure (it follows the pointee chain), so breaking the
  # cycle on the referencing side usually base-ifies far fewer types.
  var cycleEdges: seq[CycleEdge]
  proc closureSize(start: string): int =
    if start notin np.firstIdx:
      return 0

    var seen: HashSet[string]
    var q: seq[int] = @[np.firstIdx[start]]
    seen.incl start
    while q.len > 0:
      let idx = q[q.len - 1]
      q.del(q.len - 1)
      if ownerOf.getOrDefault(m.types[idx].name, "") == "":
        continue
      inc result
      for r in np.typeRefNames[idx]:
        if r in np.firstIdx and r notin seen:
          seen.incl r
          q.add np.firstIdx[r]

  while true:
    var adj: seq[seq[tuple[to: int, refName: string, srcName: string]]] =
      newSeq[seq[tuple[to: int, refName: string, srcName: string]]](moduleOrder.len)
    for i in 0 ..< m.types.len:
      # suppressed aliases are not emitted: no module edge from them
      if m.types[i].name in np.aAlias:
        continue
      let o1 = ownerOf[m.types[i].name]
      for r in np.typeRefNames[i]:
        let o2 = ownerOf.getOrDefault(r, "")
        # base handles with a module pointee render opaquely: no edge
        if o1 == "" and m.types[i].kind == tkHandle and r == m.types[i].underlying.name and
            o2 != "":
          continue
        # severed references render opaquely: no edge
        if (m.types[i].name & "/" & r) in severed:
          continue
        if o2 != "" and o2 != o1 and o2 in modulePos:
          adj[modulePos[o1]].add (modulePos[o2], r, m.types[i].name)
    for fi in 0 ..< m.fns.len:
      let fo = fnOwner[fi]
      if fo notin modulePos:
        continue
      for r in fnRefNames[fi]:
        let o2 = ownerOf.getOrDefault(r, "")
        if o2 != "" and o2 != fo and o2 in modulePos:
          adj[modulePos[fo]].add (modulePos[o2], r, "")
    for ci in 0 ..< m.consts.len:
      let co = constOwner(m.consts[ci])
      if co == "" or co notin modulePos:
        continue
      for r in constRefs[ci]:
        let o2 = ownerOf.getOrDefault(r, "")
        if o2 != "" and o2 != co and o2 in modulePos:
          adj[modulePos[co]].add (modulePos[o2], r, "")

    cycleEdges.setLen(0)
    if not allBackEdges(moduleOrder.len, adj, cycleEdges):
      break

    # pass 1 (pre-pass): sever every severable edge on the cycles
    # first and re-detect — cutting any edge of a cycle dissolves it
    # and keeps both types in their defining headers (the reference
    # renders opaquely); base-ification only breaks what cannot be
    # severed
    var didSever = false
    for e in cycleEdges:
      for j in 0 ..< e.pathSrc.len:
        let s = e.pathSrc[j]
        let key = s & "/" & e.pathRef[j]
        if s.len > 0 and key in np.ptrRefs and key notin severed:
          severed.incl key
          didSever = true
      let key0 = e.srcName & "/" & e.refName
      if e.srcName.len > 0 and key0 in np.ptrRefs and key0 notin severed:
        severed.incl key0
        didSever = true
    if didSever:
      continue

    # pass 2: nothing left to sever — base-ify
    for e in cycleEdges:
      var pick = e.refName
      if e.srcName.len > 0 and closureSize(e.srcName) < closureSize(e.refName):
        pick = e.srcName
      # prefer base-ifying the type a pointer alias points at over the
      # alias itself: a struct's reference closure is its fields, while
      # an alias is just its pointee — the pointee's header then keeps
      # the real type and only the alias is rendered opaquely in base
      if pick in np.firstIdx and m.types[np.firstIdx[pick]].kind == tkHandle and
          m.types[np.firstIdx[pick]].underlying.name.len > 0:
        let pt = m.types[np.firstIdx[pick]].underlying.name
        # only while the pointee is still in a module — if it is
        # already base, fall back to base-ifying the alias itself
        # (rendered opaquely), otherwise the loop never converges
        if pt in np.firstIdx and ownerOf.getOrDefault(pt, "") != "" and
            m.types[np.firstIdx[pt]].kind notin {tkHandle, tkUnscopedEnum}:
          pick = pt
      if ownerOf.getOrDefault(pick, "") != "":
        ownerOf[pick] = ""

    var ownerSnap: seq[tuple[nm: string, o: string]]
    for (nm, o) in ownerOf.pairs:
      ownerSnap.add (nm, o)
    for (nm, o) in ownerSnap:
      if o == "" and nm notin baseSeen:
        baseSeen.incl nm
        for j in keyToItems.getOrDefault(nm, @[]):
          baseWork.add j
    runClosure()

  # opaque stubs (referenced in signatures, not defined in this winmd)
  # have no dependencies of their own: place each in the module that
  # references it. A stub referenced by several modules goes to the
  # earliest one (moduleOrder) and the rest import it — since a stub
  # references nothing, this cannot create a cycle.
  var stubsByModule: Table[string, seq[string]]
  for n in np.stubNames.keys:
    var mods: seq[string]
    proc addMod(x: string) =
      if x.len > 0 and not contains(mods, x):
        mods.add x

    for fi in 0 ..< m.fns.len:
      for r in fnRefNames[fi]:
        if r == n:
          addMod(fnOwner[fi])
    for i in 0 ..< m.types.len:
      for r in np.typeRefNames[i]:
        if r == n:
          addMod(ownerOf[m.types[i].name])
    for ci in 0 ..< m.consts.len:
      for r in constRefs[ci]:
        if r == n:
          addMod(constOwner(m.consts[ci]))
    if mods.len > 0:
      var pick = mods[0]
      for x in mods:
        if x in modulePos and pick in modulePos and modulePos[x] < modulePos[pick]:
          pick = x
      ownerOf[n] = pick

      stubsByModule.addGrouped(pick, n)

  # group types / constants by owning module
  var typesByModule: Table[string, seq[int]]
  for idx in np.order:
    # suppressed aliases are not emitted: they do not keep a module alive
    if m.types[idx].name in np.aAlias:
      continue
    let o = ownerOf[m.types[idx].name]
    if o != "":
      typesByModule.addGrouped(o, idx)

  var constsByModule: Table[string, seq[int]]
  for ci in 0 ..< m.consts.len:
    let o = constOwner(m.consts[ci])
    if o != "":
      constsByModule.addGrouped(o, ci)

  # constant name -> all rows with that name (in m.consts order); rows with
  # an arch tag are emitted as one const with a `when` block
  var constGroups: Table[string, seq[int]]
  for ci in 0 ..< m.consts.len:
    constGroups.addGrouped(m.consts[ci].name, ci)

  # names whose arch-`when` const has already been emitted (once per group)
  var constGroupEmitted: Table[string, bool]
  var membersByModule: Table[string, seq[int]]
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkUnscopedEnum:
      let o = ownerOf[m.types[i].name]
      if o != "":
        membersByModule.addGrouped(o, i)

  # module -> modules it depends on
  var moduleDeps: Table[string, seq[string]]
  proc addDep(a, b: string) =
    if a == b:
      return
    if a notin moduleDeps:
      moduleDeps[a] = @[]
    if not contains(moduleDeps[a], b):
      moduleDeps[a].add b

  for i in 0 ..< m.types.len:
    # suppressed aliases are not emitted: no module dep from them
    if m.types[i].name in np.aAlias:
      continue
    let o1 = ownerOf[m.types[i].name]
    if o1 == "":
      continue
    for r in np.typeRefNames[i]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "" and (m.types[i].name & "/" & r) notin severed:
        addDep(o1, o2)
  for fi in 0 ..< m.fns.len:
    for r in fnRefNames[fi]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "":
        addDep(fnOwner[fi], o2)

  # constants reference their declared type (and field types for structs)
  for ci in 0 ..< m.consts.len:
    let co = constOwner(m.consts[ci])
    if co == "":
      continue
    for r in constRefs[ci]:
      let o2 = ownerOf.getOrDefault(r, "")
      if o2 != "":
        addDep(co, o2)
  for v in moduleDeps.mvalues():
    v.sort()

  # ---- header ---------------------------------------------------------------
  c.text.add "# generated by winmd2nim from Windows.Win32.winmd — do not edit\n"
  c.text.add "# types=" & $(np.knownTypes.len) & " fns=" & $m.fns.len & " consts=" &
    $m.consts.len & "\n\n"

  # ---- types -------------------------------------------------------------------
  # Every module gets one single `type` section of its own: forward
  # references resolve within the section and across modules via imports
  # (the module dependency graph is a DAG by construction).
  # reference resolution while emitting an arch variant row: refs to
  # other split names resolve to the SAME variant's row (X_AMD64 may
  # contain Y_AMD64, not the Y selector alias)
  # the arch set of the variant currently being emitted (empty = not in a
  # variant). References to split types are rewritten to the variant whose
  # arch set matches — not by index, because a km-merge chain sub-type can
  # have fewer variants than its parent (an arch with no sub-struct for a
  # member simply has no row for that member).
  var variantCtx: set[Architecture]
  proc renderRef(t: SigType): string =
    # walk pointer layers to the leaf named type (an array / by-ref in
    # between prevents the rewrite)
    var leaf = t
    var nPtr = 0
    while leaf.base == bPtr:
      inc nPtr
      leaf = leaf.inner[]
    if variantCtx.len > 0 and nPtr <= 2 and leaf.base == bNamed and
        leaf.name in np.splitInfo:
      var matched = -1
      let sets = np.splitInfo[leaf.name]
      for i in 0 ..< sets.len:
        if sets[i] == variantCtx:
          matched = i
          break
      if matched >= 0:
        let v = np.variantOut[leaf.name][matched]
        if nPtr == 0:
          v
        elif nPtr == 1:
          "ptr " & v
        else:
          "ptr ptr " & v
      else:
        np.renderType(t)
    else:
      np.renderType(t)

  proc emitType(c: var GenCtx, m: Model, i: int, name: string) =
    let t = m.types[i]
    case t.kind
    of tkStruct:
      # layout comes from the winmd type attributes (the Rust reference
      # uses the same): ExplicitLayout (0x10) means the fields are
      # overlaid — a C union — so emit {.union.}; a ClassLayout packing
      # emits {.packed.}.
      # TODO AlignmentAttribute is read into alignSize but
      #     not emitted)
      var pragmas: seq[string] = @["mdtype"]
      if t.isUnion:
        pragmas.add "union"
      if t.packSize > 0:
        pragmas.add "packed"

      let pragma = renderPragma(pragmas)
      c.line "  " & name & "*" & pragma & " = object"
      var fUsed: HashSet[string]
      for f in t.fields:
        let
          fn = fUsed.freshIdent(f.nimName)
          fldRef = leafNamed(f.ty)

        if fldRef.len > 0 and (t.name & "/" & fldRef) in severed:
          c.line "    " & esc(fn) & "*: pointer"
        else:
          c.line "    " & esc(fn) & "*: " & renderRef(f.ty)
    of tkHandle:
      # curated string-pointer aliases (README: the LPSTR/PSTR family
      # maps to the idiomatic Nim string pointer types — same ABI)
      case t.name
      of "PSTR", "PCSTR", "LPSTR", "LPCSTR":
        c.line "  " & name & "* = cstring"
        return
      of "PWSTR", "PCWSTR", "LPWSTR", "LPCWSTR":
        # the wide variant: same ABI as LPWSTR / ptr uint16
        c.line "  " & name & "* = ptr UncheckedArray[uint16]"
        return
      else:
        discard

      var base = renderRef(t.underlying)

      # base handles with a module pointee, or a pointee edge that the
      # cycle resolver severed: render opaquely
      # the graph keys use the redirected name for suppressed aliases
      let undRefG = np.skipAAlias(leafNamed(t.underlying))
      let isSevered = undRefG.len > 0 and (t.name & "/" & undRefG) in severed
      if isSevered:
        base = "pointer #[" & base & "]#"

      # a plain alias: a void-alias handle is a plain `void` alias, and a
      # severed pointee renders opaquely as `pointer`
      let hp = " {.mdalias.}"
      c.line "  " & name & "*" & hp & " = " & base
    of tkEnum:
      c.line "  " & name & "* {.mdalias.} = enum"
      for f in t.fields:
        if f.hasConstant:
          let member = esc(np.freshName(f.nimName))
          c.line "    " & member & " = " & $f.constant
    of tkUnscopedEnum:
      let base = np.renderType(t.underlying)
      c.line "  " & name & "* {.mdalias.} = " & base
    of tkDelegate:
      if t.fields.len == 0:
        c.line "  " & name & "* {.mdalias.} = pointer"
      else:
        var s = "proc ("
        var pUsed: HashSet[string]
        for k in 0 ..< t.fields.len:
          if k > 0:
            s.add ", "
          let
            pn = pused.freshIdent(t.fields[k].nimName)
            ft = t.fields[k].ty

          # the graph keys use the redirected name for suppressed aliases
          let ftRef = np.skipAAlias(leafNamed(ft))
          if ftRef.len > 0 and (t.name & "/" & ftRef) in severed:
            s.add esc(pn) & ": ptr pointer"
          else:
            s.add esc(pn) & ": " & renderRef(ft)
        let retRef = np.skipAAlias(leafNamed(t.ret))
        if retRef.len > 0 and (t.name & "/" & retRef) in severed:
          s.add "): pointer"
        else:
          s.add "): " & renderRef(t.ret)
        c.line "  " & name & "* {.mdalias.} = " & s & " {.stdcall.}"
    of tkInterface:
      c.line "  " & name & "* {.mdinterface.} = object"

  var kindSeen = false
  proc emitKind(kind: TypeKind, idxList: seq[int], label: string) =
    var has = false
    for idx in idxList:
      if m.types[idx].kind == kind and m.types[idx].name notin np.aAlias:
        has = true
        break

    if not has:
      return

    if kindSeen:
      c.line ""
    c.line "  # " & label
    for idx in idxList:
      if m.types[idx].kind == kind and m.types[idx].name notin np.aAlias:
        if np.rowVariant[idx] >= 0:
          variantCtx = np.splitInfo[m.types[idx].name][np.rowVariant[idx]]
        else:
          variantCtx = {}
        emitType(c, m, idx, esc(np.typeNames[idx]))
        variantCtx = {}
    kindSeen = true

  proc emitKinds(idxList: seq[int]) =
    emitKind(tkStruct, idxList, "structs")
    emitKind(tkHandle, idxList, "typdefs")
    emitKind(tkEnum, idxList, "scoped enums")
    emitKind(tkUnscopedEnum, idxList, "unscoped enums")
    emitKind(tkDelegate, idxList, "delegates")
    emitKind(tkInterface, idxList, "interfaces")

  # selector-alias blocks: one when/elif/else per split name — each
  # name's variant conditions differ from the others, so the chains
  # cannot be shared
  proc emitAliasBlocks(nameSet: seq[string]) =
    for n in nameSet:
      var conds: seq[set[Architecture]]
      for a in np.splitInfo[n]:
        var found = false
        for b in conds:
          if a == b:
            found = true
            break
        if not found:
          conds.add a
      var bi = 0
      for a in conds:
        let hdr = if bi == 0: "when " else: "elif "
        let cond = archCond(a)
        c.line hdr & cond & ":"
        for vi in 0 ..< np.splitInfo[n].len:
          if a == np.splitInfo[n][vi]:
            c.line "  type " & esc(m.types[np.nameRows[n][0]].nimName) & "* = " &
              np.variantOut[n][vi]
            break
        inc bi
      c.line "else:"
      c.line "  type " & esc(m.types[np.nameRows[n][0]].nimName) & "* = " &
        np.variantOut[n][0]

  var baseTypeIdxs: seq[int]
  for idx in np.order:
    # suppressed aliases are not emitted: they do not keep the base alive
    if m.types[idx].name in np.aAlias:
      continue
    if ownerOf[m.types[idx].name] == "":
      baseTypeIdxs.add idx

  var baseA: seq[int]
  var baseB: seq[int]
  for idx in baseTypeIdxs:
    let nm = m.types[idx].name
    # split names always zone A: their rows are the per-arch variants,
    # which must precede the selector aliases
    if nm notin np.splitInfo and nm in np.zoneB:
      baseB.add idx
    else:
      baseA.add idx

  var baseSplitNames: seq[string]
  var seenSplit: Table[string, bool]
  var baseSplitList: seq[string]
  for (n, l) in np.splitInfo.pairs:
    baseSplitList.add n

  for n in baseSplitList:
    if ownerOf.getOrDefault(n, "") == "" and n notin seenSplit:
      baseSplitNames.add n
      seenSplit[n] = true

  c.line "type"
  if np.guidUsed:
    # System.Guid is a TypeRef to mscorlib in this winmd (no TypeDef):
    # emit the 16-byte C GUID layout so by-value fields keep the ABI
    c.line "  # System.Guid (TypeRef to mscorlib): 16-byte C GUID layout"
    c.line "  Guid* {.inheritable, pure, completeStruct.} = object"
    c.line "    Data1*: uint32"
    c.line "    Data2*: uint16"
    c.line "    Data3*: uint16"
    c.line "    Data4*: array[8, uint8]"
    c.line ""

  emitKinds(baseA)
  if kindSeen:
    c.line ""
  emitAliasBlocks(baseSplitNames)
  if baseSplitNames.len > 0:
    c.line ""
  if baseB.len > 0:
    c.line "type"
    emitKinds(baseB)
    c.line ""

  # ---- constants -------------------------------------------------------------
  ## Sort rank of a const row: narrowest arch set first (untagged rows
  ## would sort last; no emitted `when` group contains any).
  proc rowArchRank(cc: ModelConst): int =
    if cc.arch.len == 0: 99 else: cc.arch.len

  ## True when the const rows of this name are emitted as a standalone
  ## `when` block (a `const` section cannot contain `when` statements).
  proc constIsWhen(ci: int): bool =
    let group = constGroups[m.consts[ci].name]
    if group.len <= 1:
      return false
    let v0 = m.consts[group[0]]
    var sameVal = true
    var anyArch = false
    for ci2 in group:
      let r = m.consts[ci2]
      if r.arch.len > 0:
        anyArch = true
      if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
          r.wideStr != v0.wideStr:
        sameVal = false
    anyArch and not sameVal

  ## True when the const's value is a cast to a pointer type: the VM
  ## cannot evaluate `cast[T](int)` for a pointer T at compile time, so
  ## the const is emitted as a standalone `template` declaration (a
  ## `const` section cannot hold templates either).
  proc constIsCastPtr(ci: int): bool =
    let cc = m.consts[ci]
    if cc.isStr or cc.value == 0:
      return false
    # a same-value group emits one const from its first row (the rest
    # are deduped); every other case emits one const per row
    let group = constGroups[cc.name]
    var ci2 = ci
    if group.len > 1:
      let v0 = m.consts[group[0]]
      var sameVal = true
      for ci3 in group:
        let r = m.consts[ci3]
        if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
            r.wideStr != v0.wideStr:
          sameVal = false
          break
      if sameVal:
        ci2 = group[0]
    renderedIsPtr(np, m.consts[ci2].ty)

  ## Emits one const; returns true when it emitted a standalone block
  ## (a `when` or a pointer-cast `template`, which ends the surrounding
  ## `const` section).
  proc emitFreeConst(ci: int): bool =
    let cc = m.consts[ci]

    # constant rows sharing a name:
    #  - all rows carry the same value -> one plain const (skip the rest)
    #  - rows carry an arch tag and differ -> one const per arch set in a
    #    `when` block, each branch with an explicit arch condition
    #  - otherwise -> one const per row, deduped by freshName
    let group = constGroups[cc.name]
    var sameVal = true
    var anyArch = false
    let v0 = m.consts[group[0]]
    for ci2 in group:
      let r = m.consts[ci2]
      if r.arch.len > 0:
        anyArch = true
      if r.value != v0.value or r.isStr != v0.isStr or r.strVal != v0.strVal or
          r.wideStr != v0.wideStr:
        sameVal = false
    var singleConst = group.len > 1 and (sameVal or anyArch)
    if singleConst:
      if constGroupEmitted.getOrDefault(cc.name, false):
        return # the group's const was already emitted
      constGroupEmitted[cc.name] = true

    let name = esc(np.freshName(cc.nimName)) # TODO fix freshName usage

    # wide (utf-16) string constants: not translated for now — a comment
    # with the name, the value and a TODO
    if cc.isStr and cc.wideStr:
      c.line "  # " & name & " = " & escape(cc.strVal) &
        "  # TODO: wide string constant (utf-16)"
      return false

    # value pipeline for one row: (type string, value string, value is a
    # cast to a pointer type — the VM cannot evaluate it at compile time,
    # so the const is emitted as a template)
    proc renderRow(ci2: int): (string, string, bool) =
      let cc2 = m.consts[ci2]
      var et = cc2.ty
      # constants on handle typedefs carry pvVoid; recover the base kind
      if cc2.ty.name.len > 0 and cc2.ty.name in np.typePrims:
        et.prim = np.typePrims[cc2.ty.name]
      var tyS =
        if cc2.isStr:
          "string"
        else:
          np.renderType(et)
      var val = renderConstValue(et, cc2)
      var isCast = false
      let isPtrTy = renderedIsPtr(np, cc2.ty)
      if not cc2.isStr and cc2.value == 0 and isPtrTy:
        val = "nil"
      elif not cc2.isStr and cc2.value != 0 and isPtrTy:
        val = "cast[" & tyS & "](" & renderIntConst(cc2.ty.prim, cc2.value) & ")"
        isCast = true

      # struct-typed constants (e.g. DEVPKEY_*: only the trailing propId is
      # in the metadata): emit a struct literal with defaults + last field
      if not cc2.isStr and cc2.ty.name.len > 0 and np.isTypeKind(cc2.ty.name, tkStruct):
        var stype = m.types[np.firstIdx[cc2.ty.name]]
        if stype.fields.len > 0:
          var init = esc(np.typeNames[np.firstIdx[cc2.ty.name]]) & "("
          for k in 0 ..< stype.fields.len:
            if k > 0:
              init.add ", "
            let f = stype.fields[k]
            init.add esc(f.nimName) & ": "
            if k == stype.fields.len - 1:
              var uty = f.ty
              if uty.name.len > 0 and uty.name in np.typePrims:
                uty.prim = np.typePrims[uty.name]
              var lit = renderIntConst(uty.prim, cc2.value)
              # unique base types need an explicit conversion
              if f.ty.base == bNamed and np.isTypeKind(f.ty.name, tkHandle):
                let tn2 =
                  if f.ty.name in np.aAlias:
                    np.aAliasFinal[f.ty.name]
                  else:
                    fixIdent(f.ty.name)
                lit = esc(tn2) & "(" & lit & ")"
              init.add lit
            else:
              init.add defaultLit(np, m, f.ty)
          init.add ")"
          val = init

      # unsigned constant whose target type is signed (e.g. HRESULT =
      # int32): render the wrapped two's-complement value
      if not cc2.isStr and tyS != "uint32":
        if et.prim == pvI4 and cc2.value > 2147483647 and tyS != "uint32":
          val = $(cast[int32](cc2.value)) & "'i32"
        elif et.prim == pvI2 and cc2.value > 32767 and tyS != "uint16":
          val = $(cast[int16](cc2.value)) & "'i16"
        elif et.prim == pvI1 and cc2.value > 127 and tyS != "uint8":
          val = $(cast[int8](cc2.value)) & "'i8"

      # this compiler never converts implicitly to distinct types:
      # wrap the literal in an explicit conversion (a value that is
      # already an explicit cast is left as-is)
      if not cc2.isStr and cc2.ty.name.len > 0 and np.isTypeKind(cc2.ty.name, tkHandle) and tyS != "uint32" and
          not val.startsWith("cast["):
        let tname = esc(np.nameMap.getOrDefault(cc2.ty.name, fixIdent(cc2.ty.name)))
        val = tname & "(" & val & ")"
      result = (tyS, val, isCast)

    if singleConst and sameVal:
      let (tyS, val, isCast) = renderRow(group[0])
      if isCast:
        # the VM cannot evaluate a cast to a pointer type at compile
        # time: emit a template instead of a const (a `const` section
        # cannot hold templates, so this ends the surrounding section).
        # No header pragma: a template emits no C declaration of its own
        c.line "template " & name & "*: untyped = " & val
      else:
        c.line "  " & name & "*: " & tyS & " = " & val
      return false
    elif singleConst:
      # narrowest arch set first (stable); untagged rows (if any) sort
      # last and become the `else` default. Rows can carry different
      # field types (e.g. U32 on x86 / U64 on x64), so the `when`
      # surrounds the whole declaration (name, type and value)
      var sorted = group
      for i in 1 ..< sorted.len:
        var j = i
        while j > 0 and
            rowArchRank(m.consts[sorted[j]]) < rowArchRank(m.consts[sorted[j - 1]]):
          swap(sorted[j], sorted[j - 1])
          dec j
      var rowVals: seq[(string, string, bool)]
      for ci2 in sorted:
        rowVals.add renderRow(ci2)
      # column 0: a `const` section only ends on a dedent, so the
      # `when` block must sit outside the section's indentation
      for i in 0 ..< sorted.len:
        # every branch has an explicit arch condition (no `else`): each
        # branch is a separate const declaration, so on archs no row
        # covers the const is simply not declared
        let cond =
          if i == 0:
            "when " & archCond(m.consts[sorted[i]].arch)
          else:
            "elif " & archCond(m.consts[sorted[i]].arch)
        c.line cond & ":"
        let (tyS, val, isCast) = rowVals[i]
        if isCast:
          # a cast to a pointer type: a template, not a const (the VM
          # cannot evaluate it at compile time)
          c.line "  template " & name & "*: untyped = " & val
        else:
          c.line "  const " & name & "*: " & tyS & " = " & val
      return true
    let (tyS, val, isCast) = renderRow(ci)
    if isCast:
      c.line "template " & name & "*: untyped = " & val
    else:
      c.line "  " & name & "*: " & tyS & " = " & val

  proc emitMembers(enumIdx: int) =
    let t = m.types[enumIdx]
    let baseName = esc(np.typeNames[enumIdx])
    for f in t.fields:
      if f.hasConstant:
        let member = esc(np.freshName(f.nimName))
        c.line "  " & member & "*: " & baseName & " = " &
          renderIntConst(t.underlying.prim, f.constant)

  ## Wide string consts emit a comment line only — a `const` section with
  ## no real entries would not parse.
  proc constIsWide(ci: int): bool =
    let cc = m.consts[ci]
    cc.isStr and cc.wideStr

  ## A `const` section cannot contain `when` statements or `template`
  ## declarations: arch-`when` consts and pointer-cast consts are emitted
  ## as standalone blocks and the section header is (re-)emitted around
  ## them.
  proc emitConstBlock(constIdxs: seq[int], memberIdxs: seq[int]) =
    if constIdxs.len == 0 and memberIdxs.len == 0:
      return
    var inSection = false
    var constComment = false
    for ci in constIdxs:
      if constIsWhen(ci) or constIsCastPtr(ci):
        if inSection:
          c.line ""
          inSection = false
        discard emitFreeConst(ci)
      elif constIsWide(ci):
        discard emitFreeConst(ci)
      else:
        if not inSection:
          c.line "const"
          inSection = true
        if not constComment:
          c.line "  # free constants"
          constComment = true
        discard emitFreeConst(ci)
    if memberIdxs.len > 0:
      if inSection:
        c.line ""
      else:
        c.line "const"
        inSection = true
      c.line "  # unscoped enum members"
      for i in memberIdxs:
        emitMembers(i)
      c.line ""
    elif inSection:
      c.line ""

  var baseConstIdxs: seq[int]
  for ci in 0 ..< m.consts.len:
    if constOwner(m.consts[ci]) == "":
      baseConstIdxs.add ci

  var baseMemberIdxs: seq[int]
  for i in 0 ..< m.types.len:
    if m.types[i].kind == tkUnscopedEnum and ownerOf[m.types[i].name] == "":
      baseMemberIdxs.add i
  emitConstBlock(baseConstIdxs, baseMemberIdxs)

  # the base module is emitted only when it still has content (stubs now
  # live in their referencing module and the preamble aliases are gone,
  # so this is normally empty)
  var baseEmitted =
    baseTypeIdxs.len > 0 or baseSplitNames.len > 0 or baseConstIdxs.len > 0 or
    baseMemberIdxs.len > 0 or np.guidUsed

  # ---- functions + per-module assembly ---------------------------------------
  # header-only modules can end up empty after base-closure / cycle
  # resolution — drop them and any dep edge pointing at them
  var emitted: Table[string, bool]
  for k in 0 ..< moduleOrder.len:
    let dn = moduleOrder[k]
    emitted[dn] =
      moduleIdx[dn].len > 0 or dn in typesByModule or dn in constsByModule or
      dn in membersByModule or dn in stubsByModule

  # module key -> the module's defining header stem ("" for pure DLL
  # modules): a header module is keyed by its own stem; a header stem
  # that sanitizes to an existing DLL module name merges into that
  # module (the stem is recorded on the DLL key). The recorded stem is
  # the parent (the module key for header modules, the DLL's stem for
  # merged ones), never a numbered variant (winbase_1.h does not exist
  # in the SDK)
  var dllKeys: HashSet[string]
  for i in 0 ..< m.fns.len:
    let dn =
      if m.fns[i].moduleName.len > 0:
        m.fns[i].moduleName
      else:
        "misc"
    dllKeys.incl dn

  var moduleHeader: Table[string, string]
  for k in 0 ..< moduleOrder.len:
    let dn = moduleOrder[k]
    if dn in dllKeys:
      # merged module: a mapped header stem that sanitizes to this
      # DLL's name (the DLL's stem is itself a mapped header)
      if dllNames[k] in hdrStems:
        moduleHeader[dn] = dllNames[k]
    else:
      # pure header module: keyed by its own stem
      moduleHeader[dn] = dn

  # the header to include for a module's mdheader pragma: the module's
  # header stem, unless the stem cannot be included directly
  # (noDirectInclude), in which case headerIncludeOverride names the
  # replacement ("" = no mdheader definition at all)
  var moduleHeaderFinal: Table[string, string]
  for (k, h) in moduleHeader.pairs:
    if h in noDirectInclude:
      moduleHeaderFinal[k] = headerIncludeOverride(h)
    else:
      moduleHeaderFinal[k] = h

  result.mods = @[]
  for k in 0 ..< moduleOrder.len:
    let dn = moduleOrder[k]
    if not emitted[dn]:
      continue

    var t = newStringOfCap(96 * moduleIdx[dn].len)
    t.add "# generated by winmd2nim from Windows.Win32.winmd — " & dn &
      " (do not edit)\n"

    # list import: win32base first, then the scanned dependencies
    var deps: seq[string]
    if baseEmitted:
      deps.add "win32base"

    for k2 in 0 ..< moduleOrder.len:
      let d = moduleOrder[k2]
      if d != dn and emitted.getOrDefault(d, false) and
          contains(moduleDeps.getOrDefault(dn, @[]), d):
        deps.add dllNames[k2]

    if deps.len > 0:
      let deps = deps.join(", ")
      t.add "import ./[" & deps & "]\n"
      t.add "export " & deps & "\n"
    t.add "\n"

    # the module's functions grouped per export DLL (a header module's
    # functions may span several DLLs); sorted by DLL, then by name, so
    # each DLL sits in one contiguous block. The dynlib name is
    # lowercased with the .dll suffix stripped (Nim resolves the
    # dynlib name per target OS); other extensions (.drv, .cpl) are kept
    var fns: seq[tuple[dl, name: string, idx: int]]
    for i in moduleIdx[dn]:
      let f = m.fns[i]
      var dl = if f.moduleName.len > 0: f.moduleName else: "misc"
      dl = dl.toLowerAscii()
      if dl.endsWith(".dll"):
        dl.setLen(dl.len - 4)
      fns.add (dl, f.name, i)
    fns.sort

    # file-level pragmas: mdmethod bundles the pragmas shared by all of
    # the module's functions (sideEffect); mdtype covers the structs
    # (objects, incl. the opaque stubs), mdalias the aliases
    # (handles, enums, unscoped enums, delegates) and mdinterface the
    # interfaces.
    #
    # With --headers, when the module has a resolvable defining header, a
    # `when defined(checkAbi) or defined(mdheaders):` block defines
    # mdheader (the module's `header: "stem.h"`, active only in
    # checkAbi / mdheaders builds) and mdmethod / mdtype / mdalias /
    # mdinterface include it. The dynlib stays a per-group push/pop (a
    # single header module may span several export DLLs)
    let mh = moduleHeaderFinal.getOrDefault(dn, "")
    let useHeader = emitHeaders and mh.len > 0
    var hasStruct = dn in stubsByModule
    var hasAlias = false
    var hasInterface = false
    for idx in typesByModule.getOrDefault(dn, @[]):
      case m.types[idx].kind
      of tkStruct:
        hasStruct = true
      of tkHandle, tkEnum, tkUnscopedEnum, tkDelegate:
        hasAlias = true
      of tkInterface:
        hasInterface = true

    if useHeader:
      t.add "when defined(checkAbi) or defined(mdheaders):\n"
      t.add "  {.pragma: mdheader, header: \"" & mh & ".h\".}\n"
      t.add "else:\n"
      t.add "  {.pragma: mdheader.}\n"
    if fns.len > 0:
      var p = @["sideEffect"]
      if useHeader:
        p.add "mdheader"
      t.add "{.pragma: mdmethod, " & p.join(", ") & ".}\n"
    if hasStruct:
      # bycopy: an inheritable object parameter is otherwise passed by
      # pointer, even to importc procs taking the struct by value
      if useHeader:
        t.add "{.pragma: mdtype, pure, inheritable, bycopy, completeStruct, mdheader.}\n"
      else:
        t.add "{.pragma: mdtype, pure, inheritable, bycopy, completeStruct.}\n"
    if hasAlias:
      if useHeader:
        t.add "{.pragma: mdalias, mdheader.}\n"
      else:
        t.add "{.pragma: mdalias.}\n"
    if hasInterface:
      if useHeader:
        t.add "{.pragma: mdinterface, mdheader.}\n"
      else:
        t.add "{.pragma: mdinterface.}\n"
    if useHeader or fns.len > 0 or hasStruct or hasAlias or hasInterface:
      t.add "\n"

    if dn in stubsByModule:
      t.add "type\n\n"
      t.add "  # opaque stubs: referenced in signatures, not defined in this winmd\n"
      for n in stubsByModule[dn]:
        let name = esc(np.stubNames[n])
        t.add "  " & name & "* {.mdtype.} = object\n"
      t.add "\n"

    if dn in typesByModule:
      let l0 = c.text.len
      var mA: seq[int]
      var mB: seq[int]
      for idx in typesByModule[dn]:
        let nm = m.types[idx].name
        if nm notin np.splitInfo and nm in np.zoneB:
          mB.add idx
        else:
          mA.add idx

      var mSplit: seq[string]
      var seenS: HashSet[string]
      for idx in typesByModule[dn]:
        let n = m.types[idx].name
        if n in np.splitInfo and n notin seenS:
          mSplit.add n
          seenS.incl n

      proc nonEmpty(s: string): bool =
        for line in s.split('\n'):
          let st = line.strip()
          if st.len > 0 and st != "type" and not st.startsWith("#"):
            return true
        return false

      # zone A: types that do not reference split names (before aliases)
      var sA = ""
      if mA.len > 0:
        c.line "type"
        emitKinds(mA)
        c.line ""
        sA = c.text[l0 ..< c.text.len]
        c.text.setLen(l0)
        if not nonEmpty(sA):
          sA = ""

      # selector aliases for this module's split names
      emitAliasBlocks(mSplit)
      var sAl = c.text[l0 ..< c.text.len]
      c.text.setLen(l0)
      if mSplit.len > 0:
        c.line ""

      # zone B: types that reference split names (after aliases)
      var sB = ""
      if mB.len > 0:
        c.line "type"
        emitKinds(mB)
        c.line ""
        sB = c.text[l0 ..< c.text.len]
        c.text.setLen(l0)
        if not nonEmpty(sB):
          sB = ""
      if sA.len > 0:
        t.add sA
      if sAl.len > 0:
        t.add sAl
      if sB.len > 0:
        t.add sB

    if dn in constsByModule or dn in membersByModule:
      let l0 = c.text.len
      emitConstBlock(
        constsByModule.getOrDefault(dn, @[]), membersByModule.getOrDefault(dn, @[])
      )
      t.add c.text[l0 ..< c.text.len]
      c.text.setLen(l0)

    if fns.len > 0:
      # the --lowercase option: Nim convention is that proc names
      # start with a lowercase letter; the importc pragma keeps the
      # real linkage name. The normalized (case-insensitive) name is
      # unchanged, so no new collisions are introduced
      proc freshFnName(f: ModelFn): string =
        result = np.freshName(f.nimName) # TODO fix freshName
        if lowerFirst and result.len > 0 and result[0] in {'A' .. 'Z'}:
          result[0] = result[0].toLowerAscii()

      # one fn row's declaration under the given (unescaped) name
      proc renderFnDecl(f: ModelFn, fn: string): string =
        let name = esc(fn)
        var s = "proc " & name & "*("
        var pUsed: HashSet[string]
        for pi in 0 ..< f.params.len:
          if pi > 0:
            s.add ", "

          let pn = pUsed.freshIdent(f.params[pi].nimName)

          s.add esc(pn) & ": " & np.renderType(f.params[pi].ty)
        s.add ")"
        let ret = np.renderType(f.ret)
        if ret != "void":
          s.add ": " & ret
        # Not all windows functions have side effects but we have no way of
        # knowing (or do we?) — mdmethod carries the shared sideEffect
        # pragma (and mdheader with --headers); when the emitted name
        # is exactly the C name, bare `importc` suffices (it imports
        # under the symbol's own name)

        var pragmas = @["mdmethod"]
        if fn == f.importName:
          pragmas.add "importc"
        else:
          pragmas.add "importc: \"" & f.importName & "\""

        if f.stdcall:
          pragmas.add "stdcall"

        result = s & renderPragma(pragmas) & "\n"

      var curDll = ""
      for e in fns:
        let dl = e.dl
        let f = m.fns[e.idx]
        if dl != curDll:
          if curDll.len > 0:
            t.add "{.pop.}\n"
          t.add "{.push dynlib: \"" & dl & "\".}\n"
          curDll = dl
        if e.idx in fnSplitSkip:
          continue
        let rows = fnSplitFirst.getOrDefault(e.idx, @[])
        if rows.len > 0:
          # arch-split group: one declaration per arch set under a
          # shared name (like the arch-tagged const blocks); every
          # branch has an explicit arch condition, so on archs no row
          # covers the fn is simply not declared
          let fn = freshFnName(f)
          for ri in 0 ..< rows.len:
            let r = m.fns[rows[ri]]
            t.add (if ri == 0: "when " else: "elif ") & archCond(r.arch) & ":\n"
            t.add "  " & renderFnDecl(r, fn)
          continue
        t.add renderFnDecl(f, freshFnName(f))
      t.add "{.pop.}\n"
    var fm: FnModule
    fm.dll = dn
    fm.modName = dllNames[k]
    fm.code = t
    result.mods.add fm
  result.base = c.text
  result.baseEmitted = baseEmitted

## Multi-module layout: a shared base module (unmapped types, stubs),
## one module per defining header (types + constants + functions with
## header provenance) and one per export DLL (functions without header
## provenance, wrapped in the DLL's dynlib statement); each module
## imports/exports only the modules its items reference.
proc generateModules*(
    m: Model,
    typeHdr: Table[string, string],
    emitHeaders: bool = false,
    lowerFirst: bool = false,
): seq[GenModule] =
  let core = generateCore(m, typeHdr, emitHeaders, lowerFirst)
  if core.baseEmitted:
    var gm: GenModule
    gm.name = "win32base"
    gm.code = core.base
    result.add gm

  for k in 0 ..< core.mods.len:
    var gm2: GenModule
    gm2.name = core.mods[k].modName
    gm2.code = core.mods[k].code
    result.add gm2
