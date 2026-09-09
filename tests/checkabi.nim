# checkabi.nim — ABI check of the generated win32 bindings against the
# mingw-w64 Windows headers.
#
# The generated modules are built with the generator's --headers option:
# every type and function with known RDL provenance carries a
# `header: "stem.h"` pragma, which makes the compiler treat it as declared
# in that C header (no C declaration is emitted). With -d:checkAbi the
# compiler then writes a NIM_STATIC_ASSERT(sizeof(<C type>) == <Nim size>)
# into the C file for every type that appears there; the volatile variables
# below force the types in. The C compiler (mingw, cross-compiled from
# Linux) verifies the generated layouts against the real Windows headers at
# compile time; a mismatch is a C compile error.
#
# Run via `nimble checkabi`, or manually:
#     nim c -d:mingw -d:checkAbi --cc:env --threads:off \
#     --path:gen_hdr -o:checkabi checkabi.nim
#   wine checkabi.exe

import gen_hdr/[windef, guiddef, minwindef, minwinbase, winuser, processthreadsapi]

template ensureCgen(T: typedesc) =
  ## force the type into the C file so -d:checkAbi can verify it
  var a {.volatile.}: T

# representative types across several headers
ensureCgen POINT
ensureCgen RECT
ensureCgen GUID
ensureCgen FILETIME
ensureCgen SECURITY_ATTRIBUTES
ensureCgen WIN32_FIND_DATAA
ensureCgen MSG
ensureCgen WINDOWPLACEMENT
ensureCgen STARTUPINFOA
ensureCgen PROCESS_INFORMATION

# the FFI surface works under wine: call a real API (the desktop window
# handle is non-nil; HWND is a distinct pointer, so compare via its base)
doAssert cast[pointer](GetDesktopWindow()) != nil

echo "checkAbi: all 10 types verified against the mingw headers"
