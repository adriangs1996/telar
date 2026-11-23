module telar.gui.features.explorer;

import std;

import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.base.ds;
import telar.tbc;
import telar.wire.files;

namespace telar::gui::features::explorer {

  namespace {

    using Text = ds::String<Memory>;

    void say(View& view, std::string_view text, Tone tone = Tone::info) {
      view.message.assign(runtime::utf8Prefix(text, ViewLimits::message_bytes));
      view.tone = tone;
    }

    template <typename... Arguments>
    void report(View& view, Tone tone, std::format_string<Arguments...> format, Arguments&&... arguments) {
      Text text{view.memory};

      ds::formatTo(text, format, std::forward<Arguments>(arguments)...);
      say(view, text.view(), tone);
    }

    using Windows = ds::Vec<ds::Box<Window, Memory>, Memory>;
    using Edits = ds::Vec<Edit, Memory>;

    // The window `index` among `windows`. It borrows the windows alone, so a command keeps it
    // while it changes another field of the view.
    Window& windowAt(Windows& windows, std::size_t index) noexcept {
      return windows.atMut(index).getMut();
    }

    // A name in a directory.
    struct Child {
      std::string_view directory;
      std::string_view name;
    };

    void join(Text& path, const Child& child) {
      path.assign(child.directory);
      if (!child.directory.ends_with('/')) {
        path.push('/');
      }

      path.append(child.name);
    }

    bool holds(const ds::Vec<Text, Memory>& paths, std::string_view path) noexcept {
      return std::ranges::any_of(paths, [&](const Text& kept) {
        return kept.view() == path;
      });
    }

    void add(ds::Vec<Text, Memory>& paths, std::string_view path) {
      if (!holds(paths, path)) {
        paths.push(Text{paths.memory(), path});
      }
    }

    void drop(ds::Vec<Text, Memory>& paths, std::string_view path) {
      paths.retain([&](const Text& kept) {
        return kept.view() != path;
      });
    }

    constexpr bool selectable(RowKind kind) noexcept {
      return kind == RowKind::entry || kind == RowKind::added || kind == RowKind::change || kind == RowKind::pane;
    }

    constexpr char lowered(char character) noexcept {
      return character >= 'A' && character <= 'Z' ? static_cast<char>(character - 'A' + 'a') : character;
    }

    // Whether `text` holds `part`, without regard to the case of ASCII letters.
    bool holdsFolded(std::string_view text, std::string_view part) noexcept {
      if (part.empty()) {
        return true;
      }

      const auto found = std::ranges::search(text, part, [](char left, char right) {
        return lowered(left) == lowered(right);
      });

      return !found.empty();
    }

    // The place of `directory` among the machine's directories.
    ds::Option<std::uint32_t> holderOf(const State& state, std::string_view path) noexcept {
      for (std::size_t index = 0; index < state.directories.size(); ++index) {
        if (state.directories[index]->path.view() == path) {
          return static_cast<std::uint32_t>(index);
        }
      }

      return ds::none;
    }

    const PaneFact* focusedPane(const Context& context) noexcept {
      const auto found = std::ranges::find(context.panes, context.focused, &PaneFact::id);

      return found == context.panes.end() ? nullptr : std::to_address(found);
    }

    // What building the rows of a window carries down the tree.
    struct Build {
      Window& window;
      const Edits& edits;
      const State& state;
      // The entries of a directory in the window's order, reused at every level.
      ds::Vec<std::uint32_t, Memory> order;
    };

    std::uint32_t keepText(Window& window, std::string_view text) {
      const auto offset = static_cast<std::uint32_t>(window.text.size());

      window.text.extend(std::span<const char>{text});
      return offset;
    }

    // A row of `window` that shows `text`: `row` says its kind, its depth and what it stands for.
    void pushText(Window& window, Row row, std::string_view text) {
      row.text = keepText(window, text);
      row.text_size = static_cast<std::uint32_t>(text.size());
      window.rows.push(row);
    }

    // The lines of a file's diff, below its row.
    void pushDiff(Window& window, std::string_view diff, std::uint8_t depth) {
      std::size_t lines = 0;

      while (!diff.empty() && lines < ViewLimits::diff_lines) {
        const auto end = diff.find('\n');
        const auto line = diff.substr(0, end);

        pushText(window, {.kind = RowKind::diff, .depth = depth, .tone = toneOf(line)}, line);
        diff.remove_prefix(end == std::string_view::npos ? diff.size() : end + 1);
        ++lines;
      }

      if (!diff.empty()) {
        pushText(window, {.kind = RowKind::note, .depth = depth}, "… the preview shows the rest");
      }
    }

    // The rows of the changes not written that add an entry to `directory`.
    void pushAdded(Build& build, std::string_view directory, std::uint8_t depth) {
      for (const auto& edit : build.edits) {
        if ((edit.kind == EditKind::create || edit.kind == EditKind::paste) && edit.machine == build.window.machine && edit.path.view() == directory) {
          pushText(build.window, {.kind = RowKind::added, .depth = depth, .directory = edit.directory, .item = edit.id}, edit.name.view());
        }
      }
    }

    // A directory being listed: its place among the machine's, its path, how deep it is below
    // the window's root, and the size of the largest entry it lists.
    struct Level {
      std::uint32_t holder = 0;
      std::string_view path;
      std::uint8_t depth = 0;
      std::uint64_t largest = 1;
    };

    // Keeps in `build.order` the entries of the level that the window lists, and counts at its
    // root what it leaves out. Returns the size of the largest one kept.
    std::uint64_t keepListed(Build& build, const Directory& directory, const Level& level) {
      auto& window = build.window;
      std::uint64_t largest = 1;
      Text child{window.rows.memory()};

      for (std::size_t index = 0; index < directory.entries.size(); ++index) {
        const auto& entry = directory.entries[index];
        const auto name = directory.name(entry);

        join(child, {.directory = level.path, .name = name});

        const bool hidden = !window.hidden && name.starts_with('.');
        const bool ignored = !window.ignored && standing(build.state.repository, child.view(), entry.directory).ignored;

        if (level.depth == 0) {
          window.bytes += entry.size;
          window.hidden_entries += hidden ? 1 : 0;
          window.ignored_entries += ignored && !hidden ? 1 : 0;
        }

        // A filter keeps an unfolded directory to look below it, and drops it later if nothing
        // there matched.
        const bool unfolded = entry.directory && !window.filter.empty() && holds(window.expanded, child.view());

        if (hidden || ignored || (!unfolded && !holdsFolded(name, window.filter.view()))) {
          continue;
        }

        build.order.push(static_cast<std::uint32_t>(index));
        largest = std::max(largest, entry.size);
      }

      return largest;
    }

    // Orders the entries a level lists as the window sorts them: the runtime listed them by name.
    void sortListed(std::span<std::uint32_t> listed, const Directory& directory, Sort sort) {
      if (sort == Sort::name) {
        return;
      }

      std::ranges::stable_sort(listed, [&](std::uint32_t left, std::uint32_t right) {
        const auto& first = directory.entries[left];
        const auto& second = directory.entries[right];

        if (sort == Sort::size) {
          return first.size > second.size;
        }

        return std::pair{first.identity.modified_seconds, first.identity.modified_nanoseconds} > std::pair{second.identity.modified_seconds, second.identity.modified_nanoseconds};
      });
    }

    void walk(Build& build, std::string_view path, std::uint8_t depth);

    // The row of the entry `index` of a level, the diff it unfolds and, for a directory unfolded,
    // what is below it.
    void pushEntry(Build& build, const Level& level, std::uint32_t index) { // NOLINT(misc-no-recursion): a tree unfolds ViewLimits::depth directories deep at most
      constexpr std::uint64_t whole = 1000;
      auto& window = build.window;
      const auto& directory = *build.state.directories[level.holder];
      const auto& entry = directory.entries[index];
      Text child{build.order.memory()};

      join(child, {.directory = level.path, .name = directory.name(entry)});

      const bool expanded = entry.directory && holds(window.expanded, child.view());

      window.rows.push({
          .kind = RowKind::entry,
          .depth = level.depth,
          .directory = entry.directory,
          .expanded = expanded,
          .holder = level.holder,
          .entry = index,
          .share = static_cast<std::uint16_t>(entry.size * whole / level.largest),
      });

      if (!entry.directory && holds(window.diffs, child.view())) {
        if (const auto* inspection = inspected(build.state, child.view())) {
          pushDiff(window, inspection->diff.view(), static_cast<std::uint8_t>(level.depth + 1));
        }
      }

      const auto own = window.rows.size();

      if (expanded && std::cmp_less(level.depth + 1, ViewLimits::depth)) {
        walk(build, child.view(), static_cast<std::uint8_t>(level.depth + 1));
      }

      // An unfolded directory the filter kept only to look below it, where nothing matched.
      if (expanded && window.rows.size() == own && !holdsFolded(directory.name(entry), window.filter.view())) {
        window.rows.truncate(own - 1);
      }
    }

    void walk(Build& build, std::string_view path, std::uint8_t depth) { // NOLINT(misc-no-recursion): a tree unfolds ViewLimits::depth directories deep at most
      auto& window = build.window;
      const auto holder = holderOf(build.state, path);
      if (!holder) {
        return;
      }

      const auto& directory = *build.state.directories[*holder];
      if (!directory.listed) {
        pushText(window, {.kind = RowKind::note, .depth = depth}, "reading…");
        return;
      }

      if (directory.failed) {
        pushText(window, {.kind = RowKind::note, .depth = depth}, "this account may not read it, or it is gone");
        return;
      }

      // The entries this level lists, in the window's order.
      const auto first = build.order.size();
      Level level{.holder = *holder, .path = path, .depth = depth};

      level.largest = keepListed(build, directory, level);
      sortListed(build.order.viewMut().subspan(first), directory, window.sort);
      for (std::size_t place = first; place < build.order.size(); ++place) {
        pushEntry(build, level, build.order[place]);
      }

      build.order.truncate(first);
      pushAdded(build, path, depth);
      if (!directory.whole()) {
        pushText(window, {.kind = RowKind::note, .depth = depth}, "reading more…");
      } else if (directory.total > directory.entries.size()) {
        Text more{build.order.memory()};

        ds::formatTo(more, "… {} more entries are not listed", directory.total - directory.entries.size());
        pushText(window, {.kind = RowKind::note, .depth = depth}, more.view());
      }
    }

