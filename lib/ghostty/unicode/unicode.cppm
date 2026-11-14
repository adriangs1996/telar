module;
#include <ghostty/vt/unicode.h>

export module telar.ghostty.unicode;

// libghostty-vt's Unicode header stays in this global module fragment only; importers measure text
// with the terminal's width tables through this declaration instead of including it.
export {
  using ::ghostty_unicode_grapheme_width;
}
