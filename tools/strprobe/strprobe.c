/*
 * Does a byte move with an odd operand raise an address error?
 *
 * ---------------------------------------------------------------------------
 * The observation this exists to explain
 * ---------------------------------------------------------------------------
 * Three programs on this machine die with SIGBUS at the same instruction:
 * inetd, in.telnetd and (recorded in CLAUDE.md) lpd.  Their cores are
 * identical in every register that matters:
 *
 *     pc  0x00d7be04   = _strncpy + 0x14 in libc.so.0.12, loaded at 0xd76000
 *     d1  0x0000000c   = n = 12
 *     a0  dest, even on entry, odd in the core
 *     a1  0x00dd8899   source, even on entry, odd in the core
 *
 * That is one byte into the copy.  strncpy's inner loop is two instructions:
 *
 *     5e00:  moveb  %a1@+,%a0@+
 *     5e02:  dbeq   %d1,0x5e00
 *
 * so the fault lands on the second pass, exactly when both pointers have gone
 * odd.  On sun2 SIGBUS is T_ADDRERR and nothing else -- sys/sun2/trap.c raises
 * SIGSEGV for T_BUSERR and reaches SIGBUS only from T_ADDRERR -- so the kernel
 * is reporting an *address error* on a byte move.
 *
 * A 68010 does not do that.  Byte accesses have no alignment requirement; only
 * word and long ones do.  If the machine really raises an address error here
 * then it is a core defect, and one that would explain all three deaths.
 *
 * ---------------------------------------------------------------------------
 * Why this is not obviously true, and why it needs measuring
 * ---------------------------------------------------------------------------
 * strncpy from an even source to an even destination is the commonest string
 * copy there is, and this machine runs sh, ls, awk, fsck and a 27 KB compile.
 * If every such copy faulted on its second byte nothing would work at all.  So
 * either the trigger is narrower than "both operands odd", or the fault is not
 * where the core files appear to put it.  Both possibilities are worth an
 * answer that does not depend on a kernel, a filesystem or a shared library
 * being correct, which is what a boot block buys.
 *
 * ---------------------------------------------------------------------------
 * What is measured
 * ---------------------------------------------------------------------------
 *   1  the two controls, first, because a result from the cases below is
 *      worthless if they do not hold:
 *        a  a *word* read at an odd address MUST fault -- proves the handler
 *           is installed and the machine raises address errors at all
 *        b  a plain byte read at an odd address MUST NOT fault
 *   2  the libc loop itself, byte for byte, over all four alignment
 *      combinations of (dest, source) and every length 1..16.  n = 12 with
 *      both even is the case the cores show.
 *   3  the same loop with the source in the *data* area rather than on the
 *      stack, in case the trigger is which page is being read rather than the
 *      alignment.
 *
 * Anything that faults is reported with its dest/source/length, so a failure
 * names the exact combination rather than just "it broke".
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed,
 * VBR = 0.  Vector 2 (bus error) is at 0x8 and vector 3 (address error) at
 * 0xC; both are caught separately so a failure says which of the two the
 * machine raised.  Nothing here writes a map, a context or a device register,
 * so it changes nothing lasting and is safe to run on either core.
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

/*
 * No libgcc here: -nostdlib means `/' and `%' on a long would pull in
 * __udivsi3 and __modsi3, which do not exist in a boot block.  Everything
 * printed is smaller than a thousand, so repeated subtraction costs nothing.
 */
static void putdec(u32 v)
{
    char b[12]; int i = 0;
    if (!v) { putch('0'); return; }
    while (v) {
        u32 q = 0, r = v;
        while (r >= 10) { r -= 10; q++; }
        b[i++] = '0' + (char)r;
        v = q;
    }
    while (i--) putch(b[i]);
}

/*
 * Two vectors, kept apart on purpose.  The kernel's own mapping is
 * T_BUSERR -> SIGSEGV and T_ADDRERR -> SIGBUS, so which one the machine raises
 * is the whole question: the cores say SIGBUS, meaning vector 3.
 */
volatile u32 took_addr;         /* vector 3 fired */
volatile u32 took_bus;          /* vector 2 fired */
volatile u32 saved_sp, saved_pc;

extern void addr_handler(void);
__asm__(
    "       .globl addr_handler           \n"
    "addr_handler:                        \n"
    "       movel  #1,took_addr           \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                         \n");

extern void bus_handler(void);
__asm__(
    "       .globl bus_handler            \n"
    "bus_handler:                         \n"
    "       movel  #1,took_bus            \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                         \n");

/*
 * libc's strncpy inner loop, byte for byte.  Entered through the same `bras'
 * into the dbeq that the library uses, because the first thing executed there
 * is the decrement and not the move, and a reproducer that gets that wrong is
 * testing a different loop.
 *
 * Returns 0, or -1 if it faulted.
 */
