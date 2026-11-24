#include "explorer_fixture.hpp"
#include <initializer_list>
#include <string_view>
#include <tuple>

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;

  KeyChord character(char letter, unsigned modifiers = 0) {
    return {.key = KeyChord::Key::character, .character = KeyCharacter::pack(static_cast<std::uint32_t>(letter)), .modifiers = modifiers};
  }

  // The keys of an explorer whose configuration changes none.
  const Keymap& defaults() {
    static const Keymap keymap;

    return keymap;
  }

  Stroke typed(const Keymap& keymap, Keys& keys, std::string_view text, bool visual = false) {
    Stroke last;

    for (const char letter : text) {
      last = feed(keymap, keys, character(letter), visual);
    }

    return last;
  }

  Stroke typed(Keys& keys, std::string_view text, bool visual = false) {
    return typed(defaults(), keys, text, visual);
  }

  Stroke feed(Keys& keys, KeyChord chord, bool visual) {
    return feed(defaults(), keys, chord, visual);
  }

  ExplorerKeys changes(std::initializer_list<std::tuple<std::string_view, Command, bool>> listed) {
    ExplorerKeys result;

    for (const auto& [sequence, command, visual] : listed) {
      telar::runtime::config::ExplorerKey key{.command = command, .visual = visual};

      key.keys.assign(sequence);
      check(result.put(key));
    }

    return result;
  }

  void testAKeyReadsAsNeovimSpellsIt() {
    check(notation(character('j')).view() == "j" && notation(character('G')).view() == "G");
    check(notation(character('w', static_cast<unsigned>(KeyChord::Modifier::control))).view() == "<C-w>");
    check(notation(character('c', static_cast<unsigned>(KeyChord::Modifier::super))).view() == "<D-c>");
    check(notation(character('<')).view() == "<lt>", "the character that opens a key's name is spelled out");
    check(notation({.key = KeyChord::Key::enter}).view() == "<CR>" && notation({.key = KeyChord::Key::escape}).view() == "<Esc>");
    check(notation({.key = KeyChord::Key::down}).view() == "j" && notation({.key = KeyChord::Key::page_down}).view() == "<C-d>", "an arrow moves as its letter does, a page key as the half page");
    check(notation({.key = KeyChord::Key::backspace}).view() == "<BS>" && notation({.key = KeyChord::Key::backspace, .modifiers = static_cast<unsigned>(KeyChord::Modifier::super)}).view() == "<Del>", "Command with the key that erases is Del");
  }

  void testTheKeysOfTheDesignNameTheirCommands() {
    Keys keys;

    check(typed(keys, "zo").command == Command::unfold && typed(keys, "zc").command == Command::fold && typed(keys, "zR").command == Command::unfold_all);
    check(typed(keys, "cw").command == Command::rename && typed(keys, "cc").command == Command::rename_whole);
    check(typed(keys, "i").command == Command::rename_start && typed(keys, "I").command == Command::rename_start && typed(keys, "a").command == Command::rename_end && typed(keys, "A").command == Command::rename_end);
    check(feed(keys, character('n', static_cast<unsigned>(KeyChord::Modifier::control)), false).command == Command::down && feed(keys, character('p', static_cast<unsigned>(KeyChord::Modifier::control)), false).command == Command::up);
    check(feed(keys, character('n', static_cast<unsigned>(KeyChord::Modifier::control)), true).command == Command::down, "in a selection too");
    check(feed(keys, {.key = KeyChord::Key::backspace}, false).command == Command::parent, "the key that erases goes up, as - does");
    check(feed(keys, {.key = KeyChord::Key::backspace, .modifiers = static_cast<unsigned>(KeyChord::Modifier::super)}, false).command == Command::cut);
    check(feed(keys, character('a', static_cast<unsigned>(KeyChord::Modifier::super)), false).command == Command::select_all && feed(keys, character('a', static_cast<unsigned>(KeyChord::Modifier::control)), false).command == Command::select_all);

    // A mark is jumped to with either quote.
    const auto quoted = typed(keys, "'a");
    const auto ticked = typed(keys, "`b");

    check(quoted.command == Command::jump_to_mark && quoted.argument.view() == "a" && ticked.command == Command::jump_to_mark && ticked.argument.view() == "b");
  }

  void testAltWStandsForControlW() {
    Keys keys;
    const auto alt = static_cast<unsigned>(KeyChord::Modifier::alt);

    check(feed(keys, character('w', alt), false).command == Command::none && keys.pending.view() == "<C-w>", "it starts the sequences Control with w starts");
    check(feed(keys, character('v'), false).command == Command::split_vertical);
    check(feed(keys, character('w', alt), false).command == Command::none && feed(keys, character('l'), false).command == Command::window_right);

    // A map that binds it keeps it for what it bound.
    Keymap keymap;

    check(rebind(keymap, changes({{"<M-w>", Command::refresh, false}})));
    check(feed(keymap, keys, character('w', alt), false).command == Command::refresh);
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
    check(keysOf(defaults(), Command::cut) == "dd" && keysOf(defaults(), Command::split_vertical) == "<C-w>v" && keysOf(defaults(), Command::none).empty());
  }

  void testTheConfigurationBindsUnbindsAndRebinds() {
    Keymap keymap;
    Keys keys;

    check(keysOf(keymap, Command::cut) == "dd" && keysOf(keymap, Command::cut, true) == "d" && keysOf(keymap, Command::create_directory).empty(), "by default the keys are the ones the explorer came with");
    check(!rebind(keymap, ExplorerKeys{}), "a configuration that changes nothing builds nothing");

    // `x` cuts, `dd` does nothing, `gs` stages; in a selection `x` cuts too.
    check(rebind(keymap, changes({{"x", Command::cut, false}, {"dd", Command::none, false}, {"gs", Command::stage, false}, {"x", Command::cut, true}})));
    check(typed(keymap, keys, "x").command == Command::cut && typed(keymap, keys, "dd").command == Command::none && typed(keymap, keys, "gs").command == Command::stage);
    check(typed(keymap, keys, "ga").command == Command::stage && typed(keymap, keys, "3j").count == 3, "the keys it does not change stay");
    check(typed(keymap, keys, "x", true).command == Command::cut && typed(keymap, keys, "d", true).command == Command::cut, "each mode has its own");
    check(keysOf(keymap, Command::cut) == "x" && keysOf(keymap, Command::stage) == "gs", "the keys it binds are the first a command is known by");
    check(names(keymap, "<Del>", Command::cut) && !names(keymap, "dd", Command::cut));

    // A sequence it binds takes the place of the ones it starts, and of the one that starts it.
    check(rebind(keymap, changes({{"g", Command::bottom, false}, {"cwx", Command::refresh, false}, {"M", Command::mark, false}})));
    check(typed(keymap, keys, "g").command == Command::bottom && typed(keymap, keys, "gg").command == Command::bottom && keysOf(keymap, Command::top).empty(), "gg is two of it now");
    check(typed(keymap, keys, "cwx").command == Command::refresh && keysOf(keymap, Command::rename).empty() && keysOf(keymap, Command::rename_start) == "i");

    const auto mark = typed(keymap, keys, "MQ");

    check(mark.command == Command::mark && mark.argument.view() == "Q", "a command that takes a letter takes it after its new keys");
    check(typed(keymap, keys, "dd").command == Command::cut, "what the configuration no longer changes is as it came");

    // Unbinding every key of a command leaves it with none.
    check(rebind(keymap, changes({{"?", Command::none, false}})) && keysOf(keymap, Command::help).empty() && typed(keymap, keys, "?").command == Command::none);
    check(rebind(keymap, ExplorerKeys{}) && keysOf(keymap, Command::help) == "?");
  }

  const telar::testing::Case case_configured{"keys.the_configuration_binds_unbinds_and_rebinds", testTheConfigurationBindsUnbindsAndRebinds};
  const telar::testing::Case case_design{"keys.the_keys_of_the_design_name_their_commands", testTheKeysOfTheDesignNameTheirCommands};
  const telar::testing::Case case_alt{"keys.alt_w_stands_for_control_w", testAltWStandsForControlW};
  const telar::testing::Case case_notation{"keys.a_key_reads_as_neovim_spells_it", testAKeyReadsAsNeovimSpellsIt};
  const telar::testing::Case case_sequences{"keys.a_count_then_a_sequence_names_a_command", testACountThenASequenceNamesACommand};
  const telar::testing::Case case_arguments{"keys.a_command_takes_the_next_key_as_its_argument", testACommandTakesTheNextKeyAsItsArgument};
  const telar::testing::Case case_forgotten{"keys.keys_that_name_nothing_are_forgotten", testKeysThatNameNothingAreForgotten};
  const telar::testing::Case case_visual{"keys.a_selection_takes_its_own_keys", testASelectionTakesItsOwnKeys};

}
