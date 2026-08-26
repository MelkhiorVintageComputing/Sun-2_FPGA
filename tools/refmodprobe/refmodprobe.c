/*
 * Does the MMU maintain the page map's accessed and modified bits?
 *
 * Architecture Manual 5.6.3, "Statistics Bits: Accessed and Modified":
 *
 *     The accessed and modified bits are set, as the name implies, whenever a
 *     page is accessed or modified (written into).  The statistics bits will
 *     not be updated when the page is invalid or when the protection code does
 *     not allow the attempted operation.  In addition, these bits will not be
 *     updated in a cycle that aborts due to a parity error in the previous
 *     cycle.  However, the statistics bits will be updated on all other cycles,
 *     including cycles that terminate due to timeout or cycles that cause
 *     parity errors.
 *
 * They are entry bits 21 and 20 (Manual 5.1.4: valid 31, protection 30..25,
 * type 24..22, accessed 21, modified 20, page number 19..0).  sys/sun2/map.s
 * calls them MMU_R 0x00200000 and MMU_M 0x00100000.
 *
 * ---------------------------------------------------------------------------
 * Why it matters, and why nothing here noticed for the life of the project
 * ---------------------------------------------------------------------------
 * Software never sets them; it only ever reads and clears them.  unloadpgmap
 * (map.s:69-77) reads the entry, shifts MMU_R/MMU_M down into the software pte,
 * clears them, and writes the entry back.  loadpgmap (map.s:146-150) preserves
 * them across a pmeg reload.  SunOS 4.0.3's hat_ptesync does exactly the same
 * -- entry bit 21 into p_ref, entry bit 20 into p_mod, then clear both.  So if
 * the hardware never sets them, p_mod is permanently zero, seg_vn.c's
 *
 *     if (pp->p_mod && pp->p_vnode) VOP_PUTPAGE(...)
 *
 * never fires, and every dirty page is discarded instead of written.  On the
 * board that presents as total silence rather than corruption: a file written
 * to the NFS root has the right size in its locally cached attributes, reads
 * back empty, and the server sees no WRITE request at all.
 *
 * The boot PROM cannot show any of this.  It reads and writes the maps through
 * FC 3, which is untranslated, and its own diag.s map tests run in boot state
 * where supervisor program fetches come from the PROM untranslated as well --
 * so a monitor boot never performs a translated access whose entry it later
 * compares.  SunOS is the first software to depend on the bits at all.
 *
 * ---------------------------------------------------------------------------
 * What is measured
 * ---------------------------------------------------------------------------
 * Four steps, because "the bits get set" and "the bits get set only when they
 * should" are different claims:
 *
 *   1  clear both bits through FC 3 and read the entry back -- if this does not
 *      hold, nothing below measures what it claims to
 *   2  a granted user read     -> accessed set, modified NOT set
 *   3  a granted user write    -> both set
 *   4  an access the MMU denies -> neither changed
 *
 * Step 4 is the one that catches an over-eager implementation, and it is not a
 * formality: Manual 5.6.3 says the fields of a denied entry are not used, and
 * s2map.h:99-102 spells out the consequence -- "nor will the page number or
 * type fields be used; so they can be used by software".  SunOS does exactly
 * that, keeping its own data in the fields of an entry it has invalidated.  It
 * uses PERM_NONE rather than an invalid entry so that it is the protection
 * clause being tested and not the validity one.
 *
 * This exists as its own boot block rather than another tools/ctxprobe case
 * because ctxprobe is 7549 bytes of the 7680 a boot block gets.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed,
 * VBR = 0, so the bus error vector is at 0x8.  Control space is FC 3, and the
 * map and register file sit in the low bytes of every page there: page map
 * entry at +0 (a long, covering both halves), segment map +5, the context pair
 * at +6 (supervisor) and +7 (user), bus error register at +0xC.
 *
 * Both contexts are left exactly as the monitor set them, and the scratch
 * page's entry is saved and restored, so this probe changes nothing lasting.
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
/* Control space                                                            */
/* ------------------------------------------------------------------------ */
#define BUSERROFF      0x0C

