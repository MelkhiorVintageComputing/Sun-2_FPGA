/*
 * Does a protection violation report itself as one?
 *
 * SunOS 4.0.3 panics on this machine while creating process 1.  The kernel
 * touches the last byte of pid 1's user stack on purpose -- `subyte' at
 * USRSTACK-1 = 0xffffff -- expecting the page-not-present fault that grows it.
 * The machine reported that fault as a bus *timeout* rather than a protection
 * violation, and BE_TIMEOUT is precisely the bit sys/sun2/trap.c reads as "the
 * MMU was satisfied, the memory system failed": it forecloses both pagefault()
 * and grow() and goes straight to the panic.  Expected 88<VALID,PROTERR>;
 * reported 84<VALID,TIMEOUT>.
 *
 * Reaching that through SunOS costs a netboot and most of a day.  This does
 * the same thing from a boot block in about 1.6 s, the way beprobe does for
 * the bus error frame -- and unlike the kernel it can say what the machine
 * *should* have reported, because it sets the page map entry itself.
 *
 * The case under test is the one SunOS relies on and the boot PROM never
 * produces.  sys/sun2/mmu.h's SEGINV pmeg is valid with every permission
 * denied, which is the entry the kernel leaves behind for unmapped user pages:
 *
 *      bit 31        valid            1
 *      bits 30..25   SUP_R/W/X, USR_R/W/X   all 0
 *      bits 17..16   type             0, on-board memory
 *      bits 11..0    physical page    0
 *
 * so the entry is 0x80000000.  A user data write to it selects USR_WRITE on
 * the gen_proterr 74F151 -- {P_FC[2], P_FC[1], ~P_RW_n} = 0,0,1 = D1 -- which
 * is 0, and a selected bit of 0 raises PROTERR.  The bus error register should
 * read 0x88.
 *
 * If it reads 0x84 the kernel's panic is reproduced with no kernel involved.
 * If it reads 0x88 the mechanism works here and the fault SunOS saw comes from
 * something this boot block does not reproduce -- which is worth knowing too,
 * and would point at what the kernel's access has that this one does not: a
 * MOVES that changes function code mid-instruction, after a run of supervisor
 * accesses to an entirely different segment.
 *
 * There is a standing question in sun2_fpga.v about this, on the ~P_AS_n term
 * added to PROTERR to kill 23,607 phantom protection violations: "STILL
 * UNPROVEN: the PROM generates *zero* legitimate protection faults, so a
 * monitor boot cannot show whether this preserves real ones or disables the
 * mechanism."  Case A below is the first legitimate protection fault this
 * machine has ever been asked to produce.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed, VBR =
 * 0, so the bus error vector is at 0x8.  Control space is FC 3, and the map
 * and register file sit in the low bytes of every page there: page map entry
 * at +0 (a long, covering both halves), segment map +4, context +6, bus error
 * register +0xC.
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
#define BUSERROFF  0x0C
/* Odd, and not as a quirk: the 68010 is big-endian, so a byte at an even
 * address is the high half of the word and a byte at an odd address the low
 * half.  smap_sram takes ia_in(P_DIN[7:0]), the low half, so its byte can only
 * be at an odd offset.  Same reason LEDOFF is 0xB, and the same fact the
 * context pair uses on purpose -- supervisor in the even byte at 6, user in
 * the odd byte at 7, which is why ctx_reg.v has to honour UDS and LDS
 * separately. */
#define SMAPOFF    0x05

/* sys/sun2/mmu.h: NPMEG = NPME/NPAGSEG = 256, SEGINV = NPMEG-1.  The kernel
 * points every unmapped segment at it, and it is what the failing access went
 * through -- the dump printed `pmgrp ff'. */
#define SEGINV     0xFF

/* A page nothing else uses.  beprobe borrows the address the kernel's own
 * probe faulted on; this one only needs somewhere the monitor is not living,
 * and 0x701000 is that for the same reason. */
#define PROBE_VA   0x701000UL

/* Valid, every permission denied, type 0, physical page 0 -- SEGINV. */
#define PME_DENY   0x80000000UL
/* Valid, every permission granted, type 0, physical page 0 -- the control. */
#define PME_ALLOW  0xFE000000UL

/* The byte the kernel actually faulted on: USRSTACK-1, sys/sun2/vmparam.h.
 * Same shape of entry as PROBE_VA but at the very top of the space -- segment
 * index 0x1ff, page index 0xf -- which is the last difference between this
 * probe and the access that panicked.  Its existing mapping is saved and put
 * back, because the monitor may be living up there and the console is the only
 * way this program has to report anything. */
#define KERN_VA    0xFFFFFFUL

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

static void setsegmap(u32 va, u8 ia)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%dfc\n\t"
        "movesb %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" ((va & ~0x7FFUL) + SMAPOFF), "d" (ia) : "d0", "d1", "memory");
}

static u8 getsegmap(u32 va)
{
    u8 out;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesb %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (out) : "a" ((va & ~0x7FFUL) + SMAPOFF) : "d0", "d1");
    return out;
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

