/*
 * A chained-IOPB exerciser for the emulated Xylogics 450, run on the machine.
 *
 * tb/tb_xy450.sv drives the controller against a memory model and a file, and
 * it is a replay of what the SunOS driver does rather than the driver itself.
 * This is the other half: a boot program the monitor loads and jumps to, which
 * drives real chains through the real MMU, contends with the real CPU for the
 * bus, and -- the part nothing else in this design has ever done -- takes a
 * real interrupt from a MultiBus card.
 *
 * It is written to look like sun/sys/sundev/xy.c does the same things, because
 * being able to compare them line by line is the point.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * The monitor's boot path installs the Sun-1 map before jumping here
 * (commands.c:496, `setupmap(fakemapinit); setupmap(fakemapinit2);`), so:
 *
 *   0x004000            this program, loaded from disk blocks 1..15
 *   0x000068            the level 2 autovector, VBR being 0 (s2addrs.h:114)
 *   0xEB0000 + 0xEE40   the controller's registers, MultiBus I/O, TYPE 3
 *   0xF00000 .. 0xF3FFF the DVMA window, on physical 0xC0000 as plain memory
 *   0xEF0000            the PROM vector table, left where mapinit put it
 *
 * MultiBus address X is virtual 0xF00000 + X, which is what makes an IOPB at
 * 0xF00100 the same bytes the controller fetches from MultiBus 0x100.
 *
 * We are in supervisor mode with a stack the monitor set up, and interrupts
 * are enabled at the system level -- the monitor's own NMI is running.
 */

/*
 * The monitor jumps to the first byte of what it loaded, so _start has to be
 * at the front of the image; xychain.ld places this section first.  The stack
 * is the monitor's and needs nothing done to it.
 *
 * The zeroing loop is not optional.  `objcopy -O binary` drops .bss because it
 * is NOBITS however the linker script places it, so the image stops at the end
 * of .data and every zero-initialised global lands on whatever the boot left
 * in memory.  A counter that starts at rubbish makes this program report a
 * failure it did not have.
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

/* ------------------------------------------------------------------------ */
/* The monitor                                                              */
/* ------------------------------------------------------------------------ */
/* struct sunromvec, mon/h/sunromvec.h.  v_putchar is the seventh pointer.   */
#define ROMP      0xEF0000UL
#define V_PUTCHAR (*(int (**)(int))(ROMP + 24))

static void putch(int c)          { V_PUTCHAR(c); }
static void puts_(const char *s)  { while (*s) putch(*s++); }

static void puthex(u32 v, int digits)
{
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = digits - 1; i >= 0; i--)
        putch(hex[(v >> (4 * i)) & 0xF]);
}

/*
 * Hex, not decimal: with -nostdlib there is no libgcc, and a divide by ten
 * would be a call to __udivsi3 that nothing resolves.  Every number this
 * prints is a small count, so hex costs nothing to read.
 */

/* ------------------------------------------------------------------------ */
/* The controller                                                           */
/* ------------------------------------------------------------------------ */
/*
 * struct xydevice from sundev/xycreg.h, byte for byte.  The comments there
 * give the controller's own register numbers, which are these offsets with
 * bit 0 of the address inverted -- MultiBus counts bytes little-endian and a
 * 68000 does not.
 */
struct xydevice {
    volatile u8 xy_iopbrel[2];   /* 1,0 - IOPB relocation */
    volatile u8 xy_iopboff[2];   /* 3,2 - IOPB offset */
    volatile u8 xy_resupd;       /* 5   - reset/update */
    volatile u8 xy_csr;          /* 4   - control and status */
};

#define XYIO ((struct xydevice *)(0xEB0000UL + 0xEE40))

#define XY_GO      0x80
#define XY_BUSY    0x80
#define XY_ERROR   0x40
#define XY_DBLERR  0x20
#define XY_INTR    0x10
#define XY_ADDR24  0x08
#define XY_ATTN    0x04
#define XY_ACK     0x02
#define XY_DREADY  0x01

