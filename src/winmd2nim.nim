# winmd2nim.nim — generate Nim modules exposing the Win32 API from a
# Windows metadata (.winmd) file.
#
# Usage:
#   winmd2nim.nim [--headers] [--lowercase] <input.winmd> <outdir> [type=header map file | rdl dir]
#   winmd2nim.nim [--reference:<path>=<winmd>]... <input.winmd>... <outdir>   (WinRT)
#
# --headers: with this option, a `when defined(checkAbi) or
# defined(mdheaders):` block defines `{.pragma: mdheader,
# header: "<stem>.h".}` (empty in the else branch) for the module's
# defining header, and mdmethod / mdtype / mdalias / mdinterface
# include mdheader.
#
# The header pragma makes the compiler treat the symbol as
# declared in that C header (no C declaration is emitted), so a
# build with -d:checkAbi can verify the generated layouts against the real
# Windows headers — see tests/checkabi.nim.

# A header that cannot be included directly in the C file (e.g. winnt.h) is
# replaced by another (windef.h) or gets no mdheader at all.
# Without --headers, no header / checkAbi pragmas are emitted or used.
#
# --lowercase: lowercase the first letter of function names (Nim
#   convention); the importc pragma keeps the real linkage name. When
#   the emitted name is exactly the C name (the default), the importc
#   pragma is bare.
#
# --reference:<path>=<winmd> (WinRT): a binding already written from <winmd>,
#   whose modules are imported as <path> (`winrt/abi`). Its types are named,
#   not declared again, and spelled with an alias, the first segment of
#   <path>: `winrt.Point`. Repeat it for each winmd of that binding, and for
#   each binding, in the order they were written.
#
# Writes into <outdir>:
#   win32base.nim   shared types (no header provenance), stubs
#   <header>.nim    types + constants + functions, one module per defining header
#   <dll>.nim       functions without header provenance, one module per export DLL
# or, for WinRT metadata, the WinRT modules (see README), without options.

import std/[cmdline, dirs, files, paths, syncio, times, strutils, tables]
import ./winmd/[rdlmap, reader, model, generator, winrtgen]

# paramStr is 0-indexed including the program name, but paramCount()
# excludes it — iterate 1..paramCount() inclusive, collecting the
# positional args (options may precede them)
var emitHeaders = false
var lowerFirst = false
var references: seq[(string, string)] = @[] # (path, winmd)
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
    if a.startsWith("--reference:") and '=' in a:
      let spec = a["--reference:".len .. ^1]
      let eq = spec.find('=')
      references.add (spec[0 ..< eq], spec[eq + 1 .. ^1])
      inc i
      continue
    if a.len > 0 and a[0] == '-':
      echo "unknown option: ", a
      quit(1)
    args.add a
  inc i

if args.len < 2:
  echo "usage: winmd2nim [--headers] [--lowercase] <input.winmd> <outdir> [type=header map file | rdl dir]"
  echo "       winmd2nim [--reference:<path>=<winmd>]... <input.winmd>... <outdir>   (WinRT)"
  quit(1)

let t0 = epochTime()
let wa = reader.open(args[0])
var m = model.build(wa)
let isWinrt = isWinrtMetadata(wa)
if isWinrt and (emitHeaders or lowerFirst):
  echo "--headers and --lowercase are for Win32 metadata; ",
    args[0], " is WinRT metadata"
  quit(1)
if not isWinrt and references.len > 0:
  echo "--reference is for WinRT metadata; ", args[0], " is Win32 metadata"
  quit(1)
# WinRT: every argument but the last is a winmd, and the last the output
# directory, which a Win32 map given after it would be taken for
if isWinrt:
  var misplaced = fileExists(Path(args[^1]))
  for a in args[1 ..< ^1]:
    misplaced = misplaced or not fileExists(Path(a))
  if misplaced:
    echo "a map is for Win32 metadata; ",
      args[0],
      " is WinRT metadata, ",
      "whose arguments are winmds and then the output directory"
    quit(1)

# WinRT: every argument but the last is a winmd of this binding, and each
# reference's winmds, grouped by path in the order given, a binding beneath it
var refs: seq[Reference]
if isWinrt:
  for a in args[1 ..< ^1]:
    m.types.add model.build(reader.open(a)).types
  for (path, winmd) in references:
    if refs.len == 0 or refs[^1].path != path:
      refs.add Reference(alias: path.split('/')[0], path: path)
    refs[^1].model.types.add model.build(reader.open(winmd)).types

# symbol name -> defining header stem; default: the committed provenance
# map (derived from the per-header RDL snapshot the winmd was built from)
var mapFile = "data/type_headers.txt"
if not isWinrt and args.len >= 3:
  let a = args[2]
  if a.len > 0:
    mapFile = a
var typeHdr: Table[system.string, system.string]
if isWinrt:
  discard
elif dirExists(Path(mapFile)):
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

let outPath =
  if isWinrt:
    args[^1]
  else:
    args[1]
createDir(Path(outPath))
let mods =
  if isWinrt:
    generateWinrtModules(m, refs)
  else:
    generateModules(m, typeHdr, emitHeaders, lowerFirst)
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
