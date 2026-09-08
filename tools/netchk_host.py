#!/usr/bin/env python3
"""Host end of tools/netchk.c: serve or check the same self-describing stream.

The board connects; this listens.  The pattern is tools/patwr's -u pattern,
byte for byte -- byte 2i is 0x80 and byte 2i+1 is i&0xff, repeating every 512
bytes -- so a wrong word here and a wrong word on a disk are the same
signature and the two measurements can be compared directly.

  netchk_host.py send <mbytes>    feed the board (tests DMA into memory)
  netchk_host.py recv             check what the board sends (tests DMA out)
"""
import socket, sys

PORT = 5555
CHUNK = 1 << 16


def pattern(off, n):
    b = bytearray(n)
    for k in range(n):
        p = off + k
        b[k] = 0x80 if (p & 1) == 0 else ((p >> 1) & 0xFF)
    return bytes(b)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    total = int(sys.argv[2]) * 1024 * 1024 if len(sys.argv) > 2 else 0

    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", PORT))
    s.listen(1)
    print("listening on %d ..." % PORT, flush=True)
    c, who = s.accept()
    print("connected from %s" % (who,), flush=True)

    if mode == "send":
        off = 0
        while off < total:
            n = min(CHUNK, total - off)
            c.sendall(pattern(off, n))
            off += n
        print("sent %d bytes" % off)
    else:
        off, bad = 0, 0
        while True:
            d = c.recv(CHUNK)
            if not d:
                break
            exp = pattern(off, len(d))
            if d != exp:
                for k in range(len(d)):
                    if d[k] != exp[k]:
                        if bad < 8:
                            print("BAD  byte %d  want %02x  got %02x"
                                  % (off + k, exp[k], d[k]))
                        bad += 1
            off += len(d)
        print("received %d bytes, %d wrong" % (off, bad))
    c.close()
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
