#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.gui.foundation.system;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using telar::testing::check;

  struct Scratch {
    std::filesystem::path root;

    Scratch() {
      std::string pattern = (std::filesystem::temp_directory_path() / "telar-drag-cache-XXXXXX").string();

      check(::mkdtemp(pattern.data()) != nullptr, "temporary directory");
      root = std::filesystem::canonical(pattern);
    }

    ~Scratch() {
      std::error_code ignored;

      std::filesystem::remove_all(root, ignored);
    }

    Scratch(const Scratch&) = delete;
    Scratch& operator=(const Scratch&) = delete;
    Scratch(Scratch&&) = delete;
    Scratch& operator=(Scratch&&) = delete;
  };

  // The seconds since the epoch `path` was last written at.
  std::uint64_t writtenAt(const std::filesystem::path& path) {
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::file_clock::to_sys(std::filesystem::last_write_time(path)).time_since_epoch()).count());
  }

  mode_t modeOf(const std::filesystem::path& path) {
    struct stat status{};

    check(::lstat(path.c_str(), &status) == 0, "the path is there");
    return status.st_mode & (S_IRWXU | S_IRWXG | S_IRWXO);
  }

  // Each drag has a directory of its own below the cache's, for its owner alone.
  void makesADirectoryForEachDrag() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const Scratch scratch;
    const auto root = scratch.root / "cache" / "dragged";
    ds::String<Memory> first{memory};
    ds::String<Memory> second{memory};

    check(openDragCache(first, root.native(), 1000), "the cache and the drag's directory are made");
    check(openDragCache(second, root.native(), 1000) && first.view() != second.view(), "another drag has another");

    const std::filesystem::path made{first.view()};

    check(made.parent_path() == root && made.filename().native().starts_with("drag-") && std::filesystem::is_directory(made));
    check(modeOf(root) == S_IRWXU && modeOf(made) == S_IRWXU, "both are their owner's alone");

    // What is no absolute path, or holds something that is no directory, is no cache.
    ds::String<Memory> refused{memory};

    refused.assign("stale");
    check(!openDragCache(refused, "cache/dragged", 1000) && refused.empty(), "a path from nowhere");
    check(!openDragCache(refused, "", 1000) && !openDragCache(refused, std::string(8192, 'a').insert(0, "/"), 1000));
    std::ofstream{scratch.root / "file"} << "x";
    check(!openDragCache(refused, (scratch.root / "file").native(), 1000) && !openDragCache(refused, (scratch.root / "file" / "below").native(), 1000), "a file in its place");
    std::filesystem::create_directory_symlink(root, scratch.root / "link");
    check(!openDragCache(refused, (scratch.root / "link").native(), 1000) && refused.empty(), "a link in its place");
  }

  // The directories of old drags go when a new one is made; nothing else of the cache does.
  void removesTheDirectoriesOfOldDrags() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    const Scratch scratch;
    const Scratch outside;
    const auto root = scratch.root / "dragged";
    ds::String<Memory> old{memory};
    ds::String<Memory> recent{memory};
    ds::String<Memory> next{memory};

    check(openDragCache(old, root.native(), 0) && openDragCache(recent, root.native(), 0));

    const std::filesystem::path old_path{old.view()};
    const std::filesystem::path recent_path{recent.view()};

    std::ofstream{old_path / "deploy.sh"} << "#!/bin/sh\n";
    std::filesystem::create_directory(old_path / "below");
    std::ofstream{old_path / "below" / "more"} << "x";
    std::ofstream{recent_path / "notes.txt"} << "x";
    // What is not a drag's directory: a file with its name, another directory, and a link with
    // its name to a directory elsewhere.
    std::ofstream{root / "drag-file"} << "x";
    std::filesystem::create_directory(root / "kept");
    std::ofstream{outside.root / "precious"} << "x";
    std::filesystem::create_directory_symlink(outside.root, root / "drag-link");

    const auto now = writtenAt(recent_path);
    const auto long_ago = std::filesystem::last_write_time(recent_path) - std::chrono::seconds{DragCacheLimits::kept_seconds + 60};

    for (const auto& aged : {old_path, root / "drag-file", root / "kept"}) {
      std::filesystem::last_write_time(aged, long_ago);
    }

    // Within the limit nothing goes.
    std::filesystem::last_write_time(recent_path, std::filesystem::last_write_time(recent_path) - std::chrono::seconds{DragCacheLimits::kept_seconds - 60});
    check(openDragCache(next, root.native(), now), "one more drag");
    check(!std::filesystem::exists(old_path), "the directory of the old drag is removed, with what it held");
    check(std::filesystem::exists(recent_path / "notes.txt"), "one within the limit stays");
    check(std::filesystem::exists(root / "drag-file") && std::filesystem::exists(root / "kept"), "what is no directory of a drag stays, however old");
    check(std::filesystem::is_symlink(root / "drag-link") && std::filesystem::exists(outside.root / "precious"), "and what a link points at is not the cache's to remove");
    check(std::filesystem::is_directory(std::filesystem::path{next.view()}));

    // A clock that reads before the directories were written removes none.
    check(openDragCache(next, root.native(), 0) && std::filesystem::exists(recent_path));
  }

  const telar::testing::Case case_made{"drag_cache.makes_a_directory_for_each_drag", makesADirectoryForEachDrag};
  const telar::testing::Case case_swept{"drag_cache.removes_the_directories_of_old_drags", removesTheDirectoriesOfOldDrags};

}
