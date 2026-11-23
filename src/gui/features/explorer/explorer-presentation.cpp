module telar.gui.features.explorer;

import std;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.text.utf8;
import telar.base.ds;
import telar.tbc;
import telar.wire.files;

namespace telar::gui::features::explorer {

  namespace {

    template <std::size_t Capacity, typename... Arguments>
    void write(runtime::FixedText<Capacity>& text, std::format_string<Arguments...> format, Arguments&&... arguments) {
      ds::Array<char, Capacity> buffer{};
      const auto result = std::format_to_n(buffer.viewMut().begin(), static_cast<std::ptrdiff_t>(Capacity), format, std::forward<Arguments>(arguments)...);
      const auto size = std::min<std::size_t>(static_cast<std::size_t>(result.size), Capacity);

      text.assign(runtime::utf8Prefix(std::string_view{buffer.data(), size}, size));
    }

    template <std::size_t Capacity>
    void put(runtime::FixedText<Capacity>& text, std::string_view value) {
      text.assign(runtime::utf8Prefix(value, Capacity));
    }

    // Whether a shell takes the text as one word, as it is.
    constexpr bool plain(std::string_view text) noexcept {
      return !text.empty() && std::ranges::all_of(text, [](char character) {
        return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || std::string_view{"_@%+=:,./~-"}.contains(character);
      });
    }

    void appendQuoted(ds::String<Memory>& text, std::string_view word) {
      text.push('\'');
      for (const char character : word) {
        if (character == '\'') {
          text.append(R"('\'')");
        } else {
          text.push(character);
        }
      }

      text.push('\'');
    }

    // The components `path` and `directory` share from their start.
    constexpr std::size_t sharedPrefix(std::string_view path, std::string_view directory) noexcept {
      std::size_t shared = 0;

      for (std::size_t index = 0;; ++index) {
        const bool path_ends = index == path.size() || path[index] == '/';
        const bool directory_ends = index == directory.size() || directory[index] == '/';

        if (path_ends && directory_ends) {
          shared = index;
        }

        if (index == path.size() || index == directory.size() || path[index] != directory[index]) {
          return shared;
        }
      }
    }

    constexpr std::string_view stateText(FileState staged, FileState unstaged, bool ignored) noexcept {
      if (ignored) {
        return "ignored";
      }

      if (staged == FileState::conflicted || unstaged == FileState::conflicted) {
        return "in conflict";
      }

      if (unstaged == FileState::untracked) {
        return "untracked";
      }

      if (staged != FileState::unchanged && unstaged != FileState::unchanged) {
        return "staged, and changed again";
      }

      switch (staged) {
      case FileState::added:
        return "new, staged";
      case FileState::deleted:
        return "deleted, staged";
      case FileState::renamed:
        return "renamed, staged";
      case FileState::modified:
        return "modified, staged";
      default:
        break;
      }

      switch (unstaged) {
      case FileState::deleted:
        return "deleted, not staged";
      case FileState::modified:
        return "modified, not staged";
      default:
        return "committed";
      }
    }

    // The panes whose shell is in `path`.
    template <typename Look>
    void notePanes(Look& look, const Context& context, std::string_view path) noexcept {
      for (const auto& pane : context.panes) {
        if (pane.kind != PaneKind::editor && pane.cwd == path && look.pane_count < look.panes.size()) {
          look.panes.atMut(look.pane_count++) = pane.number;
        }
      }
    }

    constexpr std::size_t countSelectable(const Window& window, std::size_t until) noexcept {
      std::size_t count = 0;

      for (std::size_t index = 0; index < until && index < window.rows.size(); ++index) {
        const auto kind = window.rows[index].kind;

        count += kind == RowKind::entry || kind == RowKind::added || kind == RowKind::change || kind == RowKind::pane ? 1 : 0;
      }

      return count;
    }

    const PaneFact* focusedPane(const Context& context) noexcept {
      const auto found = std::ranges::find(context.panes, context.focused, &PaneFact::id);

      return found == context.panes.end() ? nullptr : std::to_address(found);
    }

    void addHint(Hints& hints, Word keys, std::string_view label, bool enabled = true) {
      if (hints.count == hints.items.size()) {
        return;
      }

      auto& hint = hints.items.atMut(hints.count++);

      hint.keys = keys;
      put(hint.label, label);
      hint.enabled = enabled;
    }

  }

