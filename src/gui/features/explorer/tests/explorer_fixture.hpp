#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <array>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <map>
#include <string>
#include <string_view>
#include <vector>

#pragma once

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.config.client;
import telar.gui.features.explorer;
import telar.gui.foundation.keys;
import telar.wire.editor;
import telar.wire.files;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace telar::gui::test {

  using namespace telar::gui::features::explorer;

  // A file or a directory of the machine the fixture stands for.
  struct Listed {
    std::string name;
    bool directory = false;
    std::uint64_t size = 0;
    std::uint64_t modified = 0;
    bool link = false;
  };

  // What the runtime of a machine answers from: the directories it lists, what they weigh, and
  // what git says below the root of its repository.
  struct Disk {
    std::map<std::string, std::vector<Listed>> files;
    std::map<std::string, std::vector<std::pair<std::string, std::uint64_t>>> sizes;
    std::vector<FileChange> changes;
    // Who touched what there, the newest first, as its runtime tells it.
    std::vector<FileTouch> touches;
    bool repository = true;
    std::string root;
    std::string branch;
    std::string home;
  };

  // An explorer in a window that keeps two machines, whose runtimes the fixture answers for: the
  // one it runs on and shows, `machine`, with the panes of its tab; and `box`, another one.
  // What the runtime says an entry of the fixture is.
  constexpr FileKind kindOf(const Listed& listed) noexcept {
    if (listed.link) {
      return FileKind::link;
    }

    return listed.directory ? FileKind::directory : FileKind::file;
  }

  struct Explorer {
    static constexpr std::uint64_t machine = 1;
    static constexpr std::uint64_t box = 2;

    Explorer() {
      disk.root = "/home/dev/telar";
      disk.branch = "lifetime-speed";
      disk.home = "/home/dev";
      changes = {
          {.path = ".github/", .unstaged = FileState::untracked},
          {.path = "docs/remote.md", .staged = FileState::added, .added = 20},
          {.path = "docs/usage.md", .unstaged = FileState::modified, .added = 12, .removed = 7},
          {.path = "out/", .unstaged = FileState::ignored},
      };
      far.root = "/home/ops/site";
      far.branch = "release";
      far.home = "/home/ops";
      far.files["/home/ops"] = {{"logs", true}, {"site", true}, {"deploy.sh", false, 300, 15}};
      far.files["/home/ops/logs"] = {{"app.log", false, 9000, 25}, {"db.log", false, 4000, 35}};
      far.files["/home/ops/site"] = {{"index.html", false, 700, 45}, {"latest", false, 0, 55, true}};
      far.files["/var/log"] = {{"syslog", false, 80000, 55}};
      far.changes = {{.path = "index.html", .unstaged = FileState::modified, .added = 3, .removed = 1}};
      // In the order the runtime lists: directories first, each group by name.
      files["/home/dev/telar"] = {{".github", true}, {"assets", true}, {"docs", true}, {"out", true}, {"src", true}, {".gitignore", false, 5, 10}, {"justfile", false, 8300, 20}, {"README.md", false, 5500, 30}};
      files["/home/dev/telar/docs"] = {{"images", true}, {"agents.md", false, 6500, 40}, {"remote.md", false, 6300, 50}, {"usage.md", false, 7739, 60}};
      files["/home/dev/telar/docs/images"] = {{"window.png", false, 2500000, 70}};
      files["/home/dev/telar/assets"] = {{"logo.svg", false, 6500, 80}};
      files["/home/dev/telar/src"] = {{"main.cpp", false, 900, 90}};
      files["/home/dev"] = {{"telar", true}, {"notes.txt", false, 12, 5}};
      sizes["/home/dev/telar"] = {{"assets", 6800000}, {"docs", 3800000}, {"src", 120000}, {".github", 4096}, {"out", 21000000000}};
      panes = {
          PaneFact{.id = 11, .number = 1, .kind = PaneKind::agent, .title = "Claude Code", .cwd = "/home/dev/telar"},
          PaneFact{.id = 12, .number = 2, .kind = PaneKind::editor, .title = "nvim", .cwd = "/home/dev/telar/src"},
          PaneFact{.id = 13, .number = 3, .kind = PaneKind::shell, .title = "zsh", .cwd = "/home/dev/telar/docs"},
      };
    }

    // The machine of the window that has the keys.
    [[nodiscard]] std::uint64_t here() const {
      return view.windows.empty() ? machine : window(view).machine;
    }

    // The cache of a machine, and what its runtime answers from.
    [[nodiscard]] State& cache(std::uint64_t of) {
      return of == box ? remote : state;
    }

    [[nodiscard]] const State& cache(std::uint64_t of) const {
      return of == box ? remote : state;
    }

    [[nodiscard]] Disk& diskOf(std::uint64_t of) {
      return of == box ? far : disk;
    }

    // What a use case reads around the files, on a window of the machine that has the keys or of
    // the one named.
    [[nodiscard]] Context context() const {
      return context(here());
    }

    [[nodiscard]] Context context(std::uint64_t of) const {
      const auto& known = machines[of - 1];

      return {
          .panes = panes,
          .focused = focused,
          .workspace = "/home/dev/telar",
          .home = of == box ? std::string_view{far.home} : std::string_view{disk.home},
          .machine = known.label,
          .local = known.local,
          .now = now,
          .reach = known.reach,
          .host = of,
          .shown = shown,
          .machines = machines,
          .edited = {.text = edited_text, .files = edited},
      };
    }

    // An editor pane of a machine holds a file in a buffer, with changes not written or without.
    void hold(std::uint64_t of, std::uint64_t pane, std::string_view path, bool modified) {
      edited.push_back({.machine = of, .pane = pane, .offset = static_cast<std::uint32_t>(edited_text.size()), .size = static_cast<std::uint32_t>(path.size()), .modified = modified});
      edited_text += path;
    }

    // Answers what the explorer lacks, as the runtime of each machine that answers would, until
    // it lacks nothing.
    void answer() {
      for (const auto& known : machines) {
        if (known.reach == Reach::answers) {
          answer(known.id);
        }
      }

      settle();
    }

    void answer(std::uint64_t of) {
      auto& state = cache(of);
      auto& disk = diskOf(of);
      auto& files = disk.files;
      auto& sizes = disk.sizes;
      // A thing is asked for once: an explorer that asks without end fails here, not the runtime.
      const auto limit = requests + 256;

      while (const auto wanted = need(view, state, of)) {
        const auto request = ++requests;

        ++asked_of[of - 1];

        telar::testing::check(request < limit, "what was answered is not asked for again");
        const std::string path{wanted->path};

        asked(state, *wanted, request);
        switch (wanted->kind) {
        case NeedKind::listing: {
          const auto found = files.find(path);
          if (found == files.end()) {
            telar::testing::check(fail(state, RequestFailed{.request_id = request, .code = FailureCode::invalid_request, .message = "no such directory"}));
            break;
          }

          std::vector<DirectoryEntry> entries;

          for (const auto& listed : found->second) {
            entries.push_back({.name = listed.name, .kind = kindOf(listed), .directory = listed.directory, .size = listed.size, .identity = {.inode = 100 + entries.size(), .modified_seconds = listed.modified}});
          }

          telar::testing::check(receive(state, DirectoryContents{.request_id = request, .path = path, .total = static_cast<std::uint32_t>(entries.size()), .entries = entries}));
          break;
        }
        case NeedKind::sizes: {
          std::vector<DirectorySize> measured;

          for (const auto& [name, bytes] : sizes[path]) {
            measured.push_back({.name = name, .bytes = bytes, .complete = true});
          }

          telar::testing::check(receive(state, DirectorySizes{.request_id = request, .path = path, .sizes = measured}));
          break;
        }
        case NeedKind::changes: {
          // The machine that shows says so of any path, as its tests were written; the other one
          // only of what is below its repository.
          const bool inside = disk.repository && (of == machine || path.starts_with(disk.root));

          telar::testing::check(receive(state, RepositoryChanges{.request_id = request, .path = path, .root = inside ? std::string_view{disk.root} : std::string_view{}, .branch = disk.branch, .changes = inside ? std::span<const FileChange>{disk.changes} : std::span<const FileChange>{}}));
          break;
        }
        case NeedKind::inspection:
          telar::testing::check(receive(state, FileInspection{.request_id = request, .path = path, .size = 7739, .identity = {.inode = inspected_inode, .modified_seconds = 77}, .text = "# Usage\n", .commit = "31d2299b4000000000000000000000000000000f", .committed_seconds = 1794096000, .subject = "Describe the usage", .diff = path.ends_with("usage.md") ? std::string_view{"@@ -1,2 +1,2 @@\n-old\n+new\n context\n"} : std::string_view{}}));
          break;
        case NeedKind::search:
          telar::testing::check(receive(state, found(request, path, std::string{wanted->text}, true, of)));
          break;
        case NeedKind::home:
          telar::testing::check(receive(state, HomeLocated{.request_id = request, .path = disk.home}));
          break;
        case NeedKind::touches:
          telar::testing::check(receive(state, FileTouches{.request_id = request, .path = "/", .touches = disk.touches}));
          break;
        }

        settle();
      }
    }

    // As the window does after each answer and when a session changed: a pane followed moves
    // the windows of the machine that shows, and the rows of each machine take in what its
    // cache was answered.
    void settle() {
      for (const auto& known : machines) {
        if (known.id == shown && follow(view, context(known.id), known.id)) {
          rebuild(view, cache(known.id), context(known.id), known.id);
        } else {
          absorb(view, cache(known.id), context(known.id), known.id);
        }
      }
    }

    // Whether the letters of `query` are in `path` in their order, whatever their case: what the
    // runtime's path search takes for a match.
    [[nodiscard]] static bool matches(std::string_view path, std::string_view query) {
      std::size_t next = 0;

      for (const char letter : path) {
        if (next < query.size() && std::tolower(static_cast<unsigned char>(letter)) == std::tolower(static_cast<unsigned char>(query[next]))) {
          ++next;
        }
      }

      return next == query.size();
    }

    // The paths below `directory` that match, from it, in the order of their names.
    void gather(std::vector<std::pair<std::string, bool>>& paths, const std::string& directory, const std::string& prefix, std::string_view query, std::uint64_t of = machine) const {
      const auto& files = of == box ? far.files : disk.files;
      const auto listed = files.find(directory);
      if (listed == files.end()) {
        return;
      }

      for (const auto& entry : listed->second) {
        const auto relative = prefix + entry.name;

        if (matches(relative, query)) {
          paths.emplace_back(relative, entry.directory);
        }

        if (entry.directory) {
          gather(paths, directory + "/" + entry.name, relative + "/", query, of);
        }
      }
    }

    // What the runtime's path search answers under `request`: the paths below `root` that match
    // `query`, `search_limit` of them at most, and the first half of those alone while it still
    // reads its index, when not `complete`.
    [[nodiscard]] PathResults found(std::uint64_t request, const std::string& root, const std::string& query, bool complete, std::uint64_t of = machine) {
      std::vector<std::pair<std::string, bool>> paths;

      gather(paths, root, {}, query, of);
      std::ranges::sort(paths);
      found_root = root;
      found_paths.clear();
      found_matches.clear();

      const auto whole = std::min(paths.size(), search_limit);
      const auto count = complete ? whole : whole / 2;

      for (std::size_t index = 0; index < count; ++index) {
        found_paths.push_back(paths[index].first);
      }

      for (std::size_t index = 0; index < count; ++index) {
        found_matches.push_back({.path = found_paths[index], .kind = paths[index].second ? PathKind::directory : PathKind::file});
      }

      return {.request_id = request, .root = found_root, .scanned = static_cast<std::uint32_t>(paths.size()), .complete = complete, .truncated = paths.size() > whole, .matches = found_matches};
    }

    void start() {
      open(view, state, context(machine), machine);
      answer();
    }

    // Types `keys`, each character a key, with `<CR>`, `<Esc>` and `<C-x>` spelled as Neovim does.
    Action type(std::string_view keys) {
      Action last;

      for (std::size_t index = 0; index < keys.size();) {
        KeyChord chord{.key = KeyChord::Key::character};
        const auto close = keys[index] == '<' ? keys.find('>', index) : std::string_view::npos;

        if (close != std::string_view::npos) {
          const auto name = keys.substr(index, close - index + 1);

          if (name == "<CR>") {
            chord.key = KeyChord::Key::enter;
          } else if (name == "<Esc>") {
            chord.key = KeyChord::Key::escape;
          } else {
            chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(name[3]));
            chord.modifiers = static_cast<unsigned>(name[1] == 'C' ? KeyChord::Modifier::control : KeyChord::Modifier::super);
          }

          index = close + 1;
        } else {
          chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(static_cast<unsigned char>(keys[index])));
          ++index;
        }

        last = press(view, cache(here()), context(), chord);
        answer();
      }

      return last;
    }

    Action enter(std::string_view text) {
      const auto action = submit(view, cache(here()), context(), text);

      answer();
      return action;
    }

    // The names of the rows the current window lists, a directory's ending in a slash.
    [[nodiscard]] std::vector<std::string> names() const {
      std::vector<std::string> result;
      const auto& listed = window(view);

      for (std::size_t index = 0; index < listed.rows.size(); ++index) {
        const auto seen = look(view, cache(here()), context(), {.window = view.current, .row = index});

        result.push_back(std::string{seen.lead.view()} + std::string{seen.name.view()} + (seen.directory ? "/" : ""));
      }

      return result;
    }

    [[nodiscard]] std::string selected() const {
      return std::string{window(view).selected.view()};
    }

    [[nodiscard]] RowLook row(std::string_view name) const {
      const auto& listed = window(view);

      for (std::size_t index = 0; index < listed.rows.size(); ++index) {
        const auto seen = look(view, cache(here()), context(), {.window = view.current, .row = index});
        if (seen.name.view() == name) {
          return seen;
        }
      }

      telar::testing::check(false, "the row is listed");
      return {};
    }

    // Where the row with `name` is in the listing of a window: the current one, or the one named.
    [[nodiscard]] std::size_t at(std::string_view name) const {
      return at(name, view.current);
    }

    [[nodiscard]] std::size_t at(std::string_view name, std::size_t window_index) const {
      const auto& listed = *view.windows[window_index];

      for (std::size_t index = 0; index < listed.rows.size(); ++index) {
        if (look(view, cache(listed.machine), context(listed.machine), {.window = window_index, .row = index}).name.view() == name) {
          return index;
        }
      }

      telar::testing::check(false, "the row is listed");
      return 0;
    }

    // The pointer chooses the row named, in the current window.
    void click(std::string_view name) {
      select(view, cache(here()), context(), {.window = view.current, .row = at(name)});
      answer();
    }

    SystemAllocator upstream;
    telar::MemoryAdapter<SystemAllocator> adapter{upstream};
    telar::Memory& memory = adapter;
    // The cache of the machine that shows and of the other one, and the one view of both.
    State state{memory};
    State remote{memory};
    View view{memory};
    Disk disk;
    Disk far;
    // The machine that shows, by the names its tests know it by.
    std::map<std::string, std::vector<Listed>>& files = disk.files;
    std::map<std::string, std::vector<std::pair<std::string, std::uint64_t>>>& sizes = disk.sizes;
    std::vector<FileChange>& changes = disk.changes;
    bool& repository = disk.repository;
    // The machines the window keeps, the one whose panes show, and what was asked of each.
    std::vector<MachineFact> machines{
        {.id = machine, .label = "macbook", .local = true, .reach = Reach::answers},
        {.id = box, .label = "box", .local = false, .reach = Reach::answers},
    };
    std::uint64_t shown = machine;
    std::array<std::uint64_t, 2> asked_of{};
    // What the last answer of the path search views, and how many matches one carries.
    std::string found_root;
    std::vector<std::string> found_paths;
    std::vector<PathMatch> found_matches;
    std::size_t search_limit = FindPaths::maximum_limit;
    // The inode the runtime says a file it inspects has.
    std::uint64_t inspected_inode = 4242;
    std::vector<PaneFact> panes;
    // The files the editors hold, each path a piece of the text.
    std::string edited_text;
    std::vector<EditedFile> edited;
    std::uint64_t focused = 13;
    // The time the rows say how long ago against.
    std::uint64_t now = 1'000'000;
    std::uint64_t requests = 0;
  };

}
