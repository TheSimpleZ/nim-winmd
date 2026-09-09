# winmd2nim.nim — generate Nim modules exposing the Win32 API from a
# Windows metadata (.winmd) file.
#
# Usage:
#   winmd2nim.nim [--headers] [--lowercase] <input.winmd> <outdir> [type=header map file | rdl dir]
#
# --headers: attach a `header: "<stem>.h"` pragma to every type and
#   function whose defining header is known from the RDL/map provenance.
#   The compiler then treats it as declared in that C header (no C
#   declaration is emitted), so a cross-compiled build with -d:checkAbi
#   (mingw on Linux) can verify the generated layouts against the real
#   Windows headers — see tests/checkabi.nim. Constants get no pragma
#   (header implies nodecl).
#
# --lowercase: lowercase the first letter of function names (Nim
#   convention); the importc pragma keeps the real linkage name. When
#   the emitted name is exactly the C name (the default), the importc
#   pragma is bare.
#
# Writes into <outdir>:
#   win32base.nim   shared types (no header provenance), stubs
#   <header>.nim    types + constants + functions, one module per defining header
#   <dll>.nim       functions without header provenance, one module per export DLL

import std/[cmdline, dirs, files, paths, syncio, times, strutils, tables]
import ./winmd/[rdlmap, reader, model, generator]

# paramStr is 0-indexed including the program name, but paramCount()
# excludes it — iterate 1..paramCount() inclusive, collecting the
# positional args (options may precede them)
var emitHeaders = false
var lowerFirst = false
var args: seq[string] = @[]
var i = 1
while i <= paramCount():
  let a = paramStr(i)
  case a
  of "--headers":
    emitHeaders = true
  of "--lowercase":
    lowerFirst = true
  else:
    if a.len > 0 and a[0] == '-':
      echo "unknown option: ", a
      quit(1)
    args.add a
  inc i

if args.len < 2:
  echo "usage: winmd2nim [--headers] [--lowercase] <input.winmd> <outdir> [type=header map file | rdl dir]"
  quit(1)

# symbol name -> defining header stem; default: the committed provenance
# map (derived from the per-header RDL snapshot the winmd was built from)
var mapFile = "data/type_headers.txt"
if args.len >= 3:
  let a = args[2]
  if a.len > 0:
    mapFile = a
var typeHdr: Table[system.string, system.string]
if dirExists(Path(mapFile)):
  # a directory is the per-header RDL snapshot itself: read the .rdl
  # files directly (same mapping as the committed type=header map)
  typeHdr = readRdlMap(@[mapFile])
elif fileExists(Path(mapFile)):
  for line in lines(mapFile):
    let s = line.strip()
    if s.len == 0 or s[0] == '#':
      continue
    let eq = s.find('=')
    if eq > 0:
      typeHdr[s[0 ..< eq]] = s[eq + 1 .. s.high]
else:
  echo "note: no symbol=module map at ",
    mapFile, " — types fall back to DLL/base modules"

let t0 = epochTime()
let wa = reader.open(args[0])
let m = model.build(wa)
let outPath = args[1]
createDir(Path(outPath))
let mods = generateModules(m, typeHdr, emitHeaders, lowerFirst)
var total = 0
for gm in mods:
  writeFile($(Path(outPath) / Path(gm.name & ".nim")), gm.code)
  total += gm.code.len
echo "wrote ",
  $mods.len & " files to " & outPath & " (",
  $(total div 1024),
  " KiB total, ",
  $typeHdr.len,
  " map entries): ",
  m.types.len,
  " types, ",
  m.fns.len,
  " fns, ",
  m.consts.len,
  " consts in ",
  $(epochTime() - t0),
  "s"