  ShortText bytes(std::uint64_t value) {
    constexpr std::string_view units = "BKMGT";
    constexpr double step = 1024;
    constexpr double one_decimal_below = 10;
    ShortText text;
    auto amount = static_cast<double>(value);
    std::size_t unit = 0;

    while (amount >= step && unit + 1 < units.size()) {
      amount /= step;
      ++unit;
    }

    if (unit == 0) {
      write(text, "{}B", value);
    } else if (amount < one_decimal_below) {
      write(text, "{:.1f}{}", amount, units[unit]);
    } else {
      write(text, "{}{}", static_cast<std::uint64_t>(std::llround(amount)), units[unit]);
    }

    return text;
  }

  ShortText age(std::uint64_t then, std::uint64_t now) {
    constexpr std::uint64_t minute = 60;
    constexpr std::uint64_t hour = 60 * minute;
    constexpr std::uint64_t day_seconds = 24 * hour;
    ShortText text;
    const auto elapsed = now > then ? now - then : 0;

    if (elapsed < hour) {
      write(text, "{} min", std::max<std::uint64_t>(1, (elapsed + minute / 2) / minute));
    } else if (elapsed < day_seconds) {
      write(text, "{} h", (elapsed + hour / 2) / hour);
    } else {
      write(text, "{} d", (elapsed + day_seconds / 2) / day_seconds);
    }

    return text;
  }

  ShortText day(std::uint64_t seconds) {
    ShortText text;
    const std::chrono::sys_seconds moment{std::chrono::seconds{seconds}};
    const std::chrono::year_month_day date{std::chrono::floor<std::chrono::days>(moment)};

    write(text, "{:04}-{:02}-{:02}", static_cast<int>(date.year()), static_cast<unsigned>(date.month()), static_cast<unsigned>(date.day()));
    return text;
  }

  tbc::val_a<std::string_view> withoutHome(tbc::val_a<std::string_view> path, std::string_view home, bool& shortened) noexcept {
    shortened = home.size() > 1 && within(path, home);
    return shortened ? path.substr(home.size()) : path;
  }

  std::string_view parentOf(std::string_view path) noexcept {
    const auto slash = path.find_last_of('/');

    return slash == 0 || slash == std::string_view::npos ? std::string_view{"/"} : path.substr(0, slash);
  }

  std::string_view baseOf(std::string_view path) noexcept {
    return path.substr(path.find_last_of('/') + 1);
  }

  bool within(std::string_view path, std::string_view directory) noexcept {
    if (directory == "/") {
      return path.starts_with('/');
    }

    return path.starts_with(directory) && (path.size() == directory.size() || path[directory.size()] == '/');
  }

  void appendTyped(ds::String<Memory>& text, std::string_view path, std::string_view cwd, std::string_view home, bool quote) {
    constexpr std::size_t nearest_levels = 2;
    ds::String<Memory> word{text.memory()};
    const auto shared = cwd.starts_with('/') ? sharedPrefix(path, cwd) : 0;
    const auto above = shared >= cwd.size() ? std::string_view{} : cwd.substr(shared);
    const auto levels = static_cast<std::size_t>(std::ranges::count(above, '/'));
    bool tilde = false;

    if (path == cwd) {
      word.assign(".");
    } else if (cwd.starts_with('/') && shared != 0 && levels <= nearest_levels) {
      // Relative: `..` for each directory up, then what is below what both share.
      for (std::size_t level = 0; level < levels; ++level) {
        word.append("../");
      }

      word.append(path.size() > shared ? path.substr(shared + 1) : std::string_view{});
      if (word.view().ends_with('/')) {
        word.truncate(word.size() - 1);
      }
    } else {
      const auto below = withoutHome(path, home, tilde);

      word.assign(below.starts_with('/') && tilde ? below.substr(1) : below);
    }

    if (tilde) {
      text.append(word.empty() ? std::string_view{"~"} : std::string_view{"~/"});
    }

    if (!quote || plain(word.view()) || word.empty()) {
      text.append(word.view());
    } else {
      appendQuoted(text, word.view());
    }
  }

