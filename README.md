# nim-winmd

Library and tools for interacting with ECMA-335 / WinMD / Windows metadata files.

Useful for generating Nim API bindings for Windows libraries, including an
accurate rendering of the full Win32 API.

This project is a Nim adaptation of [win32metadata](https://github.com/microsoft/win32metadata)
and [windows-rs](https://github.com/microsoft/windows-rs/), using the same
approach and source material to provide Nim access to Windows APIs.

Similar to `windows-rs`, the aim is to generate bindings that are faithful to
the original Windows SDK, serving as a low-level ABI compatibility tool more
so than a high-level Nim projection.

A key feature is that once generated, the bindings do not require a C header
file to be present, which makes life easier and enables their safe use with
[nlvm](https://github.com/arnetheduck/nlvm/).

See [this document](https://gist.github.com/kennykerr/05c9fd30c5f544e01b1d14df79a8976f)
for a discussion on the difference between the `windows-rs` and `win32metadata`
approaches.

## Tools

Two standalone binaries are provided - the winmd reader in particular can also
be used as a library in your own project:

### `winmd2nim` — Nim binding generator

Reads a `.winmd` file and writes Nim modules covering its full API surface
(types, constants, and functions with matching ABI).

```
nim c -d:release src/winmd2nim.nim
src/winmd2nim <input.winmd> <outdir> [symbol=module map file | rdl dir]
```

It needs the `checksums` package (`nimble install checksums`), the
official home of what was `std/sha1`.

Arguments:

* `<input.winmd>` — the metadata file, e.g. `Windows.Win32.winmd`
* `<outdir>` — output directory (created if missing)
* optional third argument — symbol-to-module map:
  * a text file of `symbol=module` lines (default: `type_headers.txt`), or
  * a directory containing the per-header RDL snapshot the winmd was built
    from (e.g. the `metadata/` directory of the `windows-rs` project); the
    declared names in the `.rdl` files are read directly and produce the same
    mapping as `type_headers.txt` file

Output layout:

* `win32base.nim` — shared types without header provenance (only when non-empty)
* `<mapped_name>.nim` — names taken from name mapping file
* `<dll>.nim` — one module per export DLL, as declared in the `winmd` file

The name mapping file, or equivalently the `.rdl` files, assign names to specific
Nim modules based on the header they originated from instead of relying on
namespace and dll name found in the .winmd file.

Given WinRT metadata (`Windows.winmd`), the output is the Windows Runtime ABI
instead: `winrtbase.nim` (`GUID`, `HRESULT`, `HSTRING`, `WCHAR`, `IUnknown`,
`IInspectable`), `winrttypes.nim` (every enum, and every struct that mentions
no interface), `winrtgenerics.nim` (the IIDs of the instantiations of
parameterised interfaces, `IID_IVector_HSTRING`) and one module per namespace,
named without the `Windows` root every namespace shares (`foundation.nim`,
`ui_xaml.nim`, ...), with its interfaces, delegates and runtime classes, and
the structs that mention them: an interface is an object whose `lpVtbl` points
to its vtable, as in the SDK headers. Namespaces that refer to each other in a
cycle (Nim modules cannot) share one module, `applicationmodel_group.nim`,
which each of their modules re-exports, so `import storage` works either way.
An enum is a distinct type over its integer with its members as constants
(`AsyncStatus_Started`), as windows-rs has them, so it holds any value Windows
returns; [Flags] ones combine with `or` and `and`, and test with `in`. Every
method returns `HRESULT`, the declared return becoming a trailing `retval`
out-parameter; a runtime class is its default interface. An IID is a `GUID`
constant named after its type and written as text, which `winrtbase`'s `guid`
turns into a `GUID` at compile time
(`IID_IStringable*: GUID = guid"96369f54-8eb6-48f0-abce-c1b211e627c3"`):
`IID_IStringable` for an interface or delegate,
`IID_IVector` for a parameterised one and `IID_IVector_HSTRING` for an
instantiation. Besides what the enums borrow (and `winrtbase`'s `guid`), the
output is types and constants, as the Win32 generator's; a friendlier layer
belongs in a library on top. See `tests/winrtabi.nim` for an example.
The IIDs of instantiations exist for the instantiations the metadata mentions,
which is every one a Windows API can hand out, not for ones of your own.
A name two namespaces share is kept by the first type and suffixed on the
other (`AnimationDirection_2`, whose members are `AnimationDirection_2_Left`,
...), never taking the name of a type of the metadata.

The WinRT metadata should define every type it mentions, as the SDK's union
metadata (`UnionMetadata\<version>\Windows.winmd`) and the windows-rs copy do.
From a winmd that mentions the types of another (a contract winmd of the SDK,
or a component's, such as WinUI's), a method that mentions one is a bare
`pointer` in its vtable, a struct with a field of one is left out, its layout
unknown, and so is a runtime class whose default interface is one; a classic
COM interface (a type without the `WindowsRuntime` flag) is left out too. The
options and the map are for Win32 metadata, and refused for WinRT.

### `winmdyaml` — winmd YAML dumper

Prints a YAML representation of the contents in a `.winmd` file:

```
nim c -d:release src/winmd2nim/winmd.nim
./src/winmd2nim/winmd <file.winmd> > file.yaml
```

## Tasks

The repository has nimble tasks (`nimble tasks`):

* `nimble test` — run all test suites (the `tests/test_*.nim` files found
  via `walkDir`)
* `nimble checkabi` — ABI-check the generated bindings against the
  mingw-w64 Windows headers (cross-compiled from Linux, run under wine)
* `nimble win32abi` — regenerate the bindings into `../nim-win32-abi`
  (writing a `SOURCE.env` with git provenance tags); the bindings are
  generated with `--headers` by default, and extra `winmd2nim` flags
  (e.g. `--lowercase`) go in the `WINMDFLAGS` environment variable
* `nimble winrtcheck` — generate the WinRT modules and call the Windows
  Runtime through them (Windows only)
* `nimble winrtfull` — generate the WinRT modules and compile all of them
  (import every one)

The winrt tasks read the windows-rs copy of `Windows.winmd`, or the file
`WINRT_WINMD` names (the SDK's union metadata, for instance). The tasks
compile with the `nim` nimble puts first, its own copy when it has installed
one for the package; if that one does not match your C compiler, run them
with `nimble --useSystemNim <task>`.

The tests and the tools use the `windows-rs` git submodule at the repo
root (the winmd and the per-header RDL snapshot); the `winmd2nim` /
`winmd2yaml` binaries take the paths as command line arguments.

## Conventions

For each API declared in the `.winmd` file, the generator outputs a Nim
declaration with matching ABI.

As such, the original C header files are no longer needed - the API can be used
directly from Nim.

Bindings are organised in modules based on their provenance - header or dll name
depending on whether a symbol map was used (either as a text file or rdl).

Unlike the Windows SDK, ECMA-335 declares most ABI functions using plain
primitive types - `uint32` instead of `DWORD`.

Where the `.winmd` file makes the information available, more specific
type names may be used as plain aliases. `COLORREF` for example is a plain
alias of `uint32`.

Types, methods and aliases are marked by `mdtype`, `mdmethod`, `mdalias` and
`mdinterface` pragmas.

With the `--headers` option, an addition `mdheader` pragma is add - when the
program is compiled with `-d:checkAbi` or `-d:mdheaders`, `mdheader` is expanded
to a `{.header.}` pragma that causes Nim to use the declaration from the header
instead of its own. This mode is useful for verifying that the generator
agrees on the ABI with the C compiler - see also the `checkAbi` task.

* [Windows data types](https://learn.microsoft.com/en-us/windows/win32/winprog/windows-data-types)
* [ECMA-335 types](https://github.com/stakx/ecma-335/blob/master/docs/ii.23.1.16-element-types-used-in-signatures.md)

### Structs

Structs are mapped 1:1 to Nim objects. The C types often contain anonymous
nested structs and unions - these are mapped to a named field.

### A/W variants

Many functions and types in Windows has A/W variants which refer to ANSI and Wide / Unicode
encodings for strings.

Although `W` has been the  recommened option for some time, `A` variants have recently
seen a [resurgence](https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page#-a-vs--w-apis)
with the popularity of UTF-8.

Since there's no clear guidance here, `nim-winmd` will keep both around and
not generate shortcut aliases. This may change as the dust settles on this debate.

### Strings

Strings often appear as the equivalent of `ptr int8` in WinMD files and the binding
generator currently does not attempt to curate this this to `cstring` since
`cstring` needs to be 0-terminated and a general `ptr int8` might not be.

As an exception to the general rule of avoiding hand-curation, `LPSTR`, `PSTR`
(and the `PC*`/`LPC*` variants) get emitted as `cstring`, and the wide
variants (`LPWSTR`, `PWSTR`, ...) as `ptr UncheckedArray[uint16]` — same
ABI, no import required.

### Methods

Methods in the metadata are mapped to `proc` in Nim.

Method names are kept as-is by default (exactly the C name).

With the `--lowercase` option, the initial letter is lowercased to adhere to Nim
standards and avoid trivial conflicts with types due to the lax identifier
equivalence rules in Nim; the `importc` pragma then spells the real linkage name.

Where conflicts still happen, names get numbered suffixes.

### Interfaces

COM interfaces (`IUnknown` etc) are generated as opaque types (`object`)
and are always passed by pointer in the C ABI.

VTables are currently not generated (TODO).

## Resources

* [ECMA-335](https://ecma-international.org/wp-content/uploads/ECMA-335_6th_edition_june_2012.pdf) as PDF
* [ECMA-335](https://github.com/stakx/ecma-335) in a convenient text format
* [WinMD](https://learn.microsoft.com/en-us/uwp/winrt-cref/winmd-files) entry point from Microsoft
