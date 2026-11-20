// What a pane's line tells its owner after a key, and the menu of choices Tab opens on it.
export module telar.gui.features.prompt:menu;

import std;

import :completion;
import telar.shell.syntax;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;

export namespace telar::gui::features::prompt {

  // What the owner does after a key.
  enum class Outcome : std::uint8_t {
    // The line used the key; repaint it.
    edited,
    // Send `delivery` to the shell as a command and run it.
    run,
    // Send `delivery` to the running program as typed input followed by Enter.
    answer,
    // Send `delivery` to the shell as raw bytes (end of file, clear screen).
    bytes,
    // The key belongs to the terminal: encode and send it as usual.
    terminal,
    // Neither the line nor the terminal: telar's own binding may take it.
    ignored,
    // Tab: the owner works out the choices and offers them.
    complete,
    // Ctrl-R at the shell's prompt: the owner searches the history from the line.
    search_history,
  };

  // The choices Tab offered, over the word they would replace, in the memory of region `a`.
  struct Menu {
    static constexpr std::size_t capacity = 256;

    explicit Menu(tbc::mut_a<Memory> memory);

    tbc::val_a<Choices> choices;
    std::size_t selected = 0;
    std::size_t begin = 0;
    std::size_t end = 0;
    // Requests to the runtime whose answers join the choices.
    tbc::val_a<ds::Vec<std::uint64_t, Memory>> requests;
    shell::Dialect dialect = shell::Dialect::posix;
    // What the choices are, for the menu's heading: "commands", "branches · git".
    tbc::val_a<ds::String<Memory>> label;
    // Every choice offered for the word, and the cursor it was offered at: typing narrows them
    // down; erasing past that cursor asks for them again.
    tbc::val_a<Choices> all;
    std::size_t floor = 0;
    // Every choice for the word arrived: a cut list asks again as typing narrows it.
    bool whole = true;
    // Refined by typing: a single choice left is not written for the user.
    bool refined = false;
  };

}