  RowLook look(const View& view, const State& state, const Context& context, std::size_t window_index, std::size_t row_index) {
    RowLook result;

    if (window_index >= view.windows.size() || row_index >= view.windows[window_index]->rows.size()) {
      return result;
    }

    const auto& window = *view.windows[window_index];
    const auto& row = window.rows[row_index];

    result.kind = row.kind;
    result.depth = row.depth;
    result.tone = row.tone;
    result.directory = row.directory;
    result.expanded = row.expanded;
    result.selected = row_index == window.cursor;
    result.marked = window_index == view.current && (view.mode == Mode::visual || !window.picked.empty()) && chosen(view, window, row_index);
    put(result.name, nameOf(window, state, row));
    result.share = row.share;

    switch (row.kind) {
    case RowKind::entry: {
      if (row.holder >= state.directories.size() || row.entry >= state.directories[row.holder]->entries.size()) {
        return result;
      }

      const auto& directory = *state.directories[row.holder];
      const auto& entry = directory.entries[row.entry];
      ds::String<Memory> path{view.memory};

      pathOf(path, window, state, context, row);

      const auto held = standing(state.repository, path.view(), row.directory);

      result.staged = held.staged;
      result.unstaged = held.unstaged;
      result.below = held.below;
      result.ignored = held.ignored;
      result.lines_added = held.added;
      result.lines_removed = held.removed;
      result.measured = !row.directory || entry.measured || entry.kind != FileKind::directory;
      result.partial = row.directory && entry.measured && !entry.complete;
      if (result.measured && entry.kind != FileKind::link) {
        result.size = bytes(entry.size);
      }

      if (const auto* renamed = editOn(view, EditKind::rename, window.machine, path.view())) {
        result.renamed = true;
        put(result.name, renamed->name.view());
        write(result.note, "was {}", directory.name(entry));
      }

      const bool moved = std::ranges::any_of(view.edits, [&](const Edit& edit) {
        return edit.kind == EditKind::paste && edit.paste == PasteKind::move && edit.source_machine == window.machine && edit.source.view() == path.view();
      });

      if (moved || editOn(view, EditKind::remove, window.machine, path.view()) != nullptr) {
        result.removed = true;
        put(result.note, moved ? "moves" : "to the trash");
      } else if (editOn(view, EditKind::restore, window.machine, path.view()) != nullptr) {
        put(result.note, "git restore");
      }

      // The marks set on it, and the panes whose shell is in it.
      ds::Array<char, short_text_bytes> letters{};
      std::size_t length = 0;

      for (const auto& mark : view.marks) {
        const auto place = mark.selected.empty() ? mark.root.view() : mark.selected.view();
        if (mark.machine == window.machine && place == path.view() && length + 2 < letters.size()) {
          letters.atMut(length++) = '\'';
          letters.atMut(length++) = mark.letter.view().front();
        }
      }

      result.marks.assign({letters.data(), length});
      if (row.directory) {
        notePanes(result, context, path.view());
      }

      break;
    }
    case RowKind::added: {
      result.added = true;
      if (const auto* edit = editOf(view, row)) {
        put(result.name, edit->name.view());
        if (edit->kind == EditKind::paste) {
          bool tilde = false;
          const auto source = withoutHome(edit->source.view(), context.home, tilde);

          write(result.note, "{} {}{}", edit->paste == PasteKind::move ? "moved from" : "copy of", tilde ? "~" : "", source);
          result.size = bytes(edit->size);
        } else {
          put(result.note, edit->directory ? "new directory" : "new file");
        }
      }

      break;
    }
    case RowKind::change:
      if (row.item < state.repository.changes.size()) {
        const auto& change = state.repository.changes[row.item];
        auto path = nameOf(window, state, row);

        // A directory's path ends in a slash, which is no part of its name.
        if (path.ends_with('/')) {
          path.remove_suffix(1);
        }

        const auto slash = path.find_last_of('/');

        if (slash != std::string_view::npos) {
          put(result.lead, path.substr(0, slash + 1));
        }

        put(result.name, slash == std::string_view::npos ? path : path.substr(slash + 1));
        result.staged = change.staged;
        result.unstaged = change.unstaged;
        result.lines_added = change.added;
        result.lines_removed = change.removed;
      }

      break;
    case RowKind::pane:
      if (row.item < context.panes.size()) {
        const auto& pane = context.panes[row.item];

        put(result.name, pane.title);
        result.panes.atMut(0) = pane.number;
        result.pane_count = 1;
        put(result.note, pane.cwd);
      }

      break;
    case RowKind::header:
    case RowKind::note:
    case RowKind::diff:
      break;
    }

    return result;
  }

