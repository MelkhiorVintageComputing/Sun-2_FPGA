/*
 * When a user-mode exception is taken, which stack does the frame go on?
 *
 * The 68010 has two stack pointers behind A7.  In user mode A7 is the USP; on
 * an exception the CPU switches to supervisor state and stacks the frame on
 * the SSP.  Nothing in a monitor boot ever depends on that, because the
 * monitor never leaves supervisor mode, and neither does any of this
 * project's other boot blocks -- so the first software to care is SunOS, at
 * the first user instruction it ever runs.
 *
 * It cares fatally.  Captured on the board with the ILA, SunOS 4.0.3 dies
 * like this creating process 1:
 *
 *   A=0x002020 FC=2 read   PROTERR   ps=0xd00   the first user instruction
 *   A=0xffffd6 FC=5 write  PROTERR   ps=0x800   the frame for that fault
 *   A=0x000000 FC=6 read                        the watchdog, resetting
 *
 * The first fault is by design: sys/sun2/vax.s leaves a process with no
 * context running in KCONTEXT so that its first access faults and the handler
 * can allocate one.  The second is not.  0xffffd6 is 0x3a below USRSTACK,
 * which is a 68010 format-8 bus error frame pushed at the *user* stack
 * pointer -- while the kernel's own supervisor stack, in use a few cycles
 * earlier, was down at 0x3a66.  Two faults with no cycle between them is a
 * double bus fault, the CPU halts, and the watchdog resets the machine.
 *
 * That is a claim about the core rather than about the Sun-2, so it is asked
 * here directly, of both cores, with no MMU and no kernel involved: set the
 * two stack pointers to values that cannot be confused, drop to user mode,
 * take a trap, and look at where the frame landed and which pointer moved.
 *
 * A trap rather than a bus error deliberately.  Exception entry chooses the
 * stack the same way whatever the exception, and a trap needs nothing of the
 * memory system, so a failure here cannot be blamed on the map.
 *
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed,
 * VBR = 0.  TRAP #0 is vector 32, at 0x80.
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
 * Two stacks, far apart and both in installed memory, so which one moved is
 * unmistakable.  The supervisor stack stays where the monitor left it; the
 * user stack is put somewhere the supervisor one can never reach.
 */
#define USP_BASE  0x00030000UL

/*
 * Comparing the two stack pointers is not enough, and finding that out cost a
 * run: a core can write *below* the user stack pointer without moving it, and
 * then USP still reads back exactly where it was put while the word has
 * already landed on the user's stack.  The first version of this probe
 * declared such a core correct.
 *
 * So the words under both stack pointers are painted first and read back
 * afterwards.  A frame word that lands there changes the paint, whatever the
 * pointer says.
 */
#define PAINT  0xA5A5A5A5UL
static volatile u32 * const under_usp = (volatile u32 *)(USP_BASE - 4);

static volatile u32 * const vec_trap0  = (volatile u32 *)0x80;
static volatile u32 * const vec_buserr = (volatile u32 *)0x8;

/* Valid, every permission denied -- what the kernel leaves for an unmapped
 * user page, and what a user access to it must fault on. */
#define PME_DENY   0x80000000UL

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

/* The page the user-mode access will fault on.  Well clear of the two stacks
 * and of anything the monitor uses. */
#define FAULT_VA  0x00100000UL

/* What the handler saw, filled in before it returns to supervisor code. */
static volatile u32 ssp_at_trap;
static volatile u32 usp_at_trap;
static volatile u32 frame_pc;
static volatile u16 frame_sr;
static volatile u16 frame_fmt;
static volatile int took_trap;

static u32 ssp_before, usp_before;

/*
 * The handler runs in supervisor mode with A7 = SSP.  It records both stack
 * pointers and the frame, then leaves through the saved supervisor context
 * rather than an RTE, because an RTE would go back to user mode and there is
 * nothing there to return to.
 */
