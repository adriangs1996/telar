#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.history;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  std::string folded(std::string_view text) {
    std::string out(text.size(), '\0');

    out.resize(historyFold(text, std::span{out}));
    return out;
  }

  // The history's search folds case beyond ASCII, as its index does, and never grows the text.
  void foldsLettersOfSeveralScripts() {
    check(folded("ÉCOLE Straße") == "école straße");
    check(folded("ΑΒΓ Ά ς") == "αβγ ά σ", "Greek folds, final sigma too");
    check(folded("ДЖЁ") == "джё", "Cyrillic folds");
    check(folded("ĹŻŒ Ÿ ẞ") == "ĺżœ ÿ ß", "Latin Extended folds its odd and even runs");
    check(folded("ＡＢ") == "ａｂ", "fullwidth letters fold");
    check(folded("a\xff"
                 "B") == "a\xff"
                         "b",
        "a byte that starts no character is copied");
    check(historyFold(U'Ω') == U'ω' && historyFold(U'K') == U'k', "the letterlike signs fold to their letters");
    check(historyScore("ÉCOLE", "éc") && !historyScore("\xc3\x83\xc2\xa9", "é"), "the score compares characters, not bytes");
  }

  const telar::testing::Case case_folds_letters_of_several_scripts{"history_fold.folds_letters_of_several_scripts", foldsLettersOfSeveralScripts};

}