extern long strncpy_loop(void *dst, const void *src, long n);
__asm__(
    "       .globl strncpy_loop           \n"
    "strncpy_loop:                        \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       moveal %sp@(4),%a0            \n"
    "       moveal %sp@(8),%a1            \n"
    "       movel  %sp@(12),%d1           \n"
    "       movel  %a0,%d0                \n"
    "       bras   3f                     \n"
    "2:     moveb  %a1@+,%a0@+            \n"
    "3:     dbeq   %d1,2b                 \n"
    "       moveq  #0,%d0                 \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

/* A word read at whatever address it is given: the control that must fault. */
extern long word_read(const void *addr);
__asm__(
    "       .globl word_read              \n"
    "word_read:                           \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       moveal %sp@(4),%a0            \n"
    "       movew  %a0@,%d0               \n"
    "       andil  #0xffff,%d0            \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

/* A byte read at whatever address it is given: the control that must not. */
extern long byte_read(const void *addr);
__asm__(
    "       .globl byte_read              \n"
    "byte_read:                           \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       moveal %sp@(4),%a0            \n"
    "       moveq  #0,%d0                 \n"
    "       moveb  %a0@,%d0               \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

static u32 *vec_buserr = (u32 *)0x8;
static u32 *vec_adderr = (u32 *)0xC;

/* Aligned so the +0/+1 offsets below really do change the parity. */
static u8 src_buf[64] __attribute__((aligned(4)));
static u8 dst_buf[64] __attribute__((aligned(4)));

static int failures;

static void arm(void) { took_addr = 0; took_bus = 0; }

static void one_case(u8 *d, const u8 *s, long n, int quiet)
{
    long r;
    arm();
    r = strncpy_loop(d, s, n);
    if (r == 0 && !took_addr && !took_bus) {
        if (!quiet) puts_(".");
        return;
    }
    failures++;
    puts_("\r\n    FAULT  dst ");   puthex((u32)d, 6);
    puts_(" src ");                 puthex((u32)s, 6);
    puts_(" n ");                   putdec((u32)n);
    puts_(took_addr ? "   ADDRESS ERROR (vector 3 = SIGBUS)"
                    : "   bus error (vector 2 = SIGSEGV)");
}

int main(void)
{
    int i, di, si;
    long n, r;

    __asm__ volatile ("movew #0x2700,%%sr" : : : "memory");

    *vec_buserr = (u32)bus_handler;
    *vec_adderr = (u32)addr_handler;

    for (i = 0, r = 0; i < 64; i++) {          /* no % : wrap by hand */
        src_buf[i] = (u8)('a' + r);
        if (++r == 26) r = 0;
        dst_buf[i] = 0;
    }
    src_buf[40] = 0;

    puts_("\r\nstrprobe: does a byte move with an odd operand raise an\r\n");
    puts_("          address error?\r\n\r\n");

    /* ---- control a: a word read at an odd address must fault ---- */
    arm();
    r = word_read(&src_buf[1]);
    puts_("  control a  word read at an odd address  ");
    if (took_addr)      puts_("faults, address error -- correct\r\n");
    else if (took_bus)  { puts_("faults, but as a BUS error\r\n"); failures++; }
    else                { puts_("DID NOT FAULT -- the handler proves nothing\r\n");
                          failures++; }

    /* ---- control b: a byte read at an odd address must not ---- */
    arm();
    r = byte_read(&src_buf[1]);
    puts_("  control b  byte read at an odd address  ");
    if (!took_addr && !took_bus && r == src_buf[1])
        puts_("no fault -- correct\r\n");
    else { puts_("FAULTED -- a byte access has no alignment rule\r\n"); failures++; }

    /* ---- the libc loop, every alignment, every length 1..16 ---- */
    puts_("\r\n  strncpy's loop, all four alignments, n = 1..16:\r\n");
    for (di = 0; di < 2; di++) {
        for (si = 0; si < 2; si++) {
            puts_("    dst ");
            putch(di ? 'o' : 'e');
            puts_("  src ");
            putch(si ? 'o' : 'e');
            puts_("  ");
            for (n = 1; n <= 16; n++)
                one_case(&dst_buf[di], &src_buf[si], n, 0);
            puts_("\r\n");
        }
    }

    /*
     * The case the cores show, on its own and named: n = 12, both operands
     * even on entry, so both are odd for the second pass of the loop.
     */
    puts_("\r\n  the case three cores show -- n = 12, dst even, src even:\r\n    ");
    one_case(&dst_buf[0], &src_buf[0], 12, 0);
    puts_("\r\n");

    puts_("\r\n");
    if (failures == 0)
        puts_("  PASS: no byte move faulted.  The core does not raise an\r\n"
              "        address error on an odd byte access, so whatever kills\r\n"
              "        inetd and in.telnetd is not this instruction alone.\r\n");
    else {
        puts_("  FAIL: ");
        putdec((u32)failures);
        puts_(" case(s) faulted -- see above.\r\n");
    }

    puts_("\r\nstrprobe-finished\r\n");
    for (;;) ;
    return 0;
}
