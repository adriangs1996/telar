module telar.gui.features.explorer;

import std;

import telar.base.memory.containers;
import telar.base.ds;
import telar.config.client;
import telar.gui.foundation.keys;
import telar.tbc;

namespace telar::gui::features::explorer {

  namespace {

    // A default key: its sequence, and the command it names.
    struct Default {
      std::string_view keys;
      Command command = Command::none;
    };

    constexpr Default bind(std::string_view keys, Command command) noexcept {
      return {.keys = keys, .command = command};
    }

    // Whether the key after a command's sequence is its argument, as the letter of a mark.
    constexpr bool takesArgument(Command command) noexcept {
      return command == Command::mark || command == Command::jump_to_mark;
    }

    // The keys of normal mode. A sequence is never the start of another one.
    constexpr ds::Array normal_keys{
        bind("j", Command::down),
        bind("k", Command::up),
        bind("<C-n>", Command::down),
        bind("<C-p>", Command::up),
        bind("gg", Command::top),
        bind("G", Command::bottom),
        bind("<C-d>", Command::half_page_down),
        bind("<C-u>", Command::half_page_up),
        bind("h", Command::collapse),
        bind("l", Command::expand),
        bind("za", Command::toggle_fold),
        bind("zo", Command::unfold),
        bind("zc", Command::fold),
        bind("zM", Command::fold_all),
        bind("zR", Command::unfold_all),
        bind("]c", Command::next_change),
        bind("[c", Command::previous_change),
        bind("]a", Command::next_touch),
        bind("[a", Command::previous_touch),
        bind("<CR>", Command::enter),
        bind("-", Command::parent),
        bind("<BS>", Command::parent),
        bind("_", Command::workspace_root),
        bind("~", Command::home),
        bind("gp", Command::scope_pane),
        bind("gw", Command::scope_workspace),
        bind("gh", Command::scope_machine),
        bind("gm", Command::next_machine),
        bind("m", Command::mark),
        bind("'", Command::jump_to_mark),
        bind("`", Command::jump_to_mark),
        bind("<C-o>", Command::jump_back),
        bind("<C-i>", Command::jump_forward),
        bind("<Tab>", Command::jump_forward),
        bind("gt", Command::next_lens),
        bind("gT", Command::previous_lens),
        bind("cw", Command::rename),
        bind("cc", Command::rename_whole),
        bind("i", Command::rename_start),
        bind("I", Command::rename_start),
        bind("a", Command::rename_end),
        bind("A", Command::rename_end),
        bind("o", Command::create),
        bind("O", Command::create),
        bind("dd", Command::cut),
        bind("<Del>", Command::cut),
        bind("yy", Command::yank),
        bind("yr", Command::yank_relative),
        bind("yn", Command::yank_name),
        bind("p", Command::paste),
        bind("P", Command::paste),
        bind("u", Command::undo),
        bind("<C-w>v", Command::split_vertical),
        bind("<C-w>s", Command::split_horizontal),
        bind("<C-w>w", Command::next_window),
        bind("<C-w><C-w>", Command::next_window),
        bind("<C-w>W", Command::previous_window),
        bind("<C-w>h", Command::window_left),
        bind("<C-w>l", Command::window_right),
        bind("<C-w>k", Command::window_up),
        bind("<C-w>j", Command::window_down),
        bind("<C-w>q", Command::close_window),
        bind("<C-w>c", Command::close_window),
        bind("<C-w>o", Command::only_window),
        bind("<C-w>T", Command::pin),
        bind("gf", Command::open),
        bind("cd", Command::change_directory),
        bind("s", Command::split_shell),
        bind("@", Command::mention),
        bind(".", Command::repeat),
        bind("=", Command::toggle_diff),
        bind("ga", Command::stage),
        bind("gu", Command::unstage),
        bind("gX", Command::discard),
        bind("gc", Command::commit),
        bind("S", Command::cycle_sort),
        bind("g.", Command::toggle_hidden),
        bind("gi", Command::toggle_ignored),
        bind("R", Command::refresh),
        bind("F", Command::toggle_follow),
        bind("V", Command::visual),
        bind("/", Command::search),
        bind("n", Command::next_match),
        bind("N", Command::previous_match),
        bind(":", Command::command_line),
        bind("?", Command::help),
        bind("q", Command::quit),
        bind("<Esc>", Command::escape),
        // The shortcuts of every file manager name the same commands.
        bind("<D-c>", Command::yank),
        bind("<D-x>", Command::cut),
        bind("<D-v>", Command::paste),
        bind("<D-z>", Command::undo),
        bind("<D-s>", Command::write),
        bind("<D-a>", Command::select_all),
        // And with Control, where that is the key a system gives its shortcuts.
        bind("<C-c>", Command::yank),
        bind("<C-x>", Command::cut),
        bind("<C-v>", Command::paste),
        bind("<C-z>", Command::undo),
        bind("<C-s>", Command::write),
        bind("<C-a>", Command::select_all),
    };

