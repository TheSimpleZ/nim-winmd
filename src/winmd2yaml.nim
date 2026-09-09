import std/cmdline
import json, sequtils, strutils
import ./winmd/[signatures, reader]

let wa = reader.open(paramStr(1))

# ---- helpers -------------------------------------------------------------

## Hex-dump of a byte sequence ("01 02 ...").
proc hexBytes(b: seq[byte]): string =
  for i in 0 ..< b.len:
    if i > 0:
      result = result & " "
    result = result & toHex(b[i], 2)

## Render a decoded SigType tree (ECMA element-type names).
proc sigStr(t: SigType): string =
  case t.base
  of bPrim:
    case t.prim
    of pvVoid: "void"
    of pvBoolean: "boolean"
    of pvChar: "char"
    of pvI1: "I1"
    of pvU1: "U1"
    of pvI2: "I2"
    of pvU2: "U2"
    of pvI4: "I4"
    of pvU4: "U4"
    of pvI8: "I8"
    of pvU8: "U8"
    of pvR4: "R4"
    of pvR8: "R8"
    of pvString: "string"
    of pvI: "I"
    of pvU: "U"
  of bNamed:
    if t.ns.len > 0:
      t.ns & "." & t.name
    else:
      t.name
  of bPtr:
    "ptr " & sigStr(t.inner[])
  of bByRef:
    "byref " & sigStr(t.inner[])
  of bArray:
    "array[" & $t.arrLen & ", " & sigStr(t.inner[]) & "]"

## Render a decoded method signature as "ret(p1, p2, ...)"; undecodable
## blobs fall back to a hex dump.
proc methodSigStr(blob: seq[byte]): string =
  try:
    let ms = decodeMethodSig(wa, blob)
    result = sigStr(ms.ret) & "("
    for i in 0 ..< ms.params.len:
      if i > 0:
        result = result & ", "
      result = result & sigStr(ms.params[i])
    result = result & ")"
  except Exception:
    result = "<undecoded: " & hexBytes(blob) & ">"

## Render a decoded field/property/memberRef/typeSpec signature (prolog
## 0x06); undecodable blobs fall back to a hex dump.
proc fieldSigStr(blob: seq[byte]): string =
  try:
    result = sigStr(decodeFieldSig(wa, blob))
  except Exception:
    result = "<undecoded: " & hexBytes(blob) & ">"

# Owner maps for readable parent names (O(total), fine for a debug dump).
let owners = methodOwnerMap(wa)
var fieldOwners = newSeqWith(wa.rowCount(Field), -1)
for t in 0 ..< wa.rowCount(TypeDef):
  for f in wa.fieldsOf(t):
    fieldOwners[f] = t
var paramOwners = newSeqWith(wa.rowCount(MethodParam), -1)
for m in 0 ..< wa.rowCount(MethodDef):
  for p in wa.paramsOf(m):
    paramOwners[p] = m
var propOwners = newSeqWith(wa.rowCount(Property), -1)
for t in 0 ..< wa.rowCount(PropertyMap):
  for p in wa.propertiesOf(t):
    propOwners[p] = t
var eventOwners = newSeqWith(wa.rowCount(Event), -1)
for t in 0 ..< wa.rowCount(EventMap):
  for e in wa.eventsOf(t):
    eventOwners[e] = t

## Readable name for a coded reference (best effort; "" for the null value).
proc refName(cr: CodedRef): string =
  if cr.isNull:
    return ""
  case cr.kind
  of TypeDef:
    let t = wa.typeDef(cr.row)
    if t.namespace.len > 0:
      result = t.namespace & "." & t.name
    else:
      result = t.name
  of TypeRef:
    let t = wa.typeRef(cr.row)
    if t.namespace.len > 0:
      result = t.namespace & "." & t.name
    else:
      result = t.name
  of TypeSpec:
    result = "<typespec " & $cr.row & ">"
  of Module:
    result = wa.moduleRow(cr.row).name
  of ModuleRef:
    result = wa.moduleRef(cr.row).name
  of AssemblyRef:
    result = wa.assemblyRef(cr.row).name
  of Field:
    let owner = fieldOwners[cr.row]
    if owner >= 0:
      result = refName(typedRef(TypeDef, owner)) & "." & wa.field(cr.row).name
    else:
      result = wa.field(cr.row).name
  of MethodDef:
    let owner = owners[cr.row]
    if owner >= 0:
      result = refName(typedRef(TypeDef, owner)) & "." & wa.methodDef(cr.row).name
    else:
      result = wa.methodDef(cr.row).name
  of MethodParam:
    let m = paramOwners[cr.row]
    if m >= 0:
      result =
        refName(typedRef(MethodDef, m)) & ".param" & $wa.methodParam(cr.row).sequence
    else:
      result = "param" & $wa.methodParam(cr.row).sequence
  of Property:
    let owner = propOwners[cr.row]
    if owner >= 0:
      result = refName(typedRef(TypeDef, owner)) & "." & wa.property(cr.row).name
    else:
      result = wa.property(cr.row).name
  of Event:
    let owner = eventOwners[cr.row]
    if owner >= 0:
      result = refName(typedRef(TypeDef, owner)) & "." & wa.event(cr.row).name
    else:
      result = wa.event(cr.row).name
  else:
    result = "<0x" & toHex(byte(cr.kind), 2) & " " & $cr.row & ">"

