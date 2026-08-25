/*
 * The fault every forked child takes, and the context that is supposed to
 * isolate it.
 *
 * SunOS 4.0.3 boots on this machine, reaches its scheduler, runs /sbin/init --
 * and then every child init forks dies and dumps core.  The NFS server sees
 * `LOOKUP rc.boot' then `CREATE /core', over and over, while init itself goes
 * on writing /etc/utmp quite happily.  So init is not what is broken; the
 * processes it forks are.
 *
 * That is a very specific place to break, because a freshly forked child takes
 * a bus error *by design* on its first user instruction, and it is the first
 * software this machine has ever run that does:
 *
 *   - sys/sun2/vax.s:347 resumes a process whose p_ctx is 0 with the user
 *     context register still holding KCONTEXT, so its first instruction fetch
 *     translates through context 0 -- the kernel's own map, whose pages
 *     startup() deliberately made kernel-only.  The fetch must fault.
 *   - sys/sun2/vm_machdep.c:548 recognises that fault by getusercontext() ==
 *     KCONTEXT, calls usetup() -> ctxalloc(), which does setusercontext(N) and
 *     then invalidates every segment in the new context, and returns "fixed".
 *   - the 68010 reruns the instruction, now in context N, where the segment is
 *     SEGINV -- so it faults again, and this time the handler maps the page.
 *
 * Three things there have never been exercised by anything else.  The boot
 * PROM never leaves supervisor mode, never runs a user instruction, and always
 * writes the two context registers to the same value, so a monitor boot cannot
 * show any of it.
 *
 *   A  a protection violation on a user *instruction fetch* -- FC 2.
 *      tools/mmuprobe asked this of a supervisor data write and tools/usrprobe
 *      of a user data write; the fetch is the one the child actually takes.
 *   B  the two context registers holding different values, which is what
 *      ctxalloc() leaves behind.  Does supervisor code go on translating
 *      through its own context while user code translates through another?
 *   C  the recovery: fix the map inside the handler, RTE, and see whether the
 *      faulted instruction reruns and completes.
 *
 * What each answer means.  sys/sun2/trap.c reads the bus error register once,
 * at entry, and:
 *
 *      if (be & (BE_TIMEOUT|BE_VMEBUSERR))
 *              goto pferr;             -> SIGSEGV, pagefault() never called
 *      if (pagefault(beip->bei_accaddr)) return (0);
 *
 * so a spurious TIMEOUT bit on any of these faults turns a routine page-in
 * into SIGSEGV and a core dump -- exactly the observed symptom, and exactly
 * the shape of the bug that killed pid 1 before it (a stale 0x84 held in the
 * latch from a PROM device probe).  SunOS never tests PROTERR or VALID at all;
 * it only needs TIMEOUT and VMEBUSERR to be clear.  So:
 *
 *      0x88  VALID|PROTERR   a protection violation on a mapped page   -- right
 *      0x08  PROTERR         an invalid page or segment                -- right
 *      0x84  VALID|TIMEOUT   what the kernel reads as "do not recover" -- wrong
 *
 * Case C will differ between the two cores and that difference is the point,
 * not a failure: Suska's instruction restart is known wrong here -- the special
 * status word it pushes does not describe the faulted cycle (see
 * patches/Suska_Configware/0002 and tools/beprobe) -- so a rerun that works on
 * RD68011 and not on Suska says something about the core, not about the Sun-2.
 *
 * Reaching any of this through SunOS costs a netboot and most of a day.  This
 * costs a couple of seconds, the way beprobe and mmuprobe do.
 *
 * ---------------------------------------------------------------------------
 * Where this runs
 * ---------------------------------------------------------------------------
 * Loaded to 0x4000 by the monitor, supervisor mode, Sun-1 map installed,
 * VBR = 0, so the bus error vector is at 0x8.  Control space is FC 3, and the
 * map and register file sit in the low bytes of every page there: page map
 * entry at +0 (a long, covering both halves), segment map +5, the context pair
 * at +6 (supervisor) and +7 (user), bus error register at +0xC.
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
#define SMAPOFF        0x05
#define SUPCONTEXTOFF  0x06     /* even byte -- UDS */
#define USERCONTEXTOFF 0x07     /* odd byte  -- LDS */
#define BUSERROFF      0x0C

#define SEGINV         0xFF     /* sys/sun2/mmu.h: the permanently-invalid pmeg */

/*
 * The permission field, entry bits 31..25, in the order struct pgmapent gives
 * it: valid, SUP_READ, SUP_WRITE, SUP_EXECUTE, USR_READ, USR_WRITE, USR_EXECUTE.
 *
 * PG_KR -- what startup() marks kernel text, sys/sun2/pte.h:52 -- is
 * SUP_READ|SUP_EXECUTE, so 1101000 in those seven bits.  That is the entry the
 * child's first instruction fetch actually meets, and the ILA capture of the
 * pid-1 failure recorded exactly it: `ps=0xd00', and 0xd00 >> 5 is 1101000.
 */
#define PERM_KERNTEXT  0xD0000000UL     /* valid, sup r+x, no user access */
/* What the handler installs to recover: every permission, which is what a
 * real pagefault() ends up with once it has a page.  It has to cover the
 * marker write as well as the fetch, so that "the instruction reran" and "the
 * instruction completed" are both observable. */
