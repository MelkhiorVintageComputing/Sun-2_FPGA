/*
 * Does a read-modify-write instruction on this machine do exactly one
 * read and one write, exactly once?
 *
 * The question comes from a VME 2/50 that hangs netbooting.  The boot PROM's
 * Channel Attention routine is a pulse built from two read-modify-writes:
 *
 *      ef431a: moveal %a5@(1118),%a0
 *      ef431e: bset #5,%a0@              raise CA
 *      ef4322: moveal %a5@(1118),%a0
 *      ef4326: bclr #5,%a0@              drop it
 *
 * and the ILA caught the board executing the `bset' twice against one `bclr'.
 * CA therefore went 1 ... 1 ... 0 where the 82586 needs 1 -> 0 -> 1 -> 0, so
 * the second attention never made an edge, the chip never fetched the command
 * block, and the driver spins for ever at ef4372 waiting for a status bit that
 * cannot arrive.  The first attention worked: eight DVMA cycles are the proof.
 *
 * If a read-modify-write can run twice here, that is a core defect and it is
 * not confined to Ethernet -- every `bset', `bclr', `bchg', `tas' and
 * read-modify-write `addq' in the PROM and in SunOS is exposed to it.  So it
 * is worth an instrument that does not need a network, a chip or an ILA.
 *
 * ---------------------------------------------------------------------------
 * Why this runs on a MultiBus machine
 * ---------------------------------------------------------------------------
 * Because a boot block has to come off a disk, and XY450 is MultiBus only --
 * a 2/50 takes a Xylogics 451 on the VME bus, which this project does not
 * implement.  The failing register itself is therefore out of reach.  That is
 * survivable: what is under suspicion is the *instruction*, not the device.
 *
 * ---------------------------------------------------------------------------
 * How the cycles are counted, which is the part worth reading
 * ---------------------------------------------------------------------------
 * Software cannot see its own bus cycles.  The Am9513 can: its data pointer
 * auto-increments on every access to the data register, mode -> load -> hold,
 * which is the mechanism that once ran the monitor's clock at 98.9 Hz instead
 * of 40 because a level-sensitive strobe made one CPU write act three times
 * (see the trap in CLAUDE.md).  The same property makes it a cycle counter:
 *
 *      one read-modify-write  = one read + one write = two data accesses
 *
 * So point the pointer at a counter's mode register, put a distinct value in
 * each of mode, load and hold, do a single `bset' on the data register, and
 * then ask which register the pointer is sitting on.  Two accesses leaves it
 * one place further on than one access does, and four leaves it further still.
 * The answer is a count, not an inference.
 *
 * Counter 5 is used throughout.  The monitor arms counter 1 for its NMI and
 * SunOS uses counter 2; 5 is untouched by both, and this program never arms
 * it, so nothing here can disturb a clock the machine is relying on.
 *
 * ---------------------------------------------------------------------------
 * What it reports
 * ---------------------------------------------------------------------------
 *   1. memory, non-idempotent.  `bchg' toggles, so an instruction that runs
 *      twice leaves the bit where it started.  `addq.b #1' counted against a
 *      known iteration count says the same thing cumulatively, which catches
 *      a fault too rare to see in one pass.
 *   2. memory, the PROM's own pair.  `bset' then `bclr' on the same byte,
 *      with the value read back between and after: this is exactly what the
 *      CA routine does, and the failure seen on the board is the final read
 *      finding the bit still set.
 *   3. a device.  The Am9513 as above -- the only target here whose DTACK
 *      comes from a device rather than from memory.  Reported rather than
 *      judged: see the note at the test.
 *
 * ---------------------------------------------------------------------------
 * What it found, which was not what it was looking for
 * ---------------------------------------------------------------------------
 * Both memory tests pass on both cores, twenty thousand iterations each.  The
 * read-modify-write is sound, and the doubled Channel Attention is not a
 * read-modify-write defect.
 *
 * The ILA then showed what it is.  The routine runs once per call; the `bclr'
 * executes; and it executes against address 0x000004, because the `moveal'
 * that reloads its pointer runs in the window where the 82586 -- having just
 * been given the attention the `bset' raised -- is taking the bus, and comes
 * back with the wrong value.  CA therefore never falls.
 *
 * That is why this probe cannot reproduce it and should not be expected to:
 * there is no bus master here.  A boot block on a MultiBus machine has a disk
 * controller that could master the bus, and making it do so *while* the CPU
 * reads a longword is the shape of the reproduction -- which is a job for
 * tb_dvma rather than for a boot block, since the interleaving has to be
 * placed deliberately rather than waited for.
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
    for (i = digits - 1; i >= 0; i--) putch(hex[(v >> (4 * i)) & 0xF]);
}
/* Counts print in hex: a boot block links no libgcc, and dividing by ten
 * would pull in __udivsi3. */

/* The three read-modify-writes, each as one instruction and nothing else. */
static inline void rmw_bset(volatile u8 *p, int bit) { __asm__ volatile("bset %1,%0" : "+m"(*p) : "di"(bit) : "cc"); }
static inline void rmw_bclr(volatile u8 *p, int bit) { __asm__ volatile("bclr %1,%0" : "+m"(*p) : "di"(bit) : "cc"); }
static inline void rmw_bchg(volatile u8 *p, int bit) { __asm__ volatile("bchg %1,%0" : "+m"(*p) : "di"(bit) : "cc"); }
static inline void rmw_inc (volatile u8 *p)          { __asm__ volatile("addqb #1,%0" : "+m"(*p) : : "cc"); }
/* Word-wide, because the Am9513's registers are 16 bits and `bset' on memory
 * is always a byte operation.  addq.w is still one read and one write. */