echo "types:"
for i in 0 ..< wa.rowCount(TypeDef):
  let t = wa.typeDef(i)
  echo "  - name: ", escapeJson(t.name)
  if t.namespace.len > 0:
    echo "    ns: ", escapeJson(t.namespace)

  if t.extends.row != 0:
    echo "    extends: ", escapeJson(wa.typeName(t.extends))
  echo "    flags: 0x", toHex(t.flags)
  let fo = wa.fieldsOf(i)
  if fo.len > 0:
    echo "    fields:"
    for fi in fo:
      let f = wa.field(fi)
      echo "      - {name: ",
        escapeJson(f.name),
        ", flags: ",
        toHex(f.flags),
        ", type: ",
        escapeJson(fieldSigStr(f.signature)),
        "}"

echo "eventMaps:"
for i in 0 ..< wa.rowCount(EventMap):
  let t = wa.eventMap(i)
  echo "  - parent: ", escapeJson(wa.typeDef(t.parent).name)
  let eo = wa.eventsOf(i)
  if eo.len > 0:
    echo "    events:"
    for ei in eo:
      let e = wa.event(ei)
      echo "      - {name: ",
        escapeJson(e.name),
        ", flags: ",
        toHex(e.eventFlags),
        ", type: ",
        escapeJson(wa.typeName(e.eventType)),
        "}"

echo "propertyMaps:"
for i in 0 ..< wa.rowCount(PropertyMap):
  let t = wa.propertyMap(i)
  echo "  - parent: ", escapeJson(wa.typeDef(t.parent).name)
  let po = wa.propertiesOf(i)
  if po.len > 0:
    echo "    properties:"
    for pi in po:
      let p = wa.property(pi)
      echo "      - {name: ",
        escapeJson(p.name),
        ", flags: ",
        toHex(p.propertyFlags),
        ", type: ",
        escapeJson(fieldSigStr(p.`type`)),
        "}"

echo "modules:"
for i in 0 ..< wa.rowCount(Module):
  let m = wa.moduleRow(i)
  echo "  - {generation: ",
    $m.generation,
    ", name: ",
    escapeJson(m.name),
    ", mvid: 0x",
    toHex(m.mvid, 8),
    ", encId: 0x",
    toHex(m.encid, 8),
    ", encBaseId: 0x",
    toHex(m.encbaseid, 8),
    "}"

echo "typeRefs:"
for i in 0 ..< wa.rowCount(TypeRef):
  let t = wa.typeRef(i)
  echo "  - {scope: ",
    escapeJson(refName(t.resolutionScope)),
    ", name: ",
    escapeJson(t.name),
    ", ns: ",
    escapeJson(t.namespace),
    "}"

echo "methodDefs:"
for i in 0 ..< wa.rowCount(MethodDef):
  let m = wa.methodDef(i)
  let owner = owners[i]
  let ownerName =
    if owner >= 0:
      refName(typedRef(TypeDef, owner))
    else:
      ""
  echo "  - {name: ",
    escapeJson(m.name),
    ", owner: ",
    escapeJson(ownerName),
    ", flags: ",
    toHex(m.flags),
    ", implFlags: ",
    toHex(m.implFlags),
    ", rva: 0x",
    toHex(m.rva),
    ", sig: ",
    escapeJson(methodSigStr(m.signature)),
    "}"

echo "methodParams:"
for i in 0 ..< wa.rowCount(MethodParam):
  let p = wa.methodParam(i)
  echo "  - {flags: ",
    toHex(p.flags), ", sequence: ", $p.sequence, ", name: ", escapeJson(p.name), "}"

echo "interfaceImpls:"
for i in 0 ..< wa.rowCount(InterfaceImpl):
  let ii = wa.interfaceImpl(i)
  echo "  - {type: ",
    escapeJson(refName(typedRef(TypeDef, ii.typedef))),
    ", interface: ",
    escapeJson(refName(ii.interfaceType)),
    "}"

