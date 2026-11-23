// The explorer's keys, with Neovim's grammar: a count, then a sequence of one or more keys that
// names a command, some of which take one more key as their argument.
export module telar.gui.features.explorer:keys;

import std;

import telar.base.memory.containers;
import telar.base.ds;
import telar.config.client;
import telar.tbc;

export namespace telar::gui::features::explorer {

  using runtime::config::ExplorerKeys;
  using runtime::config::KeyChord;

  // The commands of the explorer are named where the configuration reads them, which binds keys
  // to them by name.
  using Command = runtime::config::ExplorerCommand;

  // The text of a key in Neovim's notation: `j`, `G`, `<C-w>`, `<CR>`.
  inline constexpr std::size_t notation_bytes = 16;
  using Notation = runtime::FixedText<notation_bytes>;

  // What Neovim calls the key; empty for one the explorer has no name for. An arrow reads as the
  // letter that moves the same way, and a page key as the half page.
  [[nodiscard]] Notation notation(KeyChord chord);

  // The keys typed toward a command: the count, and the sequence so far.
  inline constexpr std::size_t pending_bytes = runtime::config::explorer_keys_bytes;

  struct Keys {
    runtime::FixedText<pending_bytes> pending;
    std::uint32_t count = 0;
    bool counted = false;
  };

  // A command the keys named: with the count typed before it, 1 when none was, and for the
  // commands that take one, the key that follows them.
  struct Stroke {
    Command command = Command::none;
    std::uint32_t count = 1;
    bool counted = false;
    Notation argument;
  };

  // A sequence of keys and the command it names.
  struct Binding {
    runtime::FixedText<pending_bytes> keys;
    Command command = Command::none;
    // Whether the key after the sequence is the command's argument, as the letter of a mark.
    bool argument = false;
  };

  // The keys of the explorer: the default ones, with the changes of the configuration. It is
  // built when the configuration loads, and a key that is typed only reads it. A sequence in it
  // is never the start of another one.
  struct Keymap {
    static constexpr std::size_t normal_capacity = 256;
    static constexpr std::size_t visual_capacity = 160;

    // The default keys.
    Keymap();

    ds::Array<Binding, normal_capacity> normal;
    std::size_t normal_count = 0;
    ds::Array<Binding, visual_capacity> visual;
    std::size_t visual_count = 0;
    // The changes it was built with.
    ExplorerKeys changes;
  };

  // Builds the map again when `changes` are others than the ones it was built with: the default
  // keys, then each change in its order. A sequence that is bound takes the place of the ones
  // it starts and of the ones that start it, and comes before the default ones of its command.
  // True when the map changed.
  bool rebind(Keymap& keymap, const ExplorerKeys& changes);

  // Takes one more key. A command when the keys so far name one, in `visual` among the ones a
  // selection takes; none while they start a longer sequence or name nothing, which forgets them.
  [[nodiscard]] Stroke feed(const Keymap& keymap, Keys& keys, KeyChord chord, bool visual);

  // Forgets the keys typed so far.
  void clear(Keys& keys) noexcept;

  // The first sequence that names `command`, for the hints, the menu and the help: the one the
  // configuration bound, before the default ones. Empty for a command no key names.
  [[nodiscard]] tbc::val_a<std::string_view> keysOf(tbc::ref_a<Keymap> keymap, Command command, bool visual = false) noexcept;

  // Whether the sequence `keys` names `command`.
  [[nodiscard]] bool names(const Keymap& keymap, std::string_view keys, Command command, bool visual = false) noexcept;

}
