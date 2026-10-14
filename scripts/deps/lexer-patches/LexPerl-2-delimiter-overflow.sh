#!/bin/sh
# MAC-65 C: LexPerl HereDocCls::Append writes past Delimiter[256] when a multi-byte char ends a long quoted delimiter.
perl -0pi -e '$n = s~(void Append\(int ch\) \{(\r?\n)(\t+))(Delimiter\[DelimiterLength\+\+\])~$1if (DelimiterLength >= HERE_DELIM_MAX - 1)$2$3\treturn;\t// full: the caller reports the error$2$3$4~g; $n ||= 0; die "LexPerl C: expected 1 match, got $n\n" unless $n == 1' "$1"
