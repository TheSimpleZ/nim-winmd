# guid.nim — a GUID as the 16 bytes its text form spells, left to right:
# `96369f54-8eb6-48f0-abce-c1b211e627c3` is 0x96, 0x36, 0x9f, 0x54, 0x8e, ...
# (RFC 4122's order). In memory, where a GuidAttribute's blob stores it,
# Data1, Data2 and Data3 are little-endian instead; guidFromMemory is the one
# place that reorders.

import std/[sequtils, strformat, strutils]
import checksums/sha1

type Guid* = distinct array[16, byte]
  ## The 16 bytes of a GUID, in the order its text form spells them; distinct,
  ## so that what reads and prints a GUID applies to no other 16 bytes.

const memoryOrder = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
  ## Where in memory each byte of the text form sits: Data1 (4 bytes), Data2
  ## and Data3 (2 each) little-endian, then Data4 as is.

func `==`*(a, b: Guid): bool {.borrow.}

func bytes*(g: Guid): array[16, byte] =
  ## The 16 bytes of `g`, in the order its text form spells them.
  array[16, byte](g)

func toGuid(bytes: openArray[byte]): Guid =
  ## The GUID of the 16 `bytes`, in text order.
  var text: array[16, byte]
  text[0 .. ^1] = bytes
  Guid(text)

func guidFromMemory*(bytes: openArray[byte]): Guid =
  ## The GUID whose 16 bytes in memory are `bytes`: a GuidAttribute's value
  ## after its 2-byte prolog.
  doAssert bytes.len == 16, "a GUID is 16 bytes, not " & $bytes.len
  toGuid(memoryOrder.mapIt(bytes[it]))

func parseGuid*(s: string): Guid =
  ## The GUID the text `96369f54-8eb6-48f0-abce-c1b211e627c3` (or the same
  ## without dashes, in any case) spells.
  let hex = s.replace("-", "")
  doAssert hex.len == 32, "not a GUID: " & s
  toGuid(parseHexStr(hex).mapIt(byte(it)))

func `$`*(g: Guid): string =
  ## `96369f54-8eb6-48f0-abce-c1b211e627c3`, lowercase.
  let h = g.bytes.map(toHex).join.toLowerAscii
  fmt"{h[0 .. 7]}-{h[8 .. 11]}-{h[12 .. 15]}-{h[16 .. 19]}-{h[20 .. 31]}"

func nimLiteral*(g: Guid): string =
  ## `g` as the generated modules spell a GUID,
  ## `guid"96369f54-8eb6-48f0-abce-c1b211e627c3"`: winrtbase's `guid` turns
  ## the text into a `GUID` at compile time.
  &"guid\"{g}\""

func uuid5*(namespace: Guid, name: string): Guid =
  ## The version 5 UUID of `name` in `namespace` (RFC 4122): the SHA-1 of the
  ## namespace's bytes and the name, stamped with the version and variant.
  ## The Windows Runtime derives the IID of an instantiation of a
  ## parameterized interface this way, from its type signature.
  var u = Sha1Digest(secureHash(namespace.bytes.mapIt(char(it)) & @name))
  u[6] = (u[6] and 0x0F) or 0x50 # version 5
  u[8] = (u[8] and 0x3F) or 0x80 # the RFC 4122 variant
  toGuid(u[0 .. 15])