    void buildTree(Window& window, const Edits& edits, const State& state) {
      Build build{.window = window, .edits = edits, .state = state, .order = ds::Vec<std::uint32_t, Memory>{window.rows.memory()}};
      const auto* root = find(state, window.root.view());

      window.loading = root == nullptr || !root->listed;
      if (!window.loading) {
        walk(build, window.root.view(), 0);
      }
    }

    constexpr bool isStaged(const Change& change) noexcept {
      return change.staged != FileState::unchanged && change.staged != FileState::ignored;
    }

    constexpr bool isUnstaged(const Change& change) noexcept {
      return change.unstaged != FileState::unchanged && change.unstaged != FileState::ignored && change.unstaged != FileState::untracked;
    }

    constexpr bool isUntracked(const Change& change) noexcept {
      return change.unstaged == FileState::untracked;
    }

    // The changed paths of the repository in three groups, as `git status` lists them.
    void buildChanges(Window& window, const State& state) {
      const auto& repository = state.repository;

      struct Group {
        std::string_view title;
        bool (*belongs)(const Change&) noexcept;
      };

      const ds::Array<Group, 3> groups{
          Group{.title = "Staged", .belongs = isStaged},
          Group{.title = "Unstaged", .belongs = isUnstaged},
          Group{.title = "Untracked", .belongs = isUntracked},
      };

      window.loading = !repository.known;
      for (const auto& group : groups) {
        bool titled = false;

        for (std::size_t index = 0; index < repository.changes.size(); ++index) {
          const auto& change = repository.changes[index];
          const auto path = repository.path(change);
          if (!group.belongs(change) || !holdsFolded(path, window.filter.view())) {
            continue;
          }

          if (!titled) {
            pushText(window, {.kind = RowKind::header}, group.title);
            titled = true;
          }

          pushText(window, {.kind = RowKind::change, .directory = path.ends_with('/'), .item = static_cast<std::uint32_t>(index)}, path);
        }
      }
    }

    void buildPanes(Window& window, const Context& context) {
      window.loading = false;
      for (std::size_t index = 0; index < context.panes.size(); ++index) {
        const auto& pane = context.panes[index];
        if (holdsFolded(pane.title, window.filter.view()) || holdsFolded(pane.cwd, window.filter.view())) {
          pushText(window, {.kind = RowKind::pane, .item = static_cast<std::uint32_t>(index)}, pane.cwd);
        }
      }
    }

    // Moves what the window shows so that it holds the selection.
    void reveal(Window& window) noexcept {
      const auto page = std::max<std::size_t>(1, window.page);

      if (window.cursor < window.top) {
        window.top = window.cursor;
      } else if (window.cursor >= window.top + page) {
        window.top = window.cursor + 1 - page;
      }

      window.top = std::min(window.top, window.rows.size() > page ? window.rows.size() - page : 0);
    }

    // Puts the selection on `index` and remembers its path.
    void choose(Window& window, const State& state, const Context& context, std::size_t index) {
      if (window.rows.empty()) {
        window.cursor = 0;
        window.top = 0;
        return;
      }

      window.cursor = std::min(index, window.rows.size() - 1);

      Text path{window.rows.memory()};

      pathOf(path, window, state, context, window.rows[window.cursor]);
      window.selected.assign(path.view());
      reveal(window);
    }

    // The selectable row nearest to `index`, looking forward first.
    std::size_t nearest(const Window& window, std::size_t index) noexcept {
      for (std::size_t row = index; row < window.rows.size(); ++row) {
        if (selectable(window.rows[row].kind)) {
          return row;
        }
      }

      for (std::size_t row = std::min(index, window.rows.size()); row-- > 0;) {
        if (selectable(window.rows[row].kind)) {
          return row;
        }
      }

      return 0;
    }

    void buildWindow(Window& window, const Edits& edits, const State& state, const Context& context) {
      const auto before = window.cursor;

      window.rows.clear();
      window.text.clear();
      window.picked.clear();
      window.bytes = 0;
      window.hidden_entries = 0;
      window.ignored_entries = 0;
      switch (window.lens) {
      case Lens::tree:
        buildTree(window, edits, state);
        break;
      case Lens::changes:
        buildChanges(window, state);
        break;
      case Lens::panes:
        buildPanes(window, context);
        break;
      }

      // The selection stays on its path; where the path is gone, near where it was.
      Text path{window.rows.memory()};
      std::size_t found = window.rows.size();

      if (!window.selected.empty()) {
        for (std::size_t index = 0; index < window.rows.size() && found == window.rows.size(); ++index) {
          if (selectable(window.rows[index].kind)) {
            pathOf(path, window, state, context, window.rows[index]);
            found = path.view() == window.selected.view() ? index : found;
          }
        }
      }

      if (found != window.rows.size()) {
        window.cursor = found;
      } else if (!window.loading) {
        choose(window, state, context, nearest(window, before));
      }

      if (window.anchor && *window.anchor >= window.rows.size()) {
        window.anchor = ds::none;
      }

      reveal(window);
    }

    void rebuildCurrent(View& view, const State& state, const Context& context) {
      buildWindow(windowAt(view.windows, view.current), view.edits, state, context);
      ++view.revision;
    }

    // Keeps the changes as they are, for `u` to bring back. It takes the two fields it works on,
    // so the window a command reads stays borrowed across it.
    void remember(tbc::mut_a<ds::Vec<Edits, Memory>> history, const Edits& edits, tbc::mut_a<Memory> memory) {
      Edits kept{memory};

      for (const auto& edit : edits) {
        kept.push(edit.clone(memory));
      }

      history.push(std::move(kept));
      if (history.size() > ViewLimits::history) {
        static_cast<void>(history.remove(0));
      }
    }

    // A change more among `edits`, numbered with `next`.
    tbc::mut_a<Edit> addEdit(tbc::mut_a<Edits> edits, std::uint32_t& next, EditKind kind, std::uint64_t machine, std::string_view path) {
      auto& edit = edits.push(Edit{edits.memory()});

      edit.id = next++;
      edit.kind = kind;
      edit.machine = machine;
      edit.path.assign(path);
      return edit;
    }

    // The directory a new entry or a paste goes in: the selected one when it is unfolded, else the
    // one the selection is in.
    void targetDirectory(Text& directory, const Window& window, const State& state, const Context& context) {
      if (window.rows.empty() || window.lens != Lens::tree) {
        directory.assign(window.root.view());
        return;
      }

      const auto& row = window.rows[window.cursor];

      pathOf(directory, window, state, context, row);
      if (directory.empty()) {
        directory.assign(window.root.view());
      } else if (row.kind != RowKind::entry || !row.directory || !row.expanded) {
        const Text parent{window.root.memory(), parentOf(directory.view())};

        directory.assign(parent.view());
      }
    }

    void pushJump(View& view) {
      const auto& window = windowAt(view.windows, view.current);

      view.jumps.truncate(std::min(view.jumps.size(), view.jump));

      auto& place = view.jumps.push(Place{view.memory});

      place.machine = window.machine;
      place.root.assign(window.root.view());
      place.selected.assign(window.selected.view());
      if (view.jumps.size() > ViewLimits::jumps) {
        static_cast<void>(view.jumps.remove(0));
      }

      view.jump = view.jumps.size();
    }

    // Where a window goes: the directory it roots itself at, what it selects there, and whether
    // the place it leaves is one to jump back to.
    struct Target {
      std::string_view root;
      std::string_view selected;
      bool jump = true;
    };

    // Roots the current window at the target.
    void go(View& view, const Target& target) {
      auto& window = windowAt(view.windows, view.current);
      const Text root{view.memory, target.root};
      const Text chosen{view.memory, target.selected};

      if (target.jump) {
        pushJump(view);
      }

      window.root.assign(root.view());
      window.selected.assign(chosen.view());
      window.follow = false;
      window.filter.clear();
      window.anchor = ds::none;
      window.lens = Lens::tree;
      window.cursor = 0;
    }

    // `path` as the window means it: `~`, a path from the root, or an absolute one, with `.` and
    // `..` resolved.
    void resolve(Text& resolved, std::string_view argument, const Window& window, const Context& context) {
      Text joined{resolved.memory()};

      if (argument == "~" || argument.starts_with("~/")) {
        joined.assign(context.home);
        joined.append(argument.substr(1));
      } else if (argument.starts_with('/')) {
        joined.assign(argument);
      } else {
        join(joined, {.directory = window.root.view(), .name = argument});
      }

      resolved.clear();
      for (auto rest = joined.view(); !rest.empty();) {
        const auto end = rest.find('/');
        const auto component = rest.substr(0, end);

        rest.remove_prefix(end == std::string_view::npos ? rest.size() : end + 1);
        if (component == "..") {
          const auto slash = resolved.view().find_last_of('/');

          resolved.truncate(slash == std::string_view::npos ? 0 : slash);
        } else if (!component.empty() && component != ".") {
          resolved.push('/');
          resolved.append(component);
        }
      }

      if (resolved.empty()) {
        resolved.assign("/");
      }
    }

    // The paths of the rows a command acts on, into `view.paths`; the files alone when `files`.
    void gather(View& view, const State& state, const Context& context, bool files) {
      const auto& window = windowAt(view.windows, view.current);
      const auto rows = range(view, window);

      view.paths.clear();
      for (std::size_t index = rows.first; index <= rows.last && index < window.rows.size(); ++index) {
        const auto& row = window.rows[index];
        if (!chosen(view, window, index) || row.kind == RowKind::added || (files && row.directory)) {
          continue;
        }

        Text path{view.memory};

        pathOf(path, window, state, context, row);
        if (!path.empty()) {
          view.paths.push(std::move(path));
        }
      }
    }

    void leaveVisual(View& view) noexcept {
      if (view.mode == Mode::visual) {
        view.mode = Mode::normal;
      }

      windowAt(view.windows, view.current).anchor = ds::none;
      windowAt(view.windows, view.current).picked.clear();
    }

    // The paths gathered, as a person would type them at the pane, each with `prefix` before it.
    void typeFor(View& view, const Context& context, const PaneFact& pane, std::string_view prefix) {
      view.text.clear();
      for (const auto& path : view.paths) {
        view.text.append(prefix);
        appendTyped(view.text, path.view(), {.cwd = pane.cwd, .home = context.home, .shell = prefix.empty()});
        view.text.push(' ');
      }
    }

  }