  HeaderLook header(const View& view, const State& state, const Context& context, std::size_t window_index) {
    HeaderLook result;

    if (window_index >= view.windows.size()) {
      return result;
    }

    const auto& window = *view.windows[window_index];
    const auto root = window.root.view();
    bool tilde = false;
    const auto below = withoutHome(root, context.home, tilde);
    const auto last = baseOf(below);

    put(result.machine, context.machine);
    result.local = context.local;
    put(result.last, last);
    write(result.lead, "{}{}", tilde ? "~" : "", below.substr(0, below.size() - last.size()));
    result.repository = state.repository.known && !state.repository.root.empty();
    put(result.branch, state.repository.branch.view());
    result.upstream = state.repository.upstream;
    result.ahead = state.repository.ahead;
    result.behind = state.repository.behind;
    result.staged = state.repository.staged;
    result.unstaged = state.repository.unstaged;
    result.untracked = state.repository.untracked;
    return result;
  }

  std::string_view modeText(Mode mode) noexcept {
    switch (mode) {
    case Mode::normal:
    case Mode::help:
    case Mode::plan:
      return "NORMAL";
    case Mode::visual:
      return "VISUAL";
    case Mode::insert:
      return "INSERT";
    case Mode::search:
      return "SEARCH";
    case Mode::command:
      return "COMMAND";
    }

    return {};
  }

  StatusLook status(const View& view, const State& state, const Context& context, std::size_t window_index) {
    static_cast<void>(state);

    StatusLook result;

    if (window_index >= view.windows.size()) {
      return result;
    }

    const auto& window = *view.windows[window_index];
    bool tilde = false;
    const auto below = withoutHome(window.root.view(), context.home, tilde);

    result.current = window_index == view.current;
    result.kind = result.current ? view.mode : Mode::normal;
    result.mode = modeText(result.kind);
    result.follows = window.follow;
    if (const auto* pane = focusedPane(context); window.follow && pane != nullptr) {
      write(result.following, "[{} {}]", pane->number, pane->title);
    } else {
      put(result.following, window.follow ? "[follow]" : "[fixed]");
    }

    write(result.root, "{}{}", tilde ? "~" : "", below);
    result.pending = !view.edits.empty();
    if (window.sort != Sort::name || window.hidden || window.ignored) {
      write(result.flags, "[{}{}{}]", window.sort == Sort::size ? "size↓" : window.sort == Sort::modified ? "time↓"
                                                                                                          : "name",
          window.hidden ? " ." : "",
          window.ignored ? " !" : "");
    }

    // What the root holds is known of the tree alone.
    if (window.lens == Lens::tree) {
      result.total = bytes(window.bytes);
    }

    if (result.current) {
      if (view.keys.counted) {
        write(result.keys, "{}{}", view.keys.count, view.keys.pending.view());
      } else {
        put(result.keys, view.keys.pending.view());
      }
    }

    const auto rows = range(view, window);

    for (std::size_t index = rows.first; index <= rows.last && index < window.rows.size() && (rows.visual || !window.picked.empty()); ++index) {
      result.chosen += chosen(view, window, index) ? 1 : 0;
    }

    result.count = static_cast<std::uint32_t>(countSelectable(window, window.rows.size()));
    result.position = result.count == 0 ? 0 : static_cast<std::uint32_t>(countSelectable(window, window.cursor) + 1);
    return result;
  }

