// MacPad++ (GPLv3) — linked into libscintilla-boostregex.a by scripts/build-deps.sh (MAC-29).
//
// Notepad++ searches with basic_regex<wchar_t>. On Windows Boost classifies characters with the
// Win32 API, so \w, [[:alpha:]] and case-insensitive matching know every script. On macOS Boost
// falls back to std::ctype<wchar_t> from the global C++ locale, which is "C": libc++ then treats
// every non-ASCII character as nothing at all (\w would not match "שלום", and "É" would not match
// "é" case-insensitively). Giving the global locale a UTF-8 ctype<wchar_t> facet before the first
// search restores Notepad++'s behaviour. Only that one facet changes; number and time formatting
// stay "C".
#include <locale>

namespace {
struct UnicodeWideCtype {
    UnicodeWideCtype() {
        for (const char* name : {"en_US.UTF-8", "C.UTF-8", "UTF-8"}) {
            try {
                std::locale::global(std::locale(std::locale(), new std::ctype_byname<wchar_t>(name)));
                return;
            } catch (...) {
            }
        }
    }
};
const UnicodeWideCtype installUnicodeWideCtype;
}  // namespace

// The message of the last regex error (BoostRegexSearch's g_exceptionMessage), for Swift: the
// Find dialog's tooltip and diagnostics.
#include <string>
extern std::string g_exceptionMessage;
extern "C" const char* MacPadRegexErrorMessage() { return g_exceptionMessage.c_str(); }
