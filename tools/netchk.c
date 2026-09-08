/*
 * netchk -- stream a self-describing pattern over TCP and check it.
 *
 * The point is to take the filesystem out of the question entirely.  Every
 * corruption measurement in this investigation has run through a disk or an
 * NFS mount, so a buffer cache, a driver and a controller sit between the
 * pattern and the wire.  A socket removes all of that and leaves one thing:
 * the Ethernet's DMA into and out of main memory, the CPU reading it back.
 *
 * The pattern is tools/patwr's -u pattern, byte for byte, so a bad word here
 * and a bad word on a disk are the same signature and can be compared:
 *
 *      byte 2i     = 0x80
 *      byte 2i + 1 = i & 0xff        i counted in 16-bit words from the start
 *
 * It repeats every 512 bytes, so position is recoverable from content and a
 * wrong word names both what it should have been and where it came from.
 *
 * Byte-defined rather than word-defined on purpose: the Sun is big-endian and
 * the host may not be, and a pattern that depends on that would test the wrong
 * thing.
 *
 *   netchk r <host> <mbytes>    connect, read that many MiB, check them
 *   netchk s <host> <mbytes>    connect, send that many MiB
 *
 * The board always connects; the host always listens.  That keeps the board
 * side to one socket call and avoids bind/listen differences between 4.2BSD
 * and anything modern.
 *
 * SunOS 4.0.3 is K&R: no prototypes, and no <unistd.h>.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <stdio.h>

#define PORT   5555
#define BUFSZ  8192

char buf[BUFSZ];

main(argc, argv)
int argc;
char **argv;
{
    int  fd, mode, i, n, got, want_hi, want_lo;
    long total, done, pos, nbad;
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

    for (i = 0; i < sizeof(sin); i++) ((char *)&sin)[i] = 0;
    sin.sin_family = AF_INET;
    sin.sin_port   = htons(PORT);
    sin.sin_addr.s_addr = htonl(addr);

    if ((fd = socket(AF_INET, SOCK_STREAM, 0)) < 0) { perror("socket"); return 1; }
    if (connect(fd, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        perror("connect"); return 1;
    }

    done = 0; nbad = 0; pos = 0;
    if (mode == 'r') {
        while (done < total) {
            n = read(fd, buf, BUFSZ);
            if (n <= 0) break;
            for (i = 0; i < n; i++) {
                /* pos counts bytes; the word index is pos/2 */
                if ((pos & 1L) == 0) want_hi = 0x80, got = buf[i] & 0xff;
                else                 want_hi = (int)((pos >> 1) & 0xffL),
                                     got = buf[i] & 0xff;
                if (got != want_hi) {
                    if (nbad < 8)
                        printf("BAD  byte %ld  want %02x  got %02x\n",
                               pos, want_hi, got);
                    nbad++;
                }
                pos++;
            }
            done += n;
        }
        printf("netchk: read %ld bytes, %ld wrong\n", done, nbad);
    } else {
        while (done < total) {
            for (i = 0; i < BUFSZ; i++) {
                if (((done + i) & 1L) == 0) buf[i] = 0x80;
                else buf[i] = (char)((((done + i) >> 1) & 0xffL));
            }
            n = write(fd, buf, BUFSZ);
            if (n <= 0) break;
            done += n;
        }
        printf("netchk: sent %ld bytes\n", done);
    }
    close(fd);
    return nbad != 0;
}
