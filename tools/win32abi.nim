# tools/win32abi.nim — generate the Win32 API bindings (per-header
# + per-DLL modules) into ../nim-win32-abi (`nimble win32abi`).

import std/[envvars, dirs, paths, syncio, osproc, strutils]

const WINMD = "windows-rs/crates/libs/default/Windows.Win32.winmd"
const RDL = "windows-rs/metadata"
const OUT = "../nim-win32-abi/win32/abi"

# Provenance tag for a git checkout: full commit hash,
# "<hash>+dirty" when the worktree is dirty, "unavailable" when the
# directory is not a git checkout with commits.
proc gitTag(dir: string): string =
  if execCmd("git -C '" & dir & "' rev-parse HEAD > /dev/null") != 0:
    result = "unavailable"
    return
  # execCmdEx: execCmd returns only the exit code (no output capture)
  let hash = execCmdEx("git -C '" & dir & "' rev-parse HEAD").output.strip
  # a non-empty `status --porcelain` (modified, staged or untracked)
  # means the worktree is dirty
  if execCmd("test -z \"$(git -C '" & dir & "' status --porcelain)\"") == 0:
    result = hash
  else:
    result = hash & "+dirty"

if execCmd("nimble build winmd2nim -d:release") != 0:
  quit 1

removeDir(Path(OUT))
createDir(Path(OUT))

let flags = getenv("WINMDFLAGS")

if execCmd("./winmd2nim " & flags & " " & WINMD & " " & OUT & " " & RDL) != 0:
  quit 1

writeFile(
  "../nim-win32-abi/SOURCE.env",
  "WINDOWS_RS_GIT=" & gitTag("windows-rs") & "\n" & "NIM_WINMD_GIT=" & gitTag(".") & "\n",
)
