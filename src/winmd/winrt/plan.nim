# plan.nim — what the WinRT generator settles before it writes a word: what
# each type of the metadata is called, what it holds on the ABI with every
# reference resolved, and which module declares it. The Nim source is
# rendered from the plan alone (winrt/render); the model stays behind.
#
# The plan is built in steps (winrtgen's buildPlan): the names of every type
# (buildNaming, here), each type as it is declared (winrt/abitypes), the
# modules that declare them (placeModules, here), and the IIDs of the
# instantiations of parameterised interfaces (winrt/iids).
#
# Namespaces refer to each other in cycles (Windows.Storage mentions
# Windows.System and back), which Nim modules cannot: the namespaces of a
# cycle share one module, named after the first of them
# (applicationmodel_group), and each of them keeps a module that re-exports
# it, so `import storage` works either way. That is how winim lays out the SDK
# headers, done here by the generator.

import std/[algorithm, options, sequtils, sets, strformat, strutils, tables]
import ../[guid, model, signatures, nameplan]

type
  EnumMember* = tuple[name, value: string]
    ## A member of an enum, as the const that holds it: `AsyncStatus_Started`
    ## and `0'i32`. An enum is a distinct type over its integer, as in
    ## windows-rs, so it holds any value Windows returns (a combination of
    ## [Flags], or a member newer than the metadata) and is not mistaken for
    ## another enum.

  TypeNames* = object
    ## What the output calls a type of the metadata, and what a reference to
    ## it needs to know. The names are unique among the top-level names and
    ## never a keyword (the keywords are taken from the start), so they need no
    ## escaping.
    name*: string
    vtableName*, iidName*: string # an interface's or delegate's vtable and IID constant
    classNameConst*: string # a runtime class's `RuntimeClass_...` const
    enumMembers*: seq[EnumMember] # an enum's members
    isObject*: bool
      # an interface, delegate or runtime class: it crosses the ABI as a
      # pointer to its object

  Naming* = object
    ## The names of the types of the metadata: the first step of the plan,
    ## which the others resolve references with.
    names*: seq[TypeNames] # one per entry of m.types
    byName*: Table[string, int] # "ns.name" -> m.types index
    usedNames*: HashSet[string]
      # every top-level name given out, for naming what comes after (the IIDs
      # of the instantiations)

  AbiTypeKind* = enum
    akVoid ## no type: what a `pointer` points to
    akNamed ## a type by the name it is declared under: `int32`, `HSTRING`, `Uri`, `T`
    akPointer ## a pointer: how an interface, delegate or runtime class crosses
    akInstantiation ## an instantiation of a parameterised interface, `IVector[HSTRING]`
    akArray ## a fixed number of elements, inline in a struct

  AbiType* = ref object
    ## A type as it crosses the ABI, every reference in it resolved to the name
    ## its type is declared under.
    case kind*: AbiTypeKind
    of akVoid:
      discard
    of akNamed:
      name*: string
    of akPointer:
      target*: AbiType
    of akInstantiation:
      definition*: string # the parameterised interface, `IVector`
      args*: seq[AbiType]
    of akArray:
      element*: AbiType
      count*: int

  Parameter* = tuple[name: string, ty: AbiType] ## A parameter of a vtable slot.

  VtableSlot* = object ## A method of an interface or delegate as its vtable holds it.
    name*: string
    parameters*: Option[seq[Parameter]]
      # `this`, the method's, and a trailing `retval`, as the ABI passes them;
      # none when one of them cannot be spelled (the slot stays a `pointer`)

  DeclarationKind* = enum
    dkEnum ## an Int32 enum, or a UInt32 ([Flags]) one
    dkStruct
    dkInterface ## an interface, parameterised or not
    dkDelegate
    dkClass ## a runtime class; a static one has no default interface

  Declaration* = ref object
    ## A type as the output declares it: its names, and what it holds.
    name*: string
    case kind*: DeclarationKind
    of dkEnum:
      underlying*: AbiType # its integer: `int32`, or `uint32` for [Flags]
      isFlags*: bool # a [Flags] enum, whose members combine
      members*: seq[EnumMember] # in metadata order
    of dkStruct:
      fields*: seq[tuple[name: string, ty: AbiType]] # in metadata order
    of dkInterface, dkDelegate:
      genericParameters*: seq[string] # a parameterised one's: `T`, or `K` and `V`
      vtableName*, iidName*: string
      guid*: Guid # its IID, or a parameterised one's PIID
      slots*: seq[VtableSlot] # after IUnknown's and IInspectable's, in vtable order
    of dkClass:
      className*: string # `Windows.Foundation.Uri`, what activation takes
      classNameConst*: string
        # `RuntimeClass_Windows_Foundation_Uri`, the const holding it
      defaultInterface*: Option[AbiType]
        # the object that crosses the ABI for it (`IUriRuntimeClass`); none
        # for a static class, which has no instances

  ModuleKind* = enum
    mkTypes ## winrttypes: the enums, and the structs that mention no interface
    mkNamespace
      ## the interfaces, delegates and runtime classes of a namespace, and the
      ## structs that mention them; the namespaces of a cycle share one
    mkShim ## a namespace of a cycle: re-exports the module it shares

  Module* = object ## A module the generator writes, but winrtbase and winrtgenerics.
    kind*: ModuleKind
    name*: string # winrttypes, foundation, applicationmodel_group, ...
    namespaces*: seq[string] # the namespaces it holds, or (mkShim) stands for
    imports*: seq[string] # the modules it imports and re-exports
    declarations*: seq[Declaration] # what it declares, in metadata order

  Plan* = object ## What the text is written from.
    modules*: seq[Module] # winrttypes, then each namespace module and its shims
    instantiationIids*: seq[tuple[name: string, iid: Guid]]
      # the IID of each instantiation the metadata uses (`IID_IVector_HSTRING`)

