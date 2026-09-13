#!/usr/bin/env python3
"""Decode a bus-history capture (syn/busila_capture.tcl) around a wrong read.

    tools/busila_dec.py busila.csv [context]

The question it answers: when the master read a wrong word, had that 16-bit
value been anywhere in the window before -- on the 68010 data bus (any master,
any address), or in either half of a 32-bit word DDR3 returned (the half the
bus never shows)?  And what happened to the same DDR3 word before the read?

The trigger is dv_arrived_bad, which fires on the word *after* an isolated bad
one, so the bad read is found by walking back from the trigger for the last
master read whose data does not match tools/patwr -u's pattern for its address
(halfword index = physical offset / 2, low 8 bits).

With the change-strobe qualifier the samples are not evenly spaced in time;
"rel" is a sample index, not a clock count.
"""
import csv
import re
import sys

path = sys.argv[1]
ctx = int(sys.argv[2]) if len(sys.argv) > 2 else 40

rows = list(csv.reader(open(path)))
hdr, data = rows[0], [r for r in rows[2:] if r]


def col(prefix):
    # Vivado names a probe after its net, and a net already probed by the
    # other ILA core gets a suffix: dbg_addr_1, dv_arrived_bad_1.
    for i, h in enumerate(hdr):
        name = h.split("[")[0]
        if name == prefix or re.fullmatch(re.escape(prefix) + r"_\d+", name):
            return i
    raise SystemExit(f"no column {prefix!r}; header: {hdr}")


C = {k: col(k) for k in ("TRIGGER", "dbg_addr", "dbg_fc", "dbg_hand", "dbg_cs",
                         "dbg_data", "dbg_dvma", "dbg_ma", "bw_dat", "bw_ctl",
                         "bw_adr", "dv_arrived_bad", "cl_trig")}


def hx(s):
    return int(s, 16) if s else 0


def dec(r):
    a = hx(r[C["dbg_addr"]]) << 1
    ma = hx(r[C["dbg_ma"]])
    phys = (ma << 11) | (a & 0x7FF)
    hand = hx(r[C["dbg_hand"]])
    ctl = hx(r[C["bw_ctl"]])
    return dict(
        a=a, fc=hx(r[C["dbg_fc"]]), phys=phys, off=(phys >> 1) & 0xFF,
        as_=not (hand >> 5) & 1, rw="R" if (hand >> 4) & 1 else "W",
        dtack=not (hand >> 1) & 1, d=hx(r[C["dbg_data"]]), dv=hx(r[C["dbg_dvma"]]),
        wdat=hx(r[C["bw_dat"]]), wadr=hx(r[C["bw_adr"]]),
        cyc=(ctl >> 7) & 1, stb=(ctl >> 6) & 1, we=(ctl >> 5) & 1, ack=(ctl >> 4) & 1,
        sel=ctl & 0xF, abad=hx(r[C["dv_arrived_bad"]]), cl=hx(r[C["cl_trig"]]))


E = [dec(r) for r in data]
t = next((i for i, r in enumerate(data) if r[C["TRIGGER"]].strip() == "1"), None)
if t is None:
    t = next((i for i, e in enumerate(E) if e["abad"]), None)
if t is None:
    raise SystemExit(f"{len(E)} samples and no trigger in them")


def pat(e):
    return 0x8000 | e["off"]


# The bad read: the last master read cycle before the trigger, sampled with AS
# and DTACK asserted, whose data is not the pattern for its address.
bad = None
for i in range(t, -1, -1):
    e = E[i]
    if e["dv"] and e["as_"] and e["rw"] == "R" and e["dtack"] and e["d"] != pat(e):
        bad = i
        break
if bad is None:
    raise SystemExit("no master read with non-pattern data before the trigger")
B = E[bad]
V = B["d"]
print(f"{len(E)} samples, trigger at {t}")
print(f"bad read at {bad - t:+d}: master read phys {B['phys']:06x} "
      f"(halfword {B['off']}) got {V:04x}, pattern wants {pat(B):04x}; "
      f"DDR3 word {B['wadr']:06x} = {B['wdat']:08x}")

print(f"\n== {V:04x} on the 68010 data bus earlier in the window ==")
seen = {}
for i in range(0, bad):
    e = E[i]
    if e["as_"] and e["d"] == V:
        key = ("MST" if e["dv"] else "cpu", e["fc"], e["rw"], e["phys"])
        seen.setdefault(key, []).append(i - t)
if not seen:
    print("   none")
for (who, fc, rw, phys), rel in sorted(seen.items(), key=lambda kv: kv[1][-1]):
    print(f"   {who} FC{fc} {rw} phys {phys:06x}: {len(rel)} samples, "
          f"first {rel[0]:+d}, last {rel[-1]:+d}")

print(f"\n== {V:04x} in either half of a DDR3 word the bridge received ==")
seen = {}
for i in range(0, bad):
    e = E[i]
    if not e["ack"]:
        continue
    for half, val in (("hi", e["wdat"] >> 16), ("lo", e["wdat"] & 0xFFFF)):
        if val == V:
            key = (e["wadr"], half, "W" if e["we"] else "R")
            seen.setdefault(key, []).append(i - t)
if not seen:
    print("   none")
for (wadr, half, rw), rel in sorted(seen.items(), key=lambda kv: kv[1][-1]):
    print(f"   word {wadr:06x} {half} half, {rw}: {len(rel)} acks, "
          f"first {rel[0]:+d}, last {rel[-1]:+d}")

print(f"\n== every acknowledged transaction on DDR3 word {B['wadr']:06x} ==")
n = 0
last = None
for i in range(0, t + 1):
    e = E[i]
    if not e["ack"]:
        last = None
        continue
    # One transaction per acknowledgement.  Under the change-strobe qualifier two
    # acks many clocks apart can sit in adjacent samples, so "the sample before
    # had no ack" would drop the second; a repeated identical ack is the same one.
    key = (e["wadr"], e["we"], e["wdat"])
    if key == last:
        continue
    last = key
    if e["wadr"] == B["wadr"]:
        n += 1
        print(f"   {i - t:+6d} {'MST' if e['dv'] else 'cpu'} {'W' if e['we'] else 'R'} "
              f"sel {e['sel']:x} data {e['wdat']:08x} (bus {e['d']:04x} at {e['phys']:06x})")
if n == 0:
    print("   none in the window")

print(f"\n== {ctx} samples before the bad read, and a few after ==")
print("   rel   who FC AS R/W DTK  virt   phys   data  | wb cyc we ack sel  word    dat")
for i in range(max(0, bad - ctx), min(len(E), bad + 6)):
    e = E[i]
    mark = "  <== bad read" if i == bad else ("  <== trigger" if i == t else "")
    print(f"  {i - t:+5d}  {'MST' if e['dv'] else 'cpu'}  {e['fc']}  {int(e['as_'])}  {e['rw']}   "
          f"{int(e['dtack'])}  {e['a']:06x} {e['phys']:06x} {e['d']:04x} |    "
          f"{e['cyc']}   {e['we']}   {e['ack']}   {e['sel']:x}  {e['wadr']:06x} {e['wdat']:08x}{mark}")