    // The keys of visual mode: the motions, and the commands a selection takes.
    constexpr ds::Array visual_keys{
        bind("j", Command::down),
        bind("k", Command::up),
        bind("<C-n>", Command::down),
        bind("<C-p>", Command::up),
        bind("gg", Command::top),
        bind("G", Command::bottom),
        bind("<C-d>", Command::half_page_down),
        bind("<C-u>", Command::half_page_up),
        bind("y", Command::yank),
        bind("d", Command::cut),
        bind("<Del>", Command::cut),
        bind("<CR>", Command::enter),
        bind("@", Command::mention),
        bind("gf", Command::open),
        bind("ga", Command::stage),
        bind("gu", Command::unstage),
        bind("gX", Command::discard),
        bind("=", Command::toggle_diff),
        bind("V", Command::escape),
        bind("<Esc>", Command::escape),
        bind("q", Command::escape),
        bind("<D-c>", Command::yank),
        bind("<D-x>", Command::cut),
        bind("<C-c>", Command::yank),
        bind("<C-x>", Command::cut),
    };

    constexpr std::string_view named(KeyChord::Key key) noexcept {
      using Key = KeyChord::Key;

      switch (key) {
      case Key::up:
        return "k";
      case Key::down:
        return "j";
      case Key::left:
        return "h";
      case Key::right:
        return "l";
      case Key::home:
        return "gg";
      case Key::end:
        return "G";
      case Key::erase:
        return "<Del>";
      case Key::page_up:
        return "<C-u>";
      case Key::page_down:
        return "<C-d>";
      case Key::enter:
        return "<CR>";
      case Key::escape:
        return "<Esc>";
      case Key::backspace:
        return "<BS>";
      case Key::tab:
        return "<Tab>";
      case Key::back_tab:
        return "<S-Tab>";
      case Key::character:
        break;
      }

      return {};
    }

    void append(runtime::FixedText<pending_bytes>& pending, std::string_view text) {
      ds::Array<char, pending_bytes> joined{};
      const auto held = pending.view();
      if (held.size() + text.size() > joined.size()) {
        pending.assign({});
        return;
      }

      std::ranges::copy(held, joined.viewMut().begin());
      std::ranges::copy(text, joined.viewMut().subspan(held.size()).begin());
      pending.assign({joined.data(), held.size() + text.size()});
    }

    // The letter Neovim writes for the modifier of a chord, or NUL for a key pressed alone.
    constexpr char modifierOf(KeyChord chord) noexcept {
      using Modifier = KeyChord::Modifier;

      if (chord.has(Modifier::control)) {
        return 'C';
      }

      if (chord.has(Modifier::super)) {
        return 'D';
      }

      return chord.has(Modifier::alt) ? 'M' : '\0';
    }

  }

