/*
 * memchk -- fill a buffer with a constant, read it back, check every word.
 *
 * The CPU is the heaviest memory client this machine has, so if the shared
 * path corrupts under load it should show here with no disk, no DMA and no
 * filesystem anywhere in the picture.  The two loops are in tools/memloop.s
 * and run in the 68010's loop mode, so the bus carries operand traffic and
 * nothing else -- see that file.
 *
 * 3 MiB on a 7 MiB machine, so it stays resident and nothing pages.
 *
 * **What a constant cannot see.**  A word fetched from elsewhere *in this same
 * buffer* holds the same constant and is invisible here.  What the disk tests
 * find is program text intruding, which a constant does catch, and running the
 * pattern several times with different constants catches a value that survives
 * from the previous pass.  A position-derived pattern would be strictly
 * stronger and is the obvious next step if this comes back clean.
 */

#include <stdio.h>

#define NLONG  (3 * 1024 * 1024 / 4)

/* sbrk rather than a 3 MiB bss: SunOS's ld segfaults linking a bss that size
 * on a 7 MiB machine, identically on retry, which is the discriminator this
 * project uses for "software, not the machine".  The heap costs nothing here
 * and keeps the a.out small enough to transfer over the console. */
long *buf;

main(argc, argv)
int argc;
char **argv;
{
    static long val[6] = {
        0x00000000L, 0xffffffffL, 0x5a5a5a5aL,
        0xa5a5a5a5L, 0x0000ffffL, 0xffff0000L
    };
    long *bad, *p, n, nbad, total;
    int  i, pass, npass;

    buf = (long *)sbrk(NLONG * 4);
    if (buf == (long *)-1) { printf("memchk: sbrk failed\n"); return 2; }

    npass = (argc > 1) ? atoi(argv[1]) : 1;
    printf("memchk: %d longs (%d KiB), %d pass(es)\n",
           NLONG, NLONG / 256, npass);

    total = 0;
    for (pass = 0; pass < npass; pass++) {
        for (i = 0; i < 6; i++) {
            mfill(buf, (long)NLONG, val[i]);

            /* Walk the whole buffer, restarting past each bad word so one
             * failure does not hide the rest. */
            nbad = 0;
            p = buf;
            n = NLONG;
            while (n > 0) {
                bad = (long *)mcheck(p, n, val[i]);
                if (bad == (long *)0)
                    break;
                if (nbad < 8)
                    printf("BAD  pass %d val %08lx  at %06lx  got %08lx\n",
                           pass, val[i], (long)(bad - buf) * 4L, *bad);
                nbad++;
                n -= (bad - p) + 1;
                p = bad + 1;
            }
            if (nbad)
                printf("  val %08lx: %ld wrong\n", val[i], nbad);
            total += nbad;
        }
        printf("pass %d done, %ld wrong so far\n", pass, total);
    }
    printf("memchk: %ld wrong in %d pass(es)\n", total, npass);
    return total != 0;
}
