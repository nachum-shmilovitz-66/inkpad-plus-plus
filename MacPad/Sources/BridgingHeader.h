// Exposes the Scintilla Cocoa view and the Lexilla C API to Swift.
// Both come from build/deps (scripts/build-deps.sh).

#import <Scintilla/ScintillaView.h>
#import <Scintilla/Scintilla.h>
#import "SciLexer.h"
#import "Lexilla.h"
#import "uchardet.h"
#import "BoostRegexSearch.h"

// scripts/deps/BoostRegexLocale.cxx: the last Boost regex error message.
const char *MacPadRegexErrorMessage(void);
