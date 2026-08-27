/*
 * Does the Am9513's counter 2 -- the level 5 clock SunOS runs on -- tick?
 *
 * The monitor's clock is counter 1: `TIMER_NMI 1 / Non-maskable, level 7, no
 * gate' (msun/sys/mon/suntimer.h:15).  Every boot in this project has proved
 * that one, and only that one.  SunOS uses a different counter on a different
 * level -- `TIMER_MISC 2 / Misc timer, level 5, no gate' -- and arms it in
 * startrtclock(), which runs in main() *after* autoconfig:
 *
 *      start_level5_clock(hz_val)              [sun/sys/sun2/clock.c:57]
 *      {
 *          CLKADDR->clk_cmd  = CLK_LMODE+CLKTIMER;   // 0xFF00 + 2
 *          CLKADDR->clk_data = CLK_TICK_MODE;        // 0x0C22
 *          CLKADDR->clk_cmd  = CLK_LLOAD+CLKTIMER;   // 0xFF08 + 2
 *          CLKADDR->clk_data = CLK_HZ(hz_val);       // 3072 for 100 Hz
 *          CLKADDR->clk_cmd  = CLK_ARM+CLKNUM_TO_BIT(CLKTIMER);  // 0xFF20 + 2
 *      }
 *
 * If that counter does not tick, hardclock() never runs, the callout queue
 * never fires, and every timed sleep hangs -- which from outside looks exactly
 * like the machine sitting in the scheduler's idle loop with nothing runnable,
 * which is where a SunOS boot is at the time of writing.
 *
 * Two things make it worth measuring rather than reasoning about.  The mode
 * word is the same 0x0C22 the monitor writes to counter 1, so the source and
 * output settings are known-good; but the *sequence* is not the monitor's.
 * The monitor points the data pointer once with CLK_ACC_MODE and then relies
 * on it auto-incrementing from the mode register into the load register, and
 * it starts the counter with CLK_LOAD_ARM.  The kernel points the pointer
 * explicitly a second time with CLK_LLOAD, and starts the counter with a bare
 * CLK_ARM -- no load.  Neither of those paths has ever been exercised here.
 *
 * ---------------------------------------------------------------------------
 * What it reports
 * ---------------------------------------------------------------------------
 * Three separable answers, so a failure says which half is broken:
 *
 *   1. the registers.  Mode and load are read back after writing, which
 *      catches a value that landed in the wrong register -- the failure the
 *      byte-pointer bug in ttl_am9513.v produced for the monitor once.
 *   2. the counter.  The 9513's status register is read at the command
 *      address and carries every counter's output pin (CLKS_BIT(c) = 1<<c), so
 *      OUT2 can be watched with interrupts still masked.  A counter that
 *      counts but cannot reach the CPU shows up here as ticking.
 *   3. the interrupt.  Only then is IPL dropped, with a level 5 autovector
 *      handler installed, and the interrupts counted.
 *
 * A fourth pass repeats the whole thing with the monitor's sequence
 * (CLK_ACC_MODE + auto-increment + CLK_LOAD_ARM) on the same counter.  If the
 * kernel's sequence fails and the monitor's works on counter 2, the difference
 * is the command sequence and not the counter; if both fail, it is the
 * counter or its wiring to level 5.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor and entered in supervisor mode with the
 * Sun-1 map installed and VBR = 0, so the level 5 autovector is vector 29 at
 * 0x74 and the timer is at its ordinary virtual address, 0xEE0000
 * (msun/sys/mon/s2addrs.h:49).  Counter 2 is free: the monitor clears its
 * output during reset and never arms it.
 *
 * The monitor's own NMI keeps running throughout on counter 1 at level 7,
 * which is deliberate -- it is the control that says interrupts work at all.
 */

__asm__(
    "       .section .text.start,\"ax\"  \n"
    "       .globl _start                \n"
    "_start:                             \n"
    "       lea    __bss_start,%a0       \n"
    "       lea    __bss_end,%a1         \n"
    "1:     cmpal  %a1,%a0               \n"
    "       bccs   2f                    \n"
    "       clrb   %a0@+                 \n"
    "       bras   1b                    \n"
    "2:     jsr    main                  \n"
    "3:     bra    3b                    \n"
    "       .text                        \n");

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned long  u32;

