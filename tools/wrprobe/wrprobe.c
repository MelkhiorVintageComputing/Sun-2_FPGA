/*
 * Does this machine write to its disk correctly?  Asked from a boot block,
 * where the answer is not confounded by a filesystem.
 *
 * ---------------------------------------------------------------------------
 * Why this exists
 * ---------------------------------------------------------------------------
 * Every disk controller on the DECA corrupts *large* file writes to the
 * micro-SD card and none of them corrupts small ones, with reads perfect.
 * Measured on hardware, copies read back from the medium after a reboot:
 *
 *     3 blocks    54006 -> 54006      10 blocks   09808 -> 09808
 *   104 blocks    34435 -> 51819     104 blocks   05453 -> 29364
 *
 * Four layers have been cleared by test and none of them was it: the media (a
 * new card fails the same way), the SD path on real hardware
 * (test/deca_sdtest, 256 blocks at 25 MHz, zero errors), blk_sd in simulation
 * (`make -C sim blksd'), and the SCSI engine and sun2_dvma (`make -C sim
 * mbscsi', `dvma') -- the latter two with sustained traffic against a memory
 * as slow as DDR3, and with several commands back to back.
 *
 * What no test has is **the CPU running at the same time**.  On hardware the
 * kernel executes while the controller streams, so the CPU and the master
 * alternate through sun2_wishbone_bridge at DDR3 latency.  This tree has
 * already had a bug exactly there -- "a bridge that serves two masters must
 * know whose cycle it is answering" -- and that fix has never been tested
 * under sustained master traffic.
 *
 * A boot block is the cheapest way to get that: real MMU, real DVMA, real
 * DDR3, and a CPU busy in a loop while the transfer runs.  In simulation it
 * also gives tb_sun2's memory checker something to check, because **a boot
 * only ever reads from disk** -- a disk read is the controller DVMA-*writing*
 * to memory, and the direction a disk write uses had no coverage at all.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * As tools/xychain: the monitor's boot path installs the Sun-1 map before
 * jumping here, so MultiBus address X is virtual 0xF00000 + X, the controller
 * is at 0xEB0000 + 0xEE40 in MultiBus I/O, and the DVMA window covers
 * 0xF00000..0xF3FFFF on physical 0xC0000.
 *
 * It writes to blocks well past the boot block itself, so a disk image it has
 * run against is still bootable.
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

static void putch(int c)          { V_PUTCHAR(c); }
static void puts_(const char *s)  { while (*s) putch(*s++); }

static void puthex(u32 v, int digits)
{
    static const char hex[] = "0123456789abcdef";
    int i;
    for (i = digits - 1; i >= 0; i--)
        putch(hex[(v >> (4 * i)) & 0xF]);
}

/* ------------------------------------------------------------------------ */
/* The controller                                                           */
/* ------------------------------------------------------------------------ */
struct xydevice {
    volatile u8 xy_iopbrel[2];
    volatile u8 xy_iopboff[2];
    volatile u8 xy_resupd;
    volatile u8 xy_csr;
};

#define XYIO ((struct xydevice *)(0xEB0000UL + 0xEE40))

#define XY_GO      0x80
#define XY_BUSY    0x80
#define XY_ERROR   0x40
#define XY_INTR    0x10

#define DVMA      0xF00000UL
#define IOPB_MB   0x0100UL
#define IOPB_VA   (DVMA + IOPB_MB)

/* Two buffers, far enough apart that a transfer cannot reach the other. */
#define WBUF_MB   0x2000UL
#define RBUF_MB   0x8000UL
#define WBUF_VA   (DVMA + WBUF_MB)
#define RBUF_VA   (DVMA + RBUF_MB)

/* Where on the disk.  Past the label and the boot blocks, so an image this
 * has run against still boots. */
#define FIRST_BLK 64

#define CMD_WRITE 0x1
#define CMD_READ  0x2