  Edit::Edit(Memory& memory)
      : path(memory),
        name(memory),
        source(memory) {}

  tbc::val_a<Edit> Edit::clone(tbc::mut_a<Memory> memory) const {
    Edit copy{memory};

    copy.id = id;
    copy.kind = kind;
    copy.paste = paste;
    copy.directory = directory;
    copy.machine = machine;
    copy.path.assign(path.view());
    copy.name.assign(name.view());
    copy.source.assign(source.view());
    copy.source_machine = source_machine;
    copy.identity = identity;
    copy.size = size;
    return copy;
  }

  Yanked::Yanked(Memory& memory)
      : path(memory) {}

  PlanStep::PlanStep(Memory& memory)
      : source(memory),
        target(memory) {}

  Place::Place(Memory& memory)
      : root(memory),
        selected(memory) {}

  Window::Window(Memory& memory)
      : root(memory),
        filter(memory),
        expanded(memory),
        diffs(memory),
        rows(memory),
        text(memory),
        selected(memory),
        picked(memory),
        followed_cwd(memory) {}

  View::View(Memory& made_in)
      : memory(made_in),
        windows(memory),
        edits(memory),
        history(memory),
        yanked(memory),
        marks(memory),
        jumps(memory),
        draft(memory),
        prefill(memory),
        plan(memory),
        text(memory),
        paths(memory) {}

  DiffTone toneOf(std::string_view line) noexcept {
    if (line.starts_with("@@")) {
      return DiffTone::hunk;
    }

    if (line.starts_with('+')) {
      return DiffTone::added;
    }

    return line.starts_with('-') ? DiffTone::removed : DiffTone::context;
  }

  const Window& window(const View& view) noexcept {
    return *view.windows[view.current];
  }

  tbc::val_a<const Edit*> editOn(tbc::ref_a<View> view, EditKind kind, std::uint64_t machine, std::string_view path) noexcept {
    for (const auto& edit : view.edits) {
      if (edit.kind == kind && edit.machine == machine && edit.path.view() == path) {
        return &edit;
      }
    }

    return nullptr;
  }

  tbc::val_a<const Edit*> editOf(tbc::ref_a<View> view, const Row& row) noexcept {
    if (row.kind != RowKind::added) {
      return nullptr;
    }

    for (const auto& edit : view.edits) {
      if (edit.id == row.item) {
        return &edit;
      }
    }

    return nullptr;
  }

  Range range(const View& view, const Window& window) noexcept {
    if (view.mode == Mode::visual && window.anchor && &window == &explorer::window(view)) {
      return {.first = std::min(*window.anchor, window.cursor), .last = std::max(*window.anchor, window.cursor), .visual = true};
    }

    if (!window.picked.empty()) {
      const auto [first, last] = std::ranges::minmax(window.picked.view());

      return {.first = first, .last = last};
    }

    return {.first = window.cursor, .last = std::min(window.cursor + window.reach, std::max<std::size_t>(window.rows.size(), 1)) - 1};
  }

  bool chosen(const View& view, const Window& window, std::size_t row) noexcept {
    const auto rows = range(view, window);
    if (row < rows.first || row > rows.last || row >= window.rows.size() || !selectable(window.rows[row].kind)) {
      return false;
    }

    return rows.visual || window.picked.empty() || std::ranges::contains(window.picked, static_cast<std::uint32_t>(row));
  }

  tbc::val_a<std::string_view> nameOf(tbc::ref_a<Window> window, tbc::ref_a<State> state, const Row& row) noexcept {
    if (row.kind == RowKind::entry) {
      if (row.holder >= state.directories.size() || row.entry >= state.directories[row.holder]->entries.size()) {
        return {};
      }

      const auto& directory = *state.directories[row.holder];

      return directory.name(directory.entries[row.entry]);
    }

    const auto text = window.text.view().subspan(row.text, row.text_size);

    return {text.data(), text.size()};
  }

  void pathOf(ds::String<Memory>& path, const Window& window, const State& state, const Context& context, const Row& row) {
    path.clear();
    switch (row.kind) {
    case RowKind::entry:
      if (row.holder < state.directories.size()) {
        join(path, {.directory = state.directories[row.holder]->path.view(), .name = nameOf(window, state, row)});
      }

      break;
    case RowKind::change: {
      auto relative = nameOf(window, state, row);

      if (relative.ends_with('/')) {
        relative.remove_suffix(1);
      }

      join(path, {.directory = state.repository.root.view(), .name = relative});
      break;
    }
    case RowKind::pane:
      if (row.item < context.panes.size()) {
        path.assign(context.panes[row.item].cwd);
      }

      break;
    case RowKind::added:
    case RowKind::header:
    case RowKind::note:
    case RowKind::diff:
      break;
    }
  }

  namespace {

    // Moves the selection `delta` selectable rows, stopping at the ends.
    void moveBy(Window& window, const State& state, const Context& context, std::int64_t delta) {
      if (window.rows.empty()) {
        return;
      }

      auto index = window.cursor;
      const std::int64_t step = delta < 0 ? -1 : 1;

      for (auto left = delta < 0 ? -delta : delta; left > 0;) {
        const auto next = static_cast<std::int64_t>(index) + step;
        if (next < 0 || std::cmp_greater_equal(next, window.rows.size())) {
          break;
        }

        index = static_cast<std::size_t>(next);
        if (selectable(window.rows[index].kind)) {
          choose(window, state, context, index);
          --left;
        }
      }
    }

    // The `number`th selectable row, from one; the last one for a number past it.
    void goToNumber(Window& window, const State& state, const Context& context, std::uint32_t number) {
      std::size_t last = window.rows.size();
      std::uint32_t seen = 0;

      for (std::size_t index = 0; index < window.rows.size(); ++index) {
        if (!selectable(window.rows[index].kind)) {
          continue;
        }

        last = index;
        if (++seen == number) {
          break;
        }
      }

      if (last != window.rows.size()) {
        choose(window, state, context, last);
      }
    }

    // The row of the directory that holds the selected one.
    ds::Option<std::size_t> parentRow(const Window& window) noexcept {
      if (window.rows.empty()) {
        return ds::none;
      }

      const auto depth = window.rows[window.cursor].depth;

      for (std::size_t index = window.cursor; index-- > 0;) {
        const auto& row = window.rows[index];
        if (row.kind == RowKind::entry && row.directory && row.depth < depth) {
          return index;
        }
      }

      return ds::none;
    }

    void setExpanded(View& view, const State& state, const Context& context, std::size_t index, bool expanded) {
      auto& window = windowAt(view.windows, view.current);
      if (index >= window.rows.size() || window.rows[index].kind != RowKind::entry || !window.rows[index].directory) {
        return;
      }

      Text path{view.memory};

      pathOf(path, window, state, context, window.rows[index]);
      if (expanded) {
        add(window.expanded, path.view());
      } else {
        // What is below it folds with it.
        window.expanded.retain([&](const Text& kept) {
          return !within(kept.view(), path.view());
        });
      }

      rebuildCurrent(view, state, context);
    }

    // The next row git says something of, `direction` rows at a time, around the ends.
    void nextChange(View& view, const State& state, const Context& context, int direction) {
      auto& window = windowAt(view.windows, view.current);
      const auto count = window.rows.size();
      Text path{view.memory};

      for (std::size_t step = 1; step <= count; ++step) {
        const auto index = (window.cursor + count + static_cast<std::size_t>(direction > 0 ? step : count - step)) % count;
        const auto& row = window.rows[index];
        if (row.kind != RowKind::entry && row.kind != RowKind::change) {
          continue;
        }

        pathOf(path, window, state, context, row);

        const auto held = standing(state.repository, path.view(), row.directory);
        const bool changed = row.kind == RowKind::change || (!held.ignored && (held.staged != FileState::unchanged || held.unstaged != FileState::unchanged || held.below != 0));

        if (changed) {
          choose(window, state, context, index);
          return;
        }
      }

      say(view, "Nothing changed here", Tone::error);
    }

    void setLens(View& view, const State& state, const Context& context, Lens lens) {
      auto& window = windowAt(view.windows, view.current);

      window.lens = lens;
      window.filter.clear();
      window.anchor = ds::none;
      window.cursor = 0;
      window.selected.clear();
      rebuildCurrent(view, state, context);
    }

    // A window that follows the focused pane goes where its scope says, with the pane's
    // directory unfolded and chosen.
    void followPane(Window& window, const Context& context) {
      const auto* pane = focusedPane(context);
      const auto cwd = pane == nullptr ? std::string_view{} : pane->cwd;
      auto root = cwd;

      if (window.scope != Scope::pane) {
        root = window.scope == Scope::machine ? context.home : context.workspace;
      }

      window.followed = context.focused;
      window.followed_cwd.assign(cwd);

      if (!root.starts_with('/')) {
        root = cwd.starts_with('/') ? cwd : context.home;
      }

      if (!root.starts_with('/')) {
        root = "/";
      }

      window.root.assign(root);
      window.lens = window.lens == Lens::panes ? Lens::panes : window.lens;
      if (!cwd.starts_with('/') || !within(cwd, root) || cwd == root) {
        return;
      }

      // Every directory from the root down to the pane's is unfolded.
      for (auto slash = cwd.find('/', root == "/" ? 1 : root.size() + 1); slash != std::string_view::npos; slash = cwd.find('/', slash + 1)) {
        add(window.expanded, cwd.substr(0, slash));
      }

      window.selected.assign(cwd);
    }

    void yank(View& view, const State& state, const Context& context, PasteKind kind) {
      const auto& window = windowAt(view.windows, view.current);
      const auto rows = range(view, window);

      view.yanked.clear();
      view.yank = kind;
      for (std::size_t index = rows.first; index <= rows.last && index < window.rows.size(); ++index) {
        const auto& row = window.rows[index];
        if (!chosen(view, window, index) || (row.kind != RowKind::entry && row.kind != RowKind::change)) {
          continue;
        }

        auto& kept = view.yanked.push(Yanked{view.memory});

        kept.machine = window.machine;
        kept.directory = row.directory;
        pathOf(kept.path, window, state, context, row);
        if (row.kind == RowKind::entry && row.holder < state.directories.size()) {
          const auto& entry = state.directories[row.holder]->entries[row.entry];

          kept.identity = entry.identity;
          kept.size = entry.size;
        }
      }
    }

