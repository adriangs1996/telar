#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;

  KeyChord character(char letter, unsigned modifiers = 0) {
    return {.key = KeyChord::Key::character, .character = KeyCharacter::pack(static_cast<std::uint32_t>(letter)), .modifiers = modifiers};
  }

  Stroke typed(Keys& keys, std::string_view text, bool visual = false) {
    Stroke last;

    for (const char letter : text) {
      last = feed(keys, character(letter), visual);
    }

    return last;
  }

  void testAKeyReadsAsNeovimSpellsIt() {
    check(notation(character('j')).view() == "j" && notation(character('G')).view() == "G");
    check(notation(character('w', static_cast<unsigned>(KeyChord::Modifier::control))).view() == "<C-w>");
    check(notation(character('c', static_cast<unsigned>(KeyChord::Modifier::super))).view() == "<D-c>");
    check(notation(character('<')).view() == "<lt>", "the character that opens a key's name is spelled out");
    check(notation({.key = KeyChord::Key::enter}).view() == "<CR>" && notation({.key = KeyChord::Key::escape}).view() == "<Esc>");
    check(notation({.key = KeyChord::Key::down}).view() == "j" && notation({.key = KeyChord::Key::page_down}).view() == "<C-d>", "an arrow moves as its letter does, a page key as the half page");
  }

  void testACountThenASequenceNamesACommand() {
    Keys keys;

    check(typed(keys, "j").command == Command::down);

    const auto counted = typed(keys, "12j");

    check(counted.command == Command::down && counted.count == 12 && counted.counted, "a count before the motion");
    check(feed(keys, character('g'), false).command == Command::none && keys.pending.view() == "g", "the start of a sequence waits for its end");
    check(feed(keys, character('g'), false).command == Command::top && keys.pending.view().empty());
    check(typed(keys, "5G").count == 5);
    check(typed(keys, "dd").command == Command::cut && typed(keys, "yy").command == Command::yank && typed(keys, "cw").command == Command::rename);
    check(typed(keys, "za").command == Command::toggle_fold && typed(keys, "]c").command == Command::next_change && typed(keys, "g.").command == Command::toggle_hidden);

    check(feed(keys, character('w', static_cast<unsigned>(KeyChord::Modifier::control)), false).command == Command::none);
    check(feed(keys, character('v'), false).command == Command::split_vertical, "<C-w> starts the windows' commands");
    check(feed(keys, character('s', static_cast<unsigned>(KeyChord::Modifier::super)), false).command == Command::write, "a file manager's shortcut names the same command");
  }

  void testACommandTakesTheNextKeyAsItsArgument() {
    Keys keys;

    check(feed(keys, character('m'), false).command == Command::none);

    const auto mark = feed(keys, character('B'), false);

    check(mark.command == Command::mark && mark.argument.view() == "B", "the letter of a mark");
    check(typed(keys, "'B").command == Command::jump_to_mark);
    check(typed(keys, "'j").argument.view() == "j", "a key that is a command elsewhere is the argument here");
  }

  void testKeysThatNameNothingAreForgotten() {
    Keys keys;

    check(typed(keys, "gz").command == Command::none && keys.pending.view().empty(), "a sequence that names nothing does not hold the next key back");
    check(typed(keys, "j").command == Command::down);
    check(typed(keys, "0").command == Command::none && !keys.counted, "a count does not start with 0");
    check(typed(keys, "10j").count == 10);
    check(typed(keys, "3").command == Command::none && keys.counted);
    clear(keys);
    check(!keys.counted && typed(keys, "j").count == 1);
  }

  void testASelectionTakesItsOwnKeys() {
    Keys keys;

    check(typed(keys, "d", true).command == Command::cut && typed(keys, "y", true).command == Command::yank, "one key where normal mode takes two");
    check(typed(keys, "j", true).command == Command::down && typed(keys, "V", true).command == Command::escape);
    check(typed(keys, "o", true).command == Command::none, "a command a selection does not take");
    check(keysOf(Command::cut) == "dd" && keysOf(Command::split_vertical) == "<C-w>v" && keysOf(Command::none).empty());
  }

  const telar::testing::Case case_notation{"keys.a_key_reads_as_neovim_spells_it", testAKeyReadsAsNeovimSpellsIt};
  const telar::testing::Case case_sequences{"keys.a_count_then_a_sequence_names_a_command", testACountThenASequenceNamesACommand};
  const telar::testing::Case case_arguments{"keys.a_command_takes_the_next_key_as_its_argument", testACommandTakesTheNextKeyAsItsArgument};
  const telar::testing::Case case_forgotten{"keys.keys_that_name_nothing_are_forgotten", testKeysThatNameNothingAreForgotten};
  const telar::testing::Case case_visual{"keys.a_selection_takes_its_own_keys", testASelectionTakesItsOwnKeys};

}