  Hints hints(const View& view, const State& state, const Context& context) {
    Hints result;

    if (view.windows.empty()) {
      return result;
    }

    if (view.mode == Mode::plan) {
      addHint(result, "y", "apply");
      addHint(result, "n", "cancel");
      return result;
    }

    if (view.mode == Mode::visual) {
      addHint(result, "y", "copy");
      addHint(result, "d", "cut");
      addHint(result, "<CR>", "insert");
      addHint(result, "@", "mention");
      addHint(result, "ga", "stage");
      addHint(result, "gu", "unstage");
      addHint(result, "<Esc>", "leave");
      return result;
    }

    const auto& window = explorer::window(view);
    const auto* row = window.rows.empty() ? nullptr : &window.rows[window.cursor];
    const auto* pane = focusedPane(context);
    const bool entry = row != nullptr && (row->kind == RowKind::entry || row->kind == RowKind::change);
    LineText verb;

    static_cast<void>(state);
    if (row != nullptr && row->kind == RowKind::pane) {
      put(verb, "focus");
    } else if (row != nullptr && row->directory) {
      put(verb, "enter");
    } else if (pane != nullptr) {
      write(verb, "{} → {} {}", pane->kind == PaneKind::editor ? "open" : pane->kind == PaneKind::agent ? "mention"
                                                                                                        : "insert",
          pane->number,
          pane->title);
    } else {
      put(verb, "insert");
    }

    addHint(result, "<CR>", verb.view(), row != nullptr);
    if (!view.edits.empty()) {
      LineText pending;

      write(pending, "write {}", view.edits.size());
      addHint(result, ":w", pending.view());
      addHint(result, "u", "undo");
    }

    addHint(result, "cw", "rename", entry && window.lens == Lens::tree);
    addHint(result, "dd", "cut", entry);
    addHint(result, "yy", "copy", entry);
    addHint(result, "o", "new", window.lens == Lens::tree);
    addHint(result, "<C-w>v", "window");
    addHint(result, "=", "diff", entry && !row->directory);
    addHint(result, "ga", "stage", entry);
    addHint(result, "gu", "unstage", entry);

    LineText sort;

    write(sort, "sort: {}", window.sort == Sort::size ? "size" : window.sort == Sort::modified ? "time"
                                                                                               : "name");
    addHint(result, "S", sort.view());
    addHint(result, "g.", "dotfiles");
    addHint(result, "?", "help");
    return result;
  }

  ds::Array<LensLook, lens_count> lenses(const View& view, const State& state, const Context& context) {
    ds::Array<LensLook, lens_count> result{};
    const auto current = view.windows.empty() ? Lens::tree : explorer::window(view).lens;
    const auto changes = state.repository.staged + state.repository.unstaged + state.repository.untracked;

    result.atMut(0) = {.name = "tree", .current = current == Lens::tree};
    result.atMut(1) = {.name = "changes", .count = changes, .counted = state.repository.known && !state.repository.root.empty(), .current = current == Lens::changes};
    result.atMut(2) = {.name = "panes", .count = static_cast<std::uint32_t>(context.panes.size()), .counted = true, .current = current == Lens::panes};
    return result;
  }

  PreviewLook preview(const View& view, const State& state, const Context& context, std::uint64_t now_seconds) {
    PreviewLook result;

    if (view.windows.empty()) {
      return result;
    }

    const auto& window = explorer::window(view);
    if (window.rows.empty()) {
      return result;
    }

    const auto& row = window.rows[window.cursor];
    if (row.kind != RowKind::entry && row.kind != RowKind::change) {
      return result;
    }

    const auto path = window.selected.view();
    const auto fact = [&](Word label) -> Fact& {
      auto& added = result.facts.atMut(std::min(result.fact_count, result.facts.size() - 1));

      result.fact_count = std::min(result.fact_count + 1, result.facts.size());
      added = {};
      added.label = label;
      return added;
    };

    result.shown = true;
    result.directory = row.directory;
    put(result.name, baseOf(path));
    put(result.path, path);

    const auto held = standing(state.repository, path, row.directory);
    const auto* inspection = inspected(state, path);

    // What the listing knows before the runtime inspects the path.
    std::uint64_t size = 0;
    std::uint64_t modified = 0;
    bool measured = true;

    if (row.kind == RowKind::entry && row.holder < state.directories.size() && row.entry < state.directories[row.holder]->entries.size()) {
      const auto& entry = state.directories[row.holder]->entries[row.entry];

      size = entry.size;
      modified = entry.identity.modified_seconds;
      measured = !row.directory || entry.measured;
    } else if (inspection != nullptr) {
      size = inspection->size;
      modified = inspection->identity.modified_seconds;
    }

    if (measured) {
      auto& added = fact("Size");

      put(added.value, bytes(size).view());
      if (!row.directory) {
        write(added.detail, "{} B", size);
      }
    }

    if (modified != 0) {
      write(fact("Modified").value, "{} ago", age(modified, now_seconds).view());
    }

    if (state.repository.known && !state.repository.root.empty() && within(path, state.repository.root.view())) {
      auto& added = fact("Git");

      if (row.directory && held.below != 0) {
        write(added.value, "{} changed below", held.below);
      } else {
        put(added.value, stateText(held.staged, held.unstaged, held.ignored));
        added.added = held.added;
        added.removed = held.removed;
      }
    }

    if (inspection != nullptr && !inspection->commit.view().empty()) {
      constexpr std::size_t short_commit = 9;
      auto& added = fact("Last commit");

      write(added.value, "{} · {}", inspection->commit.view().substr(0, short_commit), day(inspection->committed_seconds).view());
      put(added.detail, inspection->subject.view());
    }

    if (inspection != nullptr && inspection->kind == FileKind::link && !inspection->target.empty()) {
      put(fact("Link to").value, inspection->target.view());
    }

    put(fact("Machine").value, context.machine);
    if (row.directory) {
      notePanes(result, context, path);
    }

    result.waiting = inspection == nullptr;
    if (inspection == nullptr || row.directory) {
      return result;
    }

    if (!inspection->diff.empty()) {
      result.title = "DIFF · = UNFOLDS IT IN THE LIST";
      result.diff = true;
    } else if (inspection->binary) {
      result.title = "BINARY FILE";
    } else if (!inspection->text.empty()) {
      result.title = inspection->truncated ? "HEAD OF THE FILE" : "CONTENTS";
    }

    return result;
  }

