module telar.gui.features.explorer;

import std;

import telar.base.memory.containers;
import telar.base.ds;
import telar.config.client;
import telar.gui.foundation.keys;

namespace telar::gui::features::explorer {

  namespace {

    struct Binding {
      std::string_view keys;
      Command command = Command::none;
      // Whether the key after the sequence is the command's argument, as the letter of a mark.
      bool argument = false;
    };

    constexpr Binding bind(std::string_view keys, Command command, bool argument = false) noexcept {
      return {.keys = keys, .command = command, .argument = argument};
    }

    // The keys of normal mode. A sequence is never the start of another one.
    constexpr ds::Array normal{
        bind("j", Command::down),
        bind("k", Command::up),
        bind("gg", Command::top),
        bind("G", Command::bottom),
        bind("<C-d>", Command::half_page_down),
        bind("<C-u>", Command::half_page_up),
        bind("h", Command::collapse),
        bind("l", Command::expand),
        bind("za", Command::toggle_fold),
        bind("zM", Command::fold_all),
        bind("zR", Command::unfold_all),
        bind("]c", Command::next_change),
        bind("[c", Command::previous_change),
        bind("<CR>", Command::enter),
        bind("-", Command::parent),
        bind("_", Command::workspace_root),
        bind("~", Command::home),
        bind("gp", Command::scope_pane),
        bind("gw", Command::scope_workspace),
        bind("gh", Command::scope_machine),
        bind("m", Command::mark, true),
        bind("'", Command::jump_to_mark, true),
        bind("<C-o>", Command::jump_back),
        bind("<C-i>", Command::jump_forward),
        bind("<Tab>", Command::jump_forward),
        bind("gt", Command::next_lens),
        bind("gT", Command::previous_lens),
        bind("cw", Command::rename),
        bind("cc", Command::rename_whole),
        bind("i", Command::rename),
        bind("a", Command::rename),
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
    };

    // The keys of visual mode: the motions, and the commands a selection takes.
    constexpr ds::Array visual_keys{
        bind("j", Command::down),
        bind("k", Command::up),
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
      result.assign(named(chord.key));
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

  void clear(Keys& keys) noexcept {
    keys.pending = {};
    keys.count = 0;
    keys.counted = false;
  }

  Stroke feed(Keys& keys, KeyChord chord, bool visual) {
    constexpr std::uint32_t decimal = 10;
    constexpr std::uint32_t largest_count = 100000;
    const auto key = notation(chord);
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

    const std::span<const Binding> bindings = visual ? std::span<const Binding>{visual_keys.view()} : std::span<const Binding>{normal.view()};
    const auto held = keys.pending.view();

    // The key after a command that takes an argument is that argument.
    for (const auto& binding : bindings) {
      if (binding.argument && binding.keys == held) {
        Stroke stroke{.command = binding.command, .count = keys.counted ? keys.count : 1, .counted = keys.counted, .argument = key};

        clear(keys);
        return stroke;
      }
    }

    append(keys.pending, text);

    const auto sequence = keys.pending.view();
    bool starts_longer = false;

    for (const auto& binding : bindings) {
      if (binding.keys == sequence && !binding.argument) {
        Stroke stroke{.command = binding.command, .count = keys.counted ? keys.count : 1, .counted = keys.counted};

        clear(keys);
        return stroke;
      }

      starts_longer = starts_longer || (binding.keys.starts_with(sequence) && (binding.argument || binding.keys.size() > sequence.size()));
    }

    if (!starts_longer) {
      clear(keys);
    }

    return {};
  }

  std::string_view keysOf(Command command) noexcept {
    for (const auto& binding : normal) {
      if (binding.command == command) {
        return binding.keys;
      }
    }

    return {};
  }

}
