/*
 * What the machine puts in a 68010 bus error frame, measured on the machine.
 *
 * SunOS 4.0.3 dies in startup() the first time it probes DVMA bus space.
 * sys/sun2/machdep.c:287-294 maps a scratch page with PGT_DVMABUS -- page map
 * TYPE 2 -- and pokes it, expecting the bus timeout to be caught:
 *
 *      disable_dvma();
 *      for (dvmapage = 0; dvmapage < btoc(dvmasize); dvmapage++) {
 *              mapin(CMAP1, btop(CADDR1), (u_int)(dvmapage | PGT_DVMABUS),
 *                    1, PG_V | PG_KW);
 *              if (poke((short *)CADDR1, TESTVAL) == 0)
 *                      break;
 *      }
 *
 * poke() (sys/sun/probe.c:107) is setjmp/longjmp around the store, and
 * sys/sun2/trap.c:155 honours it unconditionally for T_BUSERR.  It does not
 * work here: the first poke faults and the kernel panics instead of looping.
 *
 * Reproducing that through SunOS costs eight seconds of simulated time -- most
 * of a day of wall clock -- because the kernel has to be read off the disk
 * first.  This does the same thing in about 1.6 s, from a boot block, and
 * measures the one thing the kernel cannot show us: the exact contents of the
 * exception frame the CPU pushes.
 *
 * The suspicion it exists to test: the kernel's panic dump decoded the frame
 * as `ifetch 1 dfetch 0 rw 1 fcode 6' -- a supervisor *program read* -- for a
 * cycle the machine logged as `FC=5 write', a supervisor data write.  The bus
 * error register agreed with the machine (84<VALID,TIMEOUT>); only the CPU's
 * special status word disagreed.  If that is real, recovery through an RTE on
 * a format 8 frame cannot work, because the frame misdescribes the cycle to
 * re-run.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor and entered in supervisor mode with the
 * Sun-1 map installed, VBR = 0 (sys/mon/s2addrs.h), so the bus error vector is
 * at 0x8.  Page map entries are reached with `moves' against FC_MAP (3) at the
 * virtual address itself, which is how the PROM's own getpgmap/setpgmap work
 * (msun/mon/kernel/s2map.s).
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
/* The page under test                                                      */
/* ------------------------------------------------------------------------ */
/*
 * 0x701000 is the address the kernel's probe faulted on, and 0xF0800000 is the
 * page map entry it had just written -- both taken from the panic dump, so
 * this is the kernel's own case rather than a reconstruction of it.
 *
 * Decoded against `struct pgmapent' (sys/mon/s2map.h): valid, supervisor
 * read/write/execute, no user access, TYPE 2 (the system bus), physical page 0.
 * Nothing answers on the MultiBus here, so any access to it must time out.
 */
#define PROBE_VA   0x701000UL
#define PROBE_PME  0xF0800000UL

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

/* ------------------------------------------------------------------------ */
/* The bus error handler                                                    */
/* ------------------------------------------------------------------------ */
/*
 * Two jobs.  First, copy the frame the CPU pushed so it can be printed: the
 * 68010 long bus error frame is 29 words, of which the first six are SR, PC
 * (two words), the format/vector word, the special status word and the fault
 * address (two words).  Second, recover the way poke() does -- discard the
 * frame and jump back with a flag set, which is all longjmp() amounts to here.
 *
 * Recovery is deliberately *not* an RTE.  An RTE on a format 8 frame re-runs
 * the faulted bus cycle out of the frame's own saved state, so it would fault
 * again forever against an address that never answers.  poke() does not RTE
 * either; this mirrors it.
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
    "       lea    %sp@(16),%a0          \n"   /* a0 -> the exception frame */
    "       lea    frame,%a1             \n"
    "       moveq  #31,%d0               \n"
    "1:     movew  %a0@+,%a1@+           \n"
    "       dbra   %d0,1b                \n"
    "       addql  #1,nfault             \n"
    "       movel  rec_sp,%sp            \n"   /* discard frame, as longjmp does */
    "       moveq  #1,%d0                \n"
    "       movel  rec_pc,%a0            \n"
    "       jmp    %a0@                  \n"); /* to the label after the store */

extern void be_handler(void);

/*
 * The equivalent of poke(): arrange recovery, do the store, report whether it
 * completed.
 *
 * The recovery target is an explicit label, not a return address.  The first
 * version saved only the stack pointer and had the handler `rts', on the
 * assumption this function would have a frame to return through -- but it is
 * static and called once, so gcc inlines it, there is no return address at
 * that stack pointer, and the `rts' popped a string constant and jumped into
 * it.  That produced an address error inside .rodata which looked convincingly
 * like a machine fault and was nothing of the sort.  Saving the PC as well as
 * the SP makes recovery independent of how the function was compiled.
 */
