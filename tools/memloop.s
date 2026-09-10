| memloop.s -- the two inner loops, in 68010 loop mode.
|
| Loop mode is what makes this a *data* test.  The 68010 caches a loop of one
| one-word instruction followed by DBcc and runs it from inside the chip, so
| the bus carries nothing but the operand accesses -- no instruction fetches
| interleaved with the data.  Any other loop shape fetches, and then the
| traffic under test is not what it claims to be.
|
| DBcc counts 16 bits, so an outer loop breaks the buffer into 32768-long
| chunks.  The outer loop is not in loop mode and does not need to be: it runs
| once per 128 KiB.
|
| SunOS 4.0.3 m68k conventions: d0/d1/a0/a1 scratch, d2-d7/a2-a6 preserved,
| arguments on the stack, result in d0.

	.text

| void mfill(long *p, long n, long v)
	.globl	_mfill
_mfill:
	movl	d2,sp@-
	movl	d3,sp@-
	movl	sp@(12),a0
	movl	sp@(16),d2
	movl	sp@(20),d0
mf_outer:
	movl	d2,d1
	cmpl	#32768,d1
	bles	mf_go
	movl	#32768,d1
mf_go:
	subl	d1,d2
	subql	#1,d1
mf_loop:
	movl	d0,a0@+
	dbra	d1,mf_loop
	tstl	d2
	bnes	mf_outer
	movl	sp@+,d3
	movl	sp@+,d2
	rts

| long *mcheck(long *p, long n, long v)  -- 0, or the first long that differs
	.globl	_mcheck
_mcheck:
	movl	d2,sp@-
	movl	d3,sp@-
	movl	sp@(12),a0
	movl	sp@(16),d2
	movl	sp@(20),d0
mc_outer:
	movl	d2,d1
	cmpl	#32768,d1
	bles	mc_go
	movl	#32768,d1
mc_go:
	subl	d1,d2
	subql	#1,d1
mc_loop:
	cmpl	a0@+,d0
	dbne	d1,mc_loop
	bnes	mc_bad
	tstl	d2
	bnes	mc_outer
	clrl	d0
	bras	mc_out
mc_bad:
	movl	a0,d0
	subql	#4,d0
mc_out:
	movl	sp@+,d3
	movl	sp@+,d2
	rts