  Notation notation(KeyChord chord) {
    Notation result;

    if (chord.key != KeyChord::Key::character) {
      // Command with the key that erases is the Del of a keyboard that has none.
      const bool erases = chord.key == KeyChord::Key::backspace && chord.has(KeyChord::Modifier::super);

      result.assign(erases ? named(KeyChord::Key::erase) : named(chord.key));
      return result;
    }

    const auto scalar = KeyCharacter::text(chord.character);
    const auto text = scalar.view();
    if (text.empty()) {
      return result;
    }

    const char modifier = modifierOf(chord);
    if (modifier == '\0') {
      result.assign(text == "<" ? std::string_view{"<lt>"} : text);
      return result;
    }

    // `<C-w>`.
    ds::Array<char, notation_bytes> spelled{'<', modifier, '-'};
    constexpr std::size_t prefix = 3;
    if (prefix + text.size() + 1 > spelled.size()) {
      return result;
    }

    std::ranges::copy(text, spelled.viewMut().subspan(prefix).begin());
    spelled.atMut(prefix + text.size()) = '>';
    result.assign({spelled.data(), prefix + text.size() + 1});
    return result;
  }

  namespace {

    // The keys of a mode.
    tbc::val_a<std::span<const Binding>> of(tbc::ref_a<Keymap> keymap, bool visual) noexcept {
      return visual ? keymap.visual.view().first(keymap.visual_count) : keymap.normal.view().first(keymap.normal_count);
    }

    constexpr std::string_view alt_window = "<M-w>";
    constexpr std::string_view control_window = "<C-w>";

    // Whether a sequence of the map starts with `keys`.
    bool startsAny(std::span<const Binding> bindings, std::string_view keys) noexcept {
      return std::ranges::any_of(bindings, [&](const Binding& binding) {
        return binding.keys.view().starts_with(keys);
      });
    }

    void fill(std::span<Binding> bindings, std::size_t& count, std::span<const Default> defaults) {
      count = 0;
      for (const auto& known : defaults) {
        auto& binding = bindings[count++];

        binding.keys.assign(known.keys);
        binding.command = known.command;
        binding.argument = takesArgument(known.command);
      }
    }

    // One change of the configuration: the sequence leaves the map with the ones it starts and
    // the ones that start it, and comes back first when it names a command.
    void change(std::span<Binding> bindings, std::size_t& count, const runtime::config::ExplorerKey& key) noexcept {
      const auto sequence = key.keys.view();
      const bool bound = key.command != Command::none;
      std::size_t kept = 0;

      for (std::size_t index = 0; index < count; ++index) {
        const auto held = bindings[index].keys.view();
        const bool clashes = bound && (held.starts_with(sequence) || sequence.starts_with(held));
        if (held == sequence || clashes) {
          continue;
        }

        if (kept != index) {
          bindings[kept] = bindings[index];
        }

        ++kept;
      }

      count = kept;
      if (!bound || count == bindings.size()) {
        return;
      }

      std::ranges::move_backward(bindings.first(count), bindings.begin() + static_cast<std::ptrdiff_t>(count) + 1);
      bindings.front() = {.keys = key.keys, .command = key.command, .argument = takesArgument(key.command)};
      ++count;
    }

  }

  Keymap::Keymap() {
    fill(normal.viewMut(), normal_count, normal_keys.view());
    fill(visual.viewMut(), visual_count, visual_keys.view());
  }

  bool rebind(Keymap& keymap, const ExplorerKeys& changes) {
    if (keymap.changes == changes) {
      return false;
    }

    fill(keymap.normal.viewMut(), keymap.normal_count, normal_keys.view());
    fill(keymap.visual.viewMut(), keymap.visual_count, visual_keys.view());
    for (const auto& key : changes.view()) {
      if (key.visual) {
        change(keymap.visual.viewMut(), keymap.visual_count, key);
      } else {
        change(keymap.normal.viewMut(), keymap.normal_count, key);
      }
    }

    keymap.changes = changes;
    return true;
  }

  void clear(Keys& keys) noexcept {
    keys.pending = {};
    keys.count = 0;
    keys.counted = false;
  }

  namespace {