#define PERM_USERTEXT  0xFE000000UL
/* Valid, everything permitted / valid, nothing permitted.  The second is the
 * SEGINV shape: a fault without an invalid page, so the handler can grant
 * access by rewriting one entry. */
#define PERM_ALL       0xFE000000UL
#define PERM_NONE      0x80000000UL
/*
 * The copy-on-write shapes: exactly ONE permission bit clear, everything else
 * set.  This is the case no existing test covers, and the gap matters.
 *
 * tools/mmuprobe denies every permission at once (0x80000000) and ctxprobe's
 * case A uses PG_KR, which grants the user nothing at all.  Both fault whichever
 * permission bit the hardware happens to check, so neither can tell a correctly
 * selected bit from a mis-selected one.  CLAUDE.md records a bug of exactly that
 * shape already -- "the permission bits were also one bit high".
 *
 * SunOS 4.x fork is copy-on-write and arms it by *removing write permission*:
 * seg_vn.c:703 `hat_chgprot(seg, seg->s_base, seg->s_size, ~PROT_WRITE)', and
 * anon_dup's comment says it assumes the caller has done so.  If USR_WRITE is
 * not the bit actually checked for a user data write, a read-only page stays
 * writable, no copy-on-write fault ever fires, and parent and child share one
 * writable stack -- which is what the ILA measured on the board.
 *
 * bits 31..25 = VALID SUP_R SUP_W SUP_X USR_R USR_W USR_X
 */
#define PERM_NO_USRW   0xDE000000UL   /* 1101111: supervisor write denied only */
#define PERM_NO_USRW   0xFA000000UL   /* 1111101: user write denied only       */
#define PERM_MASK      0xFE000000UL

/*
 * The page the user-mode instruction fetch lands on.  It has to be somewhere
 * the monitor is not living and somewhere already backed by real memory, so
 * its existing entry is read back and only the permission bits are changed --
 * which also means this probe never has to know the physical layout.
 */
#define USER_VA        0x00100000UL

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

static void setsegmap(u32 va, u8 ia)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%dfc\n\t"
        "movesb %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" ((va & ~0x7FFUL) | SMAPOFF), "d" (ia) : "d0", "d1", "memory");
}

static u8 getsegmap(u32 va)
{
    u8 v;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesb %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (v) : "a" ((va & ~0x7FFUL) | SMAPOFF) : "d0", "d1");
    return v;
}

/*
 * The two context registers.  Byte accesses, each to its own half of the one
 * word at offset 6 -- which is the whole reason ctx_reg.v has to honour UDS
 * and LDS separately, and the reason a monitor boot cannot tell whether it
 * does: the PROM writes both, always to the same value.
 */
static void setusercontext(u8 c)
{
    __asm__ volatile (
        "movec %%dfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%dfc\n\t"
        "movesb %1,%0@\n\t"
        "movec %%d1,%%dfc"
        : : "a" ((u32)USERCONTEXTOFF), "d" (c) : "d0", "d1", "memory");
}

static u8 getusercontext(void)
{
    u8 v;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesb %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (v) : "a" ((u32)USERCONTEXTOFF) : "d0", "d1");
    return v;
}

