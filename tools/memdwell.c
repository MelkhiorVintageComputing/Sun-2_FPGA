/*
 * memdwell -- does data rot while it sits in DDR3?
 *
 * ---------------------------------------------------------------------------
 * Why
 * ---------------------------------------------------------------------------
 * Everything in the transfer path measures clean.  One bridge load per master
 * cycle, the right 32-bit lane of the 128-bit line, the right 16-bit half of
 * that word, one response per request, none unbidden, and the same address read
 * twice answers the same way both times -- all zero, on runs that demonstrably
 * corrupted.  And the corruption is in *both* directions: a file byte-perfect
 * on the card read into the buffer cache wrong (50905 -> 55306), and a buffer
 * correct in memory written to the card wrong (34435 -> 49861).
 *
 * Correct when written, wrong when read back later, both ways, with every
 * handshake in between provably right, is not a transfer fault.  It is what
 * data decaying *in place* looks like.  The one variable no test in this
 * project has ever moved is **time**: test/deca_ddr3 writes and reads straight
 * back, tb_deca_wb_ddr3 does the same, and every disk test measures traffic.
 *
 * So: fill memory, do nothing to it for a while, read it back, and see whether
 * the error count tracks the dwell rather than the number of accesses.
 *
 * ---------------------------------------------------------------------------
 * The pattern
 * ---------------------------------------------------------------------------
 *      bit 15      always 1 -- "this is pattern data"
 *      bits 14:0   the halfword's own index, modulo 32768
 *
 * A 64 KiB window in which position and value determine each other, so a bad
 * halfword decodes to where it came from, and a clear tag bit says it is not
 * ours at all.  Displacements beyond 64 KiB are ambiguous by multiples of that,
 * which is the same limitation tools/patwr has and for the same reason: the
 * corruption granule is sixteen bits, so a self-describing word has only
 * sixteen bits to describe itself with.
 *
 * ---------------------------------------------------------------------------
 * Two things that would make this measure the wrong thing
 * ---------------------------------------------------------------------------
 * **Paging.**  If the buffer is swapped out and back in during the dwell, this
 * measures the disk path again -- exactly what it is meant to exclude.  Run it
 * in single user with nothing else alive, and keep the buffer well inside
 * memory: this machine has 7 MiB with about 5.75 available, so 2 MiB is safe
 * and 4 is not.  The summary prints the size so a run can be judged later.
 *
 * **The verify is itself traffic.**  A pass that finds errors after a long
 * dwell has also just done a lot of reading, so a single long run proves
 * nothing.  The comparison that matters is between dwells over the *same*
 * amount of data: pass 1 verifies immediately, and later passes wait first.  If
 * the count rises with the wait and not with the reading, it is retention.
 *
 * Compile on the machine:  cc -O -o memdwell memdwell.c
 * Run:                     ./memdwell 2 600 4
 *                          (MiB, seconds to wait, passes)
 * The first pass always uses a zero dwell, as the control.
 */

#include <stdio.h>

char *malloc();

static unsigned short *buf;
static long nhw;                        /* halfwords in the buffer */

unsigned short
pat(i)
long i;
{
    return (unsigned short)(0x8000 | (i & 0x7fff));
}

/* Fill.  Written forwards, once, with nothing read back: the point is to leave
 * memory alone afterwards. */
void
fill()
{
    long i;
    for (i = 0; i < nhw; i++) buf[i] = pat(i);
}

long
verify(dwell)
long dwell;
{
    long i, bad = 0, shown = 0;
    unsigned short want, got;
    long gi, d;

    for (i = 0; i < nhw; i++) {
        want = pat(i);
        got  = buf[i];
        if (got == want) continue;
        bad++;
        if (shown < 8) {
            shown++;
            printf("  BAD +%08lx  want %04x  got %04x  ",
                   i * 2, want, got);
            if ((got & 0x8000) == 0) {
                printf("not pattern data\n");
            } else {
                gi = got & 0x7fff;
                d  = ((gi - (i & 0x7fff)) & 0x7fff);
                if (d > 16384) d -= 32768;
                printf("= index %ld, %+ld halfwords (%+ld bytes)\n",
                       gi, d, d * 2);
            }
        }
    }
    printf("dwell %4ld s: %ld of %ld halfwords wrong\n", dwell, bad, nhw);
    fflush(stdout);
    return bad;
}

int
main(argc, argv)
int argc;
char **argv;
{
    long mib, dwell, i;
    int  passes;
    long total = 0;

    if (argc != 4) {
        fprintf(stderr, "usage: %s <MiB> <dwell-seconds> <passes>\n", argv[0]);
        return 1;
    }
    mib    = atol(argv[1]);
    dwell  = atol(argv[2]);
    passes = atoi(argv[3]);

    nhw = mib * 1024L * 1024L / 2L;
    buf = (unsigned short *)malloc((unsigned)(nhw * 2L));
    if (buf == 0) {
        fprintf(stderr, "cannot allocate %ld MiB\n", mib);
        return 1;
    }

    printf("memdwell: %ld MiB (%ld halfwords), dwell %ld s, %d passes\n",
           mib, nhw, dwell, passes);
    printf("          pass 1 is the control and never waits\n");

    for (i = 0; i < passes; i++) {
        long this_dwell = (i == 0) ? 0L : dwell;
        fill();
        if (this_dwell) sleep((unsigned)this_dwell);
        total += verify(this_dwell);
    }

    printf("memdwell: %ld wrong in total\n", total);
    return total != 0;
}