/*
 * The IOPB, in the controller's own byte numbering.  Declaring it as a byte
 * array indexed by that numbering, rather than as struct xyiopb with its
 * swapped pairs, keeps the arithmetic where it can be seen.
 */
#define DVMA      0xF00000UL
#define IOPB_MB   0x0100UL           /* first IOPB, MultiBus address */
#define IOPB_STEP 0x0020UL
#define BUF_MB    0x1000UL           /* first data buffer */
#define BUF_STEP  0x0200UL

#define IOPB_VA(n) (DVMA + IOPB_MB + (n) * IOPB_STEP)
#define BUF_VA(n)  (DVMA + BUF_MB  + (n) * BUF_STEP)
#define BUF_MB_OF(n) (BUF_MB + (n) * BUF_STEP)

static void iopb_put(int n, int byte, u8 v)
{
    *(volatile u8 *)(IOPB_VA(n) + (byte ^ 1)) = v;
}

static u8 iopb_get(int n, int byte)
{
    return *(volatile u8 *)(IOPB_VA(n) + (byte ^ 1));
}

/*
 * One IOPB, filled the way initiopb() and xycmd() between them fill one:
 * AUD and RELO always, ECC mode 2, throttle 4, plus CHEN and IEN here.
 */
static void build(int n, int cmd, int chen, int ien, int iei,
                  u32 blk, u16 nsect, u32 nxt_mb)
{
    int i;
    u32 cyl, head, sect;

    for (i = 0; i < 24; i++) iopb_put(n, i, 0);

    /* the geometry mkxydisk writes into the label, and Set Drive Size sets */
    sect = blk % 32;
    head = (blk / 32) % 4;
    cyl  = blk / (32 * 4);

    iopb_put(n, 0x00, 0x80 | 0x40 | (chen ? 0x20 : 0) | (ien ? 0x10 : 0) | cmd);
    iopb_put(n, 0x01, (iei ? 0x40 : 0) | 0x02);        /* IEI, ECC mode 2 */
    iopb_put(n, 0x04, 0x04);                            /* XY_THROTTLE */
    iopb_put(n, 0x05, 0x00);                            /* drive type 0, unit 0 */
    iopb_put(n, 0x06, (u8)head);
    iopb_put(n, 0x07, (u8)sect);
    iopb_put(n, 0x08, (u8)(cyl & 0xFF));
    iopb_put(n, 0x09, (u8)((cyl >> 8) & 0x07));
    iopb_put(n, 0x0A, (u8)(nsect & 0xFF));
    iopb_put(n, 0x0B, (u8)(nsect >> 8));
    iopb_put(n, 0x0C, (u8)(BUF_MB_OF(n) & 0xFF));
    iopb_put(n, 0x0D, (u8)((BUF_MB_OF(n) >> 8) & 0xFF));
    iopb_put(n, 0x12, (u8)(nxt_mb & 0xFF));
    iopb_put(n, 0x13, (u8)((nxt_mb >> 8) & 0xFF));
}

/* ------------------------------------------------------------------------ */
/* The interrupt                                                            */
/* ------------------------------------------------------------------------ */
/*
 * Level 2, autovectored -- `xyc0 at mbio ? csr 0xee40 priority 2` in
 * conf.sun2/XY100, and sun2/autoconf.c clears mc_intr on anything that is not
 * a 2/50, so there is no vector to supply.  Vector 26 is at VBR + 0x68 and the
 * monitor's VBR is zero.
 *
 * The handler does what xyintr() does first and nothing else: clear IPND and
 * count.  Everything the driver does after that is done in the foreground
 * here, so the handler stays short enough to be obviously correct.
 */
/*
 * Vector 26, at VBR + 0x68 with the monitor's VBR of zero.  Written through a
 * variable rather than a constant because gcc otherwise decides a store to
 * 0x68 is a null-pointer dereference and says so at length.
 */
static volatile u32 vec_level2_addr = 0x68;

static volatile u32 irq_count;