const remapped* = {
  "System.Guid": (name: "GUID", isObject: false, signature: "g16"),
  "System.Object":
    (name: "IInspectable", isObject: true, signature: "cinterface(IInspectable)"),
  "Windows.Foundation.HResult": (
    name: "HRESULT", isObject: false, signature: "struct(Windows.Foundation.HResult;i4)"
  ),
}.toTable
  ## Types spelled with what winrtbase declares, as windows-rs remaps them
  ## (HResult is a struct around an HRESULT), and their signatures in the WinRT
  ## type system (winrt/iids). The plan leaves them out of the model.

func fullName*(t: ModelType | SigType): string =
  ## `Windows.Foundation.IStringable`: the namespace-qualified name the model
  ## and the plan know a type by.
  fmt"{t.ns}.{t.name}"

func stripArity*(name: string): string =
  ## ``IVector`1`` -> `IVector`
  name.split('`')[0]

func moduleName*(ns: string): string =
  ## Windows.Foundation.Collections -> foundation_collections: the namespace
  ## without the `Windows` root every namespace of Windows.winmd shares (the
  ## generated `system` is imported as `./system`, which Nim's own module does
  ## not shadow).
  var name = ns
  name.removePrefix("Windows.")
  name.toLowerAscii.replace('.', '_')

func indexOf*(n: Naming, t: SigType): Option[int] =
  ## The m.types index of the type `t` refers to; none for one the metadata
  ## does not define.
  let name = fullName(t)
  if name in n.byName:
    some(n.byName[name])
  else:
    none(int)