#define ROMP      0xEF0000UL
#define V_PUTCHAR (*(int (**)(int))(ROMP + 24))

static void putch(int c)         { V_PUTCHAR(c); }
static void puts_(const char *s) { while (*s) putch(*s++); }

static void puthex(u32 v, int digits)
{
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = digits - 1; i >= 0; i--)
        putch(hex[(v >> (4 * i)) & 0xF]);
}

/* ------------------------------------------------------------------------ */
/* The chip                                                                 */
/* ------------------------------------------------------------------------ */
/*
 * struct am9513_device (msun/sys/mon/am9513.h): data register first, command
 * register second, both 16 bit.  Reading the command address returns the
 * status register.
 */
struct am9513 {
    volatile u16 clk_data;
    volatile u16 clk_cmd;
};

#define CLK ((struct am9513 *)0xEE0000UL)

#define CLK_RESET       0xFFFF
#define CLK_16BIT       0xFFEF
#define CLK_ARM         0xFF20      /* + bit mask */
#define CLK_LOAD        0xFF40      /* + bit mask */
#define CLK_LOAD_ARM    0xFF60      /* + bit mask */
#define CLK_DISARM      0xFFC0      /* + bit mask */
#define CLK_CLEAR       0xFFE0      /* + counter number */
#define CLK_ACC_MODE    0xFF00      /* + counter number */
#define CLK_ACC_LOAD    0xFF08      /* + counter number */
#define CLK_ACC_HOLD    0xFF10      /* + counter number */

#define CLKTIMER        2                       /* TIMER_MISC, level 5 */
#define CLKBIT          (1 << (CLKTIMER - 1))
#define CLKS_BIT(c)     (1 << (c))              /* status: OUT of counter c */

/* CLK_TICK_MODE, sun/sys/sun2/clock.h:60 -- F2 (pulse/16), repeat, toggle. */
#define TICK_MODE       0x0C22
/* CLK_HZ(100) = (19660800/(4*16))/100 = 3072. */
#define TICK_LOAD       3072
/* A load value small enough that a tick cannot be missed inside one spin,
 * used only if the kernel's own value produces nothing. */
#define FAST_LOAD       16

static u16 read_mode(int c)
{
    CLK->clk_cmd = CLK_ACC_MODE + c;
    return CLK->clk_data;
}

static u16 read_load(int c)
{
    CLK->clk_cmd = CLK_ACC_LOAD + c;
    return CLK->clk_data;
}

static u16 read_hold(int c)
{
    CLK->clk_cmd = CLK_ACC_HOLD + c;
    return CLK->clk_data;
}

/* ------------------------------------------------------------------------ */
/* What the monitor left in counter 1                                       */
/* ------------------------------------------------------------------------ */
/*
 * Read-only, and first, before this program has written a single timer
 * register -- so what comes back is what the boot monitor's own
 * initialisation put there and nothing else.
 *
 * The monitor arms the NMI clock like this (msun/mon/kernel/sunmon.c:481):
 *
 *      TIMER_BASE->clk_cmd  = CLK_CLEAR + TIMER_NMI;
 *      TIMER_BASE->clk_cmd  = CLK_ACC_MODE + TIMER_NMI;
 *      TIMER_BASE->clk_data = NMIMODE;                 // 0x0C22
 *      TIMER_BASE->clk_data = CLK_BASIC/(NMIFREQ*NMIDIVISOR);   // 7680
 *      TIMER_BASE->clk_cmd  = CLK_LOAD_ARM + CLK_BIT(TIMER_NMI);
 *
 * -- one pointer command and two data writes, the second relying on the data
 * pointer having auto-incremented from the mode register into the load
 * register.  So the load register must read back 0x1E00, and the hold register
 * must be untouched.
 *
 * If instead load reads back 0x0C22, the mode word reached it: the write
 * landed in more than one register, which is what a data write applied on
 * every clock of a multi-clock bus cycle rather than once per cycle would do,
 * and the monitor's clock has been running at the wrong rate since the
 * beginning.  Hold would carry the same value for the same reason.
 *
 * This is the measurement that separates a real fault in the machine from an
 * artefact of this program running three passes that share pointer state.
 */
