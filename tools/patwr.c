/*
 * patwr -- write a self-describing pattern to the raw disk and say, for every
 * word that comes back wrong, *where that word came from*.
 *
 * ---------------------------------------------------------------------------
 * Why
 * ---------------------------------------------------------------------------
 * The DECA corrupts exactly one 16-bit word per damaged sector when the machine
 * writes to its micro-SD card, about one word in a hundred thousand, and only
 * in the memory-to-device direction.  Every accounting check from BrianHG's
 * controller up to the master's capture reads zero: one response per request,
 * none unbidden, the right 32-bit quarter of the 128-bit line, the right 16-bit
 * half of that word, one capture per cycle.  So the read returns the wrong
 * *contents*, and what has never been available is where those contents came
 * from.  Matching the bad values against the source file found only chance
 * collisions in a 16-bit fold, which is no evidence at all.
 *
 * A pattern that describes its own position turns each bad word into a pointer.
 *
 * ---------------------------------------------------------------------------
 * The encoding
 * ---------------------------------------------------------------------------
 *      bit 15      always 1 -- "this is pattern data"
 *      bits 14:8   sector index, modulo 128
 *      bits  7:0   word offset within the sector, 0..255
 *
 * So every word is unique within a 64 KiB window, and position and value each
 * determine the other.  A wrong word decodes to the sector and offset it was
 * really taken from, and the *displacement* from where it should have been is
 * the number that names the mechanism:
 *
 *   - one longword back, or one word back: a read returning held-over contents,
 *     which is what is left after the accounting came back clean;
 *   - a fixed larger step: compare against the DVMA chunk (4 bytes), the
 *     128-bit line (16), the sector (512) or the filesystem block (8192);
 *   - bit 15 clear: not our pattern at all, so it came from outside the
 *     transfer entirely.
 *
 * The tag bit costs half the window and is worth it: without it every value is
 * a legal position and foreign data is indistinguishable from a short
 * displacement.  It is not proof -- foreign data has an even chance of having
 * bit 15 set -- but a clear bit is conclusive one way.
 *
 * Note the half of the longword is not encoded separately: it is bit 0 of the
 * offset, so a half-swap shows up as a displacement of one and needs no bit of
 * its own.  Spending a bit on it, as first sketched, would have made every word
 * at the same half within a sector identical and hidden every short-range
 * displacement -- exactly the range the remaining suspects live in.
 *
 * ---------------------------------------------------------------------------
 * Where it runs
 * ---------------------------------------------------------------------------
 * On the machine, against the *raw* device: contiguous sectors, no allocator to
 * reason about, and physio DMAs straight out of this program's buffer, so what
 * the controller reads is what is written here.  A filesystem would put block
 * allocation between the pattern and the disk and lose the one thing being
 * measured.
 *
 * Compile on the machine:   cc -O -o patwr patwr.c
 * Run:                      ./patwr /dev/rsd0b 1000 256 4
 *                           (device, start sector, sectors per pass, passes)
 *
 * ---------------------------------------------------------------------------
 * Two ways this measured nothing, both worth keeping
 * ---------------------------------------------------------------------------
 * **Reading a file back does not check what reached the disk.**  The first
 * version wrote a 128 KiB file and read it straight back: 262,144 words, zero
 * errors, on a machine that reliably corrupts.  The read was served out of the
 * buffer cache, so it compared memory against memory and could not have failed.
 * That is the same reason every `cmp' in this investigation needed a reboot
 * first.  Hence the chunked I/O and the -v mode below: make the file far larger
 * than the cache so the read-back mostly misses it, and be able to verify in a
 * separate run after a reboot, which misses it entirely.
 *
 * **The raw device does not exercise the failing path.**  Against /dev/rsd0b,
 * 262,144 words came back clean -- and that result is real, not an artefact:
 * physio DMAs out of this program's own pages with no buffer cache in the way.
 * The workload that corrupts is a filesystem copy, which stages through kernel
 * buffers.  So the raw device is a useful *control* and not the reproduction.
 *
 * **It writes to the raw device, and the partition matters.**  In Sun's scheme
 * partition 3 -- `c' -- is normally the *whole disk*, overlapping `a' and `b',
 * so writing to `rsd0c' scribbles on the label and the root filesystem and
 * takes the machine down with it.  That is fine on a secondary disk or a
 * netbooted machine and fatal on the boot disk, which is what this project
 * runs on.  Use `rsd0b': it is the swap partition, 46 MB, bounded, does not
 * overlap root, and is untouched on an idle single-user machine.  Nothing here
 * checks the device it is given.
 */

#include <stdio.h>

#define SECSZ   512
#define WPS     (SECSZ / 2)             /* words per sector */

/* K&R: undeclared functions are assumed to return int.  atol and lseek both
 * return long.  int and long are both 32 bits on a Sun-2 so it happens not to
 * bite, but a silently truncated seek offset is not a thing to leave to the
 * word size. */