func enumMembers(t: ModelType, name: string): seq[EnumMember] =
  ## The members of enum `t`, declared as `name`, in metadata order: each
  ## named after the enum (`AsyncStatus_Started`) and a value of its integer,
  ## `0'i32`, or `1'u32` for a UInt32 ([Flags]) one. Their names are not yet
  ## unique among the top-level names.
  let unsigned = t.underlying.prim == pvU4
  for f in t.fields:
    let bits = uint32(f.constant and 0xFFFF_FFFF'u64) # the 4 bytes on the wire
    let signed = cast[int32](bits)
    let value =
      if unsigned:
        fmt"{bits}'u32"
      else:
        fmt"{signed}'i32"
    result.add (fixIdent(fmt"{name}_{f.name}"), value)

# ---------------------------------------------------------------------------
# which module declares what
# ---------------------------------------------------------------------------

func inNamespaceModule(t: ModelType, isMoved: bool): bool =
  ## True if `t` is declared in a namespace module rather than in winrttypes:
  ## an interface, delegate or runtime class, or a moved struct.
  t.kind in {tkInterface, tkDelegate} or isMoved

func refNamespaces(n: Naming, moved: HashSet[int], t: SigType): HashSet[string] =
  ## The namespaces of what `t` mentions that a namespace module declares.
  case t.base
  of bNamed:
    let i = n.indexOf(t)
    if i.isSome and (n.names[i.get].isObject or i.get in moved):
      result.incl t.ns
  of bGenericInst:
    if n.indexOf(t).isSome:
      result.incl t.ns
    for a in t.args:
      result.incl refNamespaces(n, moved, a)
  of bPtr, bByRef, bArray, bSzArray:
    result = refNamespaces(n, moved, t.inner[])
  of bPrim, bTypeVar:
    discard

func refNamespaces(n: Naming, moved: HashSet[int], t: ModelType): HashSet[string] =
  ## The namespaces, other than its own, whose modules the declaration of `t`
  ## mentions.
  if t.defaultInterface.isSome:
    result.incl refNamespaces(n, moved, t.defaultInterface.get)
  for f in t.fields:
    result.incl refNamespaces(n, moved, f.ty)
  for fn in t.methods:
    result.incl refNamespaces(n, moved, fn.ret)
    for prm in fn.params:
      result.incl refNamespaces(n, moved, prm.ty)
  result.excl t.ns

func movedStructs(n: Naming, m: Model): HashSet[int] =
  ## The structs that move from winrttypes to beside the interfaces: one that
  ## mentions an interface (HttpProgress, for its IReference<UInt64> fields),
  ## and then, until nothing more moves, one that mentions a moved struct.
  var changed = true
  while changed:
    changed = false
    for i, t in m.types:
      if t.kind == tkStruct and i notin result and
          t.fields.anyIt(refNamespaces(n, result, it.ty).len > 0):
        result.incl i
        changed = true

func namespaceEdges(
    n: Naming, m: Model, moved: HashSet[int]
): Table[string, HashSet[string]] =
  ## Each namespace that has a namespace module, and the namespaces whose
  ## modules its declarations mention.
  for i, t in m.types:
    if inNamespaceModule(t, i in moved):
      result.mgetOrPut(t.ns, initHashSet[string]()).incl refNamespaces(n, moved, t)

func reachable(edges: Table[string, HashSet[string]], start: string): HashSet[string] =
  ## The namespaces `start` refers to, directly or through others.
  var pending = toSeq(edges.getOrDefault(start))
  while pending.len > 0:
    let ns = pending.pop()
    if ns notin result:
      result.incl ns
      pending.add toSeq(edges.getOrDefault(ns))

func cycles(edges: Table[string, HashSet[string]]): seq[seq[string]] =
  ## The namespaces grouped by the cycles they refer to each other in: two
  ## share a group when each reaches the other, and one in no cycle is a group
  ## of its own. The groups, and the namespaces in each, come out sorted.
  let namespaces = sorted(toSeq(edges.keys))
  let reach = namespaces.mapIt((it, reachable(edges, it))).toTable
  var placed: HashSet[string]
  for ns in namespaces:
    if ns notin placed:
      let group = namespaces.filterIt(it == ns or (it in reach[ns] and ns in reach[it]))
      placed.incl group.toHashSet
      result.add group

func placeModules*(n: Naming, m: Model, declarations: seq[Declaration]): seq[Module] =
  ## winrttypes, then the module of each group of namespaces, each followed by
  ## a shim per namespace when the group holds more than one; `declarations` are the
  ## types as they are declared, one per entry of m.types.
  let moved = movedStructs(n, m)
  let edges = namespaceEdges(n, m, moved)
  let groups = cycles(edges)
  var groupOf: Table[string, int]
  for g, namespaces in groups:
    for ns in namespaces:
      groupOf[ns] = g
  var types = Module(kind: mkTypes, name: "winrttypes", imports: @["winrtbase"])
  var spaces = groups.mapIt(
    Module(
      kind: mkNamespace,
      name: moduleName(it[0]) & (if it.len > 1: "_group" else: ""),
      namespaces: it,
    )
  )
  for i, t in m.types:
    if inNamespaceModule(t, i in moved):
      spaces[groupOf[t.ns]].declarations.add declarations[i]
    elif t.kind in {tkEnum, tkUnscopedEnum, tkStruct}:
      types.declarations.add declarations[i]
  let names = spaces.mapIt(it.name)
  for g in 0 ..< spaces.len:
    # the groups its namespaces refer to, other than its own
    let refs = spaces[g].namespaces.mapIt(toSeq(edges[it])).concat.mapIt(groupOf[it])
    let deps = refs.filterIt(it != g).sorted.deduplicate(isSorted = true)
    spaces[g].imports = @["winrtbase", "winrttypes"] & deps.mapIt(names[it])

  result.add types
  for space in spaces:
    result.add space
    if space.namespaces.len > 1:
      result.add space.namespaces.mapIt(
        Module(
          kind: mkShim, name: moduleName(it), namespaces: @[it], imports: @[space.name]
        )
      )

# ---------------------------------------------------------------------------
# what each type is called
# ---------------------------------------------------------------------------

func references*(m: Model): Naming =
  ## What resolving a reference to a type of `m` takes: the type a name is, and
  ## whether it crosses the ABI as a pointer; the types are not named yet.
  result.names =
    m.types.mapIt(TypeNames(isObject: it.kind in {tkInterface, tkDelegate}))
  for i, t in m.types:
    result.byName[fullName(t)] = i

func buildNaming*(m: Model): Naming =
  ## What each type of `m` is called, and every top-level name given out.
  var taken = NimKeywords.toHashSet
  # what winrtbase declares, and names `system` exports that would make a
  # reference ambiguous (as in the Win32 name plan)
  taken.incl [
    "GUID", "HRESULT", "HSTRING", "HSTRING_PRIVATE", "WCHAR", "IUnknown",
    "IUnknownVtbl", "IInspectable", "IInspectableVtbl", "IID_IUnknown",
    "IID_IInspectable", "guid", "TrustLevel", "TrustLevel_BaseTrust",
    "TrustLevel_PartialTrust", "TrustLevel_FullTrust", "File", "Fileinfo",
  ].map(nimIdentNormalize).toHashSet
  var n = references(m)
  # a type keeps its metadata name unless an earlier type has it; the ones that
  # do are named after all the others, so that the name a suffix makes (Nim
  # reads `IFoo_2` as `IFoo2`) is never the name of a type of the metadata
  let wanted = m.types.mapIt(fixIdent(stripArity(it.name)))
  var later: seq[int]
  for i, t in m.types:
    if nimIdentNormalize(wanted[i]) in taken:
      later.add i
    else:
      n.names[i].name = taken.freshIdent(wanted[i])
  for i in later:
    n.names[i].name = taken.freshIdent(wanted[i])
  # the names made up from a type's come after all of the metadata's, so that
  # on a clash they give way (`FooVtbl` to a type named FooVtbl)
  for i, t in m.types:
    if t.isClass:
      let constName = "RuntimeClass_" & fullName(t).replace('.', '_')
      n.names[i].classNameConst = taken.freshIdent(constName)
    elif t.kind in {tkInterface, tkDelegate}:
      n.names[i].vtableName = taken.freshIdent(n.names[i].name & "Vtbl")
      n.names[i].iidName = taken.freshIdent("IID_" & n.names[i].name)
  for i, t in m.types:
    if t.kind in {tkEnum, tkUnscopedEnum}:
      var members = enumMembers(t, n.names[i].name)
      for member in members.mitems:
        member.name = taken.freshIdent(member.name)
      n.names[i].enumMembers = members
  n.usedNames = taken
  n