static u8 getsupcontext(void)
{
    u8 v;
    __asm__ volatile (
        "movec %%sfc,%%d1\n\t"
        "moveq #3,%%d0\n\t"
        "movec %%d0,%%sfc\n\t"
        "movesb %1@,%0\n\t"
        "movec %%d1,%%sfc"
        : "=d" (v) : "a" ((u32)SUPCONTEXTOFF) : "d0", "d1");
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
/* The fault handler                                                        */
/* ------------------------------------------------------------------------ */
static volatile u32 saved_sp, saved_pc;

static volatile int took_berr;
static volatile u16 be_reg;         /* the register, read once, as trap.c does */
static volatile u16 frame_fmt;
static volatile u16 frame_ssw;      /* format 8: the special status word */
static volatile u32 frame_addr;     /* ... and the access address */
static volatile u32 frame_pc;

/*
 * Records the fault and abandons the user program, the way usrprobe does:
 * back to a saved supervisor stack and PC rather than an RTE, because the
 * point of most of these cases is that there is nothing to return to.
 *
 * The bus error register is read here and only here, once, because a read
 * re-arms the latch -- so reading it twice would give the second read a
 * different answer and there would be no way to tell which was the fault's.
 */
extern void berr_handler(void);
__asm__(
    "       .globl berr_handler           \n"
    "berr_handler:                        \n"
    "       moveml %d0-%d1/%a0-%a1,%sp@-  \n"
    "       lea    %sp@(16),%a0           \n"
    "       movel  %a0,%sp@-              \n"
    "       jsr    berr_record            \n"
    "       addql  #4,%sp                 \n"
    "       moveml %sp@+,%d0-%d1/%a0-%a1  \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                        \n");

/* The format 8 frame the 68010 pushes for a bus error: SR, PC, format/vector,
 * special status word, fault address (68010 manual 6.4, mon/h/buserr.h).
 *
 * The stub passes its address rather than this computing it from %sp, which
 * was the first version and is wrong: gcc is free to emit a prologue that
 * moves %sp before any inline asm in the body, so the offset would be a
 * property of the optimiser rather than of the frame. */
void berr_record(u16 *fr)
{
    be_reg     = getbuserr();
    frame_pc   = *(u32 *)(fr + 1);
    frame_fmt  = fr[3];
    frame_ssw  = fr[4];
    frame_addr = *(u32 *)(fr + 5);
    took_berr  = 1;
}

/*
 * Case C wants the other kind of handler: fix the map and RTE, so the faulted
 * instruction reruns.  That is what pagefault() does, and whether it works is
 * a question about the core's instruction restart as much as about the MMU.
 */
static volatile u32 fixup_pme;
static volatile u32 fixup_va;
static volatile int took_fixup;
int fixup_record(u16 *fr);

extern void berr_fixup(void);
__asm__(
    "       .globl berr_fixup             \n"
    "berr_fixup:                          \n"
    "       moveml %d0-%d1/%a0-%a1,%sp@-  \n"
    "       lea    %sp@(16),%a0           \n"
    "       movel  %a0,%sp@-              \n"
    "       jsr    fixup_record           \n"
    "       addql  #4,%sp                 \n"
    "       tstl   %d0                    \n"
    "       bnes   1f                     \n"
    "       moveml %sp@+,%d0-%d1/%a0-%a1  \n"
    "       rte                           \n"
    "1:     movel  saved_sp,%sp           \n"   /* give up: the retry loops */
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                        \n");

/*
 * Returns non-zero to abandon rather than RTE.
 *
 * A restart that does not converge is a *hang*, not a wrong answer: the same
 * instruction faults, the handler grants access it already granted, the RTE
 * puts it back and it faults again.  The board did exactly that and printed
 * nothing at all, which is the least useful failure a probe can have.  So the
 * loop is capped, and exceeding the cap is itself the result.
 */
/*
 * One.  Fault once, fix the map, RTE; if it faults a second time the retry is
 * not converging and there is nothing more to learn by letting it run.
 *
 * The cap has to be this tight because each bus error pushes a 29-word
 * format-8 frame -- 58 bytes -- on the supervisor stack, and a boot block runs
 * on the monitor's stack.  A cap of 8 let over 500 bytes of frames pile up and
 * the board died with `Address Error, addr: 0010045F at EF443A': an odd
 * address, inside the PROM, i.e. the stack had been walked through whatever
 * lies below it before the abandon path could report anything.  Two frames
 * cannot do that.
 */
#define FIXUP_CAP 1

int fixup_record(u16 *fr)
{
    be_reg     = getbuserr();
    frame_addr = *(u32 *)(fr + 5);
    setpgmap(fixup_va, fixup_pme);
    took_fixup++;
    return (took_fixup > FIXUP_CAP);
}

/* ------------------------------------------------------------------------ */
/* The user program                                                         */
/* ------------------------------------------------------------------------ */
/*
 * What gets copied into USER_VA and jumped to in user mode.  It writes a
 * marker somewhere the supervisor can see and then traps back, so "the fetch
 * completed" and "the instruction ran" are separate observations: a rerun that
 * gets the fetch right and the operand wrong still shows up.
 *
 * Assembled here rather than written as bytes so that it stays readable, then
 * copied -- it is position independent because everything it touches is
 * absolute.
 */
/*
 * Case E's user program: an `rts' whose stack read faults.
 *
 * This is the exact thing a freshly forked child does and dies on.  Measured
 * on the board: init's child returns from libc's fork stub, its `rts' at
 * 0x7e7c reads the stack at 0xffffa0, and that segment is SEGINV in the
 * child's new context -- smap=ff, ps=800, PROTERR, which is correct and
 * expected, because a new context starts with every segment invalid and faults
 * them in.  What the child then does is return to 0xff26b4, a stack-shaped
 * address, and run away up its own stack executing garbage until something is
 * illegal.
 *
 * So the fault is right and the *restart* is the question.  Case C already
 * shows a `movel' restarting correctly; an `rts' is a different matter,
 * because the CPU has begun popping the stack when the fault arrives.  A core
 * that restarts one and not the other looks exactly like this.
 *
 * The frame goes on the supervisor stack (tools/usrprobe proved that), so
 * denying the *user* stack page is safe: the handler can run, fix the map and
 * RTE without faulting on its own frame.
 */
extern void user_rts(void);
extern void user_rts_end(void);
__asm__(
    "       .globl user_rts               \n"
    "user_rts:                            \n"
    "       rts                           \n"   /* the ONLY memory access   */
    "       .globl user_rts_end           \n"
    "user_rts_end:                        \n"
    "       .text                         \n");

/* The predecrement case: one `movel Dn,-(An)' onto the denied page. */
extern void user_push(void);
extern void user_push_end(void);
__asm__(
    "       .globl user_push              \n"
    "user_push:                           \n"
    "       movel  #0x00100810,%a0        \n"
    "       movel  #0x600DBEEF,%a0@-      \n"   /* <- faults, then restarts */
    "       trap   #0                     \n"
    "1:     bra    1b                     \n"
    "       .globl user_push_end          \n"
    "user_push_end:                        \n"
    "       .text                         \n");

/* Where a correct rts must land: a marker write, then trap back. */
extern void user_rts_target(void);
__asm__(
    "       .globl user_rts_target        \n"
    "user_rts_target:                     \n"
    "       movel  #0x600D5EED,0x00100040 \n"
    "       trap   #0                     \n"
    "1:     bra    1b                     \n"
    "       .text                         \n");

/*
 * The stack lives in the page ABOVE the code, and that is the whole point of
 * the case: deny the page the code is in and the *instruction fetch* faults,
 * the handler fixes it, and the rts then runs with everything mapped -- so
 * nothing is tested.  The fault has to land on the rts's stack read, which
 * means the stack must be somewhere the code is not.
 *
 * A first version had them in one page and also copied the return target to
 * USER_VA + 0x30 while the rts pushed 0x00100430, so the rts returned to an
 * address with no code at it and the board reported an F-line exception.  That
 * accidentally proved the rts returned exactly where it was told to, and
 * measured nothing else.
 */
#define STACK_VA   (USER_VA + 0x800)
#define RTS_MARKER (*(volatile u32 *)(USER_VA + 0x40))

extern void user_body(void);
extern void user_body_end(void);
__asm__(
    "       .globl user_body              \n"
    "user_body:                           \n"
    "       movel  #0x600DC0DE,0x00100400 \n"   /* the marker */
    "       trap   #0                     \n"
    "1:     bra    1b                     \n"
    "       .globl user_body_end          \n"
    "user_body_end:                       \n"
    "       .text                        \n");

/* Inside the USER_VA page, 0x400 clear of the code above it -- see the note
 * on user_body.  The user stack pointer go_user sets is never dereferenced
 * (nothing in user_body touches the stack, and trap #0 stacks on the SSP), so
 * it does not need a mapping in context 1 either. */
#define MARKER  (*(volatile u32 *)(USER_VA + 0x400))

static volatile int took_trap0;
extern void trap0_handler(void);
__asm__(
    "       .globl trap0_handler          \n"
    "trap0_handler:                       \n"
    "       movel  #1,took_trap0          \n"
    "       movel  saved_sp,%sp           \n"
    "       movel  saved_pc,%a0           \n"
    "       jmp    %a0@                   \n"
    "       .text                        \n");

/* Drop to user mode at USER_VA.  The RTE frame is the 68010's four-word one:
 * SR with S clear, the PC, and a format/vector word of zero. */
static volatile u32 user_sp_val;

/* Enter user mode at `pc' with USP set to user_sp_val, so the only user memory
 * access the program makes is the one under test.  go_user_at leaves USP at a
 * fixed scratch address instead, which is fine when the program sets its own. */
extern void go_user_sp(u32 pc);
__asm__(
    "       .globl go_user_sp             \n"
    "go_user_sp:                          \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #back_here3,saved_pc   \n"
    "       movel  %sp@(4),%d0            \n"
    "       movel  user_sp_val,%a0        \n"
    "       movel  %a0,%usp               \n"
    "       clrw   %sp@-                  \n"
    "       movel  %d0,%sp@-              \n"
    "       movew  #0x0000,%sp@-          \n"
    "       rte                           \n"
    "back_here3:                          \n"
    "       rts                           \n"
    "       .text                        \n");

extern void go_user_at(u32 pc);
__asm__(
    "       .globl go_user_at             \n"
    "go_user_at:                          \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #back_here2,saved_pc   \n"
    "       movel  %sp@(4),%d0            \n"
    "       movel  #0x00030000,%a0        \n"
    "       movel  %a0,%usp               \n"
    "       clrw   %sp@-                  \n"
    "       movel  %d0,%sp@-              \n"
    "       movew  #0x0000,%sp@-          \n"
    "       rte                           \n"
    "back_here2:                          \n"
    "       rts                           \n"
    "       .text                         \n");

extern void go_user(void);
__asm__(
    "       .globl go_user                \n"
    "go_user:                             \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #back_here,saved_pc    \n"
    "       movel  #0x00030000,%a0        \n"
    "       movel  %a0,%usp               \n"
    "       clrw   %sp@-                  \n"
    "       movel  #0x00100000,%sp@-      \n"
    "       movew  #0x0000,%sp@-          \n"
    "       rte                           \n"
    "back_here:                           \n"
    "       rts                           \n"
    "       .text                        \n");

/*
 * The two instructions under test, in supervisor mode.
 *
 * Each saves the stack pointer and an abandon label first, so that a retry
 * which never converges lands back here through berr_fixup's cap instead of
 * looping for ever.  In supervisor mode that is simple and safe: no mode
 * switch, and the exception frame goes on this very stack, which stays mapped.
 *
 * Written out rather than left to the compiler because the addressing mode is
 * the whole point -- `%a0@-' and `%a0@+' must survive optimisation.
 */
/* The control: absolute addressing, no address register, in supervisor mode. */
/*
 * A *user data* access performed from supervisor mode, via `moves' with
 * SFC/DFC = FC_UD (1).  The MMU sees FC 1, so the USR_READ and USR_WRITE bits
 * are the ones checked -- which is what copy-on-write clears and what
 * copyin/copyout use.  Testing SUP_WRITE instead would exercise a different
 * input of the permission mux and would not answer the question.
 *
 * Plain indirect, no auto-modify, so case E's defect cannot confuse these.
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

extern u32 sup_abs(void);
__asm__(
    "       .globl sup_abs                \n"
    "sup_abs:                             \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       movel  #0x600DCAFE,0x00100820 \n"   /* <- faults, then restarts */
    "       moveq  #0,%d0                 \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

extern u32 sup_predec(u32 addr, u32 val);
__asm__(
    "       .globl sup_predec             \n"
    "sup_predec:                          \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       movel  %sp@(4),%a0            \n"
    "       movel  %sp@(8),%d1            \n"
    "       movel  %d1,%a0@-              \n"   /* <- faults, then restarts */
    "       movel  %a0,%d0                \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

extern u32 sup_postinc(u32 addr, u32 *out);
__asm__(
    "       .globl sup_postinc            \n"
    "sup_postinc:                         \n"
    "       movel  %sp,saved_sp           \n"
    "       movel  #1f,saved_pc           \n"
    "       movel  %sp@(4),%a0            \n"
    "       movel  %a0@+,%d1              \n"   /* <- faults, then restarts */
    "       movel  %sp@(8),%a1            \n"
    "       movel  %d1,%a1@               \n"
    "       movel  %a0,%d0                \n"
    "       rts                           \n"
    "1:     moveq  #-1,%d0                \n"
    "       rts                           \n"
    "       .text                         \n");

static volatile u32 * const vec_buserr = (volatile u32 *)0x8;
static volatile u32 * const vec_trap0  = (volatile u32 *)0x80;

static void arm(void)
{
    /*
     * Re-arm the bus error register, and this is not optional.
     *
     * mon/h/buserr.h: the register keeps only the FIRST of several errors.
     * The RTL clears the latch on a read as well as on a write, but nothing in
     * a boot ever reads it -- so by the time a probe runs, the latch is still
     * holding the first bus error of the boot, which is a PROM device probe:
     * a timeout on a valid page, 0x84.  A case that reads the register without
     * clearing it first therefore reports 0x84 whatever it actually did, and
     * reads exactly like the bug this file was written to look for.
     *
     * That cost a run here.  The discarded read below is what makes each case
     * report its own error instead of the PROM's.
     */
    (void)getbuserr();

    took_berr = took_trap0 = took_fixup = 0;
    be_reg = 0; frame_fmt = 0; frame_ssw = 0; frame_addr = 0; frame_pc = 0;
    MARKER = 0;
}

static void say_reg(void)
{
    u16 b = be_reg;
    puts_("     bus error register ");  puthex(b, 4);
    puts_("  <");
    if (b & 0x80) puts_("VALID ");
    if (b & 0x40) puts_("PARERR_U ");
    if (b & 0x20) puts_("PARERR_L ");
    if (b & 0x10) puts_("TIMEOUT_VME ");
    if (b & 0x08) puts_("PROTERR ");
    if (b & 0x04) puts_("TIMEOUT ");
    puts_(">\r\n");
    if (b & 0x04) {
        puts_("     TIMEOUT is set: sys/sun2/trap.c goes straight to SIGSEGV\r\n");
        puts_("     without ever calling pagefault().  This kills the child.\r\n");
    }
}

static void say_frame(void)
{
    puts_("     frame  format ");  puthex(frame_fmt, 4);
    puts_("  ssw ");               puthex(frame_ssw, 4);
    puts_("  addr ");              puthex(frame_addr, 6);
    puts_("  pc ");                puthex(frame_pc, 6);
    puts_("\r\n");
}

/*
 * Mask interrupts for the duration.
 *
 * This probe can be delivered two ways: in a disk boot block, or -- since the
 * board has no disk -- as the network bootloader itself, substituted for
 * `sunos-sun2.bb'.  The second leaves the PROM's Ethernet driver live
 * underneath it, and the probe then takes over the bus error vector and
 * rewrites page map entries while that driver is still being entered.
 *
 * On the board that showed up as `Address Error, addr: 0010045F at EF443A'.
 * EF4438 is `bset #5,%a0@(2112)' with `moveal %a5@(1114),%a0' in front of it
 * and `bclr #5' after -- Channel Attention to the 82586, i.e. the PROM's
 * Ethernet code, faulting on its own pointer.  Nothing to do with the
 * instruction under test, and it cost three board runs to see that.
 *
 * Level 7 is the Am9513 NMI and cannot be masked, but its handler is the
 * monitor's own debounce and touches nothing here.
 */
static void mask_interrupts(void)
{
    __asm__ volatile ("movew #0x2700,%%sr" : : : "memory");
}

int main(void)
{
    mask_interrupts();
    u32 base_pme, stack_pme;
    u32 a_after;
    int h_read_ok, h_write_faulted;
    u16 be_h;
    volatile u32 d_after;
    u8  base_seg;

    puts_("\r\nctxprobe: the fault a forked child takes, and the context that\r\n");
    puts_("          is supposed to isolate it\r\n\r\n");

    *vec_buserr = (u32)berr_handler;
    *vec_trap0  = (u32)trap0_handler;

    base_pme = getpgmap(USER_VA);
    base_seg = getsegmap(USER_VA);

    puts_("  contexts at entry: supervisor ");  puthex(getsupcontext(), 2);
    puts_("  user ");                            puthex(getusercontext(), 2);
    puts_("\r\n  page ");                        puthex(USER_VA, 6);
    puts_(" entry ");                            puthex(base_pme, 8);
    puts_("  segment ");                         puthex(base_seg, 2);
    puts_("\r\n");

    /* Copy the user program into the page it will be fetched from. */
    {
        u8 *s = (u8 *)user_body, *e = (u8 *)user_body_end, *d = (u8 *)USER_VA;
        while (s < e) *d++ = *s++;
    }

    /* --------------------------------------------------------------- */
    puts_("\r\n  A  user instruction fetch of a page marked kernel-only\r\n");
    puts_("     (PG_KR: valid, sup read+execute, no user access -- what\r\n");
    puts_("      startup() leaves on kernel text, and what the child's\r\n");
    puts_("      first fetch meets in context 0)\r\n");

    arm();
    setpgmap(USER_VA, (base_pme & ~PERM_MASK) | PERM_KERNTEXT);
    go_user();
    setpgmap(USER_VA, base_pme);

    if (!took_berr) {
        puts_("     NO FAULT.  A user fetch of a page with USR_EXECUTE clear\r\n");
        puts_("     was allowed: the protection check is not working, and a\r\n");
        puts_("     child would run kernel text instead of faulting.\r\n");
    } else {
        say_reg();
        say_frame();
        if ((be_reg & 0x8C) == 0x88)
            puts_("     0x88 <VALID,PROTERR> -- correct.\r\n");
        else if (be_reg & 0x04)
            puts_("     WRONG: expected 88 <VALID,PROTERR>.\r\n");
    }

    /* --------------------------------------------------------------- */
    puts_("\r\n  B  the two context registers holding different values,\r\n");
    puts_("     which is what ctxalloc() leaves behind\r\n");

    arm();
    setusercontext(1);
    puts_("     after setusercontext(1): supervisor ");
    puthex(getsupcontext(), 2);
    puts_("  user ");
    puthex(getusercontext(), 2);
    puts_("\r\n");

    if (getsupcontext() != 0) {
        puts_("     THE SUPERVISOR CONTEXT MOVED TOO.  A byte write to the\r\n");
        puts_("     user half landed on both, and the kernel would lose\r\n");
        puts_("     itself the moment ctxalloc() ran.\r\n");
        setusercontext(0);
        goto done;
    }

    /* Supervisor code is still executing, and that is the observation: every
     * instruction of this program since setusercontext(1) has been fetched
     * through the supervisor context.  Say so explicitly, because "it did not
     * crash" is easy to read past. */
    puts_("     supervisor code is still running, so its own fetches still\r\n");
    puts_("     translate through context 0\r\n");

    /* Point this segment at SEGINV in context 1 only.  setsegmap writes
     * through the *user* context register, which is what ctxalloc relies on. */
    setsegmap(USER_VA, SEGINV);
    puts_("     segment in context 1 set to SEGINV; in context 0 it reads ");
    setusercontext(0);
    puthex(getsegmap(USER_VA), 2);
    puts_("\r\n");
    if (getsegmap(USER_VA) != base_seg) {
        puts_("     THE WRITE LANDED IN CONTEXT 0 as well -- FC 3 accesses are\r\n");
        puts_("     not being steered by the user context register.\r\n");
        setsegmap(USER_VA, base_seg);
        goto done;
    }
    setusercontext(1);

    go_user();

    if (!took_berr) {
        puts_("     NO FAULT: a user fetch through a SEGINV segment in\r\n");
        puts_("     context 1 succeeded.  The contexts are not isolated.\r\n");
    } else {
        say_reg();
        say_frame();
        if ((be_reg & 0x8C) == 0x08)
            puts_("     0x08 <PROTERR> with VALID clear -- correct for an\r\n"
                  "     invalid segment.\r\n");
        else if (be_reg & 0x04)
            puts_("     WRONG: expected 08 <PROTERR>.\r\n");
    }

    /* --------------------------------------------------------------- */
    puts_("\r\n  C  the recovery: fix the map in the handler and rerun\r\n");

    arm();
    setusercontext(1);
    setsegmap(USER_VA, base_seg);                 /* a real pmeg in context 1 */
    setpgmap(USER_VA, (base_pme & ~PERM_MASK) | PERM_KERNTEXT);
    fixup_va  = USER_VA;
    fixup_pme = (base_pme & ~PERM_MASK) | PERM_USERTEXT;
    *vec_buserr = (u32)berr_fixup;

    go_user();

    *vec_buserr = (u32)berr_handler;
    setpgmap(USER_VA, base_pme);
    setusercontext(0);

    puts_("     faults taken ");  puthex(took_fixup, 2);
    puts_("   marker ");          puthex(MARKER, 8);
    puts_("   trap back ");       puthex(took_trap0, 2);
    puts_("\r\n");
    if (took_fixup && MARKER == 0x600DC0DEUL && took_trap0) {
        puts_("     the instruction reran and completed: this is the whole\r\n");
        puts_("     of what pagefault() asks of the hardware.\r\n");
    } else if (took_fixup && !MARKER) {
        puts_("     the fault was taken and the map fixed, but the\r\n");
        puts_("     instruction never completed -- instruction restart.\r\n");
    } else if (!took_fixup) {
        puts_("     no fault at all.\r\n");
    }

    /* --------------------------------------------------------------- */
    /* --------------------------------------------------------------- */
    /*
     * E and F: does an operand fault in an auto-modifying addressing mode
     * restart correctly?
     *
     * Case C already answers this for `movel #imm,(abs)' -- no address
     * register involved -- and it passes on both the board and in simulation.
     * The instruction the forked child dies on is not that shape.  Measured
     * with the ILA: the child's `rts' reads its stack at 0xffffa0, the segment
     * is SEGINV in its fresh context (smap=ff, ps=800), the MMU raises a
     * correct protection violation with TIMEOUT clear -- and the child then
     * returns to 0xff26b4, a stack-shaped address, and runs up its own stack
     * executing rubbish until something is illegal.
     *
     * `rts' is `(A7)+'.  A faulted instruction using `(An)+' or `-(An)' has to
     * restore An before the retry, or the retry addresses somewhere else: it
     * either never converges, or completes at the wrong address.  Those are
     * exactly the two behaviours the board showed.
     *
     * This is asked in SUPERVISOR mode on purpose.  An earlier version went
     * through user mode, `go_user_at' and the USP, and what failed was that
     * machinery -- once with a hang and once by escaping into the PROM at
     * 0xEF456E -- so the measurement never got made.  Here the exception frame
     * lands on the ordinary, mapped supervisor stack, nothing switches mode,
     * and a divergent retry cannot go anywhere except round the capped loop.
     *
     * A7 itself cannot be the register under test in supervisor mode, because
     * the frame would be pushed on the page being denied.  Any other An
     * exercises the same mechanism.
     */
    /*
     * G, F, E -- in that order on purpose.
     *
     * E crashes the machine on the board (the RTE resumes at a stale PROM PC),
     * so anything after it never runs.  G is the control and F is the case
     * that matters, so both go first.
     *
     * What the three separate:
     *
     *   C  user mode,       movel #imm,(abs)   -- passes, board and simulation
     *   G  supervisor mode, movel #imm,(abs)   -- C's instruction, E's privilege
     *   F  supervisor mode, movel (An)+,Dn     -- rts's addressing mode
     *   E  supervisor mode, movel Dn,-(An)
     *
     * C and E differ in two things at once, privilege and addressing mode, so
     * neither can be blamed yet.  G holds the addressing mode fixed and changes
     * only the privilege: if G passes and F/E fail, the addressing mode is the
     * variable and rts (which is (A7)+) is implicated directly.  If G fails
     * too, privilege is the variable and the addressing mode is innocent.
     */
    stack_pme = getpgmap(STACK_VA);
    puts_("\r\n     scratch page ");  puthex(STACK_VA, 6);
    puts_(" entry ");                 puthex(stack_pme, 8);
    puts_("\r\n");
    if (!(stack_pme & 0x80000000UL)) {
        puts_("     that page is not valid -- skipping E/F/G\r\n");
        goto done;
    }

    /* --------------------------------------------------------------- */
    puts_("\r\n  G  movel #imm,(abs) in SUPERVISOR mode -- C's instruction,\r\n");
    puts_("     E's privilege.  The control that separates the two.\r\n");

    arm();
    fixup_va  = STACK_VA;
    fixup_pme = (stack_pme & ~PERM_MASK) | PERM_ALL;
    *vec_buserr = (u32)berr_fixup;
    setpgmap(STACK_VA, (stack_pme & ~PERM_MASK) | PERM_NONE);

    a_after = sup_abs();

    *vec_buserr = (u32)berr_handler;
    setpgmap(STACK_VA, stack_pme);

    puts_("     faults ");   puthex(took_fixup, 2);
    puts_("   returned ");   puthex(a_after, 8);
    puts_("   memory ");     puthex(*(volatile u32 *)(STACK_VA + 0x20), 8);
    puts_("  (want 600dcafe)\r\n");
    if (took_fixup > FIXUP_CAP)
        puts_("     G: the retry never converged\r\n");
    else if (*(volatile u32 *)(STACK_VA + 0x20) == 0x600DCAFEUL)
        puts_("     G: supervisor-mode restart of (abs) is CORRECT\r\n");
    else
        puts_("     G: supervisor-mode restart of (abs) is WRONG\r\n");

    /* --------------------------------------------------------------- */
    puts_("\r\n  F  movel (An)+,Dn whose read faults, then is restarted\r\n");
    puts_("     (the same addressing mode as rts, which is (A7)+)\r\n");

    arm();
    *(volatile u32 *)(STACK_VA + 0x10) = 0x5EED1234UL;
    fixup_va  = STACK_VA;
    fixup_pme = (stack_pme & ~PERM_MASK) | PERM_ALL;
    *vec_buserr = (u32)berr_fixup;
    setpgmap(STACK_VA, (stack_pme & ~PERM_MASK) | PERM_NONE);

    a_after = sup_postinc(STACK_VA + 0x10, (u32 *)&d_after);

    *vec_buserr = (u32)berr_handler;
    setpgmap(STACK_VA, stack_pme);

    puts_("     faults ");   puthex(took_fixup, 2);
    puts_("   An after ");   puthex(a_after, 8);
    puts_("  (want ");       puthex(STACK_VA + 0x14, 8);
    puts_(")\r\n     value read ");
    puthex(d_after, 8);      puts_("  (want 5eed1234)\r\n");
    if (took_fixup > FIXUP_CAP)
        puts_("     F: the retry NEVER CONVERGED -- (An)+ restart is wrong.\r\n"
              "     rts is (A7)+, so this is the forked child's failure.\r\n");
    else if (a_after == STACK_VA + 0x14 && d_after == 0x5EED1234UL)
        puts_("     F: (An)+ restarted correctly\r\n");
    else
        puts_("     F: (An)+ RESTARTED WRONGLY -- rts is (A7)+, so this is\r\n"
              "     the forked child's failure.\r\n");

    /* --------------------------------------------------------------- */
    /*
     * H: the copy-on-write shape, supervisor side.  One bit clear, not seven.
     * A read must succeed and a write must fault; if the write succeeds, the
     * hardware is not checking the bit the kernel clears.
     */
    puts_("\r\n  H  one permission bit clear (USR_WRITE), the rest set\r\n");
    puts_("     this is what hat_chgprot(~PROT_WRITE) leaves behind\r\n");

    arm();
    *(volatile u32 *)(STACK_VA + 0x30) = 0xC0FFEE00UL;
    *vec_buserr = (u32)berr_handler;
    setpgmap(STACK_VA, (stack_pme & ~PERM_MASK) | PERM_NO_USRW);

    a_after = usr_load(STACK_VA + 0x30);
    h_read_ok = !took_berr;
    arm();
    (void)usr_store(STACK_VA + 0x30, 0x12345678UL);
    h_write_faulted = took_berr;
    be_h = be_reg;

    setpgmap(STACK_VA, stack_pme);

    puts_("     entry ");  puthex((stack_pme & ~PERM_MASK) | PERM_NO_USRW, 8);
    puts_("   read ");     puts_(h_read_ok ? "ok" : "FAULTED");
    puts_("  value ");     puthex(a_after, 8);
    puts_("\r\n     write "); puts_(h_write_faulted ? "faulted" : "SUCCEEDED");
    puts_("  buserr ");    puthex(be_h, 4);
    puts_("   memory now ");
    puthex(*(volatile u32 *)(STACK_VA + 0x30), 8);
    puts_("\r\n");
    if (h_read_ok && h_write_faulted)
        puts_("     H: USR_WRITE is checked correctly -- read allowed, write denied\r\n");
    else if (h_read_ok && !h_write_faulted)
        puts_("     H: THE WRITE WAS ALLOWED.  A page with write permission\r\n"
              "     removed is still writable, so copy-on-write can never fire.\r\n");
    else
        puts_("     H: the READ faulted too -- the wrong bit is being checked\r\n");

    /* --------------------------------------------------------------- */
    puts_("\r\n  E  movel Dn,-(An) whose write faults, then is restarted\r\n");
    puts_("     (this one has crashed the board every time -- last)\r\n");

    arm();
    fixup_va  = STACK_VA;
    fixup_pme = (stack_pme & ~PERM_MASK) | PERM_ALL;
    *vec_buserr = (u32)berr_fixup;
    setpgmap(STACK_VA, (stack_pme & ~PERM_MASK) | PERM_NONE);

    a_after = sup_predec(STACK_VA + 0x10, 0x600DBEEFUL);

    *vec_buserr = (u32)berr_handler;
    setpgmap(STACK_VA, stack_pme);

    puts_("     faults ");        puthex(took_fixup, 2);
    puts_("   An after ");        puthex(a_after, 8);
    puts_("  (want ");            puthex(STACK_VA + 0x0C, 8);
    puts_(")\r\n     memory at An ");
    puthex(*(volatile u32 *)(STACK_VA + 0x0C), 8);
    puts_("  (want 600dbeef)\r\n");
    if (took_fixup > FIXUP_CAP)
        puts_("     E: the retry never converged -- -(An) restart is wrong\r\n");
    else if (a_after == STACK_VA + 0x0C &&
             *(volatile u32 *)(STACK_VA + 0x0C) == 0x600DBEEFUL)
        puts_("     E: -(An) restarted correctly\r\n");
    else
        puts_("     E: -(An) RESTARTED AT THE WRONG ADDRESS\r\n");

done:
    setusercontext(0);
    setsegmap(USER_VA, base_seg);
    setpgmap(USER_VA, base_pme);
    puts_("\r\n  contexts restored: supervisor ");  puthex(getsupcontext(), 2);
    puts_("  user ");                                puthex(getusercontext(), 2);
    puts_("\r\nctxprobe-finished\r\n");
    return 0;
}
