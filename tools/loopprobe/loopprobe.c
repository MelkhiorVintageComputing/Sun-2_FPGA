/*
 * Does a bus cycle survive being issued with no instruction fetch in front of
 * it?  The MC68010's loop mode is the only thing on this machine that asks.
 *
 * A 68010 executing
 *
 *      1:  movel  %d0,%a0@+          | one word, (An)+
 *          dbra   %d1,1b
 *
 * holds both instructions in the prefetch queue and runs the loop *without
 * fetching anything*: the bus carries nothing but the operand cycles, one
 * immediately after another, for as long as the loop runs.  Nothing else this
 * machine does looks like that -- every other instruction stream puts a fetch
 * between one operand cycle and the next.
 *
 * That matters because `sun2_wishbone_bridge' decides when a cycle owns its
 * memory transaction, using `issued' and `done', and a cycle that begins the
 * clock after the previous one ended is the case with the least slack in that
 * handshake.  If a write can be dropped or a read answered from the previous
 * transaction, loop mode is where it shows and a boot is where it hides: the
 * MultiBus reference boot is byte-identical either way, because the PROM's
 * copies are short and the failure is silent.
 *
 * This was written after an ILA capture on the board showed 512 consecutive
 * word writes -- a contiguous kilobyte, 8 clocks each, filling the buffer --
 * with not one instruction fetch among them and `dvma_active' low.  That is a
 * `bzero' of a u-area in loop mode and is entirely normal; the question it
 * raises is whether the memory path underneath it is.
 *
 * ---------------------------------------------------------------------------
 * What is measured
 * ---------------------------------------------------------------------------
 * Each case fills a buffer with a pattern that depends on the address, so a
 * dropped write and a stale read are told apart: a word that keeps its old
 * value is a dropped write, a word that holds a *neighbour's* value is a cycle
 * answered by the wrong transaction.  Both are reported, with the first
 * offender.
 *
 *   A  loop mode, longword writes        movel %d0,%a0@+ / dbra
 *   B  the same loop with a `nop' in it  -- two instructions, so NOT loop mode,
 *      the same number of writes to the same addresses.  This is the control:
 *      if A fails and B passes, loop mode is the variable and nothing else is.
 *   C  loop mode, longword reads         movel %a0@+,%d0 / dbra
 *   D  loop mode, word writes            movew %d0,%a0@+ / dbra
 *
 * Loop mode needs the loop instruction to be one word and the DBcc to branch
 * back exactly to it, so the asm is written out rather than left to the
 * compiler, and A and B differ by one `nop'.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed.  The
 * buffer is at 0x80000, well above this program and below the 1 MiB a disk
 * boot installs, so `MEM_MIB=1' is enough.
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

/* Freestanding: there is no libgcc here, so a `/' or `%' on a u32 becomes an
 * undefined reference to __udivsi3.  Divide by ten with shifts instead, and
 * multiply back the same way. */
static u32 div10(u32 v)
{
    u32 q = (v >> 1) + (v >> 2);
    q += q >> 4;  q += q >> 8;  q += q >> 16;
    q >>= 3;
    if (v - ((q << 3) + (q << 1)) >= 10) q++;
    return q;
}

static void putdec(u32 v)
{
    char b[12]; int n = 0;
    if (!v) { putch('0'); return; }
    while (v) { u32 q = div10(v); b[n++] = '0' + (char)(v - ((q << 3) + (q << 1))); v = q; }
    while (n) putch(b[--n]);
}

#define BUF   0x00080000UL
#define NLONG 256                 /* 1 KiB, the size the capture showed */

/*
 * The pattern.  Address-dependent, so a word holding a neighbour's value is
 * distinguishable from a word that was never written.
 */
#define PAT(i)  (0x5A000000UL | ((u32)(i) << 8) | ((i) ^ 0xA5))

/* Loop mode: one word-sized instruction with (An)+, then dbra back to it. */
static void fill_loop(u32 base, u32 n, u32 seed)
{
    __asm__ volatile (
        "1:  movel  %2,%0@+   \n\t"
        "    addql  #1,%2     \n\t"       /* NOT in the loop -- see below */
        "    dbra   %1,1b     \n\t"
        : "+a"(base), "+d"(n), "+d"(seed) : : "memory");
}

/*
 * The one above has two instructions in the loop and so is *not* loop mode.
 * The real loop-mode case has to store a constant, because anything that
 * changes the data adds a second instruction.  So the pattern for the loop
 * mode cases is a single value, and the address dependence comes from doing
 * the fill in blocks with a different value each time.
 */
static void fill_loopmode(u32 base, u32 n, u32 val)
{
    __asm__ volatile (
        "1:  movel  %2,%0@+   \n\t"
        "    dbra   %1,1b     \n\t"
        : "+a"(base), "+d"(n) : "d"(val) : "memory");
}

/* The control: identical, plus a nop, so the loop is two instructions and the
 * 68010 cannot enter loop mode.  Same writes, same addresses, same order. */
static void fill_noloop(u32 base, u32 n, u32 val)
{
    __asm__ volatile (
        "1:  movel  %2,%0@+   \n\t"
        "    nop              \n\t"
        "    dbra   %1,1b     \n\t"
        : "+a"(base), "+d"(n) : "d"(val) : "memory");
}