    // `dd`: the rows leave the listing. A row a change added is that change undone; any other is
    // removed when the plan is written, unless a `p` moves it somewhere first.
    void cut(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);
      const auto rows = range(view, window);
      std::size_t count = 0;

      remember(view.history, view.edits, view.memory);
      yank(view, state, context, PasteKind::move);
      for (std::size_t index = rows.first; index <= rows.last && index < window.rows.size(); ++index) {
        const auto& row = window.rows[index];

        if (!chosen(view, window, index)) {
          continue;
        }

        if (row.kind == RowKind::added) {
          const auto id = row.item;

          view.edits.retain([&](const Edit& edit) {
            return edit.id != id;
          });

          ++count;
          continue;
        }

        Text path{view.memory};

        pathOf(path, window, state, context, row);
        if (path.empty() || row.kind == RowKind::pane) {
          continue;
        }

        // A rename or a restore of what goes away is moot.
        view.edits.retain([&](const Edit& edit) {
          return (edit.kind != EditKind::rename && edit.kind != EditKind::restore) || edit.machine != window.machine || edit.path.view() != path.view();
        });

        if (editOn(view, EditKind::remove, window.machine, path.view()) == nullptr) {
          auto& edit = addEdit(view.edits, view.next_edit, EditKind::remove, window.machine, path.view());

          edit.directory = row.directory;
          if (row.kind == RowKind::entry && row.holder < state.directories.size()) {
            edit.identity = state.directories[row.holder]->entries[row.entry].identity;
            edit.size = state.directories[row.holder]->entries[row.entry].size;
          }
        }

        ++count;
      }

      leaveVisual(view);
      rebuildCurrent(view, state, context);
      report(view, Tone::info, "{} cut · :w sends {} to the trash · p elsewhere moves {}", count, count == 1 ? "it" : "them", count == 1 ? "it" : "them");
    }

    // `p`: what was yanked or cut goes in the directory of the selection, as a change to write.
    void paste(View& view, const State& state, const Context& context) {
      const auto& window = windowAt(view.windows, view.current);

      if (view.yanked.empty()) {
        say(view, "Nothing yanked: yy or dd first", Tone::error);
        return;
      }

      if (view.edits.size() + view.yanked.size() > ViewLimits::edits) {
        say(view, "Too many changes not written: :w first", Tone::error);
        return;
      }

      Text directory{view.memory};

      targetDirectory(directory, window, state, context);
      remember(view.history, view.edits, view.memory);
      for (const auto& item : view.yanked) {
        auto& edit = addEdit(view.edits, view.next_edit, EditKind::paste, window.machine, directory.view());

        edit.paste = view.yank;
        edit.directory = item.directory;
        edit.name.assign(baseOf(item.path.view()));
        edit.source.assign(item.path.view());
        edit.source_machine = item.machine;
        edit.identity = item.identity;
        edit.size = item.size;
      }

      report(view, Tone::info, "{} to {} into {} · :w shows the plan", view.yanked.size(), view.yank == PasteKind::move ? "move" : "copy", baseOf(directory.view()));
      // What was cut is moved once; another `p` copies it.
      view.yank = PasteKind::copy;
      rebuildCurrent(view, state, context);
    }

    // The plan of the changes typed, in the order the runtime applies it: what is created, what
    // moves and what is copied, then what is removed and what git restores.
    void plan(View& view) {
      view.plan.clear();

      const auto step = [&](PlanVerb verb, const Edit& edit) -> PlanStep& {
        auto& made = view.plan.push(PlanStep{view.memory});

        made.verb = verb;
        made.directory = edit.directory;
        made.machine = edit.machine;
        made.identity = edit.identity;
        made.size = edit.size;
        return made;
      };

      for (const auto& edit : view.edits) {
        if (edit.kind == EditKind::create && !edit.name.empty()) {
          join(step(PlanVerb::create, edit).target, {.directory = edit.path.view(), .name = edit.name.view()});
        }
      }

      for (const auto& edit : view.edits) {
        if (edit.kind == EditKind::rename) {
          auto& made = step(PlanVerb::move, edit);

          made.source.assign(edit.path.view());
          join(made.target, {.directory = parentOf(edit.path.view()), .name = edit.name.view()});
        } else if (edit.kind == EditKind::paste) {
          auto& made = step(edit.paste == PasteKind::move ? PlanVerb::move : PlanVerb::copy, edit);

          made.source.assign(edit.source.view());
          join(made.target, {.directory = edit.path.view(), .name = edit.name.view()});
        }
      }

      for (const auto& edit : view.edits) {
        // What a paste moves away is not removed as well.
        const bool moved = std::ranges::any_of(view.edits, [&](const Edit& other) {
          return other.kind == EditKind::paste && other.paste == PasteKind::move && other.source_machine == edit.machine && other.source.view() == edit.path.view();
        });

        if (edit.kind == EditKind::remove && !moved) {
          step(PlanVerb::remove, edit).source.assign(edit.path.view());
        } else if (edit.kind == EditKind::restore) {
          step(PlanVerb::restore, edit).source.assign(edit.path.view());
        }
      }
    }

    void write(View& view, bool overwrite) {
      if (view.edits.empty()) {
        say(view, "Nothing to write");
        return;
      }

      plan(view);
      if (view.plan.empty()) {
        say(view, "Nothing to write");
        return;
      }

      view.overwrite = overwrite;
      view.mode = Mode::plan;
      ++view.revision;
    }

    // `ga`, `gu`: git's index takes the rows, or lets go of them, at once.
    Action index(View& view, const State& state, const Context& context, PlanVerb verb) {
      const auto& window = windowAt(view.windows, view.current);

      gather(view, state, context, false);
      view.plan.clear();
      for (const auto& path : view.paths) {
        auto& made = view.plan.push(PlanStep{view.memory});

        made.verb = verb;
        made.machine = window.machine;
        made.source.assign(path.view());
        if (view.plan.size() == FileLimits::maximum_operations) {
          break;
        }
      }

      leaveVisual(view);
      if (view.plan.empty()) {
        return {};
      }

      view.writing = false;
      return {.kind = ActionKind::apply};
    }

    void discard(View& view, const State& state, const Context& context) {
      const auto& window = windowAt(view.windows, view.current);

      gather(view, state, context, true);
      if (view.paths.empty()) {
        say(view, "gX discards the changes of files", Tone::error);
        return;
      }

      remember(view.history, view.edits, view.memory);
      for (const auto& path : view.paths) {
        if (editOn(view, EditKind::restore, window.machine, path.view()) == nullptr && view.edits.size() < ViewLimits::edits) {
          addEdit(view.edits, view.next_edit, EditKind::restore, window.machine, path.view());
        }
      }

      leaveVisual(view);
      rebuildCurrent(view, state, context);
      report(view, Tone::info, "git restore of {} pending · :w shows it before anything is touched", view.paths.size());
    }

    void startRename(View& view, const State& state) {
      const auto& window = windowAt(view.windows, view.current);
      if (window.rows.empty()) {
        return;
      }

      const auto& row = window.rows[window.cursor];
      if (row.kind != RowKind::entry && row.kind != RowKind::added) {
        say(view, "Only an entry of a directory is renamed", Tone::error);
        return;
      }

      view.inserting = row.kind == RowKind::added ? row.item : 0;
      view.draft.assign(nameOf(window, state, row));
      if (row.kind == RowKind::entry) {
        // A name already changed starts from what it was changed to.
        const auto& directory = *state.directories[row.holder];
        Text path{view.memory};

        join(path, {.directory = directory.path.view(), .name = view.draft.view()});
        if (const auto* edit = editOn(view, EditKind::rename, window.machine, path.view())) {
          view.draft.assign(edit->name.view());
        }
      }

      view.mode = Mode::insert;
      ++view.revision;
    }

    void startCreate(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);
      if (window.lens != Lens::tree) {
        say(view, "A new entry is typed in the tree", Tone::error);
        return;
      }

      if (view.edits.size() >= ViewLimits::edits) {
        say(view, "Too many changes not written: :w first", Tone::error);
        return;
      }

      Text directory{view.memory};

      targetDirectory(directory, window, state, context);
      remember(view.history, view.edits, view.memory);

      const auto id = addEdit(view.edits, view.next_edit, EditKind::create, window.machine, directory.view()).id;

      view.inserting = id;
      view.draft.clear();
      rebuildCurrent(view, state, context);

      // The selection goes to the row being typed.
      for (std::size_t index = 0; index < window.rows.size(); ++index) {
        if (window.rows[index].kind == RowKind::added && window.rows[index].item == id) {
          window.cursor = index;
        }
      }