void irq_handler(void)
{
    irq_count++;
    XYIO->xy_csr = XY_INTR;
}

/* A trampoline, because the compiler cannot generate `rte`. */
extern void irq_stub(void);
__asm__(
    "       .text                   \n"
    "       .globl irq_stub         \n"
    "irq_stub:                      \n"
    "       moveml %d0-%d1/%a0-%a1,%sp@-  \n"
    "       jsr    irq_handler       \n"
    "       moveml %sp@+,%d0-%d1/%a0-%a1  \n"
    "       rte                     \n");

/* ------------------------------------------------------------------------ */
/* Running a chain                                                          */
/* ------------------------------------------------------------------------ */
static int fails;

static void check(int ok, const char *what)
{
    if (!ok) { puts_("FAIL: "); puts_(what); putch('\n'); fails++; }
}

/*
 * xyexec(), without the paranoid readbacks: point the controller at the head
 * of the chain and set Go.  The relocation registers stay at zero, as the
 * driver leaves them after probe.
 */
static void go(u32 head_mb)
{
    XYIO->xy_iopbrel[0] = 0;
    XYIO->xy_iopbrel[1] = 0;
    XYIO->xy_iopboff[0] = (u8)((head_mb >> 8) & 0xFF);
    XYIO->xy_iopboff[1] = (u8)(head_mb & 0xFF);
    XYIO->xy_csr = XY_GO;
}

/*
 * Wait for the chain, without polling the interrupt away from the handler.
 *
 * The spin afterwards is not padding.  GBSY drops and IPND rises in the same
 * cycle, so the read that first sees GBSY clear can happen one instruction
 * before the processor takes the interrupt -- and then a check of the counter
 * reads it one short.
 */
static int wait_idle(void)
{
    u32 n;
    int ok = 0;

    for (n = 0; n < 20000000UL; n++)
        if ((XYIO->xy_csr & XY_BUSY) == 0) { ok = 1; break; }

    for (n = 0; n < 1000UL; n++)
        (void)XYIO->xy_csr;

    return ok;
}

static void fill(int n, u8 v)
{
    int i;
    for (i = 0; i < 512; i++) *(volatile u8 *)(BUF_VA(n) + i) = v;
}

static u16 word_at(int n, int off)
{
    return (u16)((*(volatile u8 *)(BUF_VA(n) + off) << 8) |
                  *(volatile u8 *)(BUF_VA(n) + off + 1));
}