extern void trap0_handler(void);
__asm__(
    "       .globl trap0_handler          \n"
    "trap0_handler:                       \n"
    "       movel  %sp,ssp_at_trap        \n"   /* where the frame went */
    "       movel  %usp,%a0               \n"
    "       movel  %a0,usp_at_trap        \n"   /* ... and whether USP moved */
    "       movew  %sp@(0),%d0            \n"
    "       movew  %d0,frame_sr           \n"
    "       movel  %sp@(2),%d0            \n"
    "       movel  %d0,frame_pc           \n"
    "       movew  %sp@(6),%d0            \n"
    "       movew  %d0,frame_fmt          \n"
    "       movel  #1,took_trap           \n"
    "       movel  saved_sp,%sp           \n"   /* back to where main was */
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                         \n");

static volatile u32 saved_sp, saved_pc;

/* Case B: the same question asked of a bus error rather than a trap.
 *
 * The two are not the same path.  A trap is taken at an instruction boundary
 * and stacks four words; a bus error is taken in the middle of one and stacks
 * a format 8 frame of twenty-nine, with everything the CPU needs to rerun the
 * cycle.  A core can get the stack right for one and wrong for the other, so
 * asking only about the trap answers only about the trap -- and it is the bus
 * error that SunOS dies on. */
static volatile u32 ssp_at_berr, usp_at_berr;
static volatile u16 berr_fmt;
static volatile int took_berr;

extern void berr_handler(void);
__asm__(
    "       .globl berr_handler           \n"
    "berr_handler:                        \n"
    "       movel  %sp,ssp_at_berr        \n"
    "       movel  %usp,%a0               \n"
    "       movel  %a0,usp_at_berr        \n"
    "       movew  %sp@(6),%d0            \n"
    "       movew  %d0,berr_fmt           \n"
    "       movel  #1,took_berr           \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                         \n");

extern void go_user_berr(void);
__asm__(
    "       .globl go_user_berr           \n"
    "go_user_berr:                        \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #back_here_b,saved_pc  \n"
    "       movel  #0x00030000,%a0        \n"
    "       movel  %a0,%usp               \n"
    "       clrw   %sp@-                  \n"
    "       pea    user_fault             \n"
    "       movew  #0x0000,%sp@-          \n"
    "       rte                           \n"
    "user_fault:                          \n"
    "       movel  #0x00100000,%a0        \n"
    "       movel  #0x12345678,%a0@       \n"   /* denied: must bus error */
    "1:     bra    1b                     \n"
    "back_here_b:                         \n"
    "       rts                           \n"
    "       .text                         \n");

/*
 * Drop to user mode and trap straight back.  The RTE needs a frame the CPU
 * will accept: SR with S clear, the PC to resume at, and -- this is a 68010,
 * not a 68000 -- a format/vector word, which for a normal four-word frame is
 * zero.
 */
extern void go_user(void);
__asm__(
    "       .globl go_user                \n"
    "go_user:                             \n"
    "       movel  %sp,saved_sp           \n"   /* so the handler can come back */
    "       movel  #back_here,saved_pc    \n"
    "       movel  #0x00030000,%a0        \n"
    "       movel  %a0,%usp               \n"   /* the user stack, far away */
    "       clrw   %sp@-                  \n"   /* format 0, vector unused */
    "       pea    user_code              \n"
    "       movew  #0x0000,%sp@-          \n"   /* SR: user mode, all masked in */
    "       rte                           \n"
    "user_code:                           \n"
    "       trap   #0                     \n"
    "       bra    user_code              \n"   /* never reached if the trap works */
    "back_here:                           \n"
    "       rts                           \n"
    "       .text                         \n");

int main(void)
{
    puts_("\r\nusrprobe: which stack does a user-mode exception frame go on?\r\n\r\n");

    __asm__ volatile ("movel %%sp,%0" : "=m"(ssp_before));
    usp_before = USP_BASE;

    *vec_trap0 = (u32)trap0_handler;

    go_user();

    if (!took_trap) {
        puts_("  the trap never arrived -- nothing to say about the stacks\r\n");
        return 0;
    }

    puts_("  supervisor stack  before ");   puthex(ssp_before, 8);
    puts_("   at the trap ");               puthex(ssp_at_trap, 8);
    puts_("\r\n  user stack        before ");  puthex(usp_before, 8);
    puts_("   at the trap ");               puthex(usp_at_trap, 8);
    puts_("\r\n  frame  sr ");              puthex(frame_sr, 4);
    puts_("  pc ");                         puthex(frame_pc, 6);
    puts_("  format ");                     puthex(frame_fmt, 4);
    puts_("\r\n\r\n");

    /*
     * A correct 68010 stacks on the supervisor stack and leaves the user one
     * exactly where it was.  The frame is eight bytes: SR, PC, format word.
     */
    {
        int ssp_moved = (ssp_at_trap != ssp_before);
        int usp_moved = (usp_at_trap != usp_before);

        if (ssp_moved && !usp_moved) {
            puts_("  the frame went on the SUPERVISOR stack, and the user stack\r\n");
            puts_("  did not move.  That is what a 68010 does.\r\n");
            puts_("  ssp fell by ");
            puthex(ssp_before - ssp_at_trap, 2);
            puts_(" bytes\r\n");
        } else if (usp_moved && !ssp_moved) {
            puts_("  the frame went on the USER stack: usp fell by ");
            puthex(usp_before - usp_at_trap, 2);
            puts_(" bytes\r\n");
            puts_("  and the supervisor stack did not move.  That is the bug\r\n");
            puts_("  the ILA caught killing SunOS at its first user instruction:\r\n");
            puts_("  the frame lands on whatever the user stack points at, and\r\n");
            puts_("  a fault there is a double fault.\r\n");
        } else {
            puts_("  neither, or both, moved -- read the numbers above\r\n");
        }
    }

    /*
     * Case B.  Both stacks stay mapped and writable throughout, so wherever
     * the frame goes it lands somewhere real and this program survives to say
     * so -- which is the whole difference between a probe and the machine it
     * is standing in for, where the frame went somewhere unmapped and the
     * second fault killed it.
     */
    puts_("\r\n  B  a bus error rather than a trap, from user mode\r\n");

    *vec_buserr = (u32)berr_handler;
    *under_usp  = PAINT;
    setpgmap(FAULT_VA, PME_DENY);
    puts_("     entry at ");  puthex(FAULT_VA, 6);
    puts_(" is ");            puthex(getpgmap(FAULT_VA), 8);
    puts_("\r\n");

    go_user_berr();

    if (!took_berr) {
        puts_("     no bus error arrived -- the access was allowed\r\n");
    } else {
        puts_("     supervisor stack  before ");  puthex(ssp_before, 8);
        puts_("   at the fault ");                puthex(ssp_at_berr, 8);
        puts_("\r\n     user stack        before ");  puthex(USP_BASE, 8);
        puts_("   at the fault ");                puthex(usp_at_berr, 8);
        puts_("\r\n     frame format ");         puthex(berr_fmt, 4);
        puts_("  (8xxx is the long bus error frame)\r\n");
        puts_("     the word under the user stack was ");
        puthex(PAINT, 8);
        puts_(", now ");
        puthex(*under_usp, 8);
        puts_("\r\n");

        if (*under_usp != PAINT) {
            puts_("     PART OF THE FRAME WENT ON THE USER STACK.  The pointer\r\n");
            puts_("     did not move, so only the paint shows it.  On a machine\r\n");
            puts_("     where that page is not writable -- a fresh process, its\r\n");
            puts_("     stack not yet grown -- the write faults inside exception\r\n");
            puts_("     processing, which is a double fault and a dead CPU.\r\n");
            puts_("     That is how SunOS dies here at its first user instruction.\r\n");
        } else if (usp_at_berr != USP_BASE && ssp_at_berr == ssp_before) {
            puts_("     the frame went on the USER stack.  That is the bug the\r\n");
            puts_("     ILA caught: SunOS dies at its first user instruction\r\n");
            puts_("     because the frame lands wherever the user stack points\r\n");
            puts_("     and a fault there is a double fault.\r\n");
        } else if (ssp_at_berr != ssp_before && usp_at_berr == USP_BASE) {
            puts_("     the frame went on the SUPERVISOR stack, which is right,\r\n");
            puts_("     so the board's 0xffffd6 push has another explanation.\r\n");
        } else {
            puts_("     neither, or both, moved -- read the numbers above\r\n");
        }
    }

    puts_("\r\nusrprobe-finished");
    return 0;
}
