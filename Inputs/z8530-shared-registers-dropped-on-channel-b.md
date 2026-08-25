# WR2 and WR9 written through channel B are silently discarded

`z8530_scc.sv`, as of `bc619d2`. Reported from a Sun-2 workstation replica
(MC68010 + the Sun-2 MMU on an XC7A100T) that uses this core for both of its
SCCs.

## Summary

WR2 (interrupt vector base) and WR9 (Master Interrupt Control) are chip-wide
registers on a real Z8530 and may be written through either channel. In the
model's channel-B control-write case both are commented out:

```verilog
                    // WR2 and WR9 are chip-wide shared registers on the real
                    // Z8530: writable through either channel. Stored as the
                    // _a copies; channel-B writes land in the same regs.
                    //@4'd2: begin wr2_a <= data_in; reg_ptr_b <= 4'd0; end
...
                    //@4'd9: begin wr9_a <= data_in; reg_ptr_b <= 4'd0; end   // shared master-int-ctrl
```

Both fall through to `default: reg_ptr_b <= 4'd0;` — the pointer is reset and
the data is dropped with no error. The comment describing the correct
behaviour is still present directly above them; only the code implementing it
is disabled, and it has been that way since the first upload (`211d550`), so
there is no recorded reason.

WR9 bit 3 is MIE, and

```verilog
assign int_n = ~(master_int_enable & (rx_int_active_a | ... ));
```

so a driver that enables interrupts through channel B leaves `int_n`
deasserted for ever. The chip cannot interrupt at all.

## Why it is easy to miss

**The model's own testbench passes all 22 tests over this.** It exercises
interrupts thoroughly — MIE gating, TxIP, RxIP, ext/status, RR2 raw versus
status-modified — but **every** WR9 write in it targets channel A
(`z8530_scc_tb.sv` lines 316, 980, 1012, 1032, 1101, 1137), as does every WR2
write (line 1097). The channel-B path for the two shared registers is never
taken.

WR9's *reset* commands (bits 7:6) are decoded separately, at `wr9_write_evt`,
and those **do** work from channel B. So `WR9 = 0xC0` (force hardware reset)
through channel B takes effect exactly as expected, and the chip appears
healthy right up to the point where an interrupt should arrive.

## The software that hits it

SunOS 4.x on a Sun-2. `zsattach()` (`sys/sundev/zs_common.c:196-216`) walks
the chip's two ports and leaves its pointer on **port B**, then:

```c
	ZWRITE(9, ZSWR9_MASTER_IE + ZSWR9_VECTOR_INCL_STAT);
	if (vector)
		ZWRITE(2, vector);
```

`ZWRITE(n,v)` writes to `zs->zs_addr`, which at that point is channel B. So on
this machine the console SCC never raised a level-6 interrupt in the whole
life of the project.

It took a long time to see because the two things that normally reveal a dead
UART both go somewhere else on a Sun-2. The boot PROM polls RR0 and writes the
data register and never touches WR9. And kernel `printf` goes out through the
PROM monitor's `putchar` vector rather than the driver, so the machine printed
a complete autoconfig, mounted an NFS root and ran `/sbin/init` with an SCC
that could not interrupt. Only `/dev/console` writes from user processes, and
console input, go through the interrupt-driven driver — and those were the only
two things that did not work.

## Fix

Uncomment the two lines. Both branches are arms of the same `always` block, so
there is no second driver introduced. With that change the machine gets an
interactive root shell on its serial console, in both directions.

## Suggested test

A regression for this needs to write the shared registers through channel B
specifically. In our tree `tb/tb_scc.sv` does that, and pairs it with a
control that writes MIE through channel A, so a failure says which half is
broken rather than just "no interrupt".

## Unrelated observations from the same reading

Neither affects us today; both are divergences from the datasheet that a
different driver could trip over.

* **Tx interrupt pending is not set at reset.** `tx_int_pend` is latched only
  on `tx_byte_grab_pulse`, so enabling `WR1[1]` on an idle, empty transmitter
  raises nothing. Real silicon has the buffer empty out of reset and requests
  an interrupt when TxIE is set. SunOS happens to prime the first byte itself
  (`zsstart`, `zs_async.c:538-542`), so it does not notice.
* **RR3 reports raw IP bits, ungated by the WR1 interrupt enables** — noted as
  deliberate in a comment. On real silicon an IP bit only sets when its IE is
  set. A driver that scans RR3 across several chips to find the interrupter
  (SunOS's `zslevel6intr`, `zs_common.c:252-258`, does exactly this) can stop
  on a chip that has nothing enabled.
