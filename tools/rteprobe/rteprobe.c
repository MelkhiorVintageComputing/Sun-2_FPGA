/*
 * Does a byte move take an address error when it is resumed by RTE?
 *
 * ---------------------------------------------------------------------------
 * What this is chasing
 * ---------------------------------------------------------------------------
 * On the board, three programs die with SIGBUS inside libc's strncpy --
 * inetd, in.telnetd and lpd -- always at the same instruction:
 *
 *     5e00:  moveb  %a1@+,%a0@+
 *     5e02:  dbeq   %d1,0x5e00
 *
 * A bus capture of the fault (1024 samples, triggered on the kernel's addrerr
 * handler with 960 samples of pre-trigger history) shows the whole sequence:
 *
 *     the kernel's rei path executes RTE, restoring PC = 0xD7BE00
 *     one iteration runs correctly:  read DD8898 (UDS), write 020FE6 (UDS)
 *     *** no cycle at DD8899.  No cycle at 020FE7. ***
 *     a format-8 frame is pushed with 0x800C -- vector 3, ADDRESS ERROR
 *
 * So the processor refuses the odd-address byte access without issuing a bus
 * cycle for it.  A byte access has no alignment requirement on a 68010, so
 * that is wrong however the instruction was reached.
 *
 * tools/strprobe sweeps the identical loop over all four entry alignments and
 * every length 1..16 and passes on both cores.  It cannot reproduce this
 * because it masks interrupts to level 7: its loop is never interrupted and so
 * never resumed.  The missing ingredient is the RTE.
 *
 * ---------------------------------------------------------------------------
 * How the RTE is forced
 * ---------------------------------------------------------------------------
 * With the trace bit set, every instruction raises a trace exception and the
 * handler returns with RTE -- so each iteration of the loop is entered exactly
 * the way the failing one was, deterministically, with no timer to arrange and
 * no race to lose.  It is a stronger condition than the machine's (which needs
 * an interrupt to land inside a two-instruction loop) and a much cheaper one
 * to run.
 *
 * The controls matter as much as the cases:
 *
 *   a  a word read at an odd address MUST raise vector 3 -- without it the
 *      handler proves nothing
 *   b  a byte read at an odd address MUST NOT
 *   c  the same copy loop with tracing OFF must pass, which is strprobe's
 *      result reproduced here so that the two runs differ in one thing only
 *
 * Then the same loop with tracing ON, over all four alignments and several
 * lengths.  If the RTE is what matters, c passes and the traced cases fault.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, VBR = 0.  Vector 2 (bus
 * error) is at 0x8, vector 3 (address error) at 0xC and vector 9 (trace) at
 * 0x24; the first two are caught separately so a failure says which the
 * machine raised.  Nothing here writes a map, a context or a device register.
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
/* No libgcc in a boot block, so no `/' or `%' on a long. */
static void putdec(u32 v)
{
    char b[12]; int i = 0;
    if (!v) { putch('0'); return; }
    while (v) { u32 q = 0, r = v; while (r >= 10) { r -= 10; q++; }
                b[i++] = '0' + (char)r; v = q; }
    while (i--) putch(b[i]);
}

volatile u32 took_addr, took_bus, traces;
volatile u32 saved_sp, saved_pc;

