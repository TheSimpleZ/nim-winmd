# ---------------------------------------------------------------------------
# RDL provenance reader — direct alternative to the type=header map file
# ---------------------------------------------------------------------------

import std/[algorithm, dirs, os, paths, strutils, tables]

## Extract the declared name from a single RDL line, or "" when the line
## declares nothing. Covers the same declaration forms as the committed
## type=header map extraction (see _exper/plan.md):
##   struct/union/interface/enum NAME,   type NAME =,
##   [extern ["C"]] fn NAME(,           const NAME:
## Optional `#[...]` attribute groups may precede the keyword. Method
## declarations inside interface blocks are captured too — harmless, since
## method names are never TypeDefs in the winmd.
proc rdlDeclName(line: string): string =
  const idChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  # skip #[...] attribute groups
  while i + 1 < line.len and line[i] == '#' and line[i + 1] == '[':
    let j = line.find(']', i)
    if j < 0:
      return ""
    i = j + 1
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
  # keyword
  var k = i
  while k < line.len and line[k] in idChars:
    inc k
  var kw = line[i ..< k]
  i = k
  # extern ["C"] fn -> fn
  if kw == "extern":
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
    if i + 2 < line.len and line[i] == '"' and line[i + 2] == '"':
      i += 3
      while i < line.len and line[i] in {' ', '\t'}:
        inc i
    var k2 = i
    while k2 < line.len and line[k2] in idChars:
      inc k2
    if line[i ..< k2] != "fn":
      return ""
    i = k2
    kw = "fn"
  while i < line.len and line[i] in {' ', '\t'}:
    inc i
  # declared name
  var j = i
  while j < line.len and line[j] in idChars:
    inc j
  if j <= i:
    return ""
  let name = line[i ..< j]
  i = j
  case kw
  of "struct", "union", "interface", "enum":
    result = name
  of "type":
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
    if i < line.len and line[i] == '=':
      result = name
  of "fn":
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
    if i < line.len and line[i] == '(':
      result = name
  of "const":
    while i < line.len and line[i] in {' ', '\t'}:
      inc i
    if i < line.len and line[i] == ':':
      result = name
  else:
    discard

## Top-level *.rdl files of a directory (walkDir is not recursive)
iterator rdlFilesIn(dir: string): string =
  for kind, path in walkDir(Path(dir)):
    if kind == pcFile and ($path).endsWith(".rdl"):
      yield $path

## Build the type-name -> header-stem provenance map by reading the
## per-header RDL snapshot directly — the same mapping the committed
## data/type_headers.txt encodes: every declared name maps to the stem of
## the .rdl file it is declared in, and a name declared in several files
## maps to the alphabetically-last stem (the committed map was sort -u'd,
## so the last sorted pair wins).
##
## A directory holding the windows-rs metadata layout (<dir>/win32/*.rdl
## + <dir>/wdk/*.rdl) is expanded to those two subdirectories; the
## winrt/ subtree holds WinRT namespaces — a different provenance domain
## — and is excluded. Any other directory is scanned as-is.
proc readRdlMap*(rdlDirs: seq[string]): Table[string, string] =
  var files: seq[string]
  for d in rdlDirs:
    if dirExists(Path(d / "win32")) and dirExists(Path(d / "wdk")):
      for f in rdlFilesIn(d / "win32"):
        files.add f
      for f in rdlFilesIn(d / "wdk"):
        files.add f
    else:
      for f in rdlFilesIn(d):
        files.add f

  var pairs: seq[string]
  for f in files:
    let (_, name, ext) = f.splitFile()
    if ext == ".rdl":
      for line in lines(f):
        let nm = rdlDeclName(line)
        if nm.len > 0:
          pairs.add nm & '=' & name

  # sort so the alphabetically-last stem wins per name (sort -u semantics)
  pairs.sort
  for p in pairs:
    let eq = p.find('=')
    result[p[0 ..< eq]] = p[eq + 1 .. p.high]