/* Read to inspect, write to clear -- mon/h/buserr.h, and the register really
 * is write-to-clear here: leaving it out of the DTACK list once turned every
 * unprotected bus error into a halt. */
static u16 get_berr(void)
{
    u16 out;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesw %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (out) : "a" (BUSERROFF) : "d0", "d1");
    return out;
}

static void clear_berr(void)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%dfc\n\t"
        "movesw %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" (BUSERROFF), "d" (0) : "d0", "d1", "memory");
}

/* ------------------------------------------------------------------------ */
/* The bus error handler                                                    */
/* ------------------------------------------------------------------------ */
/*
 * beprobe's, and for its reasons: copy the frame so the special status word
 * can be printed, then recover through a saved PC as well as a saved SP,
 * because the faulting helper is static and gets inlined, so there is no
 * return address at that stack pointer.  Recovery is deliberately not an RTE:
 * an RTE on a format 8 frame re-runs the faulted cycle, which would fault for
 * ever against a page whose entry still denies it.
 */
static volatile u32 * const vec_buserr = (volatile u32 *)0x8;
static volatile u32 * const vec_adrerr = (volatile u32 *)0xC;

volatile u16 frame[32];
volatile u32 nfault;
volatile u32 rec_sp;
volatile u32 rec_pc;

__asm__(
    "       .globl be_handler            \n"
    "be_handler:                         \n"
    "       moveml %d0-%d1/%a0-%a1,%sp@- \n"
    "       lea    %sp@(16),%a0          \n"
    "       lea    frame,%a1             \n"
    "       moveq  #31,%d0               \n"
    "1:     movew  %a0@+,%a1@+           \n"
    "       dbra   %d0,1b                \n"
    "       addql  #1,nfault             \n"
    "       movel  rec_sp,%sp            \n"
    "       moveq  #1,%d0                \n"
    "       movel  rec_pc,%a0            \n"
    "       jmp    %a0@                  \n");

extern void be_handler(void);

/* ------------------------------------------------------------------------ */
/* The three accesses                                                       */
/* ------------------------------------------------------------------------ */
/*
 * A: a *user data* write, through MOVES with DFC = FC_UD.  This is the
 *    kernel's access -- subyte does exactly this -- and the only instruction
 *    that changes function code mid-instruction.
 */
static int probe_user_write(u32 va)
{
    register int r asm("d0");
    __asm__ volatile (
        "movel %%sp,rec_sp\n\t"
        "lea    %%pc@(1f),%%a1\n\t"
        "movel  %%a1,rec_pc\n\t"
        "movec  %%dfc,%%d1\n\t"
        "moveq  #1,%%d0\n\t"            /* FC_UD, user data */
        "movec  %%d0,%%dfc\n\t"
        "moveq  #0,%%d0\n\t"
        "movesb %%d0,%1@\n\t"           /* the access under test */
        "1:\n\t"
        "movec  %%d1,%%dfc"
        : "=d" (r) : "a" (va) : "a1", "d1", "memory");
    return r;
}

/* B: an ordinary supervisor data write to the same entry.  Selects SUP_WRITE
 *    rather than USR_WRITE, and does not involve MOVES at all -- so if A and B
 *    disagree, the function code is implicated rather than the lookup. */
static int probe_super_write(u32 va)
{
    register int r asm("d0");
    __asm__ volatile (
        "movel %%sp,rec_sp\n\t"
        "lea    %%pc@(1f),%%a1\n\t"
        "movel  %%a1,rec_pc\n\t"
        "moveq  #0,%%d0\n\t"
        "moveb  %%d0,%1@\n\t"
        "1:\n\t"
        : "=d" (r) : "a" (va) : "a1", "memory");
    return r;
}

/* C: the control.  Same page, permissions granted, a supervisor read -- which
 *    must complete.  If this faults, the entry is not being used at all and
 *    nothing else here means anything. */
static int probe_super_read(u32 va)
{
    register int r asm("d0");
    __asm__ volatile (
        "movel %%sp,rec_sp\n\t"
        "lea    %%pc@(1f),%%a1\n\t"
        "movel  %%a1,rec_pc\n\t"
        "moveq  #0,%%d0\n\t"
        "moveb  %1@,%%d1\n\t"
        "1:\n\t"
        : "=d" (r) : "a" (va) : "a1", "d1", "memory");
    return r;
}

/*
 * E: the same access, but with a read from a different segment immediately
 *    before it and nothing in between.  The kernel's faulting MOVES arrives
 *    straight off a run of supervisor accesses in another segment, so the
 *    segment index, the page index and the function code all change in one
 *    cycle -- and both map lookups are clocked and in series, so a shortfall
 *    there is invisible whenever an access repeats the previous segment.
 */
static int probe_user_write_after_far(u32 va, u32 far)
{
    register int r asm("d0");
    __asm__ volatile (
        "movel %%sp,rec_sp\n\t"
        "lea    %%pc@(1f),%%a1\n\t"
        "movel  %%a1,rec_pc\n\t"
        "movec  %%dfc,%%d1\n\t"
        "moveq  #1,%%d0\n\t"
        "movec  %%d0,%%dfc\n\t"
        "moveb  %2@,%%d0\n\t"          /* a different segment, supervisor data */
        "moveq  #0,%%d0\n\t"
        "movesb %%d0,%1@\n\t"          /* ... and straight into the access */
        "1:\n\t"
        "movec  %%d1,%%dfc"
        : "=d" (r) : "a" (va), "a" (far) : "a1", "d1", "memory");
    return r;
}

