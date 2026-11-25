#!/usr/bin/env python3
"""Dev tool: convert Auctionator's SavedVariables into a plain Lua file for offline tests.

    python3 -I Tools/dev/export_auctionator.py <path to WTF/.../SavedVariables/Auctionator.lua> /tmp/auctionator_plain.lua

Auctionator stores each realm's price database as one CBOR-encoded string; this decodes
it (minimal CBOR decoder: ints, strings, arrays, maps, floats) and writes:
    AUCTIONATOR_PRICE_DATABASE_PLAIN = { [realm] = { [dbKey] = { m=, l={}, h={}, a={} } } }
    AUCTIONATOR_VENDOR_PRICE_CACHE = {...}
"""
import re
import struct
import sys


def lua_unescape(raw):
    out = bytearray()
    i = 0
    n = len(raw)
    while i < n:
        c = raw[i]
        if c != 0x5C:  # backslash
            out.append(c)
            i += 1
            continue
        i += 1
        c = raw[i]
        simple = {ord("n"): 10, ord("t"): 9, ord("r"): 13, ord("a"): 7, ord("b"): 8,
                  ord("f"): 12, ord("v"): 11, ord("\\"): 92, ord('"'): 34, ord("'"): 39, 10: 10}
        if c in simple:
            out.append(simple[c])
            i += 1
        elif 0x30 <= c <= 0x39:
            j = i
            while j < n and j < i + 3 and 0x30 <= raw[j] <= 0x39:
                j += 1
            out.append(int(raw[i:j]) & 0xFF)
            i = j
        else:
            out.append(c)
            i += 1
    return bytes(out)


class CBOR:
    def __init__(self, b):
        self.b, self.i = b, 0

    def arg(self, info):
        if info < 24:
            return info
        size = {24: 1, 25: 2, 26: 4, 27: 8}[info]
        v = int.from_bytes(self.b[self.i:self.i + size], "big")
        self.i += size
        return v

    def item(self):
        ib = self.b[self.i]
        self.i += 1
        major, info = ib >> 5, ib & 31
        if major == 0:
            return self.arg(info)
        if major == 1:
            return -1 - self.arg(info)
        if major in (2, 3):
            ln = self.arg(info)
            s = self.b[self.i:self.i + ln]
            self.i += ln
            return s.decode("utf-8", "replace")
        if major == 4:
            return [self.item() for _ in range(self.arg(info))]
        if major == 5:
            d = {}
            for _ in range(self.arg(info)):
                k = self.item()
                d[k] = self.item()
            return d
        if major == 6:
            self.arg(info)
            return self.item()
        if major == 7:
            if info == 20: return False
            if info == 21: return True
            if info in (22, 23): return None
            if info == 25:
                v = struct.unpack(">e", self.b[self.i:self.i + 2])[0]; self.i += 2; return v
            if info == 26:
                v = struct.unpack(">f", self.b[self.i:self.i + 4])[0]; self.i += 4; return v
            if info == 27:
                v = struct.unpack(">d", self.b[self.i:self.i + 8])[0]; self.i += 8; return v
        raise ValueError(f"unsupported CBOR byte {ib:#x} at {self.i - 1}")


def lua_val(v):
    if isinstance(v, dict):
        return "{" + ",".join(f"[{lua_key(k)}]={lua_val(x)}" for k, x in v.items()) + "}"
    if isinstance(v, list):
        return "{" + ",".join(lua_val(x) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    if isinstance(v, (int, float)):
        return repr(v)
    return '"' + str(v).replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_key(k):
    return lua_val(k)


def main():
    src, out = sys.argv[1], sys.argv[2]
    raw = open(src, "rb").read()
    m = re.search(rb"AUCTIONATOR_PRICE_DATABASE = \{(.*?)\n\}\s*\nAUCTIONATOR_", raw, re.S)
    realms = {}
    for rm in re.finditer(rb'\["([^"]+)"\] = "((?:[^"\\]|\\.)*)"', m.group(1), re.S):
        realm = rm.group(1).decode()
        data = CBOR(lua_unescape(rm.group(2))).item()
        realms[realm] = data
        print(f"{realm}: {len(data)} items", file=sys.stderr)
    vm = re.search(rb"AUCTIONATOR_VENDOR_PRICE_CACHE = \{(.*?)\n\}\s*\n", raw, re.S)
    with open(out, "w") as f:
        f.write("AUCTIONATOR_PRICE_DATABASE_PLAIN = " + lua_val(realms) + "\n")
        f.write("AUCTIONATOR_VENDOR_PRICE_CACHE = {" + vm.group(1).decode("utf-8", "replace") + "\n}\n")


if __name__ == "__main__":
    main()