echo "memberRefs:"
for i in 0 ..< wa.rowCount(MemberRef):
  let mr = wa.memberRef(i)
  echo "  - {parent: ",
    escapeJson(refName(mr.parent)),
    ", name: ",
    escapeJson(mr.name),
    ", type: ",
    escapeJson(fieldSigStr(mr.signature)),
    "}"

echo "constants:"
for i in 0 ..< wa.rowCount(Constant):
  let c = wa.constant(i)
  echo "  - {parent: ",
    escapeJson(refName(c.parent)),
    ", type: 0x",
    toHex(c.typeTag, 2),
    ", value: ",
    escapeJson(hexBytes(c.value)),
    "}"

echo "customAttributes:"
for i in 0 ..< wa.rowCount(CustomAttribute):
  let a = wa.customAttribute(i)
  echo "  - {parent: ",
    escapeJson(refName(a.parent)),
    ", ctor: ",
    escapeJson(wa.ctorTypeName(a, owners)),
    ", value: ",
    escapeJson(hexBytes(a.value)),
    "}"

echo "classLayouts:"
for i in 0 ..< wa.rowCount(ClassLayout):
  let cl = wa.classLayout(i)
  echo "  - {type: ",
    escapeJson(refName(typedRef(TypeDef, cl.typedef))),
    ", packing: ",
    $cl.packing,
    ", size: ",
    $cl.classSize,
    "}"

echo "methodSemantics:"
for i in 0 ..< wa.rowCount(MethodSemantics):
  let ms = wa.methodSemantics(i)
  echo "  - {semantics: ",
    toHex(ms.semantics),
    ", method: ",
    escapeJson(refName(typedRef(MethodDef, ms.`method`))),
    ", association: ",
    escapeJson(refName(ms.association)),
    "}"

echo "moduleRefs:"
for i in 0 ..< wa.rowCount(ModuleRef):
  let mr = wa.moduleRef(i)
  echo "  - ", escapeJson(mr.name)

echo "typeSpecs:"
for i in 0 ..< wa.rowCount(TypeSpec):
  let ts = wa.typeSpec(i)
  echo "  - {type: ", escapeJson(fieldSigStr(ts.signature)), "}"

echo "implMaps:"
for i in 0 ..< wa.rowCount(ImplMap):
  let im = wa.implMap(i)
  let modName =
    if im.moduleRef < wa.rowCount(ModuleRef):
      wa.moduleRef(im.moduleRef).name
    else:
      "<none>"
  echo "  - {member: ",
    escapeJson(refName(im.memberForwarded)),
    ", importName: ",
    escapeJson(im.importName),
    ", module: ",
    escapeJson(modName),
    ", flags: ",
    toHex(im.flags),
    "}"

echo "assemblies:"
for i in 0 ..< wa.rowCount(Assembly):
  let a = wa.assembly(i)
  echo "  - {name: ",
    escapeJson(a.name),
    ", version: ",
    $a.major,
    ".",
    $a.minor,
    ".",
    $a.build,
    ".",
    $a.revision,
    ", flags: ",
    toHex(a.flags),
    ", culture: ",
    escapeJson(a.culture),
    ", publicKey: ",
    escapeJson(hexBytes(a.publicKey)),
    "}"

echo "assemblyRefs:"
for i in 0 ..< wa.rowCount(AssemblyRef):
  let a = wa.assemblyRef(i)
  echo "  - {name: ",
    escapeJson(a.name),
    ", version: ",
    $a.major,
    ".",
    $a.minor,
    ".",
    $a.build,
    ".",
    $a.revision,
    ", flags: ",
    toHex(a.flags),
    ", culture: ",
    escapeJson(a.culture),
    ", publicKeyToken: ",
    escapeJson(hexBytes(a.publicKeyToken)),
    "}"

echo "nestedClasses:"
for i in 0 ..< wa.rowCount(NestedClass):
  let nc = wa.nestedClass(i)
  echo "  - {inner: ",
    escapeJson(refName(typedRef(TypeDef, nc.innerType))),
    ", enclosing: ",
    escapeJson(refName(typedRef(TypeDef, nc.enclosingType))),
    "}"

echo "genericParams:"
for i in 0 ..< wa.rowCount(GenericParam):
  let g = wa.genericParam(i)
  echo "  - {number: ",
    $g.number,
    ", flags: ",
    toHex(g.flags),
    ", owner: ",
    escapeJson(refName(g.owner)),
    ", name: ",
    escapeJson(g.name),
    "}"
