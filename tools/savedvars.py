"""Parse a WoW SavedVariables .lua file as DATA (never executed) into Python objects.

Supports the subset WoW writes: assignments `Name = value`, tables with
["key"] = v / [n] = v / positional entries, strings with Lua escapes,
numbers, true/false/nil, and -- comments.

Usage: python -I savedvars.py <input.lua> <output.json>
"""
import json
import re
import sys

_NUM = re.compile(rb"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|inf|nan)")
_IDENT = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_ESC = {b"n": b"\n", b"r": b"\r", b"t": b"\t", b"a": b"\a", b"b": b"\b", b"f": b"\f",
        b"v": b"\v", b"\\": b"\\", b'"': b'"', b"'": b"'", b"\n": b"\n"}


class Parser:
    def __init__(self, data: bytes):
        self.s = data
        self.i = 0

    def ws(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in b" \t\r\n,;":
                self.i += 1
            elif s.startswith(b"--", self.i):
                j = s.find(b"\n", self.i)
                self.i = n if j < 0 else j + 1
            else:
                break

    def string(self):
        q = self.s[self.i:self.i + 1]
        self.i += 1
        out = bytearray()
        s = self.s
        while True:
            c = s[self.i:self.i + 1]
            if c == q:
                self.i += 1
                break
            if c == b"\\":
                nxt = s[self.i + 1:self.i + 2]
                if nxt.isdigit():
                    m = re.match(rb"\d{1,3}", s[self.i + 1:self.i + 4])
                    out.append(int(m.group()))
                    self.i += 1 + len(m.group())
                else:
                    out += _ESC.get(nxt, nxt)
                    self.i += 2
            else:
                out += c
                self.i += 1
        return out.decode("utf-8", errors="surrogateescape")

    def value(self):
        self.ws()
        c = self.s[self.i:self.i + 1]
        if c == b"{":
            return self.table()
        if c in (b'"', b"'"):
            return self.string()
        m = _IDENT.match(self.s, self.i)
        if m and m.group() in (b"true", b"false", b"nil"):
            self.i = m.end()
            return {b"true": True, b"false": False, b"nil": None}[m.group()]
        m = _NUM.match(self.s, self.i)
        if not m:
            raise ValueError(f"unexpected {self.s[self.i:self.i + 30]!r} at {self.i}")
        self.i = m.end()
        t = m.group()
        if t.lower().startswith((b"0x", b"-0x")):
            return int(t, 16)
        f = float(t)
        return int(f) if f.is_integer() and b"." not in t and b"e" not in t.lower() else f

    def table(self):
        self.i += 1
        d, arr = {}, []
        while True:
            self.ws()
            if self.s[self.i:self.i + 1] == b"}":
                self.i += 1
                break
            if self.s[self.i:self.i + 1] == b"[":
                self.i += 1
                k = self.value()
                self.ws()
                assert self.s[self.i:self.i + 1] == b"]", self.i
                self.i += 1
                self.ws()
                assert self.s[self.i:self.i + 1] == b"=", self.i
                self.i += 1
                d[k] = self.value()
                continue
            m = _IDENT.match(self.s, self.i)
            if m:
                j = m.end()
                while j < len(self.s) and self.s[j] in b" \t":
                    j += 1
                if self.s[j:j + 1] == b"=" and self.s[j:j + 2] != b"==":
                    self.i = j + 1
                    d[m.group().decode()] = self.value()
                    continue
            arr.append(self.value())
        if arr and not d:
            return arr
        for n, v in enumerate(arr, 1):
            d[n] = v
        # dense integer keys 1..n -> list
        if d and all(isinstance(k, int) for k in d) and sorted(d) == list(range(1, len(d) + 1)):
            return [d[k] for k in range(1, len(d) + 1)]
        return d

    def assignments(self):
        out = {}
        while True:
            self.ws()
            if self.i >= len(self.s):
                return out
            m = _IDENT.match(self.s, self.i)
            if not m:
                raise ValueError(f"expected name at {self.i}")
            self.i = m.end()
            self.ws()
            assert self.s[self.i:self.i + 1] == b"=", self.i
            self.i += 1
            out[m.group().decode()] = self.value()


def load(path):
    with open(path, "rb") as fh:
        return Parser(fh.read()).assignments()


def _jsonable(o):
    if isinstance(o, dict):
        return {str(k): _jsonable(v) for k, v in o.items()}
    if isinstance(o, list):
        return [_jsonable(v) for v in o]
    return o


if __name__ == "__main__":
    data = load(sys.argv[1])
    with open(sys.argv[2], "w", encoding="utf-8") as fh:
        json.dump(_jsonable(data), fh, ensure_ascii=False)
    print("parsed:", ", ".join(data))