  tbc::val_a<std::string_view> previewText(const View& view, tbc::ref_a<State> state) noexcept {
    if (view.windows.empty()) {
      return {};
    }

    const auto& window = explorer::window(view);
    if (window.rows.empty() || window.rows[window.cursor].directory) {
      return {};
    }

    const auto* inspection = inspected(state, window.selected.view());
    if (inspection == nullptr) {
      return {};
    }

    return inspection->diff.empty() ? inspection->text.view() : inspection->diff.view();
  }

  std::string_view verbText(PlanVerb verb) noexcept {
    switch (verb) {
    case PlanVerb::create:
      return "CREATE";
    case PlanVerb::move:
      return "MOVE";
    case PlanVerb::copy:
      return "COPY";
    case PlanVerb::remove:
      return "DELETE";
    case PlanVerb::restore:
      return "RESTORE";
    case PlanVerb::stage:
      return "STAGE";
    case PlanVerb::unstage:
      return "UNSTAGE";
    }

    return {};
  }

  LineText outcomeText(const State& state) {
    LineText text;
    std::size_t applied = 0;
    std::size_t renamed = 0;
    std::size_t stale = 0;
    std::size_t missing = 0;
    std::size_t refused = 0;

    for (const auto& outcome : state.outcomes) {
      switch (outcome.outcome) {
      case FileOutcome::done:
        ++applied;
        break;
      case FileOutcome::renamed:
        ++applied;
        ++renamed;
        break;
      case FileOutcome::stale:
        ++stale;
        break;
      case FileOutcome::missing:
        ++missing;
        break;
      case FileOutcome::refused:
      case FileOutcome::failed:
        ++refused;
        break;
      }
    }

    ds::Array<char, line_text_bytes> buffer{};
    std::size_t length = 0;
    const auto append = [&](std::string_view part) {
      const auto taken = std::min(part.size(), buffer.size() - length);

      std::ranges::copy(part.substr(0, taken), buffer.viewMut().subspan(length).begin());
      length += taken;
    };

    const auto count = [&](std::size_t value, std::string_view what) {
      if (value != 0) {
        ShortText number;

        write(number, " · {} ", value);
        append(number.view());
        append(what);
      }
    };

    append(state.undone ? "taken back" : ":w");
    count(applied, state.undone ? "step" : "applied by the runtime");
    count(renamed, "under another name: the target existed");
    count(stale, "skipped: changed since it was listed");
    count(missing, "skipped: gone");
    count(refused, "refused");
    if (state.undoable) {
      append(" · u takes it back");
    }

    text.assign(runtime::utf8Prefix({buffer.data(), length}, line_text_bytes));
    return text;
  }

}
