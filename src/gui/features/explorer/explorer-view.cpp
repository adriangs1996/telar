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

    void join(Text& path, std::string_view directory, std::string_view name) {
      path.assign(directory);
      if (!directory.ends_with('/')) {
        path.push('/');
      }

      path.append(name);
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
      const auto at = static_cast<std::uint32_t>(window.text.size());

      window.text.extend(std::span<const char>{text});
      return at;
    }

    void pushText(Window& window, RowKind kind, std::uint8_t depth, std::string_view text, std::uint32_t item = 0, DiffTone tone = DiffTone::context) {
      const auto at = keepText(window, text);

      window.rows.push({.kind = kind, .depth = depth, .tone = tone, .text = at, .text_size = static_cast<std::uint32_t>(text.size()), .item = item});
    }

    // The lines of a file's diff, below its row.
    void pushDiff(Window& window, std::string_view diff, std::uint8_t depth) {
      std::size_t lines = 0;

      while (!diff.empty() && lines < ViewLimits::diff_lines) {
        const auto end = diff.find('\n');
        const auto line = diff.substr(0, end);
        const auto tone = line.starts_with("@@") ? DiffTone::hunk : line.starts_with('+') ? DiffTone::added
                                                                : line.starts_with('-')   ? DiffTone::removed
                                                                                          : DiffTone::context;

        pushText(window, RowKind::diff, depth, line, 0, tone);
        diff.remove_prefix(end == std::string_view::npos ? diff.size() : end + 1);
        ++lines;
      }

      if (!diff.empty()) {
        pushText(window, RowKind::note, depth, "… the preview shows the rest");
      }
    }

    // The rows of the changes not written that add an entry to `directory`.
    void pushAdded(Build& build, std::string_view directory, std::uint8_t depth) {
      for (const auto& edit : build.edits) {
        if ((edit.kind == EditKind::create || edit.kind == EditKind::paste) && edit.machine == build.window.machine && edit.path.view() == directory) {
          const auto at = keepText(build.window, edit.name.view());

          build.window.rows.push({.kind = RowKind::added, .depth = depth, .directory = edit.directory, .text = at, .text_size = static_cast<std::uint32_t>(edit.name.size()), .item = edit.id});
        }
      }
    }

    void walk(Build& build, std::string_view path, std::uint8_t depth) {
      auto& window = build.window;
      const auto holder = holderOf(build.state, path);
      if (!holder) {
        return;
      }

      const auto& directory = *build.state.directories[*holder];
      if (!directory.listed) {
        pushText(window, RowKind::note, depth, "reading…");
        return;
      }

      if (directory.failed) {
        pushText(window, RowKind::note, depth, "this account may not read it, or it is gone");
        return;
      }

      // The entries this level lists, in the window's order.
      const auto first = build.order.size();
      std::uint64_t largest = 1;

      for (std::size_t index = 0; index < directory.entries.size(); ++index) {
        const auto& entry = directory.entries[index];
        const auto name = directory.name(entry);
        Text child{build.order.memory()};

        join(child, path, name);

        const bool hidden = name.starts_with('.');
        const bool ignored = standing(build.state.repository, child.view(), entry.directory).ignored;

        if (depth == 0) {
          window.bytes += entry.size;
          window.hidden_entries += hidden && !window.hidden ? 1 : 0;
          window.ignored_entries += ignored && !window.ignored && !(hidden && !window.hidden) ? 1 : 0;
        }

        // A filter keeps an unfolded directory to look below it, and drops it later if nothing
        // there matched.
        const bool unfolded = entry.directory && !window.filter.empty() && holds(window.expanded, child.view());

        if ((hidden && !window.hidden) || (ignored && !window.ignored) || (!unfolded && !holdsFolded(name, window.filter.view()))) {
          continue;
        }

        build.order.push(static_cast<std::uint32_t>(index));
        largest = std::max(largest, entry.size);
      }

      const auto listed = build.order.viewMut().subspan(first);

      if (window.sort != Sort::name) {
        std::ranges::stable_sort(listed, [&](std::uint32_t left, std::uint32_t right) {
          const auto& a = directory.entries[left];
          const auto& b = directory.entries[right];

          return window.sort == Sort::size ? a.size > b.size : std::pair{a.identity.modified_seconds, a.identity.modified_nanoseconds} > std::pair{b.identity.modified_seconds, b.identity.modified_nanoseconds};
        });
      }

      constexpr std::uint64_t whole = 1000;

      for (std::size_t place = first; place < build.order.size(); ++place) {
        const auto index = build.order[place];
        const auto& entry = directory.entries[index];
        Text child{build.order.memory()};

        join(child, path, directory.name(entry));

        const bool expanded = entry.directory && holds(window.expanded, child.view());

        window.rows.push({
            .kind = RowKind::entry,
            .depth = depth,
            .directory = entry.directory,
            .expanded = expanded,
            .holder = *holder,
            .entry = index,
            .share = static_cast<std::uint16_t>(entry.size * whole / largest),
        });

        if (!entry.directory && holds(window.diffs, child.view())) {
          if (const auto* inspection = inspected(build.state, child.view())) {
            pushDiff(window, inspection->diff.view(), static_cast<std::uint8_t>(depth + 1));
          }
        }

        const auto own = window.rows.size();

        if (expanded && depth + 1 < ViewLimits::depth) {
          walk(build, child.view(), static_cast<std::uint8_t>(depth + 1));
        }

        // An unfolded directory the filter kept only to look below it, where nothing matched.
        if (expanded && window.rows.size() == own && !holdsFolded(directory.name(entry), window.filter.view())) {
          window.rows.truncate(own - 1);
        }
      }

      build.order.truncate(first);
      pushAdded(build, path, depth);
      if (!directory.whole()) {
        pushText(window, RowKind::note, depth, "reading more…");
      } else if (directory.total > directory.entries.size()) {
        Text more{build.order.memory()};

        ds::formatTo(more, "… {} more entries are not listed", directory.total - directory.entries.size());
        pushText(window, RowKind::note, depth, more.view());
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

    // The changed paths of the repository in three groups, as `git status` lists them.
    void buildChanges(Window& window, const State& state) {
      const auto& repository = state.repository;

      struct Group {
        std::string_view title;
        bool (*belongs)(const Change&) noexcept;
      };

      const ds::Array<Group, 3> groups{
          Group{.title = "Staged", .belongs = [](const Change& change) noexcept {
                  return change.staged != FileState::unchanged && change.staged != FileState::ignored;
                }},
          Group{.title = "Unstaged", .belongs = [](const Change& change) noexcept {
                  return change.unstaged != FileState::unchanged && change.unstaged != FileState::ignored && change.unstaged != FileState::untracked;
                }},
          Group{.title = "Untracked", .belongs = [](const Change& change) noexcept {
                  return change.unstaged == FileState::untracked;
                }},
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
            pushText(window, RowKind::header, 0, group.title);
            titled = true;
          }

          pushText(window, RowKind::change, 0, path, static_cast<std::uint32_t>(index));
          window.rows.backMut().directory = path.ends_with('/');
        }
      }
    }

    void buildPanes(Window& window, const Context& context) {
      window.loading = false;
      for (std::size_t index = 0; index < context.panes.size(); ++index) {
        const auto& pane = context.panes[index];
        if (holdsFolded(pane.title, window.filter.view()) || holdsFolded(pane.cwd, window.filter.view())) {
          pushText(window, RowKind::pane, 0, pane.cwd, static_cast<std::uint32_t>(index));
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
      } else if (!(row.kind == RowKind::entry && row.directory && row.expanded)) {
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

    // Roots the current window at `root`, with `selected` chosen there.
    void go(View& view, std::string_view root, std::string_view selected, bool jump) {
      auto& window = windowAt(view.windows, view.current);
      const Text target{view.memory, root};
      const Text chosen{view.memory, selected};

      if (jump) {
        pushJump(view);
      }

      window.root.assign(target.view());
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
        join(joined, window.root.view(), argument);
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
        appendTyped(view.text, path.view(), pane.cwd, context.home, prefix.empty());
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

  View::View(Memory& memory)
      : memory(memory),
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

    const auto found = std::ranges::find(view.edits, row.item, &Edit::id);

    return found == view.edits.end() ? nullptr : std::to_address(found);
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

    return std::string_view{window.text.data(), window.text.size()}.substr(row.text, row.text_size);
  }

  void pathOf(ds::String<Memory>& path, const Window& window, const State& state, const Context& context, const Row& row) {
    path.clear();
    switch (row.kind) {
    case RowKind::entry:
      if (row.holder < state.directories.size()) {
        join(path, state.directories[row.holder]->path.view(), nameOf(window, state, row));
      }

      break;
    case RowKind::change: {
      auto relative = nameOf(window, state, row);

      if (relative.ends_with('/')) {
        relative.remove_suffix(1);
      }

      join(path, state.repository.root.view(), relative);
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
        if (next < 0 || next >= static_cast<std::int64_t>(window.rows.size())) {
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
      std::string_view root = window.scope == Scope::machine ? context.home : window.scope == Scope::workspace ? context.workspace
                                                                                                               : cwd;

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
          return !((edit.kind == EditKind::rename || edit.kind == EditKind::restore) && edit.machine == window.machine && edit.path.view() == path.view());
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
      auto& window = windowAt(view.windows, view.current);

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
          join(step(PlanVerb::create, edit).target, edit.path.view(), edit.name.view());
        }
      }

      for (const auto& edit : view.edits) {
        if (edit.kind == EditKind::rename) {
          auto& made = step(PlanVerb::move, edit);

          made.source.assign(edit.path.view());
          join(made.target, parentOf(edit.path.view()), edit.name.view());
        } else if (edit.kind == EditKind::paste) {
          auto& made = step(edit.paste == PasteKind::move ? PlanVerb::move : PlanVerb::copy, edit);

          made.source.assign(edit.source.view());
          join(made.target, edit.path.view(), edit.name.view());
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

        join(path, directory.path.view(), view.draft.view());
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

    // Enter ends insert mode: the name typed is the change.
    void endInsert(View& view, const State& state, const Context& context, std::string_view typed) {
      auto& window = windowAt(view.windows, view.current);
      const auto name = typed.ends_with('/') ? typed.substr(0, typed.size() - 1) : typed;
      const bool acceptable = !name.empty() && !name.contains('/') && name != "." && name != ".." && name.size() <= FileLimits::name_bytes;

      view.mode = Mode::normal;
      if (view.inserting != 0) {
        const auto id = view.inserting;
        Edit* found = nullptr;

        for (auto& edit : view.edits.viewMut()) {
          if (edit.id == id) {
            found = &edit;
          }
        }

        view.inserting = 0;
        if (found == nullptr) {
          return;
        }

        if (!acceptable) {
          view.edits.retain([&](const Edit& edit) {
            return edit.id != id;
          });

          say(view, typed.empty() ? "No name: nothing added" : "A name holds no slash: nothing added", typed.empty() ? Tone::info : Tone::error);
        } else {
          found->name.assign(name);
          // A name that ends in a slash is a directory's.
          found->directory = found->kind == EditKind::create ? typed.ends_with('/') : found->directory;
        }

        rebuildCurrent(view, state, context);
        return;
      }

      if (window.rows.empty() || window.rows[window.cursor].kind != RowKind::entry) {
        return;
      }

      const auto& row = window.rows[window.cursor];
      const auto current_name = nameOf(window, state, row);
      Text path{view.memory};

      pathOf(path, window, state, context, row);
      if (!acceptable) {
        say(view, "A name holds no slash and is not empty: nothing renamed", Tone::error);
        return;
      }

      remember(view.history, view.edits, view.memory);
      view.edits.retain([&](const Edit& edit) {
        return !(edit.kind == EditKind::rename && edit.machine == window.machine && edit.path.view() == path.view());
      });

      if (name != current_name) {
        auto& edit = addEdit(view.edits, view.next_edit, EditKind::rename, window.machine, path.view());

        edit.name.assign(name);
        edit.directory = row.directory;
        edit.identity = state.directories[row.holder]->entries[row.entry].identity;
        edit.size = state.directories[row.holder]->entries[row.entry].size;
      }

      ++view.revision;
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
    Action enter(View& view, State& state, const Context& context) {
      auto& window = windowAt(view.windows, view.current);
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
        go(view, path.view(), {}, true);
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

    Action run(View& view, State& state, const Context& context, const Stroke& stroke);

    Action runCommand(View& view, State& state, const Context& context, const Stroke& stroke) {
      auto& window = windowAt(view.windows, view.current);
      const auto count = static_cast<std::int64_t>(stroke.count);
      const auto half = std::max<std::int64_t>(1, window.page / 2);

      switch (stroke.command) {
      case Command::none:
        return {};
      case Command::down:
        moveBy(window, state, context, count);
        return {};
      case Command::up:
        moveBy(window, state, context, -count);
        return {};
      case Command::top:
        goToNumber(window, state, context, stroke.counted ? stroke.count : 1);
        return {};
      case Command::bottom:
        goToNumber(window, state, context, stroke.counted ? stroke.count : std::numeric_limits<std::uint32_t>::max());
        return {};
      case Command::half_page_down:
        moveBy(window, state, context, half * count);
        return {};
      case Command::half_page_up:
        moveBy(window, state, context, -half * count);
        return {};
      case Command::collapse:
        if (!window.rows.empty() && window.rows[window.cursor].expanded) {
          setExpanded(view, state, context, window.cursor, false);
        } else if (const auto parent = parentRow(window)) {
          choose(window, state, context, *parent);
        }

        return {};
      case Command::expand:
        if (window.rows.empty()) {
          return {};
        }

        if (window.rows[window.cursor].kind == RowKind::entry && window.rows[window.cursor].directory) {
          if (!window.rows[window.cursor].expanded) {
            setExpanded(view, state, context, window.cursor, true);
          } else {
            moveBy(window, state, context, 1);
          }

          return {};
        }

        // `l` on a file opens it, as it does in a tree of Neovim.
        return run(view, state, context, {.command = Command::open});
      case Command::toggle_fold:
        if (!window.rows.empty()) {
          setExpanded(view, state, context, window.cursor, !window.rows[window.cursor].expanded);
        }

        return {};
      case Command::fold_all:
        window.expanded.clear();
        rebuildCurrent(view, state, context);
        return {};
      case Command::unfold_all: {
        // One more level each time: every directory that shows unfolds.
        Text path{view.memory};

        for (const auto& row : window.rows) {
          if (row.kind == RowKind::entry && row.directory && !row.expanded) {
            pathOf(path, window, state, context, row);
            add(window.expanded, path.view());
          }
        }

        rebuildCurrent(view, state, context);
        return {};
      }
      case Command::next_change:
        nextChange(view, state, context, 1);
        return {};
      case Command::previous_change:
        nextChange(view, state, context, -1);
        return {};
      case Command::enter:
        return enter(view, state, context);
      case Command::parent: {
        if (window.root.view() == "/") {
          return {};
        }

        const Text child{view.memory, window.root.view()};

        go(view, parentOf(child.view()), child.view(), true);
        rebuildCurrent(view, state, context);
        return {};
      }
      case Command::workspace_root:
        go(view, context.workspace.starts_with('/') ? context.workspace : context.home, {}, true);
        rebuildCurrent(view, state, context);
        return {};
      case Command::home:
        go(view, context.home.starts_with('/') ? context.home : std::string_view{"/"}, {}, true);
        rebuildCurrent(view, state, context);
        return {};
      case Command::scope_pane:
      case Command::scope_workspace:
      case Command::scope_machine:
        pushJump(view);
        window.scope = stroke.command == Command::scope_pane ? Scope::pane : stroke.command == Command::scope_workspace ? Scope::workspace
                                                                                                                        : Scope::machine;
        window.follow = true;
        window.lens = Lens::tree;
        followPane(window, context);
        rebuildCurrent(view, state, context);
        return {};
      case Command::mark: {
        const auto letter = stroke.argument.view();
        if (!isLetter(letter)) {
          say(view, "A mark is a letter", Tone::error);
          return {};
        }

        auto* mark = markOf(view.marks, letter);
        if (mark == nullptr) {
          if (view.marks.size() == ViewLimits::marks) {
            return {};
          }

          mark = &view.marks.push(Place{view.memory});
        }

        mark->letter = stroke.argument;
        mark->machine = window.machine;
        mark->root.assign(window.root.view());
        mark->selected.assign(window.selected.view());
        report(view, Tone::info, "mark {} set", letter);
        ++view.revision;
        return {};
      }
      case Command::jump_to_mark: {
        const auto* mark = markOf(view.marks, stroke.argument.view());
        if (mark == nullptr) {
          report(view, Tone::error, "E20: Mark not set: {}", stroke.argument.view());
          return {};
        }

        const Text root{view.memory, mark->root.view()};
        const Text selected{view.memory, mark->selected.view()};
        const auto machine = mark->machine;

        pushJump(view);
        windowAt(view.windows, view.current).machine = machine;
        go(view, root.view(), selected.view(), false);
        rebuildCurrent(view, state, context);
        return {};
      }
      case Command::jump_back:
      case Command::jump_forward: {
        const bool back = stroke.command == Command::jump_back;
        if (back ? view.jump == 0 : view.jump + 1 >= view.jumps.size()) {
          say(view, back ? "At the oldest place" : "At the newest place");
          return {};
        }

        // Going back from the newest place keeps where it was, to come forward to.
        if (back && view.jump == view.jumps.size()) {
          pushJump(view);
          --view.jump;
        }

        view.jump = back ? view.jump - 1 : view.jump + 1;

        const Text root{view.memory, view.jumps[view.jump].root.view()};
        const Text selected{view.memory, view.jumps[view.jump].selected.view()};

        window.machine = view.jumps[view.jump].machine;
        go(view, root.view(), selected.view(), false);
        rebuildCurrent(view, state, context);
        return {};
      }
      case Command::next_lens:
      case Command::previous_lens: {
        const auto lens = static_cast<std::size_t>(window.lens);
        const auto next = stroke.counted ? (stroke.count - 1) % lens_count : stroke.command == Command::next_lens ? (lens + 1) % lens_count
                                                                                                                  : (lens + lens_count - 1) % lens_count;

        setLens(view, state, context, static_cast<Lens>(next));
        return {};
      }
      case Command::rename:
      case Command::rename_whole:
        startRename(view, state);
        return {};
      case Command::create:
        startCreate(view, state, context);
        return {};
      case Command::cut:
        cut(view, state, context);
        return {};
      case Command::yank:
      case Command::yank_relative:
      case Command::yank_name: {
        yank(view, state, context, PasteKind::copy);
        gather(view, state, context, false);
        view.text.clear();
        for (const auto& path : view.paths) {
          if (!view.text.empty()) {
            view.text.push('\n');
          }

          if (stroke.command == Command::yank_name) {
            view.text.append(baseOf(path.view()));
          } else if (const auto* pane = focusedPane(context); stroke.command == Command::yank_relative && pane != nullptr) {
            appendTyped(view.text, path.view(), pane->cwd, context.home, false);
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
      case Command::paste:
        paste(view, state, context);
        return {};
      case Command::undo:
        if (!view.history.empty()) {
          if (auto previous = view.history.pop()) {
            view.edits = std::move(previous.getMut());
          }

          rebuildCurrent(view, state, context);
          report(view, Tone::info, "undone · {} change{} not written", view.edits.size(), view.edits.size() == 1 ? "" : "s");
          return {};
        }

        if (state.undoable) {
          return {.kind = ActionKind::undo};
        }

        say(view, "Already at the oldest change");
        return {};
      case Command::write:
        write(view, false);
        return {};
      case Command::split_vertical:
        split(view, state, context, true);
        return {};
      case Command::split_horizontal:
        split(view, state, context, false);
        return {};
      case Command::next_window:
      case Command::window_right:
      case Command::window_down:
        view.current = (view.current + 1) % view.windows.size();
        ++view.revision;
        return {};
      case Command::previous_window:
      case Command::window_left:
      case Command::window_up:
        view.current = (view.current + view.windows.size() - 1) % view.windows.size();
        ++view.revision;
        return {};
      case Command::close_window:
        return quit(view, false, false);
      case Command::only_window: {
        auto kept = std::move(view.windows.atMut(view.current));

        view.windows.clear();
        view.windows.push(std::move(kept));
        view.current = 0;
        ++view.revision;
        return {};
      }
      case Command::pin:
        view.pinned = !view.pinned;
        say(view, view.pinned ? "pinned beside the panes" : "back over the panes");
        ++view.revision;
        return {.kind = ActionKind::pin};
      case Command::open:
        gather(view, state, context, true);
        leaveVisual(view);
        if (view.paths.empty()) {
          say(view, "gf opens files; on a directory use <CR>, cd or s", Tone::error);
          return {};
        }

        return {.kind = ActionKind::open};
      case Command::change_directory:
      case Command::split_shell: {
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

        if (stroke.command == Command::split_shell) {
          return {.kind = ActionKind::split};
        }

        const auto* pane = focusedPane(context);
        if (pane == nullptr || pane->kind != PaneKind::shell) {
          say(view, "cd is for a shell's pane; s opens one here", Tone::error);
          return {};
        }

        return {.kind = ActionKind::change_directory, .pane = pane->id};
      }
      case Command::mention: {
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
      case Command::repeat:
        if (view.last == Command::none) {
          return {};
        }

        return run(view, state, context, {.command = view.last, .count = stroke.count, .counted = stroke.counted});
      case Command::toggle_diff: {
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
        return {};
      }
      case Command::stage:
        return index(view, state, context, PlanVerb::stage);
      case Command::unstage:
        return index(view, state, context, PlanVerb::unstage);
      case Command::discard:
        discard(view, state, context);
        return {};
      case Command::commit:
        view.prefill.assign("commit ");
        view.mode = Mode::command;
        ++view.revision;
        return {};
      case Command::cycle_sort:
        window.sort = window.sort == Sort::name ? Sort::size : window.sort == Sort::size ? Sort::modified
                                                                                         : Sort::name;
        rebuildCurrent(view, state, context);
        return {};
      case Command::toggle_hidden:
        window.hidden = !window.hidden;
        rebuildCurrent(view, state, context);
        return {};
      case Command::toggle_ignored:
        window.ignored = !window.ignored;
        rebuildCurrent(view, state, context);
        return {};
      case Command::refresh:
        invalidate(state, {});
        say(view, "reading again");
        ++view.revision;
        return {};
      case Command::toggle_follow:
        window.follow = !window.follow;
        if (window.follow) {
          followPane(window, context);
        }

        rebuildCurrent(view, state, context);
        return {};
      case Command::visual:
        view.mode = Mode::visual;
        window.anchor = window.cursor;
        window.picked.clear();
        ++view.revision;
        return {};
      case Command::search:
        view.prefill.assign(window.filter.view());
        view.mode = Mode::search;
        ++view.revision;
        return {};
      case Command::next_match:
      case Command::previous_match:
        moveBy(window, state, context, stroke.command == Command::next_match ? count : -count);
        return {};
      case Command::command_line:
        view.prefill.clear();
        view.mode = Mode::command;
        ++view.revision;
        return {};
      case Command::help:
        view.mode = Mode::help;
        ++view.revision;
        return {};
      case Command::quit:
        return quit(view, false, true);
      case Command::escape:
        if (view.mode == Mode::visual || !window.picked.empty()) {
          leaveVisual(view);
        } else if (!window.filter.empty()) {
          window.filter.clear();
          rebuildCurrent(view, state, context);
        }

        ++view.revision;
        return {};
      }

      return {};
    }

    Action run(View& view, State& state, const Context& context, const Stroke& stroke) {
      // The commands `.` repeats: the ones that change something or hand something over.
      switch (stroke.command) {
      case Command::cut:
      case Command::paste:
      case Command::open:
      case Command::mention:
      case Command::stage:
      case Command::unstage:
      case Command::toggle_diff:
      case Command::enter:
        view.last = stroke.command;
        break;
      default:
        break;
      }

      // A count before a command that acts on rows takes that many, from the selected one.
      switch (stroke.command) {
      case Command::cut:
      case Command::yank:
      case Command::yank_relative:
      case Command::yank_name:
      case Command::stage:
      case Command::unstage:
      case Command::discard:
        windowAt(view.windows, view.current).reach = stroke.counted ? std::max<std::uint32_t>(stroke.count, 1) : 1;
        break;
      default:
        break;
      }

      const auto action = runCommand(view, state, context, stroke);

      // The command may have closed the window it ran in.
      if (view.current < view.windows.size()) {
        windowAt(view.windows, view.current).reach = 1;
      }

      return action;
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

    Action command(View& view, State& state, const Context& context, std::string_view line) {
      auto& window = windowAt(view.windows, view.current);

      line.remove_prefix(std::min(line.find_first_not_of(" :"), line.size()));
      while (line.ends_with(' ')) {
        line.remove_suffix(1);
      }

      const auto name = line.substr(0, line.find(' '));
      const auto argument = argumentOf(line);

      if (name.empty()) {
        return {};
      }

      if (name == "w" || name == "write" || name == "wa") {
        write(view, false);
      } else if (name == "w!") {
        write(view, true);
      } else if (name == "q" || name == "quit" || name == "close") {
        return quit(view, false, false);
      } else if (name == "q!") {
        return quit(view, true, true);
      } else if (name == "qa") {
        return quit(view, false, true);
      } else if (name == "e!" && argument.empty()) {
        view.edits.clear();
        view.history.clear();
        invalidate(state, {});
        say(view, "changes discarded · reading again");
        rebuildCurrent(view, state, context);
      } else if (name == "e" || name == "edit" || name == "cd" || name == "vs" || name == "vsplit" || name == "sp" || name == "split") {
        if (name != "e" && name != "edit" && name != "cd") {
          split(view, state, context, name.starts_with('v'));
        }

        if (!argument.empty()) {
          Text target{view.memory};

          resolve(target, argument, windowAt(view.windows, view.current), context);
          go(view, target.view(), {}, true);
          rebuildCurrent(view, state, context);
        }
      } else if (name == "only") {
        return runCommand(view, state, context, {.command = Command::only_window});
      } else if (name == "commit") {
        if (argument.empty()) {
          say(view, "A commit needs a message: :commit Describe the change", Tone::error);
          return {};
        }

        view.text.assign(argument);
        return {.kind = ActionKind::commit};
      } else if (name == "tree" || name == "changes" || name == "panes") {
        setLens(view, state, context, name == "tree" ? Lens::tree : name == "changes" ? Lens::changes
                                                                                      : Lens::panes);
      } else if (name == "follow") {
        window.follow = true;
        followPane(window, context);
        rebuildCurrent(view, state, context);
      } else if (name == "pin") {
        return runCommand(view, state, context, {.command = Command::pin});
      } else if (name == "marks") {
        Text listed{view.memory};

        for (const auto& mark : view.marks) {
          ds::formatTo(listed, "{}'{} {}", listed.empty() ? "" : " · ", mark.letter.view(), mark.root.view());
        }

        say(view, listed.empty() ? std::string_view{"No marks set"} : listed.view());
      } else if (name == "help") {
        view.mode = Mode::help;
      } else {
        report(view, Tone::error, "E492: Not an editor command: {}", name);
      }

      ++view.revision;
      return {};
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

  tbc::val_a<ds::Option<Need>> need(tbc::ref_a<View> view, const State& state, std::uint64_t machine) {
    const auto lacking = [&](NeedKind kind, std::string_view path) -> ds::Option<Need> {
      const Need wanted{.kind = kind, .path = path};
      if (path.starts_with('/') && lacks(state, wanted)) {
        return wanted;
      }

      return ds::none;
    };

    // What each window lists first; then what git says, the preview, and the sizes last.
    for (const auto& window : view.windows) {
      if (window->machine != machine || window->lens == Lens::panes) {
        continue;
      }

      if (auto wanted = lacking(NeedKind::listing, window->root.view())) {
        return wanted;
      }

      for (const auto& path : window->expanded) {
        if (within(path.view(), window->root.view())) {
          if (auto wanted = lacking(NeedKind::listing, path.view())) {
            return wanted;
          }
        }
      }
    }

    // What git says is asked for the window that takes the keys alone. One answer is kept: two
    // windows in two repositories would ask for theirs in turns, without end.
    if (view.current < view.windows.size() && view.windows[view.current]->machine == machine) {
      if (auto wanted = lacking(NeedKind::changes, view.windows[view.current]->root.view())) {
        return wanted;
      }
    }

    for (const auto& window : view.windows) {
      if (window->machine != machine) {
        continue;
      }

      if (window->lens != Lens::panes && !window->rows.empty() && window->rows[window->cursor].kind != RowKind::added) {
        if (auto wanted = lacking(NeedKind::inspection, window->selected.view())) {
          return wanted;
        }
      }

      for (const auto& path : window->diffs) {
        if (auto wanted = lacking(NeedKind::inspection, path.view())) {
          return wanted;
        }
      }
    }

    for (const auto& window : view.windows) {
      if (window->machine != machine || window->lens != Lens::tree) {
        continue;
      }

      if (auto wanted = lacking(NeedKind::sizes, window->root.view())) {
        return wanted;
      }

      for (const auto& path : window->expanded) {
        if (within(path.view(), window->root.view())) {
          if (auto wanted = lacking(NeedKind::sizes, path.view())) {
            return wanted;
          }
        }
      }
    }

    return ds::none;
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

  void select(View& view, const State& state, const Context& context, std::size_t window, std::size_t row, bool extend, bool toggle) {
    if (window >= view.windows.size() || view.mode == Mode::plan || view.mode == Mode::help) {
      return;
    }

    view.current = window;

    auto& chosen_window = windowAt(view.windows, view.current);
    if (row >= chosen_window.rows.size() || !selectable(chosen_window.rows[row].kind)) {
      ++view.revision;
      return;
    }

    if (extend) {
      // From the selection up to the row, as a visual selection.
      chosen_window.anchor = chosen_window.anchor.valueOr(chosen_window.cursor);
      chosen_window.picked.clear();
      view.mode = Mode::visual;
    } else if (toggle) {
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

  Action activate(View& view, State& state, const Context& context, std::size_t window, std::size_t row) {
    select(view, state, context, window, row, false, false);
    if (window >= view.windows.size() || row >= windowAt(view.windows, view.current).rows.size() || view.mode != Mode::normal) {
      return {};
    }

    return run(view, state, context, {.command = Command::enter});
  }

  void toggle(View& view, const State& state, const Context& context, std::size_t window, std::size_t row) {
    select(view, state, context, window, row, false, false);
    if (window < view.windows.size() && row < windowAt(view.windows, view.current).rows.size()) {
      setExpanded(view, state, context, row, !windowAt(view.windows, view.current).rows[row].expanded);
    }
  }

  void resize(View& view, std::size_t window, std::uint16_t rows) noexcept {
    if (window < view.windows.size()) {
      auto& resized = view.windows.atMut(window).getMut();

      resized.page = std::max<std::uint16_t>(1, rows);
      reveal(resized);
      ++view.revision;
    }
  }

  void scroll(View& view, std::size_t window, std::int64_t rows) noexcept {
    if (window >= view.windows.size()) {
      return;
    }

    auto& scrolled = view.windows.atMut(window).getMut();
    const auto page = std::max<std::size_t>(1, scrolled.page);
    const auto last = static_cast<std::int64_t>(scrolled.rows.size() > page ? scrolled.rows.size() - page : 0);

    scrolled.top = static_cast<std::size_t>(std::clamp<std::int64_t>(static_cast<std::int64_t>(scrolled.top) + rows, 0, last));
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
