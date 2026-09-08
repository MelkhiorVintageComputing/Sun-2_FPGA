/*
 * netchk -- stream a self-describing pattern over TCP and check it.
 *
 * The point is to take the filesystem out of the question entirely.  Every
 * corruption measurement in this investigation has run through a disk or an
 * NFS mount, so a buffer cache, a driver and a controller sit between the
 * pattern and the wire.  A socket removes all of that and leaves one thing:
 * the Ethernet's DMA into and out of main memory, and the CPU reading it back.
 *
 * The pattern is tools/patwr's -u pattern, byte for byte, so a bad word here
 * and a bad word on a disk are the same signature and can be compared:
 *
 *      byte 2i     = 0x80
 *      byte 2i + 1 = i & 0xff        i counted in 16-bit words from the start
 *
 * It repeats every 512 bytes, so position is recoverable from content, and --
 * the reason this is fast -- a buffer whose length is a multiple of 512 is
 * valid at *every* aligned offset in the stream.  Build it once and the send
 * side does no per-byte work at all, while the check side is one longword
 * compare per four bytes.
 *
 * **That matters for what is being tested.**  A byte-at-a-time loop on a
 * 20 MHz 68010 runs at a few hundred KB/s, which barely troubles the Ethernet
 * or the DMA; the first version of this program was the bottleneck rather than
 * the machine.  Comparing four bytes at a time against a precomputed buffer
 * puts the load where it belongs.
 *
 * Byte-defined rather than word-defined on purpose: the Sun is big-endian and
 * the host may not be, and a pattern that depended on that would test the
 * wrong thing.  The longword compare is safe because both ends build the same
 * bytes.
 *
 *   netchk r <host> <mbytes>    connect, read that many MiB, check them
 *   netchk s <host> <mbytes>    connect, send that many MiB
 *
 * The board always connects; the host always listens.  That keeps the board
 * side to one socket call.  SunOS 4.0.3 is K&R: no prototypes, no <unistd.h>.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdio.h>

#define PORT   5555
#define BUFSZ  16384            /* a multiple of 512, so ref[] tiles the stream */

char ref[BUFSZ];
char buf[BUFSZ];

main(argc, argv)
int argc;
char **argv;
{
    int  fd, mode, i, n, have;
    long total, done, nbad, t0, t1;
    long *p, *q;
    struct sockaddr_in sin;
    unsigned long addr;
    unsigned int a, b, c, d;

    if (argc != 4) {
        fprintf(stderr, "usage: netchk r|s <host> <mbytes>\n");
        return 2;
    }
    mode = argv[1][0];
    if (sscanf(argv[2], "%u.%u.%u.%u", &a, &b, &c, &d) != 4) {
        fprintf(stderr, "netchk: bad address %s\n", argv[2]);
        return 2;
    }
    addr = ((unsigned long)a << 24) | ((unsigned long)b << 16) |
           ((unsigned long)c << 8)  | (unsigned long)d;
    total = atol(argv[3]) * 1024L * 1024L;

    for (i = 0; i < BUFSZ; i++)
        ref[i] = ((i & 1) == 0) ? 0x80 : (char)((i >> 1) & 0xff);

    for (i = 0; i < sizeof(sin); i++) ((char *)&sin)[i] = 0;
    sin.sin_family = AF_INET;
    sin.sin_port   = htons(PORT);
    sin.sin_addr.s_addr = htonl(addr);

    if ((fd = socket(AF_INET, SOCK_STREAM, 0)) < 0) { perror("socket"); return 1; }
    if (connect(fd, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        perror("connect"); return 1;
    }

    done = 0; nbad = 0; have = 0;
    time(&t0);
    if (mode == 'r') {
        while (done < total) {
            n = read(fd, buf + have, BUFSZ - have);
            if (n <= 0) break;
            have += n;
            if (have == BUFSZ) {          /* a whole aligned block: compare it */
                p = (long *)buf; q = (long *)ref;
                for (i = 0; i < BUFSZ / 4; i++) {
                    if (p[i] != q[i]) {
                        if (nbad < 8)
                            printf("BAD  byte %ld  want %08lx  got %08lx\n",
                                   done + (long)i * 4L, q[i], p[i]);
                        nbad++;
                    }
                }
                done += BUFSZ;
                have = 0;
            }
        }
        time(&t1);
        printf("netchk: read %ld bytes, %ld wrong longwords, %ld s\n",
               done, nbad, t1 - t0);
    } else {
        while (done < total) {
            n = write(fd, ref, BUFSZ);
            if (n <= 0) break;
            done += n;
        }
        time(&t1);
        printf("netchk: sent %ld bytes, %ld s\n", done, t1 - t0);
    }
    close(fd);
    return nbad != 0;
}