static void iopb_put(int byte, u8 v)
{
    *(volatile u8 *)(IOPB_VA + (byte ^ 1)) = v;
}

static u8 iopb_get(int byte)
{
    return *(volatile u8 *)(IOPB_VA + (byte ^ 1));
}

/* The geometry mkxydisk writes into the label and Set Drive Size sets. */
static void build(int cmd, u32 blk, u16 nsect, u32 buf_mb)
{
    int i;
    u32 cyl, head, sect;

    for (i = 0; i < 24; i++) iopb_put(i, 0);

    sect = blk % 32;
    head = (blk / 32) % 4;
    cyl  = blk / (32 * 4);

    iopb_put(0x00, 0x80 | 0x40 | cmd);      /* AUD | RELO | cmd */
    iopb_put(0x01, 0x02);                   /* ECC mode 2 */
    iopb_put(0x04, 0x04);                   /* throttle */
    iopb_put(0x05, 0x00);                   /* drive type 0, unit 0 */
    iopb_put(0x06, (u8)head);
    iopb_put(0x07, (u8)sect);
    iopb_put(0x08, (u8)(cyl & 0xFF));
    iopb_put(0x09, (u8)((cyl >> 8) & 0x07));
    iopb_put(0x0A, (u8)(nsect & 0xFF));
    iopb_put(0x0B, (u8)(nsect >> 8));
    iopb_put(0x0C, (u8)(buf_mb & 0xFF));
    iopb_put(0x0D, (u8)((buf_mb >> 8) & 0xFF));
}

static void go(void)
{
    XYIO->xy_iopbrel[0] = 0;
    XYIO->xy_iopbrel[1] = 0;
    XYIO->xy_iopboff[0] = (u8)((IOPB_MB >> 8) & 0xFF);
    XYIO->xy_iopboff[1] = (u8)(IOPB_MB & 0xFF);
    XYIO->xy_csr = XY_GO;
}

/*
 * Wait, and keep the CPU busy while waiting.
 *
 * The idling is the point rather than an accident: a CPU spinning on the
 * controller's status register is issuing bus cycles the whole time the master
 * is streaming, which is what the machine looks like when a kernel writes a
 * file and what no testbench in this tree reproduces.  A wait that halted
 * would remove the very condition being tested.
 */
static int wait_idle(void)
{
    u32 n;
    for (n = 0; n < 20000000UL; n++)
        if ((XYIO->xy_csr & XY_BUSY) == 0) return 1;
    return 0;
}

/* ------------------------------------------------------------------------ */
/* The pattern                                                              */
/* ------------------------------------------------------------------------ */
/*
 * Derived from the block *and* the offset, so a sector that lands at the wrong
 * block fails the compare rather than passing by resembling its neighbour --
 * which matters here, because "the hardware writes at the wrong address" is
 * one of the two theories this program exists to separate.
 */
static u8 pat(u32 blk, u32 off)
{
    return (u8)((blk * 7u) ^ (off * 11u) ^ (off >> 8));
}

static int fails;

static void fill(u32 blk, u16 nsect)
{
    u32 i, n = (u32)nsect * 512u;
    for (i = 0; i < n; i++)
        *(volatile u8 *)(WBUF_VA + i) = pat(blk + i / 512u, i % 512u);
}

static u32 verify(u32 blk, u16 nsect, u32 *first_off, u8 *got, u8 *want)
{
    u32 i, n = (u32)nsect * 512u, bad = 0;
    for (i = 0; i < n; i++) {
        u8 g = *(volatile u8 *)(RBUF_VA + i);
        u8 w = pat(blk + i / 512u, i % 512u);
        if (g != w) {
            if (bad == 0) { *first_off = i; *got = g; *want = w; }
            bad++;
        }
    }
    return bad;
}

/*
 * One write, then one read of the same blocks into a different buffer.
 *
 * The read goes somewhere else on purpose.  Reading back into the buffer that
 * was written would pass whenever the controller never touched memory at all,
 * which is the failure mode nearest to the one being chased.
 */
