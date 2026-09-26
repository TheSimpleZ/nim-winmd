# test_guid.nim — the GUID type: byte order between memory and text, the
# generated literal, and version 5 UUIDs (doAssert-based).
# Run: nim r --verbosity:0 tests/test_guid.nim  (or `nimble test`)

import std/strutils
import ../src/winmd/guid

# a Guid holds the bytes the text spells, in its order
let stringable = parseGuid("96369f54-8eb6-48f0-abce-c1b211e627c3")
doAssert stringable.bytes == [
  0x96'u8, 0x36, 0x9f, 0x54, 0x8e, 0xb6, 0x48, 0xf0, 0xab, 0xce, 0xc1, 0xb2, 0x11, 0xe6,
  0x27, 0xc3,
]
doAssert $stringable == "96369f54-8eb6-48f0-abce-c1b211e627c3"
# a Guid is distinct: other 16 bytes print as an array, not as a GUID
doAssert ($stringable.bytes).startsWith("[150, 54, 159, 84, ")
doAssert parseGuid("96369F548EB648F0ABCEC1B211E627C3") == stringable

# what a GuidAttribute's blob holds after its prolog: the bytes in memory,
# Data1, Data2 and Data3 little-endian
let inMemory = [
  0x54'u8, 0x9f, 0x36, 0x96, 0xb6, 0x8e, 0xf0, 0x48, 0xab, 0xce, 0xc1, 0xb2, 0x11, 0xe6,
  0x27, 0xc3,
]
let blob = @[0x01'u8, 0x00] & @inMemory & @[0x00'u8, 0x00]
doAssert guidFromMemory(blob.toOpenArray(2, 17)) == stringable

doAssert nimLiteral(stringable) == "guid\"96369f54-8eb6-48f0-abce-c1b211e627c3\""

# RFC 4122's own example: the DNS namespace and www.example.com
doAssert uuid5(parseGuid("6ba7b810-9dad-11d1-80b4-00c04fd430c8"), "www.example.com") ==
  parseGuid("2ed6657d-e927-568b-95e1-2665a8aea6a2")

# the IID of IVector<String>, as the SDK headers declare it: the WinRT
# pinterface namespace and the instantiation's type signature
doAssert uuid5(
  parseGuid("11f47ad5-7b73-42c0-abae-878b1e16adee"),
  "pinterface({913337e9-11a1-4345-a3a2-4e7f956e222d};string)",
) == parseGuid("98b9acc1-4b56-532e-ac73-03d5291cca90")

echo "test_guid: all assertions passed"
