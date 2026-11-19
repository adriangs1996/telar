// The keys the command editor reads and the actions a binding names: what ui hands the line and
// the configuration binds, apart from Qt.
export module telar.gui.features.prompt:keys;

import std;
import telar.base.memory.allocators;
import telar.base.ds;

export namespace telar::gui::features::prompt {

  enum class Key : std::uint8_t {
    character,
    enter,
    backspace,
    delete_forward,
    left,
    right,
    up,
    down,
    home,
    end,
    tab,
    backtab,
    escape,
  };

  struct Modifiers {
    bool control = false;
    bool alt = false;
    bool shift = false;

    bool operator==(const Modifiers&) const = default;
  };

  // One key press. `text` holds what a character key types, UTF-8; `character` the code point
  // a binding matches, lower case for letters with control.
  struct KeyPress {
    Key key = Key::character;
    char32_t character = 0;
    Modifiers modifiers{};
    std::string_view text;
  };

  // What a key bound in `client.prompt.bindings` does. The names, in this order, are
  // `prompt_action_names` in telar-config, which validates them.
  enum class Action : std::uint8_t {
    submit,
    newline,
    cancel,
    complete,
    accept_suggestion,
    history_previous,
    history_next,
    history_search,
    line_start,
    line_end,
    char_left,
    char_right,
    word_left,
    word_right,
    delete_char,
    backspace,
    kill_line,
    kill_to_start,
    kill_word,
    kill_word_back,
    yank,
    undo,
    redo,
    transpose,
    clear_screen,
    normal_mode,
    insert_mode,
  };

  enum class Keymap : std::uint8_t {
    emacs,
    vim,
  };

  enum class Mode : std::uint8_t {
    insert,
    normal,
    visual,
    visual_line,
  };

  // The system clipboard behind vim's "+ and "* registers.
  struct Clipboard {
    // Replaces `text` with what the clipboard holds.
    ds::Function<void(ds::String<Memory>& text)> read;
    ds::Function<void(std::string_view text)> write;
  };

}