static void round(u32 blk, u16 nsect)
{
    u32 bad, off = 0;
    u8  got = 0, want = 0;
    u32 i;

    fill(blk, nsect);
    for (i = 0; i < (u32)nsect * 512u; i++)
        *(volatile u8 *)(RBUF_VA + i) = 0xA5;

    build(CMD_WRITE, blk, nsect, WBUF_MB);
    go();
    if (!wait_idle()) { puts_("FAIL: write never finished\n"); fails++; return; }
    if (XYIO->xy_csr & XY_ERROR) {
        puts_("FAIL: write set ERROR, cc "); puthex(iopb_get(3), 2); putch('\n');
        fails++; return;
    }

    build(CMD_READ, blk, nsect, RBUF_MB);
    go();
    if (!wait_idle()) { puts_("FAIL: read never finished\n"); fails++; return; }
    if (XYIO->xy_csr & XY_ERROR) {
        puts_("FAIL: read set ERROR, cc "); puthex(iopb_get(3), 2); putch('\n');
        fails++; return;
    }

    bad = verify(blk, nsect, &off, &got, &want);
    puts_("blk "); puthex(blk, 4);
    puts_(" x"); puthex(nsect, 2);
    puts_(": ");
    if (bad == 0) {
        puts_("ok\n");
    } else {
        puts_("BAD "); puthex(bad, 4);
        puts_(" bytes, first at "); puthex(off, 4);
        puts_(" got "); puthex(got, 2);
        puts_(" want "); puthex(want, 2);
        putch('\n');
        fails++;
    }
}

int main(void)
{
    u32 blk;
    int i;

    puts_("\nwrprobe: writes through the real DVMA path\n");

    /*
     * Set Drive Size, and it has to carry the geometry.
     *
     * The controller loads max_head/max_sect/max_cyl straight out of this
     * IOPB's bytes 6, 7 and 8/9 (sun2_xy450.sv:729-733) and then rejects any
     * transfer addressing beyond them.  tools/xychain issues this command with
     * a zeroed IOPB and gets away with it because every block it touches is
     * 0..3, where the head is always zero; the first block here is 64, which
     * is head 2, and a zeroed geometry answers CC_HADR (0x20).
     *
     * These are maximum *index* values, matching what mkxydisk writes into the
     * label: 4 heads, 32 sectors, 32 cylinders plus 2 alternates.
     */
    build(0xB, 0, 0, 0);
    iopb_put(0x06, 3);          /* heads 0..3 */
    iopb_put(0x07, 31);         /* sectors 0..31 */
    iopb_put(0x08, 33);         /* cylinders 0..33 */
    iopb_put(0x09, 0);
    go();
    if (!wait_idle()) { puts_("FAIL: Set Drive Size hung\n"); fails++; }
    if (XYIO->xy_csr & XY_ERROR) {
        puts_("FAIL: Set Drive Size cc "); puthex(iopb_get(3), 2); putch('\n');
        fails++;
    }

    /*
     * One sector, then sixteen, then sixteen again four times over.
     *
     * That order is the experiment.  On hardware a 2 KB file survives and a
     * 106 KB one does not, and 106 KB is thirteen filesystem blocks -- so if
     * the fault needs *many* transfers rather than a big one, the single
     * sector passes and the run of sixteens fails.  If it needs a long single
     * transfer, the reverse.  Either way the console says which.
     */
    round(FIRST_BLK, 1);
    round(FIRST_BLK + 8, 16);

    blk = FIRST_BLK + 32;
    for (i = 0; i < 4; i++) {
        round(blk, 16);
        blk += 16;
    }

    puts_("wrprobe: ");
    if (fails == 0) puts_("PASS");
    else { puts_("FAIL, "); puthex((u32)fails, 2); puts_(" problems"); }
    puts_("\nwrprobe-finished\n");
    return 0;
}
