/*
 * Does a double bus fault reach the watchdog?
 *
 * A real 2/50 reboots itself when the CPU dies.  Architecture Manual 4.6.1:
 * the board has "a watchdog circuit which generates a signal equivalent to
 * power-on reset (POR) whenever the 68010 halts with a double bus fault", and
 * Engineering Manual 3.7.1 gives the mechanism -- the CPU drives HALT low and
 * PAL A102 "automatically generates processor reset to continue processing".
 *
 * top_fpga.v now models that: HALT_OUTn asserted starts a 255-clock dog_reset,
 * which is ORed into the machine's reset.  Nothing exercised it, though, and
 * the obvious candidate turned out not to be one.  The VME machine with
 * patches/Suska_Configware/0001 reverted and the maps powered up as zeros ends
 * with `seen_err' and `seen_stall' lit and no halt at all: the RESET-
 * instruction stall leaves AS asserted for ever, so the CPU never reaches the
 * state where it would assert HALT.  That is a hung bus, not a dead CPU, and
 * the two need separate stimulus.
 *
 * This produces the real thing.  MC68000UM 6.3.9: a bus error during the
 * exception processing of a bus error, an address error or a reset halts the
 * processor -- it is the one case the 68010 cannot continue from.  So:
 *
 *   1. map a page as TYPE 2 with nothing behind it, exactly as beprobe does,
 *      so every access to it times out;
 *   2. point the supervisor stack pointer into that page;
 *   3. store to it.
 *
 * The store takes a bus error.  The CPU begins exception processing and pushes
 * the 29-word frame at a stack pointer that also faults, and that second fault
 * is the double one.  HALT goes low and stays there.
 *
 * What to look for afterwards, and it is the whole point of the tool: with the
 * watchdog working the machine reboots -- the monitor's LED sequence runs
 * again and the banner is printed a second time.  Without it the machine is
 * simply dead, with the front panel frozen wherever it stood.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor and entered in supervisor mode with the
 * Sun-1 map installed and VBR = 0 (sys/mon/s2addrs.h).  Everything it prints
 * is printed *before* it arms, because after that there is no CPU left to
 * print with.
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
/* The dead page                                                            */
/* ------------------------------------------------------------------------ */
/*
 * The same page and the same page map entry beprobe uses: valid, supervisor
 * read/write/execute, TYPE 2 -- the system bus -- physical page 0.  Nothing is
 * plugged in there, so every access to it runs the bus timeout out and takes a
 * bus error.  Using beprobe's case rather than inventing one keeps this
 * comparable with a tool whose behaviour is already recorded.
 */
#define PROBE_VA   0x701000UL
#define PROBE_PME  0xF0800000UL

/* Far enough into the page that the frame push cannot fall off the front of
 * it: a 68010 long bus error frame is 29 words, and the push runs downwards. */
#define BAD_SP     (PROBE_VA + 0x400)

static void setpgmap(u32 va, u32 pme)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"          /* FC_MAP */
        "movec %%d0,%%dfc\n\t"
        "movesl %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" (va & ~0x7FFUL), "d" (pme) : "d0", "d1", "memory");
}

static u32 getpgmap(u32 va)
{
    u32 out;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesl %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (out) : "a" (va & ~0x7FFUL) : "d0", "d1");
    return out;
}

int main(void)
{
    puts_("\r\ndogprobe: a real double bus fault, for the watchdog\r\n");

    setpgmap(PROBE_VA, PROBE_PME);
    puts_("  page map entry written ");
    puthex(PROBE_PME, 8);
    puts_(" read back ");
    puthex(getpgmap(PROBE_VA), 8);
    puts_("\r\n");

    puts_("  stack -> ");
    puthex(BAD_SP, 6);
    puts_(", faulting store -> ");
    puthex(PROBE_VA, 6);
    puts_("\r\n");
    puts_("  the frame push faults too, which is the double one\r\n");

    /*
     * Everything above is printed first because there is no way back from
     * here.  No stack, no function calls, nothing after the store: the CPU
     * takes a bus error on it, begins pushing the frame at a stack pointer
     * that faults as well, and halts with HALT asserted.
     *
     * If the watchdog works, the next thing on this console is the monitor's
     * banner, printed by a machine that has just reset itself.
     */
    puts_("dogprobe-armed\r\n");

    __asm__ volatile (
        "movel %0,%%sp\n\t"          /* supervisor stack into the dead page */
        "movew #0x5555,%1@\n\t"      /* bus error; the frame push faults too */
        : : "d" (BAD_SP), "a" (PROBE_VA) : "memory");

    /* Not reached.  If it ever is, the machine did not fault as intended and
     * saying so is more useful than looping in silence. */
    puts_("dogprobe: NO FAULT -- the store completed\r\n");
    for (;;)
        ;
}
