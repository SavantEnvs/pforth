\ mayhem/oracle/t_bounds.fth -- assertions written for mayhem/test.sh (NOT from upstream).
\
\ 1+, 1-, 2+, 2- and DO +LOOP at values next to the signed limits, chosen so that NOTHING
\ overflows: the graded binary /mayhem/pforth_fuzzer (UBSan stops on signed overflow) can run
\ every one of them. Upstream's own wrap-around tests (t_corex.fth lines 275-316) do overflow, so
\ test.sh runs those on the test binary and on the UBSan-recovering twin instead; these extra
\ assertions also check the same words on the graded binary itself. For example a patch that
\ makes 1+ clamp negative results to 0 in the fuzz build only fails "-2 1+".
\ The expected halves below hold the same values as mayhem/oracle/expected.txt; test.sh removes
\ them (mayhem/oracle/strip.awk) before pForth reads this file.
\ Every line is complete on its own, because test.sh feeds this file line by line to the graded
\ libFuzzer binary (one line per input).

decimal

0 INVERT 1 RSHIFT CONSTANT B-MAX-INT
B-MAX-INT INVERT CONSTANT B-MIN-INT
B-MAX-INT 7 RSHIFT 1+ CONSTANT B-STEP
VARIABLE B-BUMP

\ ( 0 limit start step -- count ) runs DO ... +LOOP and counts the passes, like t_corex's GD8,
\ but stops after 101 passes (a fixed work budget, not a timer). The right counts are 3 or 4, so
\ the budget only matters when a patch breaks 1+, 1- or +LOOP: a wrong limit would otherwise make
\ the test binary (no UBSan) count through 2^63 values and never finish; now it returns 101.
: B-GD8 B-BUMP ! DO 1+ DUP 100 > IF LEAVE THEN B-BUMP @ +LOOP ;

\ 1+ and 1- around zero and on negative numbers
T{ -2 1+ }T{ -1 }T
T{ -1 1+ }T{ 0 }T
T{ 0 1+ }T{ 1 }T
T{ -1000 1+ }T{ -999 }T
T{ -3 1+ 1+ 1+ }T{ 0 }T
T{ 1 1- }T{ 0 }T
T{ 0 1- }T{ -1 }T
T{ -1 1- }T{ -2 }T
T{ -3 2+ }T{ -1 }T
T{ 1 2- }T{ -1 }T

\ next to MIN-INT and MAX-INT, without crossing them
T{ B-MIN-INT 1+ B-MIN-INT - }T{ 1 }T
T{ B-MAX-INT 1- B-MAX-INT - }T{ -1 }T
T{ B-MIN-INT 1+ 1- B-MIN-INT = }T{ TRUE }T
T{ B-MAX-INT 1- 1+ B-MAX-INT = }T{ TRUE }T
T{ B-MIN-INT 1+ 0< }T{ TRUE }T
T{ B-MAX-INT 1- 0> }T{ TRUE }T
T{ B-MIN-INT 2+ B-MIN-INT - }T{ 2 }T
T{ B-MAX-INT 2- B-MAX-INT - }T{ -2 }T

\ DO +LOOP that stops exactly at a limit next to MAX-INT or MIN-INT (no index overflows)
T{ 0 -2 -5 1 B-GD8 }T{ 3 }T
T{ 0 B-MAX-INT B-MAX-INT 3 - 1 B-GD8 }T{ 3 }T
T{ 0 B-MIN-INT 1+ B-MIN-INT 4 + -1 B-GD8 }T{ 4 }T
T{ 0 B-MAX-INT B-MAX-INT B-STEP 4 * - B-STEP B-GD8 }T{ 4 }T
T{ 0 B-MIN-INT B-STEP + DUP B-STEP 3 * + B-STEP NEGATE B-GD8 }T{ 4 }T