static void fill_loopmode_w(u32 base, u32 n, u16 val)
{
    __asm__ volatile (
        "1:  movew  %2,%0@+   \n\t"
        "    dbra   %1,1b     \n\t"
        : "+a"(base), "+d"(n) : "d"(val) : "memory");
}

/* Loop-mode reads, summed so the compiler cannot drop them. */
static u32 sum_loopmode(u32 base, u32 n)
{
    u32 acc = 0;
    __asm__ volatile (
        "1:  addl   %0@+,%2   \n\t"
        "    dbra   %1,1b     \n\t"
        : "+a"(base), "+d"(n), "+d"(acc) : : "memory");
    return acc;
}

/*
 * Every case fills in blocks of BLK longwords, each block with its own value,
 * so a word that came from the wrong transaction lands in the wrong block and
 * is caught.  Within a block a dropped write leaves whatever the previous pass
 * put there, which is a different block's value -- also caught.
 */
#define BLK   16
#define BLKSH 4     /* log2(BLK) -- shift, because there is no __udivsi3 */

static int check(u32 base, u32 nlong, u32 pass, const char *what)
{
    volatile u32 *p = (volatile u32 *)base;
    u32 i, bad = 0, first = 0, got = 0, want = 0;
    for (i = 0; i < nlong; i++) {
        u32 w = 0x5A000000UL | (pass << 16) | ((i >> BLKSH) & 0xFFFF);
        if (p[i] != w) {
            if (!bad) { first = i; got = p[i]; want = w; }
            bad++;
        }
    }
    puts_("     "); puts_(what);
    if (!bad) { puts_(": all "); putdec(nlong); puts_(" longwords correct\r\n"); return 0; }
    puts_(": "); putdec(bad); puts_(" of "); putdec(nlong);
    puts_(" WRONG -- first at index "); putdec(first);
    puts_(" (addr "); puthex(base + 4 * first, 6);
    puts_(") want "); puthex(want, 8);
    puts_(" got "); puthex(got, 8);
    puts_("\r\n");
    return bad;
}

static void fill_blocks(u32 base, u32 nlong, u32 pass, int loopmode)
{
    u32 b;
    for (b = 0; b < nlong; b += BLK) {
        u32 val = 0x5A000000UL | (pass << 16) | ((b >> BLKSH) & 0xFFFF);
        if (loopmode) fill_loopmode(base + 4 * b, BLK - 1, val);
        else          fill_noloop  (base + 4 * b, BLK - 1, val);
    }
}

int main(void)
{
    u32 bad_a, bad_b;
    volatile u32 *p = (volatile u32 *)BUF;
    u32 i;

    puts_("\r\nloopprobe: does a bus cycle survive with no fetch in front of it?\r\n");
    puts_("           (MC68010 loop mode, which RD68011 implements)\r\n\r\n");
    puts_("  buffer "); puthex(BUF, 6);
    puts_("  "); putdec(NLONG); puts_(" longwords\r\n");

    /* Poison, so a dropped write cannot pass by leaving the right value. */
    for (i = 0; i < NLONG; i++) p[i] = 0xDEADBEEFUL;

    puts_("\r\n  A  loop mode: movel %d0,%a0@+ / dbra\r\n");
    fill_blocks(BUF, NLONG, 1, 1);
    bad_a = check(BUF, NLONG, 1, "loop mode ");

    for (i = 0; i < NLONG; i++) p[i] = 0xDEADBEEFUL;

    puts_("\r\n  B  control: the same loop with a nop in it, so NOT loop mode\r\n");
    fill_blocks(BUF, NLONG, 2, 0);
    bad_b = check(BUF, NLONG, 2, "no loop   ");

    puts_("\r\n  C  loop-mode reads: addl %a0@+,%d2 / dbra\r\n");
    {
        u32 want = 0, s;
        for (i = 0; i < NLONG; i++) want += p[i];
        s = sum_loopmode(BUF, NLONG - 1);
        puts_("     sum by ordinary reads "); puthex(want, 8);
        puts_("   by loop mode "); puthex(s, 8);
        puts_(s == want ? "   match\r\n" : "   MISMATCH\r\n");
    }

    puts_("\r\n  D  loop mode, word writes: movew %d0,%a0@+ / dbra\r\n");
    {
        u32 bad = 0;
        volatile u16 *w = (volatile u16 *)BUF;
        for (i = 0; i < NLONG * 2; i++) w[i] = 0xFFFF;
        fill_loopmode_w(BUF, NLONG * 2 - 1, 0x1234);
        for (i = 0; i < NLONG * 2; i++) if (w[i] != 0x1234) bad++;
        puts_("     "); putdec(bad); puts_(" of "); putdec(NLONG * 2);
        puts_(" words wrong\r\n");
    }

    puts_("\r\n  ");
    if (bad_a && !bad_b)
        puts_("LOOP MODE IS THE VARIABLE: A fails where B, the same writes\r\n"
              "  without loop mode, passes.\r\n");
    else if (bad_a && bad_b)
        puts_("both fail -- the memory path is wrong for more than loop mode\r\n");
    else if (!bad_a && !bad_b)
        puts_("both pass -- loop mode is not dropping cycles here\r\n");
    else
        puts_("B fails and A passes, which makes no sense; read the numbers\r\n");

    puts_("\r\nloopprobe-finished\r\n");
    return 0;
}
