# test_tools.nim — the command-line tools, built and run on small winmds of
# the windows-rs submodule: winmd2nim picks its generator by the metadata and
# refuses the Win32 options for WinRT, and winmd2yaml decodes WinRT
# signatures (doAssert-based).
# Run: nim r --verbosity:0 tests/test_tools.nim  (or `nimble test`)

import std/[os, osproc, strutils]

const
  components = "windows-rs/crates/tools/reactor/winmd/"
  winrtWinmd = components & "Microsoft.Windows.System.Power.winmd"
  win32Winmd = components & "extras.winmd" # classic COM interfaces, constants

let dir = getTempDir() / "winmd_test_tools"
removeDir(dir)
createDir(dir)

proc build(tool: string): string =
  ## src/`tool`.nim built into the test's folder.
  result = dir / tool.addFileExt(ExeExt)
  let command =
    [getCurrentCompilerExe(), "c", "--hints:off", "--verbosity:0", "-o:" & result]
  let (output, code) = execCmdEx(quoteShellCommand(command) & " src/" & tool & ".nim")
  doAssert code == 0, output

proc run(exe: string, args: varargs[string]): tuple[output: string, exitCode: int] =
  ## `exe` run with `args`: what it printed, and its exit code.
  execCmdEx(quoteShellCommand(@[exe] & @args))

# --- winmd2nim ---

let winmd2nim = build("winmd2nim")

# WinRT metadata: the WinRT modules, with no word of the Win32 map
let winrtOut = dir / "winrt"
let winrt = run(winmd2nim, winrtWinmd, winrtOut)
doAssert winrt.exitCode == 0, winrt.output
doAssert "note:" notin winrt.output
for module in ["winrtbase", "winrttypes", "winrtgenerics"]:
  doAssert fileExists(winrtOut / module & ".nim")

# a winmd that holds nothing but its contract is WinRT metadata all the same
let contractOut = dir / "contract"
let contract = run(winmd2nim, components & "Microsoft.Foundation.winmd", contractOut)
doAssert contract.exitCode == 0 and "note:" notin contract.output, contract.output
doAssert fileExists(contractOut / "winrtbase.nim")

# the options and the map are for Win32 metadata: refused for WinRT, before
# anything is written
for args in [
  @["--headers", winrtWinmd, dir / "headers"],
  @["--lowercase", winrtWinmd, dir / "lowercase"],
  @[winrtWinmd, dir / "map", "data/type_headers.txt"],
]:
  let refused = run(winmd2nim, args)
  doAssert refused.exitCode == 1, refused.output
  doAssert "are for Win32 metadata" in refused.output
  doAssert not dirExists(args[^2]) and not dirExists(args[^1])

# Win32 metadata: the Win32 generator, which takes the options
let win32Out = dir / "win32"
let win32 = run(winmd2nim, "--headers", win32Winmd, win32Out)
doAssert win32.exitCode == 0, win32.output
doAssert fileExists(win32Out / "win32base.nim")

# --- winmd2yaml ---

# every signature of a WinRT winmd is decoded: a generic instantiation, a type
# variable in a MemberRef of a parameterised interface's method, an array, a
# property's type and a TypeSpec
let yaml = run(build("winmd2yaml"), components & "Microsoft.UI.winmd")
doAssert yaml.exitCode == 0
doAssert "undecoded" notin yaml.output
for expected in [
  "sig: \"void(Windows.Foundation.Collections.IVector`1<Microsoft.UI.Input.PointerPoint>)\"",
  "name: \"IndexOf\", type: \"boolean(!0, byref U4)\"",
  "type: \"Microsoft.UI.Input.NonClientRegionKind[]\"",
  "{name: \"AliceBlue\", flags: 0000, type: \"Windows.UI.Color\"}",
  "{type: \"Windows.Foundation.Collections.IIterable`1<Microsoft.UI.Composition.CompositionAnimation>\"}",
]:
  doAssert expected in yaml.output, expected

removeDir(dir)
echo "test_tools: all assertions passed"