char *malloc();
long  atol();
long  lseek();

/* The word that belongs at (sector, offset). */
unsigned short
patword(sec, off)
long sec;
int off;
{
    return (unsigned short)(0x8000 | (((sec & 0x7f) << 8)) | (off & 0xff));
}

/* Decode a word back to where it came from.  Returns 0 if it is not ours. */
int
decode(w, secp, offp)
unsigned short w;
long *secp;
int *offp;
{
    if ((w & 0x8000) == 0) return 0;
    *secp = (w >> 8) & 0x7f;
    *offp = w & 0xff;
    return 1;
}

static char *dev;
static long  start;                     /* first sector */
static long  nsec;                      /* sectors per pass */
static int   passes;
static long  nbad = 0;
static long  nchecked = 0;

/*
 * Report one bad word.  The displacement is the point: `sector' here is modulo
 * 128, so the difference is taken modulo 128 too and reported as the signed
 * distance in *words*, which is what can be compared against a chunk, a line or
 * a sector.
 */
void
report(sec, off, want, got)
long sec;
int off;
unsigned short want, got;
{
    long gsec;
    int  goff;
    long dw;

    printf("BAD  sector %5ld  word %3d  want %04x  got %04x  ",
           sec, off, want, got);

    if (!decode(got, &gsec, &goff)) {
        printf("not pattern data\n");
        return;
    }

    /* Distance in words, modulo the 128-sector window. */
    dw = ((gsec - (sec & 0x7f)) & 0x7f) * (long)WPS + (goff - off);
    if (dw > (64L * WPS)) dw -= 128L * WPS;      /* fold to nearest */

    printf("= sector %ld word %d, %+ld words (%+ld bytes)\n",
           gsec, goff, dw, dw * 2);
}

int
main(argc, argv)
int argc;
char **argv;
{
    unsigned short *buf;
    long sec, base, done;
    int  off, fd, i, vonly;
    long chunk = 64;                    /* sectors per I/O, 32 KiB */
    long off_bytes;

    if (argc != 5 && argc != 6) {
        fprintf(stderr,
          "usage: %s <path> <startsec> <nsec> <passes> [-v]\n", argv[0]);
        fprintf(stderr,
          "       -v verifies only, for a run after a reboot\n");
        return 1;
    }
    dev    = argv[1];
    start  = atol(argv[2]);
    nsec   = atol(argv[3]);
    passes = atoi(argv[4]);
    vonly  = (argc == 6);

    buf = (unsigned short *)malloc((unsigned)(chunk * SECSZ));
    if (buf == 0) { fprintf(stderr, "out of memory\n"); return 1; }

    printf("patwr: %s sectors %ld..%ld, %d pass(es)%s\n",
           dev, start, start + nsec - 1, passes, vonly ? ", verify only" : "");

    for (i = 0; i < passes; i++) {
        if (!vonly) {
            fd = open(dev, 2);
            if (fd < 0) { perror(dev); return 1; }
            for (base = 0; base < nsec; base += chunk) {
                long n = (nsec - base < chunk) ? (nsec - base) : chunk;
                for (sec = 0; sec < n; sec++)
                    for (off = 0; off < WPS; off++)
                        buf[sec * WPS + off] = patword(start + base + sec, off);
                off_bytes = (start + base) * (long)SECSZ;
                if (lseek(fd, off_bytes, 0) != off_bytes) {perror("lseek w");return 1;}
                if (write(fd, (char *)buf, (int)(n * SECSZ)) != n * SECSZ) {
                    perror("write"); return 1;
                }
            }
            close(fd);
            sync();
        }

        /* Read-only for the verify: after a reboot the root is mounted ro,
         * and opening O_RDWR fails with "Read-only file system" before a
         * single word is checked. */
        fd = open(dev, vonly ? 0 : 2);
        if (fd < 0) { perror(dev); return 1; }
        for (base = 0; base < nsec; base += chunk) {
            long n = (nsec - base < chunk) ? (nsec - base) : chunk;
            off_bytes = (start + base) * (long)SECSZ;
            if (lseek(fd, off_bytes, 0) != off_bytes) {perror("lseek r");return 1;}
            if (read(fd, (char *)buf, (int)(n * SECSZ)) != n * SECSZ) {
                perror("read"); return 1;
            }
            for (sec = 0; sec < n; sec++) {
                for (off = 0; off < WPS; off++) {
                    unsigned short want = patword(start + base + sec, off);
                    unsigned short got  = buf[sec * WPS + off];
                    nchecked++;
                    if (got != want) {
                        nbad++;
                        report(start + base + sec, off, want, got);
                    }
                }
            }
        }
        close(fd);
        printf("pass %d: %ld words checked, %ld bad so far\n",
               i + 1, nchecked, nbad);
        fflush(stdout);
    }

    printf("patwr: %ld of %ld words wrong\n", nbad, nchecked);
    return nbad != 0;
}