extern void addr_handler(void);
__asm__(
    "       .globl addr_handler           \n"
    "addr_handler:                        \n"
    "       movel  #1,took_addr           \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"   /* jmp, not rte: T stays clear */
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
 * The trace handler: count the instruction and return.  The RTE is the whole
 * point -- it is what puts the next instruction in the state the failing one
 * was in.  The 68010 clears T on exception entry and RTE restores it, so
 * tracing continues without anything further being done here.
 */
extern void trace_handler(void);
__asm__(
    "       .globl trace_handler          \n"
    "trace_handler:                       \n"
    "       addql  #1,traces              \n"
    "       rte                           \n"
    "       .text                         \n");

/* libc's loop, byte for byte, entered at the dbeq exactly as the library does. */
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

/* The copy, run with the trace bit set so every instruction returns by RTE. */
extern long traced_copy(void *dst, const void *src, long n);
__asm__(
    "       .globl traced_copy            \n"
    "traced_copy:                         \n"
    /* Arguments go on in reverse so dst ends up on top: after each push the
     * next one has slid down by four, so the same offset reads the next
     * argument.  Pushing dst first instead put n where dst belonged and the
     * loop copied to address 12 -- a watchdog on one core and a jump into the
     * source buffer on the other. */
    "       movel  %sp@(12),%sp@-         \n"   /* n   */
    "       movel  %sp@(12),%sp@-         \n"   /* src */
    "       movel  %sp@(12),%sp@-         \n"   /* dst */
    "       nop                           \n"
    "       orw    #0x8000,%sr            \n"   /* T on */
    "       jsr    strncpy_loop           \n"
    "       andiw  #0x7fff,%sr            \n"   /* T off */
    "       lea    %sp@(12),%sp           \n"
    "       rts                           \n"
    "       .text                         \n");

static u32 *vec_buserr = (u32 *)0x08;
static u32 *vec_adderr = (u32 *)0x0C;
static u32 *vec_trace  = (u32 *)0x24;

static u8 src_buf[64] __attribute__((aligned(4)));
static u8 dst_buf[64] __attribute__((aligned(4)));

static int failures, traced_faults;

static void arm(void) { took_addr = 0; took_bus = 0; }

static void one(u8 *d, const u8 *s, long n, int traced)
{
    arm();
    if (traced) traced_copy(d, s, n); else strncpy_loop(d, s, n);
    if (!took_addr && !took_bus) { putch('.'); return; }
    if (traced) traced_faults++; else failures++;
    puts_("\r\n    FAULT  dst ");   puthex((u32)d, 6);
    puts_(" src ");                 puthex((u32)s, 6);
    puts_(" n ");                   putdec((u32)n);
    puts_(took_addr ? "   ADDRESS ERROR (vector 3 = SIGBUS)"
                    : "   bus error (vector 2 = SIGSEGV)");
    puts_("\r\n    ");
}

int main(void)
{
    int i, di, si; long n, r; u32 rr;

    __asm__ volatile ("movew #0x2700,%%sr" : : : "memory");

    *vec_buserr = (u32)bus_handler;
    *vec_adderr = (u32)addr_handler;
    *vec_trace  = (u32)trace_handler;

    for (i = 0, rr = 0; i < 64; i++) {
        src_buf[i] = (u8)('a' + rr);
        if (++rr == 26) rr = 0;
        dst_buf[i] = 0;
    }
    src_buf[40] = 0;

    puts_("\r\nrteprobe: does a byte move take an address error when it is\r\n");
    puts_("          resumed by RTE?\r\n\r\n");

    /* ---- controls ---- */
    arm(); r = word_read(&src_buf[1]);
    puts_("  control a  word read at an odd address  ");
    if (took_addr)     puts_("address error -- correct\r\n");
    else { puts_("DID NOT FAULT -- the handler proves nothing\r\n"); failures++; }

    arm(); r = byte_read(&src_buf[1]);
    puts_("  control b  byte read at an odd address  ");
    if (!took_addr && !took_bus && r == src_buf[1]) puts_("no fault -- correct\r\n");
    else { puts_("FAULTED -- a byte access has no alignment rule\r\n"); failures++; }

    /* ---- control c: the loop, untraced.  strprobe's result, repeated. ---- */
    puts_("\r\n  control c  the copy loop, NOT traced (no RTE):\r\n    ");
    for (di = 0; di < 2; di++)
        for (si = 0; si < 2; si++)
            for (n = 1; n <= 13; n++) one(&dst_buf[di], &src_buf[si], n, 0);
    puts_("\r\n");

    /* ---- the case: the same loop, every instruction resumed by RTE ---- */
    puts_("\r\n  the case: the same loop with the trace bit set, so every\r\n");
    puts_("  iteration is entered by RTE:\r\n    ");
    traces = 0;
    for (di = 0; di < 2; di++)
        for (si = 0; si < 2; si++)
            for (n = 1; n <= 13; n++) one(&dst_buf[di], &src_buf[si], n, 1);
    puts_("\r\n\r\n  trace exceptions taken: ");
    putdec(traces);
    puts_("\r\n\r\n");

    if (traces == 0) {
        puts_("  INCONCLUSIVE: no trace exception was taken, so nothing was\r\n"
              "        resumed by RTE and the case below was never tested.\r\n");
    } else if (failures == 0 && traced_faults == 0) {
        puts_("  PASS: the loop is correct traced and untraced.  RTE resumption\r\n"
              "        alone does not reproduce the board's fault.\r\n");
    } else if (failures == 0 && traced_faults > 0) {
        puts_("  REPRODUCED: the loop is correct when run straight through and\r\n"
              "        faults when its iterations are entered by RTE.  ");
        putdec((u32)traced_faults);
        puts_(" case(s).\r\n");
    } else {
        puts_("  FAIL: ");
        putdec((u32)failures);
        puts_(" untraced case(s) faulted -- see above; the controls or the\r\n"
              "        untraced loop are wrong, so the traced result means little.\r\n");
    }

    puts_("\r\nrteprobe-finished\r\n");
    for (;;) ;
    return 0;
}