static void dump_counter1(void)
{
    u16 mode = read_mode(1);
    u16 load = read_load(1);
    u16 hold = read_hold(1);

    puts_("\n  counter 1 as the monitor left it (NMI, level 7):\n");
    puts_("    mode ");  puthex(mode, 4);  puts_(" expected 0c22\n");
    puts_("    load ");  puthex(load, 4);  puts_(" expected 1e00 = 7680, 40 Hz from F2\n");
    puts_("    hold ");  puthex(hold, 4);  puts_(" expected untouched\n");

    if (load == 0x1E00)
        puts_("    -> the monitor's two data writes landed one per register\n");
    else if (load == mode)
        puts_("    -> the mode word reached the load register: one write, several registers\n");
    else
        puts_("    -> neither: the load register holds something else again\n");
}

/* ------------------------------------------------------------------------ */
/* The interrupt                                                            */
/* ------------------------------------------------------------------------ */
/*
 * Level 5, autovectored: vector 29 at VBR + 0x74, and the monitor's VBR is
 * zero.  Through a variable, because gcc reads a store to a small constant
 * address as a null dereference and says so at length -- xychain.c and
 * beprobe.c both hit that.
 *
 * The handler does what the kernel's does first and nothing else: clear the
 * counter's output pin, which is what deasserts INT5, and count.  In toggle
 * mode the output would otherwise stay high and the machine would take the
 * same interrupt for ever.
 */
static volatile u32 vec_level5_addr = 0x74;

static volatile u32 irq_count;

void irq_handler(void)
{
    irq_count++;
    CLK->clk_cmd = CLK_CLEAR + CLKTIMER;
}

extern void irq_stub(void);
__asm__(
    "       .text                         \n"
    "       .globl irq_stub               \n"
    "irq_stub:                            \n"
    "       moveml %d0-%d1/%a0-%a1,%sp@-  \n"
    "       jsr    irq_handler            \n"
    "       moveml %sp@+,%d0-%d1/%a0-%a1  \n"
    "       rte                           \n");

static void spl7(void) { __asm__ volatile ("movew #0x2700,%sr"); }

/*
 * spl4, not spl0, for the window where the level 5 interrupt is let through.
 *
 * This program is netbooted as often as it is booted off a disk now, and a
 * netboot leaves the Ethernet armed: the first packet to arrive lands as a
 * level 3 autovector, which nothing here handles, and the probe dies with
 * `Exception 6C' part-way through its second measurement.  Installing a
 * handler would not help, because a device that keeps asserting is re-entered
 * the instant the handler returns.  Masking below 5 is what the measurement
 * actually wants: level 5 is the only thing being counted.
 *
 * Level 7 still gets through -- it is non-maskable, and it is the monitor's
 * own NMI, whose handler is already installed and already runs throughout.
 */
static void spl4(void) { __asm__ volatile ("movew #0x2400,%sr"); }

/* ------------------------------------------------------------------------ */
/* The measurements                                                         */
/* ------------------------------------------------------------------------ */
static int fails;

static void check(int ok, const char *what)
{
    if (!ok) { puts_("FAIL: "); puts_(what); putch('\n'); fails++; }
}

/*
 * Watch OUT2 in the status register with interrupts masked.  Counts edges
 * rather than levels: in toggle mode with nothing clearing it, the pin sits
 * high for a whole period, so a level test would say "ticking" for a counter
 * that reached terminal count exactly once.
 */
static u32 watch_out(u32 spins)
{
    u32 i, edges = 0;
    u8  prev = (CLK->clk_cmd & CLKS_BIT(CLKTIMER)) ? 1 : 0;

    for (i = 0; i < spins; i++) {
        u8 now = (CLK->clk_cmd & CLKS_BIT(CLKTIMER)) ? 1 : 0;
        if (now != prev) edges++;
        prev = now;
    }
    return edges;
}

static void arm_kernel_way(u16 load)
{
    CLK->clk_cmd  = CLK_ACC_MODE + CLKTIMER;    /* CLK_LMODE */
    CLK->clk_data = TICK_MODE;
    CLK->clk_cmd  = CLK_ACC_LOAD + CLKTIMER;    /* CLK_LLOAD */
    CLK->clk_data = load;
    CLK->clk_cmd  = CLK_ARM + CLKBIT;
}

/*
 * The monitor's, from sunmon.c:481-485: point the data pointer once and let it
 * auto-increment into the load register, then load *and* arm.
 */
