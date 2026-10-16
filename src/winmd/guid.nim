# guid.nim — a GUID as the 16 bytes of its text, and RFC 4122 version 5 UUIDs.

import std/[sequtils, strformat, strutils]
import checksums/sha1

type Guid* = distinct array[16, byte] ## The bytes in text order.

const memoryOrder = [3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15]
  ## Data1-3 are little-endian in memory.

func `==`*(a, b: Guid): bool {.borrow.}

func bytes*(g: Guid): array[16, byte] =
  ## The bytes of `g`, in text order.
  array[16, byte](g)

func toGuid(bytes: openArray[byte]): Guid =
  ## The GUID of `bytes`, in text order.
  var text: array[16, byte]
  text[0 .. ^1] = bytes
  Guid(text)

func guidFromMemory*(bytes: openArray[byte]): Guid =
  ## The GUID whose bytes in memory are `bytes`, as in a GuidAttribute.
  doAssert bytes.len == 16, "a GUID is 16 bytes, not " & $bytes.len
  toGuid(memoryOrder.mapIt(bytes[it]))

func parseGuid*(s: string): Guid =
  ## `96369f54-8eb6-48f0-abce-c1b211e627c3`, dashes optional.
  let hex = s.replace("-", "")
  doAssert hex.len == 32, "not a GUID: " & s
  toGuid(parseHexStr(hex).mapIt(byte(it)))

func `$`*(g: Guid): string =
  ## `96369f54-8eb6-48f0-abce-c1b211e627c3`
  let h = g.bytes.map(toHex).join.toLowerAscii
  fmt"{h[0 .. 7]}-{h[8 .. 11]}-{h[12 .. 15]}-{h[16 .. 19]}-{h[20 .. 31]}"

func nimLiteral*(g: Guid): string =
  ## `guid"96369f54-8eb6-48f0-abce-c1b211e627c3"`
  &"guid\"{g}\""

func uuid5*(namespace: Guid, name: string): Guid =
  ## The RFC 4122 version 5 UUID of `name` in `namespace`.
  var u = Sha1Digest(secureHash(namespace.bytes.mapIt(char(it)) & @name))
  u[6] = (u[6] and 0x0F) or 0x50 # version 5
  u[8] = (u[8] and 0x3F) or 0x80 # the RFC 4122 variant
  toGuid(u[0 .. 15])