int main(void)
{
    u32 before;
    int i, n;

    puts_("\nxychain: chained IOPBs, on the machine\n");

    /* The controller should be idle and the drive ready. */
    (void)XYIO->xy_resupd;                    /* controller reset */
    for (n = 0; n < 1000000 && (XYIO->xy_csr & XY_BUSY); n++)
        ;
    check((XYIO->xy_csr & XY_BUSY) == 0, "the controller reset never finished");
    check((XYIO->xy_csr & XY_DREADY) != 0, "no drive");

    /* Tell the controller the geometry mkxydisk labelled the disk with. */
    build(0, 0xB, 0, 0, 0, 0, 0, 0);          /* Set Drive Size */
    iopb_put(0, 0x06, 4 - 1);                 /* heads */
    iopb_put(0, 0x07, 32 - 1);                /* sectors */
    iopb_put(0, 0x08, (32 + 2) - 1);          /* cylinders */
    iopb_put(0, 0x09, 0);
    go(IOPB_MB);
    check(wait_idle(), "Set Drive Size never finished");
    check(iopb_get(0, 3) == 0, "Set Drive Size failed");

    /* Take the interrupt from here on. */
    *(volatile u32 *)vec_level2_addr = (u32)irq_stub;
    __asm__ volatile ("movew #0x2000,%sr");   /* supervisor, IPL 0 */

    /*
     * A chain of four reads of the first four blocks, one interrupt expected
     * at the end because IEI is clear -- xyasynch() sets xy_ie and clears
     * xy_intrall, and a second interrupt would be read as the *next* chain
     * completing.
     */
    for (i = 0; i < 4; i++) {
        build(i, 0x2, i < 3, 1, 0, i, 1, IOPB_MB + (i + 1) * IOPB_STEP);
        fill(i, 0x00);
    }
    irq_count = 0;
    before = irq_count;
    go(IOPB_MB);
    check(wait_idle(), "a chain of four never cleared GBSY");

    for (i = 0; i < 4; i++) {
        check((iopb_get(i, 2) & 0x01) != 0, "an IOPB in the chain has no DONE");
        check(iopb_get(i, 3) == 0, "an IOPB in the chain reported an error");
    }
    check(word_at(0, 508) == 0xDABE, "the chain did not read the label");

    /*
     * Block 1 is the first sector of this program, so the second IOPB of the
     * chain read the code that is executing it.  Comparing the two is a
     * stronger check than any constant: it fails on a wrong block number, a
     * wrong buffer address, a byte swap, or a single dropped byte.
     */
    for (i = 0, n = 0; i < 512; i++)
        if (*(volatile u8 *)(BUF_VA(1) + i) != *(volatile u8 *)(0x4000UL + i))
            n++;
    check(n == 0, "block 1 did not come back as a copy of this program");

    /*
     * The interrupt.  This is the first thing in this machine to depend on a
     * MultiBus card driving INT2, on IPND surviving as a level until the
     * handler writes it back, and on the 74LS148 and the autovector path.
     */
    puts_("interrupts taken: ");
    puthex(irq_count - before, 2);
    putch('\n');
    check(irq_count - before == 1,
          "a chain with IEI clear must interrupt exactly once");

    /* And again with IEI set: one interrupt per IOPB. */
    for (i = 0; i < 4; i++) {
        build(i, 0x2, i < 3, 1, 1, i, 1, IOPB_MB + (i + 1) * IOPB_STEP);
        fill(i, 0x00);
    }
    before = irq_count;
    go(IOPB_MB);
    check(wait_idle(), "a chain of four with IEI never cleared GBSY");
    puts_("interrupts taken with IEI: ");
    puthex(irq_count - before, 2);
    putch('\n');
    check(irq_count - before == 4,
          "a chain with IEI set must interrupt on every IOPB");

    /*
     * A tail with a stale next pointer, which is what xychain() leaves every
     * time: it clears xy_chain and never clears xy_nxtoff (xy.c:744-745).
     *
     * The stale value points at a real, loaded IOPB rather than at rubbish.
     * Pointing it at an unused address proves nothing here -- the DVMA window
     * is zeroed, a zero IOPB decodes as a NOP with no interrupt and no error,
     * and a controller that followed the pointer would look exactly like one
     * that did not.  IOPB 4 is a live read into a buffer with a pattern in it,
     * so if it runs at all it leaves a mark.
     */
    build(0, 0x2, 1, 1, 0, 0, 1, IOPB_MB + IOPB_STEP);
    build(1, 0x2, 0, 1, 0, 1, 1, IOPB_MB + 4 * IOPB_STEP);   /* stale */
    build(4, 0x2, 0, 1, 0, 3, 1, 0);
    fill(0, 0x00); fill(1, 0x00); fill(4, 0xA5);
    before = irq_count;
    go(IOPB_MB);
    check(wait_idle(), "a chain with a stale tail pointer never stopped");
    check(iopb_get(1, 3) == 0, "the tail of the chain failed");
    check((iopb_get(4, 2) & 0x01) == 0,
          "the controller followed a next pointer behind a clear CHEN");
    check(*(volatile u8 *)BUF_VA(4) == 0xA5,
          "the IOPB behind a clear CHEN transferred data");
    check(irq_count - before == 1, "the stale-tail chain interrupted more than once");

    if (fails == 0) puts_("xychain: PASS\n");
    else            { puts_("xychain: FAIL, "); puthex(fails, 2); puts_(" checks\n"); }

    puts_("xychain-finished\n");
    for (;;)
        ;
}