/*
 * The permission field, entry bits 31..25: valid, SUP_READ, SUP_WRITE,
 * SUP_EXECUTE, USR_READ, USR_WRITE, USR_EXECUTE.
 */
#define PERM_ALL       0xFE000000UL     /* valid, every permission           */
#define PERM_NONE      0x80000000UL     /* valid, none -- denied, not invalid */
#define PERM_MASK      0xFE000000UL

/* The statistics bits themselves. */
#define REFMOD_ACC     0x00200000UL     /* entry bit 21, MMU_R */
#define REFMOD_MOD     0x00100000UL     /* entry bit 20, MMU_M */
#define REFMOD         (REFMOD_ACC | REFMOD_MOD)

/*
 * A page the monitor has already backed with real memory, whose existing entry
 * is read back so this probe never has to know the physical layout.  The same
 * page tools/ctxprobe uses for its scratch.
 */
#define SCRATCH_VA     0x00100800UL

static void setpgmap(u32 va, u32 pme)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%dfc\n\t"
        "movesl %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" (va & ~0x7FFUL), "d" (pme) : "d0", "d1", "memory");
}

static u32 getpgmap(u32 va)
{
    u32 v;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesl %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (v) : "a" (va & ~0x7FFUL) : "d0", "d1");
    return v;
}

static u16 getbuserr(void)
{
    u16 v;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesw %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (v) : "a" ((u32)BUSERROFF) : "d0", "d1");
    return v;
}

/* ------------------------------------------------------------------------ */
/* Faulting and recovering                                                  */
/* ------------------------------------------------------------------------ */
static volatile u32 saved_sp, saved_pc;
static volatile int took_berr;
static volatile u16 be_reg;

#define vec_buserr ((volatile u32 *)0x08)

/*
 * Recover with a saved PC as well as a saved SP.  The accessors below are
 * small and get inlined, so there is no return address at that stack pointer
 * and an `rts' would pop whatever happened to be there -- the mistake
 * tools/beprobe records having made.
 */
extern void berr_handler(void);
__asm__(
    "       .globl berr_handler           \n"
    "berr_handler:                        \n"
    "       movel  #1,took_berr           \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                         \n");

/*
 * A user-mode data read and a user-mode data write, through `moves' with the
 * source/destination function code set to 1.  These are the accesses the
 * permission check treats as user data, and they are plain indirect with no
 * auto-modify so nothing about instruction restart can confuse the result.
 * Each returns -1 if it faulted.
 */