static inline void rmw_incw(volatile u16 *p)         { __asm__ volatile("addqw #1,%0" : "+m"(*p) : : "cc"); }

/*
 * struct am9513_device (msun/sys/mon/am9513.h): data register first, command
 * register second.  Counter 5 is untouched by the monitor and by SunOS, and
 * nothing here ever arms it.
 */
struct am9513 { volatile u16 clk_data; volatile u16 clk_cmd; };
#define CLK          ((struct am9513 *)0xEE0000UL)
#define CLK_ACC_MODE 0xFF00
#define CLK_ACC_LOAD 0xFF08
#define CLK_ACC_HOLD 0xFF10
#define CTR          5

static u16 read_at(u16 which) { CLK->clk_cmd = which + CTR; return CLK->clk_data; }
static void write_at(u16 which, u16 v) { CLK->clk_cmd = which + CTR; CLK->clk_data = v; }

#define ITERS 20000

static u8 target;          /* in .bss, so ordinary main memory */

int main(void)
{
    u32 i, bad_chg = 0, bad_pair = 0;
    u8 after_set, after_clr;

    puts_("\r\ncaprobe: read-modify-write, on memory and on a device\r\n");

    /* ---- 1. memory, non-idempotent ------------------------------------- */
    target = 0;
    for (i = 0; i < ITERS; i++) {
        rmw_bchg(&target, 5);
        if (((target >> 5) & 1) != ((i + 1) & 1)) bad_chg++;
    }
    puts_("  bchg  toggles wrong (hex): "); puthex(bad_chg, 4);
    puts_(bad_chg ? "  FAIL\r\n" : "  (PASS)\r\n");

    target = 0;
    for (i = 0; i < ITERS; i++) rmw_inc(&target);
    puts_("  addq.b x"); puthex(ITERS, 4); puts_(" (hex) -> ");
    puthex(target, 2);
    puts_(" want "); puthex(ITERS & 0xFF, 2);
    puts_(target == (u8)ITERS ? "  (PASS)\r\n" : "  FAIL\r\n");

    /* ---- 2. memory, the PROM's own bset/bclr pair ----------------------- */
    for (i = 0; i < ITERS; i++) {
        target = 0;
        rmw_bset(&target, 5);
        after_set = target;
        rmw_bclr(&target, 5);
        after_clr = target;
        if (!(after_set & 0x20) || (after_clr & 0x20)) bad_pair++;
    }
    puts_("  bset/bclr pair wrong (hex): "); puthex(bad_pair, 4);
    puts_(bad_pair ? "  FAIL\r\n" : "  (PASS)\r\n");

    /* ---- 3. a device, with the cycles counted by the chip itself -------- */
    /*
     * Park three distinguishable values, then do exactly one read-modify-write
     * starting with the pointer on MODE.  One RMW is two data accesses, so the
     * read takes MODE and the write lands in LOAD, leaving HOLD alone.  A
     * second execution would read LOAD and write HOLD -- so HOLD is the
     * witness, and it does not need the pointer's wrap behaviour to be known.
     */
    write_at(CLK_ACC_MODE, 0xAAAA);
    write_at(CLK_ACC_LOAD, 0xBBBB);
    write_at(CLK_ACC_HOLD, 0xCCCC);

    CLK->clk_cmd = CLK_ACC_MODE + CTR;      /* pointer on MODE, then one RMW */
    rmw_incw(&CLK->clk_data);

    {
        u16 m = read_at(CLK_ACC_MODE), l = read_at(CLK_ACC_LOAD), h = read_at(CLK_ACC_HOLD);
        puts_("  am9513 after one addq.w: mode="); puthex(m, 4);
        puts_(" load="); puthex(l, 4);
        puts_(" hold="); puthex(h, 4);
        /*
         * Reported, not judged, and here is why.  This was written expecting
         * the data pointer to auto-increment on every data access, so that one
         * read-modify-write would read MODE and write LOAD.  It does not:
         * mode comes back holding the incremented value, so the write went
         * back where the read came from.  Both cores give byte-identical
         * results here -- Suska and RD68011, same three words -- which is the
         * proof that this measures ttl_am9513's pointer semantics and not the
         * CPU's cycles.  A test that cannot distinguish two different
         * processors is not testing a processor.
         *
         * Whether the model is right about the pointer is a real question --
         * the monitor's own NMI setup relies on mode -> load auto-increment
         * (see the trap in CLAUDE.md) -- but it is a different question from
         * the one this probe exists to ask, and answering it wrongly here
         * would leave a FAIL in the tree that means nothing.
         */
        puts_("\r\n    (observation only: identical on both cores, so this\r\n"
              "     measures the Am9513 model's data pointer, not the CPU)\r\n");
        (void)m; (void)l; (void)h;
    }

    puts_("caprobe-finished\r\n");
    return 0;
}