    // The keys of the mode the keys are read in, and the ones it borrows where it has none.
    struct Maps {
      std::span<const Binding> own;
      std::span<const Binding> lent;
    };

    // The binding whose sequence is `keys`, of the mode's own first: one that takes an argument,
    // or one that takes none, as `argument` asks. And whether it was borrowed.
    struct Named {
      const Binding* binding = nullptr;
      bool borrowed = false;
    };

    tbc::val_a<Named> named(tbc::val_a<Maps> maps, std::string_view keys, bool argument) noexcept {
      for (const auto& binding : maps.own) {
        if (binding.argument == argument && binding.keys.view() == keys) {
          return {.binding = &binding};
        }
      }

      for (const auto& binding : maps.lent) {
        if (binding.argument == argument && binding.keys.view() == keys) {
          return {.binding = &binding, .borrowed = true};
        }
      }

      return {};
    }

    // Whether a sequence of `bindings` goes on from `keys`: a longer one, or one that takes an
    // argument after them.
    bool startsLonger(std::span<const Binding> bindings, std::string_view keys) noexcept {
      return std::ranges::any_of(bindings, [&](const Binding& binding) {
        return binding.keys.view().starts_with(keys) && (binding.argument || binding.keys.view().size() > keys.size());
      });
    }

  }

  Stroke feed(const Keymap& keymap, Keys& keys, KeyChord chord, bool visual) {
    constexpr std::uint32_t decimal = 10;
    constexpr std::uint32_t largest_count = 100000;
    const auto bindings = of(keymap, visual);
    // A selection takes the keys of normal mode that it has none of its own for.
    const auto lent = visual ? of(keymap, false) : std::span<const Binding>{};
    auto key = notation(chord);

    // Alt+w stands for Ctrl+w, which some systems keep for themselves, unless the map binds it.
    if (key.view() == alt_window && !startsAny(bindings, alt_window) && !startsAny(lent, alt_window)) {
      key.assign(control_window);
    }

    const auto text = key.view();
    if (text.empty()) {
      return {};
    }

    // A digit is part of the count, unless a sequence has started; a count never starts with 0.
    if (keys.pending.view().empty() && text.size() == 1 && text.front() >= '0' && text.front() <= '9' && (keys.counted || text.front() != '0')) {
      keys.count = std::min(largest_count, (keys.count * decimal) + static_cast<std::uint32_t>(text.front() - '0'));
      keys.counted = true;
      return {};
    }

    const auto held = keys.pending.view();

    // The key after a command that takes an argument is that argument.
    if (const auto taker = named({.own = bindings, .lent = lent}, held, true); taker.binding != nullptr) {
      Stroke stroke{.command = taker.binding->command, .count = keys.counted ? keys.count : 1, .counted = keys.counted, .argument = key, .borrowed = taker.borrowed};

      clear(keys);
      return stroke;
    }

    append(keys.pending, text);

    const auto sequence = keys.pending.view();

    if (const auto whole = named({.own = bindings, .lent = lent}, sequence, false); whole.binding != nullptr) {
      Stroke stroke{.command = whole.binding->command, .count = keys.counted ? keys.count : 1, .counted = keys.counted, .borrowed = whole.borrowed};

      clear(keys);
      return stroke;
    }

    Stroke nothing;

    if (!startsLonger(bindings, sequence) && !startsLonger(lent, sequence)) {
      nothing.unknown = keys.pending;
      clear(keys);
    }

    return nothing;
  }

  tbc::val_a<std::string_view> keysOf(tbc::ref_a<Keymap> keymap, Command command, bool visual) noexcept {
    for (const auto& binding : of(keymap, visual)) {
      if (binding.command == command) {
        return binding.keys.view();
      }
    }

    return {};
  }

  bool names(const Keymap& keymap, std::string_view keys, Command command, bool visual) noexcept {
    return std::ranges::any_of(of(keymap, visual), [&](const Binding& binding) {
      return binding.command == command && binding.keys.view() == keys;
    });
  }

}
