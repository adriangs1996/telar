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

      if (staged == FileState::added) {
        return "new, staged";
      }

      if (staged == FileState::deleted) {
        return "deleted, staged";
      }

      if (staged == FileState::renamed) {
        return "renamed, staged";
      }

      if (staged == FileState::modified) {
        return "modified, staged";
      }

      if (unstaged == FileState::deleted) {
        return "deleted, not staged";
      }

      return unstaged == FileState::modified ? "modified, not staged" : "committed";
    }

    // The panes whose shell is in `path`.
    template <typename Look>
    void notePanes(Look& look, const Context& context, std::string_view path) noexcept {
      // The panes are of the machine the window shows: a directory of another one holds none.
      if (context.host != context.shown) {
        return;
      }

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

        count += kind == RowKind::entry || kind == RowKind::added || kind == RowKind::change || kind == RowKind::pane || kind == RowKind::match ? 1 : 0;
      }

      return count;
    }

    const PaneFact* focusedPane(const Context& context) noexcept {
      const auto found = std::ranges::find(context.panes, context.focused, &PaneFact::id);

      return found == context.panes.end() ? nullptr : std::to_address(found);
    }

    // What a hint says its keys do now, and whether they do it on the selected row.
    struct HintLabel {
      std::string_view text;
      bool enabled = true;
    };

    void addHint(Hints& hints, Word keys, const HintLabel& label) {
      if (hints.count == hints.items.size()) {
        return;
      }

      auto& hint = hints.items.atMut(hints.count++);

      hint.keys = keys;
      put(hint.label, label.text);
      hint.enabled = label.enabled;
    }

    constexpr std::string_view sortName(Sort sort) noexcept {
      switch (sort) {
      case Sort::name:
        return "name";
      case Sort::size:
        return "size";
      case Sort::modified:
        return "time";
      }

      return {};
    }

    // What Enter does with a file for a pane of `kind`.
    constexpr std::string_view handVerb(PaneKind kind) noexcept {
      switch (kind) {
      case PaneKind::editor:
        return "open";
      case PaneKind::agent:
        return "mention";
      case PaneKind::shell:
      case PaneKind::program:
        return "insert";
      }

      return {};
    }

    // A row being described, and what is known around it.
    struct Seen {
      const View& view;
      const State& state;
      const Context& context;
      const Window& window;
      const Row& row;
    };

    // What the changes typed take away of the entry at `path`.
    void noteRemoval(RowLook& look, const View& view, std::uint64_t machine, std::string_view path) {
      const bool moved = std::ranges::any_of(view.edits, [&](const Edit& edit) {
        return edit.kind == EditKind::paste && edit.paste == PasteKind::move && edit.source_machine == machine && edit.source.view() == path;
      });

      if (moved || editOn(view, EditKind::remove, machine, path) != nullptr) {
        look.removed = true;
        put(look.note, moved ? "moves" : "to the trash");
      } else if (editOn(view, EditKind::restore, machine, path) != nullptr) {
        put(look.note, "git restore");
      }
    }

    // The marks set on `path`, as Neovim writes them.
    void noteMarks(RowLook& look, const View& view, std::uint64_t machine, std::string_view path) {
      ds::Array<char, short_text_bytes> letters{};
      std::size_t length = 0;

      for (const auto& mark : view.marks) {
        const auto place = mark.selected.empty() ? mark.root.view() : mark.selected.view();
        if (mark.machine == machine && place == path && length + 2 < letters.size()) {
          letters.atMut(length++) = '\'';
          letters.atMut(length++) = mark.letter.view().front();
        }
      }

      look.marks.assign({letters.data(), length});
    }

    // How long ago a touch was, in the few characters a row has for it: `40s`, `6m`, `2h`, `3d`.
    ShortText since(std::uint64_t then, std::uint64_t now) {
      constexpr std::uint64_t minute = 60;
      constexpr std::uint64_t hour = 60 * minute;
      constexpr std::uint64_t day_seconds = 24 * hour;
      ShortText text;
      const auto elapsed = now > then ? now - then : 0;

      if (elapsed < minute) {
        write(text, "{}s", elapsed);
      } else if (elapsed < hour) {
        write(text, "{}m", elapsed / minute);
      } else if (elapsed < day_seconds) {
        write(text, "{}h", elapsed / hour);
      } else {
        write(text, "{}d", elapsed / day_seconds);
      }

      return text;
    }

    // The chip of the one a touch is by: `you` for the person, and for an agent the place in the
    // tab of its pane, which is how the status line names a pane too.
    ActorLook actorOf(const Touch& touch, const Context& context) {
      ActorLook look;

      if (touch.actor == TouchActor::user) {
        put(look.chip, "you");
        return look;
      }

      look.tone = touch.provider == AgentProvider::claude ? ActorTone::claude : ActorTone::agent;
      if (touch.provider == AgentProvider::codex) {
        look.tone = ActorTone::codex;
      }

      if (const auto pane = std::ranges::find(context.panes, touch.pane, &PaneFact::id); pane != context.panes.end()) {
        write(look.chip, "{}", pane->number);
      } else {
        put(look.chip, "·");
      }

      return look;
    }

    // The name a person knows the one a touch is by: themselves, or what the agent is called.
    std::string_view whoOf(const Touch& touch) noexcept {
      if (touch.actor == TouchActor::user) {
        return "You";
      }

      switch (touch.provider) {
      case AgentProvider::claude:
        return "Claude Code";
      case AgentProvider::codex:
        return "Codex";
      case AgentProvider::pi:
        return "Pi";
      case AgentProvider::cursor:
        return "Cursor";
      case AgentProvider::opencode:
        return "OpenCode";
      case AgentProvider::unknown:
      case AgentProvider::last_custom:
        return "Agent";
      }

      return "Agent";
    }

    // Who touched the file at `path`: one chip for each hand and pane, the last first.
    void noteActors(RowLook& look, const Seen& seen, std::string_view path) {
      const auto& touches = seen.state.touches;
      ds::Array<const Touch*, actor_capacity> shown{};

      for (const auto& touch : touches.items) {
        if (look.actor_count == look.actors.size()) {
          return;
        }

        const bool again = std::ranges::any_of(shown.view().first(look.actor_count), [&](const Touch* earlier) {
          return earlier->actor == touch.actor && earlier->pane == touch.pane;
        });

        if (!again && touches.path(touch) == path) {
          shown.atMut(look.actor_count) = &touch;
          look.actors.atMut(look.actor_count++) = actorOf(touch, seen.context);
        }
      }
    }

    // The last touches of the file at `path`, for its preview: the newest first.
    void noteActivity(PreviewLook& look, const State& state, const Context& context, std::string_view path) {
      for (const auto& touch : state.touches.items) {
        if (look.activity_count == look.activity.size()) {
          return;
        }

        if (state.touches.path(touch) != path) {
          continue;
        }

        auto& line = look.activity.atMut(look.activity_count++);

        line.actor = actorOf(touch, context);
        if (const auto pane = std::ranges::find(context.panes, touch.pane, &PaneFact::id); pane != context.panes.end()) {
          write(line.who, "{} · pane {}", whoOf(touch), pane->number);
        } else {
          put(line.who, whoOf(touch));
        }

        line.verb.assign(touch.verb.view());
        line.ago = since(touch.seconds, context.now);
      }
    }

    void entryLook(RowLook& look, const Seen& seen) {
      const auto& row = seen.row;
      if (row.holder >= seen.state.directories.size() || row.entry >= seen.state.directories[row.holder]->entries.size()) {
        return;
      }

      const auto& directory = *seen.state.directories[row.holder];
      const auto& entry = directory.entries[row.entry];
      const auto machine = seen.window.machine;
      ds::String<Memory> path{seen.view.memory};

      pathOf(path, seen.window, seen.state, seen.context, row);

      const auto held = standing(seen.state.repository, path.view(), row.directory);

      look.staged = held.staged;
      look.unstaged = held.unstaged;
      look.below = held.below;
      look.ignored = held.ignored;
      look.lines_added = held.added;
      look.lines_removed = held.removed;
      look.measured = !row.directory || entry.measured || entry.kind != FileKind::directory;
      look.partial = row.directory && entry.measured && !entry.complete;
      if (look.measured && entry.kind != FileKind::link) {
        look.size = bytes(entry.size);
      }

      if (const auto* renamed = editOn(seen.view, EditKind::rename, machine, path.view())) {
        look.renamed = true;
        put(look.name, renamed->name.view());
        write(look.note, "was {}", directory.name(entry));
      }

      noteRemoval(look, seen.view, machine, path.view());
      noteMarks(look, seen.view, machine, path.view());
      if (!row.directory) {
        noteActors(look, seen, path.view());
      }

      if (row.directory) {
        notePanes(look, seen.context, path.view());
      }
    }

    // How much of a transfer's file arrived, in thousandths.
    constexpr std::uint16_t shareOf(const Transfer& transfer) noexcept {
      constexpr std::uint64_t whole = 1000;

      return transfer.size == 0 ? 0 : static_cast<std::uint16_t>(std::min(whole, transfer.done * whole / transfer.size));
    }

    // What a transfer does now, or how it ended.
    constexpr Word phaseText(TransferPhase phase) noexcept {
      switch (phase) {
      case TransferPhase::waiting:
        return "waits";
      case TransferPhase::reading:
      case TransferPhase::writing:
        return "on the way";
      case TransferPhase::placing:
      case TransferPhase::trashing:
        return "arriving";
      case TransferPhase::dropping:
        return "stopping";
      case TransferPhase::arrived:
        return "arrived";
      case TransferPhase::failed:
        return "did not arrive";
      case TransferPhase::cancelled:
        return "cancelled";
      }

      return {};
    }

    void addedLook(RowLook& look, const Seen& seen) {
      look.added = true;

      const auto* edit = editOf(seen.view, seen.row);
      if (edit == nullptr) {
        // A file that arrives from another machine: how much of it did.
        if (const auto* transfer = transferOf(seen.view, seen.row)) {
          look.arriving = true;
          put(look.name, transfer->name.view());
          write(look.note, "arriving from {} · {} of {}", labelOf(seen.context, transfer->from), bytes(transfer->done).view(), bytes(transfer->size).view());
          look.size = bytes(transfer->done);
          look.share = shareOf(*transfer);
        }

        return;
      }

      put(look.name, edit->name.view());
      if (edit->kind != EditKind::paste) {
        put(look.note, edit->directory ? "new directory" : "new file");
        return;
      }

      bool tilde = false;
      const auto source = withoutHome(edit->source.view(), seen.context.home, tilde);

      write(look.note, "{} {}{}", edit->paste == PasteKind::move ? "moved from" : "copy of", tilde ? "~" : "", source);
      look.size = bytes(edit->size);
    }

    // A row of a flat list names a path from a root: what leads to its name, and its name.
    void putPath(RowLook& look, std::string_view path) {
      // A directory's path may end in a slash, which is no part of its name.
      if (path.ends_with('/')) {
        path.remove_suffix(1);
      }

      const auto slash = path.find_last_of('/');

      if (slash != std::string_view::npos) {
        put(look.lead, path.substr(0, slash + 1));
      }

      put(look.name, slash == std::string_view::npos ? path : path.substr(slash + 1));
    }

    // A path the filter found: what git says of it, and the changes typed on it, as of an entry.
    void matchLook(RowLook& look, const Seen& seen) {
      const auto& row = seen.row;
      const auto& search = seen.state.search;
      const auto machine = seen.window.machine;
      const auto relative = nameOf(seen.window, seen.state, row);
      ds::String<Memory> path{seen.view.memory};

      putPath(look, relative);
      pathOf(path, seen.window, seen.state, seen.context, row);

      const auto held = standing(seen.state.repository, path.view(), row.directory);

      look.staged = held.staged;
      look.unstaged = held.unstaged;
      look.below = held.below;
      look.ignored = held.ignored;
      look.lines_added = held.added;
      look.lines_removed = held.removed;
      const bool touch = seen.window.lens == Lens::touched;

      // Outside the repository the window asked about, the search still says what git holds.
      if (!touch && look.staged == FileState::unchanged && look.unstaged == FileState::unchanged && row.item < search.matches.size()) {
        look.unstaged = search.matches[row.item].state;
      }

      // A row of the touches says how its file was touched last, and how long ago.
      if (touch && row.item < seen.state.touches.items.size()) {
        const auto& last = seen.state.touches.items[row.item];

        look.verb.assign(last.verb.view());
        look.size = bytes(last.size);
        look.ago = since(last.seconds, seen.context.now);
      }

      noteActors(look, seen, path.view());

      if (const auto* renamed = editOn(seen.view, EditKind::rename, machine, path.view())) {
        look.renamed = true;
        put(look.name, renamed->name.view());
        write(look.note, "was {}", baseOf(relative));
      }

      noteRemoval(look, seen.view, machine, path.view());
      noteMarks(look, seen.view, machine, path.view());
      if (row.directory) {
        notePanes(look, seen.context, path.view());
      }
    }

    void changeLook(RowLook& look, const Seen& seen) {
      if (seen.row.item >= seen.state.repository.changes.size()) {
        return;
      }

      const auto& change = seen.state.repository.changes[seen.row.item];

      putPath(look, nameOf(seen.window, seen.state, seen.row));
      look.staged = change.staged;
      look.unstaged = change.unstaged;
      look.lines_added = change.added;
      look.lines_removed = change.removed;
    }

    void paneLook(RowLook& look, const Seen& seen) {
      if (seen.row.item >= seen.context.panes.size()) {
        return;
      }

      const auto& pane = seen.context.panes[seen.row.item];

      put(look.name, pane.title);
      look.panes.atMut(0) = pane.number;
      look.pane_count = 1;
      put(look.note, pane.cwd);
    }

    // `[size↓ . !]`: how the window sorts, and what it lists besides.
    void writeFlags(StatusLook& look, const Window& window) {
      if (window.sort == Sort::name && !window.hidden && !window.ignored) {
        return;
      }

      write(look.flags, "[{}{}{}{}]", sortName(window.sort), window.sort == Sort::name ? "" : "↓", window.hidden ? " ." : "", window.ignored ? " !" : "");
    }

    // The filter of a window and, where the runtime searches for it, how many paths it found.
    void writeFilter(StatusLook& look, const Window& window, const State& state) {
      if (window.filter.empty()) {
        return;
      }

      const auto& search = state.search;
      const auto query = queryOf(window);

      if (!window.matching || !search.of(window.root.view(), query)) {
        write(look.filter, "/{}", window.matching ? query : window.filter.view());
      } else if (!search.known) {
        write(look.filter, "/{} …", query);
      } else {
        write(look.filter, "/{} {}{}{}", query, search.matches.size(), search.truncated ? "+" : "", search.waiting != 0 ? " …" : "");
      }
    }

    // How many rows a selection holds; none while nothing is selected.
    std::uint32_t chosenRows(const View& view, const Window& window) noexcept {
      const auto rows = range(view, window);
      std::uint32_t count = 0;

      if (!rows.visual && window.picked.empty()) {
        return count;
      }

      for (std::size_t index = rows.first; index <= rows.last && index < window.rows.size(); ++index) {
        count += chosen(view, window, index) ? 1 : 0;
      }

      return count;
    }

    // The hints of a mode whose keys do not depend on the selected row; false for a mode whose
    // hints do.
    bool fixedHints(Hints& hints, Mode mode) {
      switch (mode) {
      case Mode::plan:
        addHint(hints, "y", {.text = "apply"});
        addHint(hints, "n", {.text = "cancel"});
        return true;
      case Mode::question:
        addHint(hints, "y", {.text = "bring a copy"});
        addHint(hints, "n", {.text = "leave it"});
        return true;
      case Mode::menu:
        addHint(hints, "j k", {.text = "move"});
        addHint(hints, "<CR>", {.text = "run"});
        addHint(hints, "<Esc>", {.text = "close"});
        return true;
      case Mode::visual:
        addHint(hints, "y", {.text = "copy"});
        addHint(hints, "d", {.text = "cut"});
        addHint(hints, "<CR>", {.text = "insert"});
        addHint(hints, "@", {.text = "mention"});
        addHint(hints, "ga", {.text = "stage"});
        addHint(hints, "gu", {.text = "unstage"});
        addHint(hints, "<Esc>", {.text = "leave"});
        return true;
      case Mode::search:
        addHint(hints, "<CR>", {.text = "keep the filter"});
        addHint(hints, "<Esc>", {.text = "drop it"});
        return true;
      case Mode::command:
        addHint(hints, ":w", {.text = "plan"});
        addHint(hints, ":e", {.text = "path"});
        addHint(hints, ":vs", {.text = "window"});
        addHint(hints, ":e LABEL:PATH", {.text = "another machine"});
        addHint(hints, ":machine", {.text = "list them"});
        addHint(hints, ":commit", {.text = "message"});
        addHint(hints, "<Tab>", {.text = "complete a path or a machine"});
        return true;
      case Mode::normal:
      case Mode::insert:
      case Mode::help:
        return false;
      }

      return false;
    }

    // What Enter does on the selected row, for the hint that says it.
    void writeEnter(LineText& verb, const Row* row, const PaneFact* pane) {
      if (row != nullptr && row->kind == RowKind::pane) {
        put(verb, "focus");
      } else if (row != nullptr && row->directory) {
        put(verb, "enter");
      } else if (pane != nullptr) {
        write(verb, "{} → {} {}", handVerb(pane->kind), pane->number, pane->title);
      } else {
        put(verb, "insert");
      }
    }

    // The keys a line of the menu teaches, and what it says while it needs no more than that.
    struct MenuText {
      MenuEntry entry = MenuEntry::rule;
      Word keys;
      Word label;
    };

    constexpr ds::Array<MenuText, 22> menu_texts{
        {
            {.entry = MenuEntry::rule, .keys = "", .label = ""},
            {.entry = MenuEntry::hand, .keys = "<CR>", .label = ""},
            {.entry = MenuEntry::open, .keys = "gf", .label = "Open in the editor"},
            {.entry = MenuEntry::mention, .keys = "@", .label = ""},
            {.entry = MenuEntry::rename, .keys = "cw", .label = "Rename"},
            {.entry = MenuEntry::new_file, .keys = "o", .label = "New file"},
            {.entry = MenuEntry::new_directory, .keys = "o …/", .label = "New directory"},
            {.entry = MenuEntry::cut, .keys = "dd", .label = "Cut"},
            {.entry = MenuEntry::copy, .keys = "yy", .label = "Copy"},
            {.entry = MenuEntry::paste, .keys = "p", .label = "Paste here"},
            {.entry = MenuEntry::copy_relative, .keys = "yr", .label = "Copy the relative path"},
            {.entry = MenuEntry::trash, .keys = "<Del>", .label = "Move to the trash"},
            {.entry = MenuEntry::shell_here, .keys = "s", .label = "Open a shell here"},
            {.entry = MenuEntry::change_directory, .keys = "cd", .label = ""},
            {.entry = MenuEntry::window_here, .keys = ":vs", .label = "Open in a new window"},
            {.entry = MenuEntry::diff, .keys = "=", .label = "Show the diff"},
            {.entry = MenuEntry::stage, .keys = "ga", .label = "Stage (git add)"},
            {.entry = MenuEntry::unstage, .keys = "gu", .label = "Unstage"},
            {.entry = MenuEntry::discard, .keys = "gX", .label = "Discard changes…"},
            {.entry = MenuEntry::new_window, .keys = "<C-w>v", .label = "New window"},
            {.entry = MenuEntry::drop_change, .keys = "dd", .label = "Remove from the changes"},
            {.entry = MenuEntry::write, .keys = ":w", .label = ""},
        },
    };

    // Whether a line's label counts the rows of the selection it acts on.
    constexpr bool countsRows(MenuEntry entry) noexcept {
      constexpr ds::Array<MenuEntry, 6> counted{MenuEntry::hand, MenuEntry::open, MenuEntry::mention, MenuEntry::cut, MenuEntry::copy, MenuEntry::trash};

      return std::ranges::contains(counted, entry);
    }

    // What a line says that depends on where the menu is: the pane a file goes to, the agent,
    // how many changes wait.
    void writeMenuLabel(LineText& label, const MenuText& text, const View& view, const Context& context) {
      const auto& window = explorer::window(view);
      const auto* row = window.rows.empty() ? nullptr : &window.rows[window.cursor];
      const auto* pane = focusedPane(context);

      switch (text.entry) {
      case MenuEntry::hand: {
        LineText verb;

        writeEnter(verb, row, pane);
        // The verbs are the explorer's own words, in lower case.
        constexpr char to_upper = 'A' - 'a';
        const auto first = verb.view().front();

        write(label, "{}{}", first >= 'a' && first <= 'z' ? static_cast<char>(first + to_upper) : first, verb.view().substr(1));
        break;
      }
      case MenuEntry::mention: {
        const auto agent = std::ranges::find(context.panes, PaneKind::agent, &PaneFact::kind);

        write(label, "Mention to {}", agent == context.panes.end() ? std::string_view{"the agent"} : agent->title);
        break;
      }
      case MenuEntry::change_directory:
        if (pane != nullptr) {
          write(label, "cd pane {} here", pane->number);
        } else {
          put(label, "cd the pane here");
        }

        break;
      case MenuEntry::write:
        write(label, "Apply {} change{}…", view.edits.size(), view.edits.size() == 1 ? "" : "s");
        break;
      case MenuEntry::rule:
      case MenuEntry::open:
      case MenuEntry::rename:
      case MenuEntry::new_file:
      case MenuEntry::new_directory:
      case MenuEntry::cut:
      case MenuEntry::copy:
      case MenuEntry::paste:
      case MenuEntry::copy_relative:
      case MenuEntry::trash:
      case MenuEntry::shell_here:
      case MenuEntry::window_here:
      case MenuEntry::diff:
      case MenuEntry::stage:
      case MenuEntry::unstage:
      case MenuEntry::discard:
      case MenuEntry::new_window:
      case MenuEntry::drop_change:
        put(label, text.label);
        break;
      }
    }

    tbc::mut_a<Fact> addFact(tbc::mut_a<PreviewLook> look, Word label) noexcept {
      auto& added = look.facts.atMut(std::min(look.fact_count, look.facts.size() - 1));

      look.fact_count = std::min(look.fact_count + 1, look.facts.size());
      added = {};
      added.label = label;
      return added;
    }

    // What is known of a row's size and age: what its listing says, else what its inspection does.
    struct Listed {
      std::uint64_t size = 0;
      std::uint64_t modified = 0;
      bool measured = true;
    };

    Listed listedOf(const State& state, const Row& row, const Inspection* inspection) noexcept {
      if (row.kind == RowKind::entry && row.holder < state.directories.size() && row.entry < state.directories[row.holder]->entries.size()) {
        const auto& entry = state.directories[row.holder]->entries[row.entry];

        return {.size = entry.size, .modified = entry.identity.modified_seconds, .measured = !row.directory || entry.measured};
      }

      if (inspection != nullptr) {
        return {.size = inspection->size, .modified = inspection->identity.modified_seconds};
      }

      return {};
    }

    void addListed(PreviewLook& look, const Listed& listed, std::uint64_t now_seconds) {
      if (listed.measured) {
        auto& added = addFact(look, "Size");

        put(added.value, bytes(listed.size).view());
        if (!look.directory) {
          write(added.detail, "{} B", listed.size);
        }
      }

      if (listed.modified != 0) {
        write(addFact(look, "Modified").value, "{} ago", age(listed.modified, now_seconds).view());
      }
    }

    void addGit(PreviewLook& look, const Repository& repository, std::string_view path) {
      if (!repository.known || repository.root.empty() || !within(path, repository.root.view())) {
        return;
      }

      const auto held = standing(repository, path, look.directory);
      auto& added = addFact(look, "Git");

      if (look.directory && held.below != 0) {
        write(added.value, "{} changed below", held.below);
        return;
      }

      put(added.value, stateText(held.staged, held.unstaged, held.ignored));
      added.added = held.added;
      added.removed = held.removed;
    }

    void addInspected(PreviewLook& look, const Inspection& inspection) {
      constexpr std::size_t short_commit = 9;

      if (!inspection.commit.view().empty()) {
        auto& added = addFact(look, "Last commit");

        write(added.value, "{} · {}", inspection.commit.view().substr(0, short_commit), day(inspection.committed_seconds).view());
        put(added.detail, inspection.subject.view());
      }

      if (inspection.kind == FileKind::link && !inspection.target.empty()) {
        put(addFact(look, "Link to").value, inspection.target.view());
      }
    }

    // The title over the text a preview shows of a file.
    Word titleOf(const Inspection& inspection) noexcept {
      if (!inspection.diff.empty()) {
        return "DIFF · = UNFOLDS IT IN THE LIST";
      }

      if (inspection.binary) {
        return "BINARY FILE";
      }

      if (inspection.text.empty()) {
        return {};
      }

      return inspection.truncated ? "HEAD OF THE FILE" : "CONTENTS";
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
      write(text, "{} min", std::max<std::uint64_t>(1, (elapsed + (minute / 2)) / minute));
    } else if (elapsed < day_seconds) {
      write(text, "{} h", (elapsed + (hour / 2)) / hour);
    } else {
      write(text, "{} d", (elapsed + (day_seconds / 2)) / day_seconds);
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
    if (shortened) {
      path.remove_prefix(home.size());
    }

    return path;
  }

  std::string_view parentOf(std::string_view path) noexcept {
    const auto slash = path.find_last_of('/');
    if (slash == 0 || slash == std::string_view::npos) {
      return "/";
    }

    path.remove_suffix(path.size() - slash);
    return path;
  }

  std::string_view baseOf(std::string_view path) noexcept {
    // With no slash this is the whole path: one past the end of none is zero.
    path.remove_prefix(path.find_last_of('/') + 1);
    return path;
  }

  bool within(std::string_view path, std::string_view directory) noexcept {
    if (directory == "/") {
      return path.starts_with('/');
    }

    return path.starts_with(directory) && (path.size() == directory.size() || path[directory.size()] == '/');
  }

  void appendTyped(ds::String<Memory>& text, std::string_view path, const Reader& reader) {
    constexpr std::size_t nearest_levels = 2;
    const auto cwd = reader.cwd;
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
      const auto below = withoutHome(path, reader.home, tilde);

      word.assign(below.starts_with('/') && tilde ? below.substr(1) : below);
    }

    if (tilde) {
      text.append(word.empty() ? std::string_view{"~"} : std::string_view{"~/"});
    }

    if (!reader.shell || plain(word.view()) || word.empty()) {
      text.append(word.view());
    } else {
      appendQuoted(text, word.view());
    }
  }

  RowLook look(const View& view, const State& state, const Context& context, const Pick& pick) {
    const auto window_index = pick.window;
    const auto row_index = pick.row;
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
    result.marked = window_index == view.current && (selecting(view) || !window.picked.empty()) && chosen(view, window, row_index);
    put(result.name, nameOf(window, state, row));
    result.share = row.share;

    const Seen seen{.view = view, .state = state, .context = context, .window = window, .row = row};

    switch (row.kind) {
    case RowKind::entry:
      entryLook(result, seen);
      break;
    case RowKind::added:
      addedLook(result, seen);
      break;
    case RowKind::change:
      changeLook(result, seen);
      break;
    case RowKind::pane:
      paneLook(result, seen);
      break;
    case RowKind::match:
      matchLook(result, seen);
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
    case Mode::menu:
    case Mode::question:
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
    StatusLook result;

    if (window_index >= view.windows.size()) {
      return result;
    }

    const auto& window = *view.windows[window_index];
    bool tilde = false;
    const auto below = withoutHome(window.root.view(), context.home, tilde);

    result.current = window_index == view.current;
    // A menu leaves the mode it shows over on the status line.
    result.kind = result.current ? view.mode : Mode::normal;
    if (result.kind == Mode::menu) {
      // A menu leaves the mode it shows over on the status line.
      result.kind = view.menu.over;
    }

    result.mode = modeText(result.kind);
    result.follows = window.follow;
    if (const auto* pane = focusedPane(context); window.follow && pane != nullptr) {
      write(result.following, "[{} {}]", pane->number, pane->title);
    } else {
      put(result.following, window.follow ? "[follow]" : "[fixed]");
    }

    write(result.root, "{}{}", tilde ? "~" : "", below);
    result.pending = !view.edits.empty();
    writeFlags(result, window);
    writeFilter(result, window, state);

    // What the root holds is known of the tree alone, not of what a filter found in it.
    if (window.lens == Lens::tree && !window.matching) {
      result.total = bytes(window.bytes);
    }

    if (result.current) {
      if (view.keys.counted) {
        write(result.keys, "{}{}", view.keys.count, view.keys.pending.view());
      } else {
        put(result.keys, view.keys.pending.view());
      }
    }

    result.carried = static_cast<std::uint32_t>(std::ranges::count_if(view.transfers, [&](const Transfer& transfer) {
      return !ended(transfer.phase) && (transfer.from == window.machine || transfer.to == window.machine);
    }));

    result.chosen = chosenRows(view, window);
    result.count = static_cast<std::uint32_t>(countSelectable(window, window.rows.size()));
    result.position = result.count == 0 ? 0 : static_cast<std::uint32_t>(countSelectable(window, window.cursor) + 1);
    return result;
  }

  Hints hints(const View& view, const State& state, const Context& context) {
    Hints result;

    if (view.windows.empty()) {
      return result;
    }

    if (fixedHints(result, view.mode)) {
      return result;
    }

    const auto& window = explorer::window(view);
    const auto* row = window.rows.empty() ? nullptr : &window.rows[window.cursor];
    const bool entry = row != nullptr && (row->kind == RowKind::entry || row->kind == RowKind::change || row->kind == RowKind::match);
    const bool tree = window.lens == Lens::tree;
    LineText verb;

    static_cast<void>(state);
    writeEnter(verb, row, focusedPane(context));
    addHint(result, "<CR>", {.text = verb.view(), .enabled = row != nullptr});
    if (!view.edits.empty()) {
      LineText pending;

      write(pending, "write {}", view.edits.size());
      addHint(result, ":w", {.text = pending.view()});
      addHint(result, "u", {.text = "undo"});
    }

    addHint(result, "cw", {.text = "rename", .enabled = entry && tree});
    addHint(result, "dd", {.text = "cut", .enabled = entry});
    addHint(result, "yy", {.text = "copy", .enabled = entry});
    addHint(result, "o", {.text = "new", .enabled = tree});
    addHint(result, "<C-w>v", {.text = "window"});
    addHint(result, "=", {.text = "diff", .enabled = entry && !row->directory});
    addHint(result, "ga", {.text = "stage", .enabled = entry});
    addHint(result, "gu", {.text = "unstage", .enabled = entry});

    LineText sort;

    write(sort, "sort: {}", sortName(window.sort));
    addHint(result, "S", {.text = sort.view()});
    addHint(result, "g.", {.text = "dotfiles"});
    addHint(result, "?", {.text = "help"});
    return result;
  }

  ds::Array<LensLook, lens_count> lenses(const View& view, const State& state, const Context& context) {
    ds::Array<LensLook, lens_count> result{};
    const auto current = view.windows.empty() ? Lens::tree : explorer::window(view).lens;
    const auto changes = state.repository.staged + state.repository.unstaged + state.repository.untracked;

    result.atMut(0) = {.name = "tree", .current = current == Lens::tree};
    result.atMut(1) = {.name = "changes", .count = changes, .counted = state.repository.known && !state.repository.root.empty(), .current = current == Lens::changes};
    // The files touched below the root of the window that takes the keys, each once.
    const auto& touches = state.touches;
    const auto root = view.windows.empty() ? std::string_view{} : explorer::window(view).root.view();
    std::uint32_t touched = 0;

    for (std::size_t index = 0; index < touches.items.size(); ++index) {
      const auto path = touches.path(touches.items[index]);
      const bool named = std::ranges::any_of(touches.items.view().first(index), [&](const Touch& earlier) {
        return touches.path(earlier) == path;
      });

      touched += !named && path != root && within(path, root) ? 1 : 0;
    }

    result.atMut(2) = {.name = "touched", .count = touched, .counted = touches.known, .current = current == Lens::touched};
    result.atMut(3) = {.name = "panes", .count = static_cast<std::uint32_t>(context.panes.size()), .counted = true, .current = current == Lens::panes};
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
    if (row.kind != RowKind::entry && row.kind != RowKind::change && row.kind != RowKind::match) {
      return result;
    }

    const auto path = window.selected.view();
    const auto* inspection = inspected(state, path);

    result.shown = true;
    result.directory = row.directory;
    put(result.name, baseOf(path));
    put(result.path, path);
    addListed(result, listedOf(state, row, inspection), now_seconds);
    addGit(result, state.repository, path);
    if (inspection != nullptr) {
      addInspected(result, *inspection);
    }

    put(addFact(result, "Machine").value, context.machine);
    if (row.directory) {
      notePanes(result, context, path);
    } else {
      noteActivity(result, state, context, path);
    }

    result.waiting = inspection == nullptr;
    if (inspection != nullptr && !row.directory) {
      result.title = titleOf(*inspection);
      result.diff = !inspection->diff.empty();
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

  MenuLook menu(const View& view, const State& state, const Context& context) {
    MenuLook result;

    static_cast<void>(state);
    if (view.mode != Mode::menu || view.windows.empty()) {
      return result;
    }

    const auto chosen_rows = chosenRows(view, explorer::window(view));

    result.count = view.menu.count;
    for (std::size_t index = 0; index < view.menu.count; ++index) {
      const auto item = view.menu.items[index];
      const auto& text = menu_texts[static_cast<std::size_t>(item.entry)];
      auto& line = result.lines.atMut(index);

      line.rule = item.entry == MenuEntry::rule;
      line.enabled = item.enabled;
      line.current = index == view.menu.current;
      line.keys = text.keys;
      writeMenuLabel(line.label, text, view, context);
      if (chosen_rows > 1 && countsRows(item.entry)) {
        LineText counted;

        write(counted, "{} ({})", line.label.view(), chosen_rows);
        line.label = counted;
      }
    }

    return result;
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

  LineText outcomeText(const Written& written, std::size_t waiting) {
    LineText text;

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

    append(written.undone ? "taken back" : ":w");
    count(written.applied, written.undone ? "step" : "applied by the runtime");
    count(written.renamed, "under another name: the target existed");
    count(written.stale, "skipped: changed since it was listed");
    count(written.missing, "skipped: gone");
    count(written.refused, "refused");
    count(waiting, waiting == 1 ? "machine still to answer" : "machines still to answer");
    if (written.undoable && waiting == 0) {
      append(" · u takes it back");
    }

    text.assign(runtime::utf8Prefix({buffer.data(), length}, line_text_bytes));
    return text;
  }

  TransferLooks transfers(const View& view, const Context& context, std::uint64_t now_ms) {
    constexpr std::uint64_t second_ms = 1000;
    TransferLooks result;

    // The ones that run, then the ones that wait, then the ones that just ended.
    for (const bool running : {true, false}) {
      for (const auto& transfer : view.transfers) {
        const bool active = transfer.phase != TransferPhase::waiting && !ended(transfer.phase);
        if (active != running) {
          continue;
        }

        if (result.count == result.items.size()) {
          ++result.more;
          continue;
        }

        auto& look = result.items.atMut(result.count++);
        const auto elapsed = now_ms > transfer.started_ms ? now_ms - transfer.started_ms : 0;

        look.id = transfer.id;
        put(look.name, transfer.name.view());
        write(look.route, "{} → {}", labelOf(context, transfer.from), labelOf(context, transfer.to));
        write(look.progress, "{} of {}", bytes(transfer.done).view(), bytes(transfer.size).view());
        look.share = shareOf(transfer);
        if (active && elapsed >= second_ms / 2 && transfer.done != 0) {
          write(look.rate, "{}/s", bytes(transfer.done * second_ms / elapsed).view());
        }

        look.phase = phaseText(transfer.phase);
        look.ended = ended(transfer.phase);
        look.failed = transfer.phase == TransferPhase::failed;
      }
    }

    return result;
  }

}