extern u32 usr_load(u32 addr);
__asm__(
    "       .globl usr_load               \n"
    "usr_load:                            \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       movel  %sp@(4),%a0            \n"
    "       moveq  #1,%d0                 \n"
    "       movec  %d0,%sfc               \n"
    "       movesl %a0@,%d0               \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

extern u32 usr_store(u32 addr, u32 val);
__asm__(
    "       .globl usr_store              \n"
    "usr_store:                           \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       movel  %sp@(4),%a0            \n"
    "       movel  %sp@(8),%d1            \n"
    "       moveq  #1,%d0                 \n"
    "       movec  %d0,%dfc               \n"
    "       movesl %d1,%a0@               \n"
    "       moveq  #0,%d0                 \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

/*
 * Re-arm the bus error register before every case.  mon/h/buserr.h: the
 * register keeps only the FIRST of several errors.  The RTL clears the latch on
 * a read as well as a write, but nothing in a boot ever reads it -- so by the
 * time a probe runs the latch still holds the first bus error of the boot, a
 * PROM device probe, 0x84.  A case that reads it without clearing first reports
 * 0x84 whatever it actually did.
 */
static void arm(void)
{
    (void)getbuserr();
    took_berr = 0;
    be_reg = 0;
}

/*
 * Level 7 is the Am9513 NMI and cannot be masked, but its handler is the
 * monitor's own debounce and touches nothing here.
 */
static void mask_interrupts(void)
{
    __asm__ volatile ("movew #0x2700,%%sr" : : : "memory");
}

int main(void)
{
    u32 pme, all, e_clr, e_rd, e_wr, e_den;
    int rd_faulted, wr_faulted, den_faulted;

    mask_interrupts();
    *vec_buserr = (u32)berr_handler;

    puts_("\r\nrefmodprobe: does the MMU maintain the page map's accessed\r\n");
    puts_("             and modified bits?\r\n\r\n");

    pme = getpgmap(SCRATCH_VA);
    puts_("  scratch page ");  puthex(SCRATCH_VA, 6);
    puts_("  entry ");         puthex(pme, 8);
    puts_("\r\n");

    if (!(pme & 0x80000000UL)) {
        puts_("  that page is not valid -- nothing to measure\r\n");
        goto done;
    }

    all = (pme & ~PERM_MASK) | PERM_ALL;

    /* 1 -- clear both bits and confirm the clear landed */
    setpgmap(SCRATCH_VA, all & ~REFMOD);
    e_clr = getpgmap(SCRATCH_VA);

    /* 2 -- a granted user read: accessed only */
    arm();
    (void)usr_load(SCRATCH_VA + 0x40);
    rd_faulted = took_berr;
    be_reg = getbuserr();
    e_rd = getpgmap(SCRATCH_VA);

    /* 3 -- a granted user write: both */
    setpgmap(SCRATCH_VA, all & ~REFMOD);
    arm();
    (void)usr_store(SCRATCH_VA + 0x40, 0x600DF00DUL);
    wr_faulted = took_berr;
    e_wr = getpgmap(SCRATCH_VA);

    /* 4 -- an access the MMU denies: neither */
    setpgmap(SCRATCH_VA, ((pme & ~PERM_MASK) | PERM_NONE) & ~REFMOD);
    arm();
    (void)usr_load(SCRATCH_VA + 0x40);
    den_faulted = took_berr;
    e_den = getpgmap(SCRATCH_VA);

    setpgmap(SCRATCH_VA, pme);

    puts_("\r\n  cleared       ");  puthex(e_clr, 8);
    puts_("\r\n  granted read  ");  puthex(e_rd, 8);
    if (rd_faulted) puts_("  FAULTED");
    puts_("\r\n  granted write ");  puthex(e_wr, 8);
    if (wr_faulted) puts_("  FAULTED");
    puts_("\r\n  denied access ");  puthex(e_den, 8);
    puts_(den_faulted ? "  faulted" : "  NO FAULT");
    puts_("\r\n\r\n");

    if ((e_clr & REFMOD) != 0)
        puts_("  the bits did not clear -- a write to the entry through FC 3\r\n"
              "  is not landing, so nothing above measures what it claims to\r\n");
    else if (rd_faulted || wr_faulted)
        puts_("  a granted access faulted: the permissions are wrong, so the\r\n"
              "  bits were never going to be set\r\n");
    else if (!den_faulted)
        puts_("  the DENIED access did not fault, so step 4 proves nothing\r\n"
              "  about a denied entry\r\n");
    else if ((e_rd & REFMOD) == 0 && (e_wr & REFMOD) == 0)
        puts_("  NEITHER BIT IS MAINTAINED.  The MMU never sets accessed or\r\n"
              "  modified, so no page is ever dirty, seg_vn.c never calls\r\n"
              "  VOP_PUTPAGE, and nothing the machine writes is ever flushed.\r\n");
    else if ((e_rd & REFMOD) == REFMOD_ACC &&
             (e_wr & REFMOD) == REFMOD &&
             (e_den & REFMOD) == 0)
        puts_("  correct -- a read sets accessed, a write sets both, and a\r\n"
              "  denied access changes neither\r\n");
    else {
        if ((e_rd & REFMOD_ACC) == 0)
            puts_("  a granted read did not set accessed\r\n");
        if ((e_rd & REFMOD_MOD) != 0)
            puts_("  a READ set the modified bit\r\n");
        if ((e_wr & REFMOD) != REFMOD)
            puts_("  a granted write did not set both bits\r\n");
        if ((e_den & REFMOD) != 0)
            puts_("  A DENIED ACCESS UPDATED THE ENTRY.  Manual 5.6.3 forbids\r\n"
                  "  it, and SunOS keeps its own data in the fields of an entry\r\n"
                  "  it has invalidated.\r\n");
    }

done:
    puts_("\r\nrefmodprobe-finished\r\n");
    return 0;
}
