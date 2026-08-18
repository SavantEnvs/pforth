\ mayhem/oracle/t_tools.fth -- record-emitting replacement for pForth's fth/t_tools.fth.
\
\ Used ONLY by mayhem/test.sh. It defines the assertion words the pinned test scripts in this
\ directory use (TEST{ }TEST T{ }T{ }T), but it does not decide pass/fail: there is no counter
\ and no "N passed, M failed" summary. Each assertion prints ONE record line
\
\     @@ <nonce> <seq> A <n> : <a1> .. <an>
\
\ <seq> numbers the assertions of the script in order (T{ increments it). The A list is the
\ stack saved by }T{ (what the code under test computed, top of stack first), in signed decimal.
\ No expected values are printed: mayhem/test.sh removes the expected half of every assertion
\ (mayhem/oracle/strip.awk) before pForth reads the script, compares each A list with its own
\ copy of the right answers (mayhem/oracle/expected.txt) and decides pass/fail itself. }T still
\ clears whatever is on the stack (t_corex.fth's GD9 leaves one value there) but prints none of
\ it. <nonce> is a number test.sh makes for every process and defines as ORACLE-NONCE before
\ this file is loaded; it only marks the record lines and is no secret (the program reads it).
\ T.END prints "@@ <nonce> END" when the whole script has run.
\
\ Upstream's fth/t_tools.fth compared the two halves inside the interpreter and printed a
\ tally, which the old test.sh read. Upstream words the scripts do not use (TEST-PASSED,
\ TEST-FAILED, ERROR, the-test) are left out. Every definition fits on one line, because
\ mayhem/test.sh also feeds this file line by line to the graded libFuzzer binary. FLUSHEMIT
\ after each record keeps the records printed before a crash of the test binary. In the fuzz
\ build (PF_NO_FILEIO) pForth's FLUSHEMIT does nothing, so if a graded or twin run crashes, the
\ records still in its stdout buffer are lost and those assertions count as failed.

anew task-t_tools.fth

decimal

variable T-SEQ  0 T-SEQ !
32 constant T-MAXR
variable T-DEST
variable actual-depth
create actual-results T-MAXR cells allot
variable expected-depth
create expected-results T-MAXR cells allot

: empty-stack ( ... -- ) DEPTH dup 0> IF 0 DO DROP LOOP ELSE drop THEN ;

\ Move the whole data stack into the array at addr (top of stack first, at most T-MAXR cells
\ kept) and leave only the depth it had.
: T.SAVE ( ... addr -- n ) T-DEST ! DEPTH dup 0 ?DO i T-MAXR < IF swap T-DEST @ i cells + ! ELSE nip THEN LOOP ;

: T.ITEMS ( addr n -- ) T-MAXR min 0 ?DO dup i cells + @ (.) type space LOOP drop ;

: TEST{ ( -- ) ;

: }TEST ( -- ) STATE @ abort" STATE is non-zero in }TEST - compiling mode on!" ; immediate

: T{ ( -- ) empty-stack 1 T-SEQ +! ;

: }T{ ( ... -- ) actual-results T.SAVE actual-depth ! ;

: T.HEAD ( -- ) cr ." @@ " ORACLE-NONCE (.) type space ;
: T.ACTUAL ( -- ) ." A " actual-depth @ (.) type ."  : " actual-results actual-depth @ T.ITEMS ;

: }T ( ... -- ) expected-results T.SAVE expected-depth ! base @ >r decimal T.HEAD T-SEQ @ (.) type space T.ACTUAL cr flushemit r> base ! ;

: T.END ( -- ) base @ >r decimal T.HEAD ." END" cr flushemit r> base ! ;
