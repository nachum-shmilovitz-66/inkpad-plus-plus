#!/bin/sh
# MAC-65 A: LexPerl interpolated here-doc loop never advances over a NUL byte.
perl -0pi -e '$n = s~(\} else if \(endType == 2\) \{(\r?\n)\t+if \(!sc\.atLineEnd\)\r?\n\t+sc\.Forward\(\);\r?\n(\t+)\})(?! else if \(sLen == 0\))~$1 else if (sLen == 0) {$2$3\tsc.Forward();\t// NUL byte: step over it, or this loop never ends$2$3\}~g; $n ||= 0; die "LexPerl: expected 1 match, got $n\n" unless $n == 1' "$1"