static void arm_monitor_way(u16 load)
{
    CLK->clk_cmd  = CLK_CLEAR + CLKTIMER;
    CLK->clk_cmd  = CLK_ACC_MODE + CLKTIMER;
    CLK->clk_data = TICK_MODE;
    CLK->clk_data = load;
    CLK->clk_cmd  = CLK_LOAD_ARM + CLKBIT;
}

static void disarm(void)
{
    CLK->clk_cmd = CLK_DISARM + CLKBIT;
    CLK->clk_cmd = CLK_CLEAR + CLKTIMER;
}

/*
 * One pass: arm, look at the registers, watch the pin, then let the interrupt
 * through.  `spins' is in status reads, and one costs about 15 us of simulated
 * time -- a device read through the MMU, not a register access -- so the count
 * has to be chosen against the tick rate rather than left large.  It is
 * simulated time that is expensive here: the first version spun 40000 times in
 * every phase, which at a load of 16 is eleven thousand interrupts and did not
 * finish inside an hour of wall clock.
 */
static void pass(const char *what, void (*arm)(u16), u16 load, u32 spins)
{
    u16 mode_rb, load_rb;
    u32 edges, irqs;

    puts_("\n  ");
    puts_(what);
    puts_(":\n");

    disarm();
    irq_count = 0;

    spl7();                                  /* the counter alone, first */
    arm(load);

    mode_rb = read_mode(CLKTIMER);
    load_rb = read_load(CLKTIMER);
    puts_("    mode written ");   puthex(TICK_MODE, 4);
    puts_(" read back ");         puthex(mode_rb, 4);
    puts_("\n    load written ");  puthex(load, 4);
    puts_(" read back ");         puthex(load_rb, 4);
    puts_("\n");
    check(mode_rb == TICK_MODE, "the mode register did not take the value");
    check(load_rb == load,      "the load register did not take the value");

    edges = watch_out(spins);
    puts_("    OUT2 edges with interrupts masked: ");
    puthex(edges, 4);
    puts_("\n");

    /* Now let it through.  The handler clears OUT2, so each terminal count
     * costs one interrupt rather than latching the line high for ever. */
    CLK->clk_cmd = CLK_CLEAR + CLKTIMER;
    irq_count = 0;
    spl4();
    (void)watch_out(spins);
    spl7();

    irqs = irq_count;
    puts_("    level 5 interrupts taken: ");
    puthex(irqs, 4);
    puts_("\n");

    if (edges == 0)
        puts_("    -> the counter never reached terminal count\n");
    else if (irqs == 0)
        puts_("    -> counts, but nothing reached the CPU at level 5\n");
    else
        puts_("    -> counter and interrupt both work\n");

    disarm();
}

int main(void)
{
    puts_("\nclkprobe: Am9513 counter 2, the level 5 clock SunOS arms\n");

    /* First, before anything here writes a timer register. */
    dump_counter1();

    *(volatile u32 *)vec_level5_addr = (u32)irq_stub;

    /*
     * Exactly what startrtclock() does, values and all.  100 Hz is a tick
     * every 10 ms of simulated time, so this needs the long spin: 15000
     * status reads is around 225 ms and some twenty ticks.
     */
    pass("the kernel's sequence, CLK_HZ(100) = 3072", arm_kernel_way,
         TICK_LOAD, 15000);

    /*
     * The same sequence with a load small enough to reach terminal count
     * hundreds of times inside a spin a tenth as long.  Separates "the counter
     * does not count" from "the counter counts too slowly to see here", which
     * the kernel's own value cannot do on its own.
     */
    pass("the kernel's sequence, load 16", arm_kernel_way,
         FAST_LOAD, 1500);

    /*
     * The monitor's sequence on the same counter.  This is the control: it is
     * the path counter 1 takes every boot, so if it works here and the
     * kernel's does not, the difference is CLK_LLOAD / bare CLK_ARM.
     */
    pass("the monitor's sequence, load 16", arm_monitor_way,
         FAST_LOAD, 1500);

    puts_("\n");
    if (fails == 0) puts_("clkprobe: no register faults\n");
    else            { puts_("clkprobe: register faults: "); puthex(fails, 2); putch('\n'); }

    puts_("clkprobe-finished\n");
    return 0;
}
