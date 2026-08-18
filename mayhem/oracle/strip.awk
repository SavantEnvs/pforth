# mayhem/oracle/strip.awk -- used only by mayhem/test.sh:
#     awk -v S=<script> -f strip.awk expected.txt <script>.fth > <stripped script>
#
# Takes the right answers out of a pinned test script before pForth reads it. Every assertion
# "T{ <code> }T{ <expected> }T" becomes "T{ <code> }T{ }T": the program under test computes the
# code half and never sees the expected half (mayhem/test.sh holds the answers, in expected.txt).
# The output has the same number of lines as the input, so line numbers ("S" lines) still match.
#
# Rules from expected.txt for this script:
#   O <script> <word>     <word> also starts an expected half (t_file.fth: ": -> }T{ ;").
#   X <script> <line> <words>
#                         <words> are added to the end of the code half of the assertion whose
#                         expected half starts on <line>. Used where a result is an address: the
#                         added words turn it into an offset from the string it points into, so
#                         every right answer is a plain number.
# Tokens are separated by spaces and tabs. Not looked at: text after "\" or TESTING (t_file.fth's
# TESTING skips the rest of its line), inside ( ) or .( ) on one line, inside strings, and the
# word after CHAR, [CHAR] or ":". An expected half that is not inside an assertion started by T{
# (the one in t_corex.fth's GD9 definition) is left alone. mayhem/test.sh checks the SHA-256 of
# every output, so a change in any of this (or in awk) fails closed instead of changing a test.

function skip_to(line, from, delim,   i, c) {   # position after the closing delim, or past the end
  for (i = from; i <= length(line); i++) {
    c = substr(line, i, 1)
    if (delim == "\\\"" && c == "\\") { i++; continue }   # S\" : backslash escapes
    if (c == substr(delim, length(delim), 1)) return i + 1
  }
  return length(line) + 1
}

BEGIN { split("S\" S\\\" .\" C\" ABORT\" \" $\" ,\"", q, " "); for (i in q) quoted[q[i]] = 1 }

FNR == NR {
  if ($1 == "O" && $2 == S) opener[toupper($3)] = 1
  if ($1 == "X" && $2 == S) { t = $0; sub(/^X[ \t]+[^ \t]+[ \t]+[0-9]+[ \t]+/, "", t); extra[$3] = t }
  next
}

{
  line = $0; out = ""; keep = inexp ? 0 : 1; pos = 1; skipnext = 0
  while (pos <= length(line) && match(substr(line, pos), /[^ \t]+/)) {
    s = pos + RSTART - 1; e = s + RLENGTH; tok = toupper(substr(line, s, RLENGTH)); pos = e
    if (inexp) {                                      # inside an expected half: drop tokens
      if (tok == "}T") { inexp = 0; out = out (out == "" ? "" : " "); keep = s; continue }
      if (tok == "\\") break
      if (tok in quoted) pos = skip_to(line, e + 1, tok == "S\\\"" ? "\\\"" : "\"")
      continue
    }
    if (skipnext) { skipnext = 0; continue }
    if (tok == "\\" || tok == "TESTING") break
    if (tok == "(" || tok == ".(") { pos = skip_to(line, e, ")"); continue }
    if (tok in quoted) { pos = skip_to(line, e + 1, tok == "S\\\"" ? "\\\"" : "\""); continue }
    if (tok == ":" || tok == "CHAR" || tok == "[CHAR]") { skipnext = 1; continue }
    if (tok == "T{") { asserting = 1; continue }
    if ((tok == "}T{" || (tok in opener)) && asserting) {
      asserting = 0; inexp = 1
      if (FNR in extra) { out = out substr(line, keep, s - keep) extra[FNR] " "; keep = s; used[FNR] = 1 }
      out = out substr(line, keep, e - keep); keep = 0
    }
  }
  if (keep) out = out substr(line, keep)
  print out
}

END {
  if (inexp) { print "strip.awk: " S ": expected half not closed at the end" > "/dev/stderr"; exit 2 }
  for (l in extra) if (!(l in used)) { print "strip.awk: " S ": X rule for line " l " not used" > "/dev/stderr"; exit 2 }
}