static void report_at(const char *what, int rc, u32 before, u32 va)
{
    u16 be  = get_berr();
    u16 ssw = frame[4];

    puts_("  ");
    puts_(what);
    puts_("\r\n    va ");      puthex(va, 6);
    puts_("  seg ");           puthex(getsegmap(va), 2);
    puts_("  entry ");         puthex(before, 8);
    puts_(" -> ");             puthex(getpgmap(va), 8);
    puts_("\r\n    fault ");   putch(rc ? 'y' : 'n');
    puts_("  bus error reg "); puthex(be, 2);
    puts_(" <");
    if (be & 0x80) puts_("VALID,");
    if (be & 0x08) puts_("PROTERR,");
    if (be & 0x04) puts_("TIMEOUT,");
    puts_(">\r\n");
    if (rc) {
        puts_("    ssw ");     puthex(ssw, 4);
        puts_("  if=");        putch('0' + ((ssw >> 13) & 1));
        puts_(" df=");         putch('0' + ((ssw >> 12) & 1));
        puts_(" by=");         putch('0' + ((ssw >>  9) & 1));
        puts_(" rw=");         putch('0' + ((ssw >>  8) & 1));
        puts_(" fc=");         putch('0' + (ssw & 7));
        puts_("\r\n");
    }
}

int main(void)
{
    int rc;

    puts_("\r\nmmuprobe: is a protection violation reported as one?\r\n");

    *vec_buserr = (u32)be_handler;
    *vec_adrerr = (u32)be_handler;

    /* A -- the kernel's case: valid, no permissions, user data write. */
    setpgmap(PROBE_VA, PME_DENY);
    clear_berr();
    nfault = 0;
    rc = probe_user_write(PROBE_VA);
    report_at("A  user data write, entry valid with no permissions", rc, PME_DENY, PROBE_VA);
    puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");

    /* B -- the same entry, supervisor data write, no MOVES. */
    setpgmap(PROBE_VA, PME_DENY);
    clear_berr();
    nfault = 0;
    rc = probe_super_write(PROBE_VA);
    report_at("B  supervisor data write, same entry", rc, PME_DENY, PROBE_VA);
    puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");

    /* C -- the control: permissions granted, must complete. */
    setpgmap(PROBE_VA, PME_ALLOW);
    clear_berr();
    nfault = 0;
    rc = probe_super_read(PROBE_VA);
    report_at("C  supervisor data read, permissions granted", rc, PME_ALLOW, PROBE_VA);
    puts_("     expected: fault n\r\n");

    /* D -- the kernel's topology: through SEGINV, into reserved PMEG 255.
     * Setting the segment map first means the page map write below lands in
     * that PMEG rather than in the segment's ordinary one. */
    setsegmap(PROBE_VA, SEGINV);
    setpgmap(PROBE_VA, PME_DENY);
    clear_berr();
    nfault = 0;
    rc = probe_user_write(PROBE_VA);
    report_at("D  user data write through SEGINV (pmgrp ff)", rc, PME_DENY, PROBE_VA);
    puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");

    /* E -- and arriving from a different segment, as the kernel's does. */
    setsegmap(PROBE_VA, SEGINV);
    setpgmap(PROBE_VA, PME_DENY);
    clear_berr();
    nfault = 0;
    rc = probe_user_write_after_far(PROBE_VA, 0x400UL);
    report_at("E  the same, straight off a read in another segment", rc, PME_DENY, PROBE_VA);
    puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");

    /* F -- the kernel's own address.  Save what is there and put it back:
     * the monitor may have something mapped at the top of the space, and the
     * console is the only way this program can report anything. */
    {
        u8  seg_was = getsegmap(KERN_VA);
        u32 pme_was = getpgmap(KERN_VA);

        setsegmap(KERN_VA, SEGINV);
        setpgmap(KERN_VA, PME_DENY);
        clear_berr();
        nfault = 0;
        rc = probe_user_write(KERN_VA);
        report_at("F  user data write at USRSTACK-1, the kernel's address",
                  rc, PME_DENY, KERN_VA);
        puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");
        setsegmap(KERN_VA, seg_was);
        setpgmap(KERN_VA, pme_was);

        setsegmap(KERN_VA, SEGINV);
        setpgmap(KERN_VA, PME_DENY);
        clear_berr();
        nfault = 0;
        rc = probe_user_write_after_far(KERN_VA, 0x400UL);
        report_at("G  the same, straight off a read in another segment",
                  rc, PME_DENY, KERN_VA);
        puts_("     expected: fault y, 88 <VALID,PROTERR>\r\n");
        setsegmap(KERN_VA, seg_was);
        setpgmap(KERN_VA, pme_was);
    }

    puts_("mmuprobe-finished\r\n");
    return 0;
}
