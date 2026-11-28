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

  // Latin Extended-B, which the fold once missed, and the scripts past the first plane fold as
  // Unicode's simple case folding does.
  void foldsEveryScriptUnicodeFolds() {
    check(folded("ǍƁȂƑ ǅ") == "ǎɓȃƒ ǆ", "Latin Extended-B folds");
    check(folded("\U00010400\U0001E900") == "\U00010428\U0001E922", "Deseret and Adlam fold");
    check(historyFold(U'ⱥ') == historyFold(U'Ⱥ') && folded("ⱥȺ") == "ȺȺ", "letters that fold together meet on the shorter one");
    check(historyScore("ǍBC", "ǎb").hasValue(), "the score folds them too");
  }

  // Every character folds to one that folds to itself, and never to a longer UTF-8 sequence,
  // so a folded text fits where the text was.
  void foldsEveryCharacterToAFixedPointNoLonger() {
    const auto length = [](std::uint32_t character) {
      return character < 0x80 ? 1 : character < 0x800 ? 2
                                : character < 0x10000 ? 3
                                                      : 4;
    };

    for (std::uint32_t character = 0; character < 0x110000; ++character) {
      const auto fold = historyFold(character);

      check(historyFold(fold) == fold, "a fold is folded");
      check(length(fold) <= length(character), "a fold is no longer");
    }
  }

  const telar::testing::Case case_folds_every_script{"history_fold.folds_every_script_unicode_folds", foldsEveryScriptUnicodeFolds};
  const telar::testing::Case case_folds_to_a_fixed_point{"history_fold.folds_every_character_to_a_fixed_point_no_longer", foldsEveryCharacterToAFixedPointNoLonger};
  const telar::testing::Case case_folds_letters_of_several_scripts{"history_fold.folds_letters_of_several_scripts", foldsLettersOfSeveralScripts};

}