static int probe_write(u32 va, u16 val)
{
    register int r asm("d0");
    __asm__ volatile (
        "movel %%sp,rec_sp\n\t"
        "lea    %%pc@(1f),%%a1\n\t"
        "movel  %%a1,rec_pc\n\t"
        "moveq  #0,%%d0\n\t"
        "movew  %2,%1@\n\t"          /* the store under test */
        "1:\n\t"
        : "=d" (r) : "a" (va), "d" (val) : "a1", "memory");
    return r;
}

int main(void)
{
    u32 before, after;
    int rc;

    puts_("\r\nbeprobe: 68010 bus error frame, measured\r\n");

    /* Through a variable: gcc treats a literal store to 0x8 as a null deref
     * and warns, which xychain.c hit too.  The vector really is at 8 -- VBR
     * is zero and the monitor's map leaves low memory straight through. */
    *vec_buserr = (u32)be_handler;      /* vector 2, bus error */
    *vec_adrerr = (u32)be_handler;      /* vector 3, address error -- see below */

    setpgmap(PROBE_VA, PROBE_PME);
    before = getpgmap(PROBE_VA);
    puts_("  page map entry written ");
    puthex(PROBE_PME, 8);
    puts_(" read back ");
    puthex(before, 8);
    puts_("\r\n");

    puts_("  storing to ");
    puthex(PROBE_VA, 6);
    puts_(" (TYPE 2, nothing on the bus)\r\n");

    rc = probe_write(PROBE_VA, 0x5555);

    puts_("  store returned ");
    puthex((u32)rc, 1);
    puts_(rc ? " (faulted, recovered)\r\n" : " (completed, no fault)\r\n");
    puts_("  faults taken ");
    puthex(nfault, 2);
    puts_("\r\n");

    if (nfault) {
        u32 pc  = ((u32)frame[1] << 16) | frame[2];
        u16 fv  = frame[3];
        u16 ssw = frame[4];
        u32 fa  = ((u32)frame[5] << 16) | frame[6];

        /* Which vector the CPU actually raised.  Both are caught, because
         * that is the question: a bus timeout must be vector 2.  If the
         * machine raises vector 3 instead, SunOS could never recover -- its
         * trap dispatch only consults `nofault' under case T_BUSERR, so an
         * address error goes straight to the panic path however the probe was
         * armed. */
        puts_("  vector offset ");  puthex(fv & 0xFFF, 3);
        puts_((fv & 0xFFF) == 0x008 ? " = 2, bus error\r\n" :
              (fv & 0xFFF) == 0x00C ? " = 3, ADDRESS error\r\n" : " = ?\r\n");

        puts_("  frame: sr=");      puthex(frame[0], 4);
        puts_(" pc=");              puthex(pc, 8);
        puts_(" fmt/vec=");         puthex(fv, 4);
        puts_("\r\n         ssw=");  puthex(ssw, 4);
        puts_(" fault addr=");      puthex(fa, 8);
        puts_("\r\n");

        /*
         * The MC68010 special status word, UM 6.3.9.  RR is rerun, IF an
         * instruction fetch, DF a data fetch, RM a read-modify-write, HB the
         * high byte, BY a byte transfer, RW read (1) or write (0), and the low
         * three bits the function code of the faulted cycle.
         *
         * What this run has to answer: the machine drove a supervisor *data
         * write*, so DF should be 1, RW 0 and FC 5.  The kernel's panic dump
         * reported IF=1, RW=1 and FC=6 instead.
         */
        puts_("         decoded: rr=");  putch('0' + ((ssw >> 15) & 1));
        puts_(" if=");                   putch('0' + ((ssw >> 13) & 1));
        puts_(" df=");                   putch('0' + ((ssw >> 12) & 1));
        puts_(" rm=");                   putch('0' + ((ssw >> 11) & 1));
        puts_(" hb=");                   putch('0' + ((ssw >> 10) & 1));
        puts_(" by=");                   putch('0' + ((ssw >>  9) & 1));
        puts_(" rw=");                   putch('0' + ((ssw >>  8) & 1));
        puts_(" fc=");                   putch('0' + (ssw & 7));
        puts_("\r\n");

        puts_("         expected for this store: if=0 df=1 rw=0 fc=5\r\n");

        if (((ssw >> 13) & 1) || !((ssw >> 12) & 1) ||
            ((ssw >> 8) & 1)  || (ssw & 7) != 5)
            puts_("  MISMATCH: the frame does not describe the cycle\r\n");
        else
            puts_("  frame agrees with the cycle\r\n");
    }

    after = getpgmap(PROBE_VA);
    puts_("  page map entry now ");
    puthex(after, 8);
    puts_("\r\n");

    puts_("beprobe-finished\r\n");
    return 0;
}