      view.mode = Mode::insert;
    }

    // A name an entry can take: one component of a path, no longer than a file system allows.
    constexpr bool acceptable(std::string_view name) noexcept {
      return !name.empty() && !name.contains('/') && name != "." && name != ".." && name.size() <= FileLimits::name_bytes;
    }

    // What was typed for a name, without the slash that says it is a directory's.
    constexpr std::string_view nameTyped(std::string_view typed) noexcept {
      if (typed.ends_with('/')) {
        typed.remove_suffix(1);
      }

      return typed;
    }

    // The name typed for the row the change `id` adds: the change takes it, or goes with a name
    // an entry cannot take. False when no such change is left.
    bool nameAdded(View& view, std::uint32_t id, std::string_view typed) {
      const auto name = nameTyped(typed);
      Edit* found = nullptr;

      for (auto& edit : view.edits.viewMut()) {
        if (edit.id == id) {
          found = &edit;
        }
      }

      if (found == nullptr) {
        return false;
      }

      if (acceptable(name)) {
        found->name.assign(name);
        // A name that ends in a slash is a directory's.
        found->directory = found->kind == EditKind::create ? typed.ends_with('/') : found->directory;
        return true;
      }

      view.edits.retain([&](const Edit& edit) {
        return edit.id != id;
      });

      say(view, typed.empty() ? "No name: nothing added" : "A name holds no slash: nothing added", typed.empty() ? Tone::info : Tone::error);
      return true;
    }

    // The name typed on the selected entry: a rename of it, unless it is the name it has.
    void renameSelected(View& view, const State& state, const Context& context, std::string_view typed) {
      const auto& window = windowAt(view.windows, view.current);
      if (window.rows.empty() || window.rows[window.cursor].kind != RowKind::entry) {
        return;
      }

      const auto& row = window.rows[window.cursor];
      const auto name = nameTyped(typed);
      Text path{view.memory};

      pathOf(path, window, state, context, row);
      if (!acceptable(name)) {
        say(view, "A name holds no slash and is not empty: nothing renamed", Tone::error);
        return;
      }

      remember(view.history, view.edits, view.memory);
      view.edits.retain([&](const Edit& edit) {
        return edit.kind != EditKind::rename || edit.machine != window.machine || edit.path.view() != path.view();
      });

      if (name != nameOf(window, state, row)) {
        auto& edit = addEdit(view.edits, view.next_edit, EditKind::rename, window.machine, path.view());

        edit.name.assign(name);
        edit.directory = row.directory;
        edit.identity = state.directories[row.holder]->entries[row.entry].identity;
        edit.size = state.directories[row.holder]->entries[row.entry].size;
      }

      ++view.revision;
    }

    // Enter ends insert mode: the name typed is the change.
    void endInsert(View& view, const State& state, const Context& context, std::string_view typed) {
      view.mode = Mode::normal;
      if (view.inserting == 0) {
        renameSelected(view, state, context, typed);
        return;
      }

      const auto id = view.inserting;

      view.inserting = 0;
      if (nameAdded(view, id, typed)) {
        rebuildCurrent(view, state, context);
      }
    }

    // A window more after the others, on what the window `index` shows.
    void cloneWindow(tbc::mut_a<Windows> windows, tbc::mut_a<Memory> memory, std::size_t index) {
      auto made = ds::makeBox<Window>(memory, memory);
      auto& window = made.getMut();
      const auto& from = windows[index].get();

      window.machine = from.machine;
      window.root.assign(from.root.view());
      window.lens = from.lens;
      window.scope = from.scope;
      window.follow = false;
      window.hidden = from.hidden;
      window.ignored = from.ignored;
      window.sort = from.sort;
      window.selected.assign(from.selected.view());
      window.page = from.page;
      for (const auto& path : from.expanded) {
        window.expanded.push(Text{memory, path.view()});
      }

      windows.push(std::move(made));
    }

    void split(View& view, const State& state, const Context& context, bool side_by_side) {
      if (view.windows.size() >= ViewLimits::windows) {
        say(view, "Three windows at most", Tone::error);
        return;
      }

      // The new window stands after the current one, and takes the keys.
      cloneWindow(view.windows, view.memory, view.current);
      view.side_by_side = view.windows.size() == 2 ? side_by_side : view.side_by_side;
      view.current = view.windows.size() - 1;
      buildWindow(windowAt(view.windows, view.current), view.edits, state, context);
      ++view.revision;
    }

    // The changes typed keep `q` from closing the last window, as Neovim's E37 does.
    Action quit(View& view, bool force, bool everything) {
      if (!everything && view.windows.size() > 1) {
        static_cast<void>(view.windows.remove(view.current));
        view.current = std::min(view.current, view.windows.size() - 1);
        ++view.revision;
        return {};
      }

      if (!view.edits.empty() && !force) {
        report(view, Tone::error, "E37: {} change{} not written (:w shows the plan, :q! discards {})", view.edits.size(), view.edits.size() == 1 ? "" : "s", view.edits.size() == 1 ? "it" : "them");
        return {};
      }

      if (force) {
        view.edits.clear();
        view.history.clear();
      }

      return {.kind = ActionKind::close};
    }

    tbc::val_a<Place*> markOf(tbc::mut_a<ds::Vec<Place, Memory>> marks, std::string_view letter) noexcept {
      for (auto& mark : marks.viewMut()) {
        if (mark.letter.view() == letter) {
          return &mark;
        }
      }

      return nullptr;
    }

    constexpr bool isLetter(std::string_view text) noexcept {
      return text.size() == 1 && ((text.front() >= 'a' && text.front() <= 'z') || (text.front() >= 'A' && text.front() <= 'Z'));
    }

    // Enter on the rows chosen: a directory alone is entered; files go to the focused pane as its
    // kind takes them.
    Action enter(View& view, const State& state, const Context& context) {
      const auto& window = windowAt(view.windows, view.current);
      if (window.rows.empty()) {
        return {};
      }

      const auto& row = window.rows[window.cursor];
      const auto rows = range(view, window);
      const bool single = rows.first == rows.last;

      if (row.kind == RowKind::added) {
        say(view, "It does not exist yet: :w first", Tone::error);
        return {};
      }

      if (row.kind == RowKind::pane && row.item < context.panes.size()) {
        return {.kind = ActionKind::focus_pane, .pane = context.panes[row.item].id};
      }

      if (single && row.directory) {
        Text path{view.memory};

        pathOf(path, window, state, context, row);
        go(view, {.root = path.view()});
        rebuildCurrent(view, state, context);
        return {};
      }

      const auto* pane = focusedPane(context);
      if (pane == nullptr) {
        say(view, "No pane has the focus", Tone::error);
        return {};
      }

      gather(view, state, context, pane->kind == PaneKind::editor);
      leaveVisual(view);
      if (view.paths.empty()) {
        return {};
      }

      if (pane->kind == PaneKind::editor) {
        return {.kind = ActionKind::open, .pane = pane->id};
      }

      typeFor(view, context, *pane, pane->kind == PaneKind::agent ? std::string_view{"@"} : std::string_view{});
      return {.kind = pane->kind == PaneKind::agent ? ActionKind::mention : ActionKind::insert, .pane = pane->id};
    }

    // `h`: folds the selected directory, or goes to the one that holds the row.
    void collapse(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      if (!window.rows.empty() && window.rows[window.cursor].expanded) {
        setExpanded(view, state, context, window.cursor, false);
      } else if (const auto parent = parentRow(window)) {
        choose(window, state, context, *parent);
      }
    }

    void toggleFold(View& view, const State& state, const Context& context) {
      const auto& window = windowAt(view.windows, view.current);

      if (!window.rows.empty()) {
        setExpanded(view, state, context, window.cursor, !window.rows[window.cursor].expanded);
      }
    }

    void foldAll(View& view, const State& state, const Context& context) {
      windowAt(view.windows, view.current).expanded.clear();
      rebuildCurrent(view, state, context);
    }

    // `zR`, one more level each time: every directory that shows unfolds.
    void unfoldAll(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);
      Text path{view.memory};

      for (const auto& row : window.rows) {
        if (row.kind == RowKind::entry && row.directory && !row.expanded) {
          pathOf(path, window, state, context, row);
          add(window.expanded, path.view());
        }
      }

      rebuildCurrent(view, state, context);
    }

    // `-`: the directory above, with the one it came from selected.
    void goUp(View& view, const State& state, const Context& context) {
      if (windowAt(view.windows, view.current).root.view() == "/") {
        return;
      }

      const Text child{view.memory, windowAt(view.windows, view.current).root.view()};

      go(view, {.root = parentOf(child.view()), .selected = child.view()});
      rebuildCurrent(view, state, context);
    }

    void rootAt(View& view, const State& state, const Context& context, std::string_view root) {
      go(view, {.root = root});
      rebuildCurrent(view, state, context);
    }

    // `gp`, `gw`, `gh`: the window follows the focused pane, rooted where `scope` says.
    void setScope(View& view, const State& state, const Context& context, Scope scope) {
      pushJump(view);

      auto& window = windowAt(view.windows, view.current);

      window.scope = scope;
      window.follow = true;
      window.lens = Lens::tree;
      followPane(window, context);
      rebuildCurrent(view, state, context);
    }

    void setMark(View& view, const Notation& letter) {
      const auto& window = windowAt(view.windows, view.current);

      if (!isLetter(letter.view())) {
        say(view, "A mark is a letter", Tone::error);
        return;
      }

      auto* mark = markOf(view.marks, letter.view());
      if (mark == nullptr) {
        if (view.marks.size() == ViewLimits::marks) {
          return;
        }

        mark = &view.marks.push(Place{view.memory});
      }

      mark->letter = letter;
      mark->machine = window.machine;
      mark->root.assign(window.root.view());
      mark->selected.assign(window.selected.view());
      report(view, Tone::info, "mark {} set", letter.view());
      ++view.revision;
    }

    void jumpToMark(View& view, const State& state, const Context& context, std::string_view letter) {
      const auto* mark = markOf(view.marks, letter);
      if (mark == nullptr) {
        report(view, Tone::error, "E20: Mark not set: {}", letter);
        return;
      }

      const Text root{view.memory, mark->root.view()};
      const Text selected{view.memory, mark->selected.view()};
      const auto machine = mark->machine;

      pushJump(view);
      windowAt(view.windows, view.current).machine = machine;
      go(view, {.root = root.view(), .selected = selected.view(), .jump = false});
      rebuildCurrent(view, state, context);
    }

    // `<C-o>`, `<C-i>`: back and forward through the places the window was rooted at.
    void jump(View& view, const State& state, const Context& context, bool back) {
      const bool ended = back ? view.jump == 0 : view.jump + 1 >= view.jumps.size();
      if (ended) {
        say(view, back ? "At the oldest place" : "At the newest place");
        return;
      }

      // Going back from the newest place keeps where it was, to come forward to.
      if (back && view.jump == view.jumps.size()) {
        pushJump(view);
        --view.jump;
      }

      view.jump = back ? view.jump - 1 : view.jump + 1;

      const Text root{view.memory, view.jumps[view.jump].root.view()};
      const Text selected{view.memory, view.jumps[view.jump].selected.view()};

      windowAt(view.windows, view.current).machine = view.jumps[view.jump].machine;
      go(view, {.root = root.view(), .selected = selected.view(), .jump = false});
      rebuildCurrent(view, state, context);
    }

    // `gt`, `gT`: the next or the previous lens, or the one a count names.
    void cycleLens(View& view, const State& state, const Context& context, const Stroke& stroke) {
      const auto lens = static_cast<std::size_t>(windowAt(view.windows, view.current).lens);
      auto next = (lens + (stroke.command == Command::next_lens ? 1 : lens_count - 1)) % lens_count;

      if (stroke.counted) {
        next = (stroke.count - 1) % lens_count;
      }

      setLens(view, state, context, static_cast<Lens>(next));
    }

    // `yy`, `yr`, `yn`: the rows are yanked, and their paths, as `command` writes them, are what
    // the clipboard takes.
    Action yankPaths(View& view, const State& state, const Context& context, Command command) {
      yank(view, state, context, PasteKind::copy);
      gather(view, state, context, false);
      view.text.clear();
      for (const auto& path : view.paths) {
        if (!view.text.empty()) {
          view.text.push('\n');
        }

        if (command == Command::yank_name) {
          view.text.append(baseOf(path.view()));
        } else if (const auto* pane = focusedPane(context); command == Command::yank_relative && pane != nullptr) {
          appendTyped(view.text, path.view(), {.cwd = pane->cwd, .home = context.home, .shell = false});
        } else {
          view.text.append(path.view());
        }
      }

      leaveVisual(view);
      ++view.revision;
      if (view.paths.empty()) {
        return {};
      }

      if (view.paths.size() == 1) {
        report(view, Tone::info, "yanked: {} · p copies it here or in another window", view.text.view());
      } else {
        report(view, Tone::info, "{} paths yanked · p copies them here or in another window", view.paths.size());
      }

      return {.kind = ActionKind::copy};
    }

    // `u`: the last change typed is taken back; with none, the last plan the runtime applied.
    Action undo(View& view, const State& state, const Context& context) {
      if (view.history.empty()) {
        if (state.undoable) {
          return {.kind = ActionKind::undo};
        }

        say(view, "Already at the oldest change");
        return {};
      }

      if (auto previous = view.history.pop()) {
        view.edits = std::move(previous.getMut());
      }

      rebuildCurrent(view, state, context);
      report(view, Tone::info, "undone · {} change{} not written", view.edits.size(), view.edits.size() == 1 ? "" : "s");
      return {};
    }

    void otherWindow(View& view, bool next) noexcept {
      view.current = (view.current + (next ? 1 : view.windows.size() - 1)) % view.windows.size();
      ++view.revision;
    }

    void onlyWindow(View& view) {
      auto kept = std::move(view.windows.atMut(view.current));

      view.windows.clear();
      view.windows.push(std::move(kept));
      view.current = 0;
      ++view.revision;
    }

    // `<C-w>T`: whether the explorer stays open after it hands a file to a pane.
    void togglePin(View& view) {
      view.pinned = !view.pinned;
      say(view, view.pinned ? "stays open when a file goes to a pane" : "closes when a file goes to a pane");
      ++view.revision;
    }

    // `gf`: the files chosen open in the editor of the tab.
    Action openFiles(View& view, const State& state, const Context& context) {
      gather(view, state, context, true);
      leaveVisual(view);
      if (view.paths.empty()) {
        say(view, "gf opens files; on a directory use <CR>, cd or s", Tone::error);
        return {};
      }

      return {.kind = ActionKind::open};
    }

    // `l`: unfolds a directory, then moves into it; on a file it opens it, as in a tree of Neovim.
    Action expand(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);
      if (window.rows.empty()) {
        return {};
      }

      const auto& row = window.rows[window.cursor];
      if (row.kind != RowKind::entry || !row.directory) {
        // What `.` repeats then is the opening.
        view.last = Command::open;
        return openFiles(view, state, context);
      }

      if (!row.expanded) {
        setExpanded(view, state, context, window.cursor, true);
      } else {
        moveBy(window, state, context, 1);
      }

      return {};
    }

    // `cd`, `s`: the directory of the row, for the focused shell to go to or for a new one to
    // start in.
    Action toDirectory(View& view, const State& state, const Context& context, bool split) {
      const auto& window = windowAt(view.windows, view.current);
      if (window.rows.empty()) {
        return {};
      }

      const auto& row = window.rows[window.cursor];

      pathOf(view.text, window, state, context, row);
      if (view.text.empty()) {
        return {};
      }

      if (!row.directory) {
        const Text parent{view.memory, parentOf(view.text.view())};

        view.text.assign(parent.view());
      }

      if (split) {
        return {.kind = ActionKind::split};
      }

      const auto* pane = focusedPane(context);
      if (pane == nullptr || pane->kind != PaneKind::shell) {
        say(view, "cd is for a shell's pane; s opens one here", Tone::error);
        return {};
      }

      return {.kind = ActionKind::change_directory, .pane = pane->id};
    }

    // `@`: the rows chosen, mentioned to the agent of the tab.
    Action mention(View& view, const State& state, const Context& context) {
      const auto agent = std::ranges::find(context.panes, PaneKind::agent, &PaneFact::kind);
      if (agent == context.panes.end()) {
        say(view, "No agent in this tab to mention it to", Tone::error);
        return {};
      }

      gather(view, state, context, false);
      leaveVisual(view);
      if (view.paths.empty()) {
        return {};
      }

      typeFor(view, context, *agent, "@");
      return {.kind = ActionKind::mention, .pane = agent->id};
    }

    // `=`: the diff of each file chosen unfolds below its row, or folds.
    void toggleDiff(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      gather(view, state, context, true);
      for (const auto& path : view.paths) {
        if (holds(window.diffs, path.view())) {
          drop(window.diffs, path.view());
        } else {
          add(window.diffs, path.view());
        }
      }

      leaveVisual(view);
      rebuildCurrent(view, state, context);
    }

    // The command line opens with `prefill` typed.
    void startCommand(View& view, std::string_view prefill) {
      view.prefill.assign(prefill);
      view.mode = Mode::command;
      ++view.revision;
    }

    void startSearch(View& view) {
      view.prefill.assign(windowAt(view.windows, view.current).filter.view());
      view.mode = Mode::search;
      ++view.revision;
    }

    constexpr Sort sortAfter(Sort sort) noexcept {
      switch (sort) {
      case Sort::name:
        return Sort::size;
      case Sort::size:
        return Sort::modified;
      case Sort::modified:
        return Sort::name;
      }

      return Sort::name;
    }

    void cycleSort(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      window.sort = sortAfter(window.sort);
      rebuildCurrent(view, state, context);
    }

    void toggleHidden(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      window.hidden = !window.hidden;
      rebuildCurrent(view, state, context);
    }

    void toggleIgnored(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      window.ignored = !window.ignored;
      rebuildCurrent(view, state, context);
    }

    void refresh(View& view, State& state) {
      invalidate(state, {});
      say(view, "reading again");
      ++view.revision;
    }

    void toggleFollow(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      window.follow = !window.follow;
      if (window.follow) {
        followPane(window, context);
      }

      rebuildCurrent(view, state, context);
    }

    void startVisual(View& view) {
      auto& window = windowAt(view.windows, view.current);

      view.mode = Mode::visual;
      window.anchor = window.cursor;
      window.picked.clear();
      ++view.revision;
    }

    void showHelp(View& view) noexcept {
      view.mode = Mode::help;
      ++view.revision;
    }

    // Escape leaves the selection, or else drops the filter.
    void escape(View& view, const State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);

      if (view.mode == Mode::visual || !window.picked.empty()) {
        leaveVisual(view);
      } else if (!window.filter.empty()) {
        window.filter.clear();
        rebuildCurrent(view, state, context);
      }

      ++view.revision;
    }

    Action runCommand(View& view, State& state, const Context& context, const Stroke& stroke) { // NOLINT(readability-function-size): one case per command, in one switch, is what makes a command without its case an error
      auto& window = windowAt(view.windows, view.current);
      const auto count = static_cast<std::int64_t>(stroke.count);
      const auto half = std::max<std::int64_t>(1, window.page / 2);

      switch (stroke.command) {
      case Command::none:
      case Command::repeat:
        // `.` is another command by the time it gets here: `run` names the one it repeats.
        break;
      case Command::down:
      case Command::next_match:
        moveBy(window, state, context, count);
        break;
      case Command::up:
      case Command::previous_match:
        moveBy(window, state, context, -count);
        break;
      case Command::top:
        goToNumber(window, state, context, stroke.counted ? stroke.count : 1);
        break;
      case Command::bottom:
        goToNumber(window, state, context, stroke.counted ? stroke.count : std::numeric_limits<std::uint32_t>::max());
        break;
      case Command::half_page_down:
        moveBy(window, state, context, half * count);
        break;
      case Command::half_page_up:
        moveBy(window, state, context, -half * count);
        break;
      case Command::collapse:
        collapse(view, state, context);
        break;
      case Command::expand:
        return expand(view, state, context);
      case Command::toggle_fold:
        toggleFold(view, state, context);
        break;
      case Command::fold_all:
        foldAll(view, state, context);
        break;
      case Command::unfold_all:
        unfoldAll(view, state, context);
        break;
      case Command::next_change:
        nextChange(view, state, context, 1);
        break;
      case Command::previous_change:
        nextChange(view, state, context, -1);
        break;
      case Command::enter:
        return enter(view, state, context);
      case Command::parent:
        goUp(view, state, context);
        break;
      case Command::workspace_root:
        rootAt(view, state, context, context.workspace.starts_with('/') ? context.workspace : context.home);
        break;
      case Command::home:
        rootAt(view, state, context, context.home.starts_with('/') ? context.home : std::string_view{"/"});
        break;
      case Command::scope_pane:
        setScope(view, state, context, Scope::pane);
        break;
      case Command::scope_workspace:
        setScope(view, state, context, Scope::workspace);
        break;
      case Command::scope_machine:
        setScope(view, state, context, Scope::machine);
        break;
      case Command::mark:
        setMark(view, stroke.argument);
        break;
      case Command::jump_to_mark:
        jumpToMark(view, state, context, stroke.argument.view());
        break;
      case Command::jump_back:
        jump(view, state, context, true);
        break;
      case Command::jump_forward:
        jump(view, state, context, false);
        break;
      case Command::next_lens:
      case Command::previous_lens:
        cycleLens(view, state, context, stroke);
        break;
      case Command::rename:
      case Command::rename_whole:
        startRename(view, state);
        break;
      case Command::create:
        startCreate(view, state, context);
        break;
      case Command::cut:
        cut(view, state, context);
        break;
      case Command::yank:
      case Command::yank_relative:
      case Command::yank_name:
        return yankPaths(view, state, context, stroke.command);
      case Command::paste:
        paste(view, state, context);
        break;
      case Command::undo:
        return undo(view, state, context);
      case Command::write:
        write(view, false);
        break;
      case Command::split_vertical:
        split(view, state, context, true);
        break;
      case Command::split_horizontal:
        split(view, state, context, false);
        break;
      case Command::next_window:
      case Command::window_right:
      case Command::window_down:
        otherWindow(view, true);
        break;
      case Command::previous_window:
      case Command::window_left:
      case Command::window_up:
        otherWindow(view, false);
        break;
      case Command::close_window:
        return quit(view, false, false);
      case Command::only_window:
        onlyWindow(view);
        break;
      case Command::pin:
        togglePin(view);
        break;
      case Command::open:
        return openFiles(view, state, context);
      case Command::change_directory:
        return toDirectory(view, state, context, false);
      case Command::split_shell:
        return toDirectory(view, state, context, true);
      case Command::mention:
        return mention(view, state, context);
      case Command::toggle_diff:
        toggleDiff(view, state, context);
        break;
      case Command::stage:
        return index(view, state, context, PlanVerb::stage);
      case Command::unstage:
        return index(view, state, context, PlanVerb::unstage);
      case Command::discard:
        discard(view, state, context);
        break;
      case Command::commit:
        startCommand(view, "commit ");
        break;
      case Command::cycle_sort:
        cycleSort(view, state, context);
        break;
      case Command::toggle_hidden:
        toggleHidden(view, state, context);
        break;
      case Command::toggle_ignored:
        toggleIgnored(view, state, context);
        break;
      case Command::refresh:
        refresh(view, state);
        break;
      case Command::toggle_follow:
        toggleFollow(view, state, context);
        break;
      case Command::visual:
        startVisual(view);
        break;
      case Command::search:
        startSearch(view);
        break;
      case Command::command_line:
        startCommand(view, {});
        break;
      case Command::help:
        showHelp(view);
        break;
      case Command::quit:
        return quit(view, false, true);
      case Command::escape:
        escape(view, state, context);
        break;
      }

      return {};
    }

    // The commands `.` repeats: the ones that change something or hand something over.
    constexpr bool repeats(Command command) noexcept {
      constexpr ds::Array<Command, 8> repeated{Command::cut, Command::paste, Command::open, Command::mention, Command::stage, Command::unstage, Command::toggle_diff, Command::enter};

      return std::ranges::contains(repeated, command);
    }

    // The commands a count gives that many rows to, from the selected one.
    constexpr bool takesRows(Command command) noexcept {
      constexpr ds::Array<Command, 7> counted{Command::cut, Command::yank, Command::yank_relative, Command::yank_name, Command::stage, Command::unstage, Command::discard};

      return std::ranges::contains(counted, command);
    }

    // Runs a command that is not `.`, which `.` then repeats if it is one of those.
    Action dispatch(View& view, State& state, const Context& context, const Stroke& stroke) {
      if (repeats(stroke.command)) {
        view.last = stroke.command;
      }

      if (takesRows(stroke.command)) {
        windowAt(view.windows, view.current).reach = stroke.counted ? std::max<std::uint32_t>(stroke.count, 1) : 1;
      }

      const auto action = runCommand(view, state, context, stroke);

      // The command may have closed the window it ran in.
      if (view.current < view.windows.size()) {
        windowAt(view.windows, view.current).reach = 1;
      }

      return action;
    }

    Action run(View& view, State& state, const Context& context, const Stroke& stroke) {
      if (stroke.command != Command::repeat) {
        return dispatch(view, state, context, stroke);
      }

      // `.`: the last command it repeats, with the count typed now. That one is never `.`.
      if (view.last == Command::none) {
        return {};
      }

      return dispatch(view, state, context, {.command = view.last, .count = stroke.count, .counted = stroke.counted});
    }

    // What follows the command's name on the command line.
    constexpr std::string_view argumentOf(std::string_view line) noexcept {
      const auto space = line.find(' ');
      if (space == std::string_view::npos) {
        return {};
      }

      line.remove_prefix(space);
      line.remove_prefix(std::min(line.find_first_not_of(' '), line.size()));
      return line;
    }

    // A line of the command line: the name of the command, and what follows it.
    struct Typed {
      std::string_view name;
      std::string_view argument;
    };

    // What a command that changed what shows ends with.
    Action changed(View& view) noexcept {
      ++view.revision;
      return {};
    }

    // The commands that take no argument and say themselves what they changed: `:w` and `:q`
    // with their marks, `:only` and `:pin`. None for another name.
    ds::Option<Action> plainCommand(View& view, std::string_view name) {
      if (name == "w" || name == "write" || name == "wa") {
        write(view, false);
        return changed(view);
      }

      if (name == "w!") {
        write(view, true);
        return changed(view);
      }

      if (name == "q" || name == "quit" || name == "close") {
        return quit(view, false, false);
      }

      if (name == "q!") {
        return quit(view, true, true);
      }

      if (name == "qa") {
        return quit(view, false, true);
      }

      if (name == "only") {
        onlyWindow(view);
        return Action{};
      }

      if (name == "pin") {
        togglePin(view);
        return Action{};
      }

      return ds::none;
    }

    // `:e!`, and `:e`, `:cd`, `:vs` and `:sp`, which take this window or a new one to a path; none
    // for another name.
    ds::Option<Action> goCommand(View& view, State& state, const Context& context, const Typed& typed) {
      const auto name = typed.name;

      if (name == "e!" && typed.argument.empty()) {
        view.edits.clear();
        view.history.clear();
        invalidate(state, {});
        say(view, "changes discarded · reading again");
        rebuildCurrent(view, state, context);
        return changed(view);
      }

      const bool splits = name == "vs" || name == "vsplit" || name == "sp" || name == "split";
      if (!splits && name != "e" && name != "edit" && name != "cd") {
        return ds::none;
      }

      if (splits) {
        split(view, state, context, name.starts_with('v'));
      }

      if (!typed.argument.empty()) {
        Text target{view.memory};

        resolve(target, typed.argument, windowAt(view.windows, view.current), context);
        go(view, {.root = target.view()});
        rebuildCurrent(view, state, context);
      }

      return changed(view);
    }

    constexpr ds::Option<Lens> lensNamed(std::string_view name) noexcept {
      if (name == "tree") {
        return Lens::tree;
      }

      if (name == "changes") {
        return Lens::changes;
      }

      if (name == "panes") {
        return Lens::panes;
      }

      return ds::none;
    }

    void listMarks(View& view) {
      Text listed{view.memory};

      for (const auto& mark : view.marks) {
        ds::formatTo(listed, "{}'{} {}", listed.empty() ? "" : " · ", mark.letter.view(), mark.root.view());
      }

      say(view, listed.empty() ? std::string_view{"No marks set"} : listed.view());
    }

    // The commands that change what the windows show; false for another name.
    bool showCommand(View& view, const State& state, const Context& context, std::string_view name) {
      if (const auto lens = lensNamed(name)) {
        setLens(view, state, context, *lens);
      } else if (name == "follow") {
        auto& window = windowAt(view.windows, view.current);

        window.follow = true;
        followPane(window, context);
        rebuildCurrent(view, state, context);
      } else if (name == "marks") {
        listMarks(view);
      } else if (name == "help") {
        view.mode = Mode::help;
      } else {
        return false;
      }

      return true;
    }

    Action command(View& view, State& state, const Context& context, std::string_view line) {
      line.remove_prefix(std::min(line.find_first_not_of(" :"), line.size()));
      while (line.ends_with(' ')) {
        line.remove_suffix(1);
      }

      const Typed typed{.name = line.substr(0, line.find(' ')), .argument = argumentOf(line)};

      if (typed.name.empty()) {
        return {};
      }

      if (const auto done = plainCommand(view, typed.name)) {
        return *done;
      }

      if (const auto done = goCommand(view, state, context, typed)) {
        return *done;
      }

      if (typed.name == "commit") {
        if (typed.argument.empty()) {
          say(view, "A commit needs a message: :commit Describe the change", Tone::error);
          return {};
        }

        view.text.assign(typed.argument);
        return {.kind = ActionKind::commit};
      }

      if (!showCommand(view, state, context, typed.name)) {
        report(view, Tone::error, "E492: Not an editor command: {}", typed.name);
      }

      return changed(view);
    }

  }

  void open(View& view, const State& state, const Context& context, std::uint64_t machine) {
    view.open = true;
    view.mode = Mode::normal;
    clear(view.keys);
    if (view.windows.empty()) {
      auto& made = view.windows.push(ds::makeBox<Window>(view.memory, view.memory)).getMut();

      made.machine = machine;
      view.current = 0;
    }

    say(view, {});
    static_cast<void>(follow(view, context, machine));
    rebuild(view, state, context, machine);
  }

  void close(View& view) noexcept {
    view.open = false;
    view.mode = Mode::normal;
    clear(view.keys);
    ++view.revision;
  }

  bool follow(View& view, const Context& context, std::uint64_t machine) {
    const auto* pane = focusedPane(context);
    const auto cwd = pane == nullptr ? std::string_view{} : pane->cwd;
    bool moved = false;

    for (auto& window : view.windows.viewMut()) {
      if (window->machine == machine && window->follow && (window->root.empty() || window->followed != context.focused || window->followed_cwd.view() != cwd)) {
        followPane(window.getMut(), context);
        moved = true;
      }
    }

    if (moved) {
      ++view.revision;
    }

    return moved;
  }

  void rebuild(View& view, const State& state, const Context& context, std::uint64_t machine) {
    for (auto& window : view.windows.viewMut()) {
      if (window->machine == machine) {
        buildWindow(window.getMut(), view.edits, state, context);
      }
    }

    view.built = state.revision;
    ++view.revision;
  }

  namespace {

    // `kind` of `path`, when the cache of the machine lacks it and has not asked for it.
    tbc::val_a<ds::Option<Need>> lacking(const State& state, NeedKind kind, tbc::val_a<std::string_view> path) {
      const Need wanted{.kind = kind, .path = path};
      if (path.starts_with('/') && lacks(state, wanted)) {
        return wanted;
      }

      return ds::none;
    }

    // The listing, or the sizes, that the tree of a window lacks: of its root first, then of each
    // directory it unfolds below it.
    tbc::val_a<ds::Option<Need>> lackingBelow(tbc::ref_a<Window> window, const State& state, NeedKind kind) {
      if (auto wanted = lacking(state, kind, window.root.view())) {
        return wanted;
      }

      for (const auto& path : window.expanded) {
        if (!within(path.view(), window.root.view())) {
          continue;
        }

        if (auto wanted = lacking(state, kind, path.view())) {
          return wanted;
        }
      }

      return ds::none;
    }

    // The listings the windows of `machine` lack, or with `sizes` the sizes their trees do.
    tbc::val_a<ds::Option<Need>> treeNeed(tbc::ref_a<View> view, const State& state, std::uint64_t machine, bool sizes) {
      for (const auto& window : view.windows) {
        // Every lens but the panes' reads the directories; the tree alone shows their sizes.
        const bool reads = sizes ? window->lens == Lens::tree : window->lens != Lens::panes;
        if (window->machine != machine || !reads) {
          continue;
        }

        if (auto wanted = lackingBelow(*window, state, sizes ? NeedKind::sizes : NeedKind::listing)) {
          return wanted;
        }
      }

      return ds::none;
    }

    // The previews the windows of `machine` lack: of each selection, and of each diff unfolded.
    tbc::val_a<ds::Option<Need>> previewNeed(tbc::ref_a<View> view, const State& state, std::uint64_t machine) {
      for (const auto& window : view.windows) {
        if (window->machine != machine) {
          continue;
        }

        if (window->lens != Lens::panes && !window->rows.empty() && window->rows[window->cursor].kind != RowKind::added) {
          if (auto wanted = lacking(state, NeedKind::inspection, window->selected.view())) {
            return wanted;
          }
        }

        for (const auto& path : window->diffs) {
          if (auto wanted = lacking(state, NeedKind::inspection, path.view())) {
            return wanted;
          }
        }
      }

      return ds::none;
    }

  }

  tbc::val_a<ds::Option<Need>> need(tbc::ref_a<View> view, const State& state, std::uint64_t machine) {
    // What each window lists first; then what git says, the preview, and the sizes last.
    if (auto wanted = treeNeed(view, state, machine, false)) {
      return wanted;
    }

    // What git says is asked for the window that takes the keys alone. One answer is kept: two
    // windows in two repositories would ask for theirs in turns, without end.
    if (view.current < view.windows.size() && view.windows[view.current]->machine == machine) {
      if (auto wanted = lacking(state, NeedKind::changes, view.windows[view.current]->root.view())) {
        return wanted;
      }
    }

    if (auto wanted = previewNeed(view, state, machine)) {
      return wanted;
    }

    return treeNeed(view, state, machine, true);
  }

  Action press(View& view, State& state, const Context& context, KeyChord chord) {
    if (!view.open || view.windows.empty()) {
      return {};
    }

    const auto key = notation(chord);
    const auto text = key.view();

    if (view.mode == Mode::plan) {
      const bool accepted = text == "y" || text == "<CR>";

      view.mode = Mode::normal;
      ++view.revision;
      if (accepted) {
        view.writing = true;
        return {.kind = ActionKind::apply, .overwrite = view.overwrite};
      }

      view.plan.clear();
      say(view, "Plan cancelled · the changes are still pending");
      return {};
    }

    if (view.mode == Mode::help) {
      view.mode = Mode::normal;
      ++view.revision;
      return {};
    }

    if (view.mode != Mode::normal && view.mode != Mode::visual) {
      return {};
    }

    const auto stroke = feed(view.keys, chord, view.mode == Mode::visual);

    ++view.revision;
    if (stroke.command == Command::none) {
      return {};
    }

    say(view, {});
    return run(view, state, context, stroke);
  }

  void typed(View& view, const State& state, const Context& context, std::string_view text) {
    if (view.mode != Mode::search || view.windows.empty()) {
      return;
    }

    windowAt(view.windows, view.current).filter.assign(text);
    rebuildCurrent(view, state, context);
  }

  Action submit(View& view, State& state, const Context& context, std::string_view text) {
    if (view.windows.empty()) {
      return {};
    }

    switch (view.mode) {
    case Mode::insert:
      endInsert(view, state, context, text);
      return {};
    case Mode::search:
      windowAt(view.windows, view.current).filter.assign(text);
      view.mode = Mode::normal;
      rebuildCurrent(view, state, context);
      return {};
    case Mode::command:
      view.mode = Mode::normal;
      return command(view, state, context, text);
    case Mode::normal:
    case Mode::visual:
    case Mode::plan:
    case Mode::help:
      break;
    }

    return {};
  }

  void cancel(View& view, const State& state, const Context& context) {
    if (view.windows.empty()) {
      return;
    }

    switch (view.mode) {
    case Mode::insert:
      // A new entry with no name yet is not added.
      if (view.inserting != 0) {
        const auto id = view.inserting;

        view.edits.retain([&](const Edit& edit) {
          return edit.id != id || !edit.name.empty();
        });

        view.inserting = 0;
      }

      break;
    case Mode::search:
      windowAt(view.windows, view.current).filter.clear();
      break;
    case Mode::plan:
      view.plan.clear();
      say(view, "Plan cancelled · the changes are still pending");
      break;
    case Mode::visual:
      leaveVisual(view);
      break;
    case Mode::command:
    case Mode::help:
    case Mode::normal:
      break;
    }

    view.mode = Mode::normal;
    clear(view.keys);
    rebuildCurrent(view, state, context);
  }

  void select(View& view, const State& state, const Context& context, const Pick& pick) {
    const auto window = pick.window;
    const auto row = pick.row;

    if (window >= view.windows.size() || view.mode == Mode::plan || view.mode == Mode::help) {
      return;
    }

    view.current = window;

    auto& chosen_window = windowAt(view.windows, view.current);
    if (row >= chosen_window.rows.size() || !selectable(chosen_window.rows[row].kind)) {
      ++view.revision;
      return;
    }

    if (pick.extend) {
      // From the selection up to the row, as a visual selection.
      chosen_window.anchor = chosen_window.anchor.valueOr(chosen_window.cursor);
      chosen_window.picked.clear();
      view.mode = Mode::visual;
    } else if (pick.toggle) {
      const auto picked = static_cast<std::uint32_t>(row);

      if (chosen_window.picked.empty()) {
        chosen_window.picked.push(static_cast<std::uint32_t>(chosen_window.cursor));
      }

      if (std::ranges::contains(chosen_window.picked, picked)) {
        chosen_window.picked.retain([&](std::uint32_t kept) {
          return kept != picked;
        });
      } else {
        chosen_window.picked.push(picked);
      }
    } else {
      leaveVisual(view);
    }

    choose(chosen_window, state, context, row);
    ++view.revision;
  }

  Action activate(View& view, State& state, const Context& context, const Pick& pick) {
    select(view, state, context, {.window = pick.window, .row = pick.row});
    if (pick.window >= view.windows.size() || pick.row >= windowAt(view.windows, view.current).rows.size() || view.mode != Mode::normal) {
      return {};
    }

    return run(view, state, context, {.command = Command::enter});
  }

  void toggle(View& view, const State& state, const Context& context, const Pick& pick) {
    select(view, state, context, {.window = pick.window, .row = pick.row});
    if (pick.window < view.windows.size() && pick.row < windowAt(view.windows, view.current).rows.size()) {
      setExpanded(view, state, context, pick.row, !windowAt(view.windows, view.current).rows[pick.row].expanded);
    }
  }

  void resize(View& view, const WindowRows& shown) noexcept {
    if (shown.window < view.windows.size()) {
      auto& resized = view.windows.atMut(shown.window).getMut();

      resized.page = static_cast<std::uint16_t>(std::clamp<std::int64_t>(shown.count, 1, std::numeric_limits<std::uint16_t>::max()));
      reveal(resized);
      ++view.revision;
    }
  }

  void scroll(View& view, const WindowRows& moved) noexcept {
    if (moved.window >= view.windows.size()) {
      return;
    }

    auto& scrolled = view.windows.atMut(moved.window).getMut();
    const auto page = std::max<std::size_t>(1, scrolled.page);
    const auto last = static_cast<std::int64_t>(scrolled.rows.size() > page ? scrolled.rows.size() - page : 0);

    scrolled.top = static_cast<std::size_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(scrolled.top) + moved.count, 0, last));
    ++view.revision;
  }

  void settle(View& view, const State& state, const Context& context, std::uint64_t machine) {
    if (view.settled == state.settled) {
      return;
    }

    view.settled = state.settled;
    if (!state.error.view().empty()) {
      say(view, state.error.view(), Tone::error);
    } else if (!state.committed.empty() && state.outcomes.empty()) {
      report(view, Tone::info, "[{}] · committed by the runtime of {}", state.committed.view(), context.machine);
    } else {
      const auto text = outcomeText(state);

      say(view, text.view(), std::ranges::any_of(state.outcomes, [](const Outcome& outcome) {
        return outcome.outcome != FileOutcome::done && outcome.outcome != FileOutcome::renamed;
      })
                                 ? Tone::error
                                 : Tone::info);
      // The changes that were written are no longer pending.
      if (view.writing && !state.undone) {
        view.edits.clear();
        view.history.clear();
      }
    }

    view.writing = false;
    view.plan.clear();
    rebuild(view, state, context, machine);
  }

  std::size_t operations(tbc::ref_a<View> view, std::uint64_t machine, tbc::mut_a<Operations> output) noexcept {
    std::size_t count = 0;

    for (const auto& step : view.plan) {
      if (step.machine != machine || count == output.size()) {
        continue;
      }

      FileOperationKind kind = FileOperationKind::trash;

      switch (step.verb) {
      case PlanVerb::create:
        kind = step.directory ? FileOperationKind::create_directory : FileOperationKind::create_file;
        break;
      case PlanVerb::move:
        kind = FileOperationKind::move;
        break;
      case PlanVerb::copy:
        kind = FileOperationKind::copy;
        break;
      case PlanVerb::remove:
        kind = FileOperationKind::trash;
        break;
      case PlanVerb::restore:
        kind = FileOperationKind::restore;
        break;
      case PlanVerb::stage:
        kind = FileOperationKind::stage;
        break;
      case PlanVerb::unstage:
        kind = FileOperationKind::unstage;
        break;
      }

      output.atMut(count++) = {.kind = kind, .source = step.source.view(), .target = step.target.view(), .identity = step.identity};
    }

    return count;
  }

}
