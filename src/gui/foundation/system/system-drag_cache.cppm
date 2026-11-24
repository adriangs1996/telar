// Where the files of another machine wait for a drag to take them out of the window, on a system
// that asks for no file when it is let go: a directory of the user's cache with one directory
// for each drag, which is removed once it is old.
export module telar.gui.foundation.system:drag_cache;

import std;

import telar.base.ds;
import telar.base.memory.allocators;

export {
  namespace telar::gui::inline foundation::inline system {

    struct DragCacheLimits {
      // How long the directory of a drag is kept, and how many entries of the cache one look
      // at it reads.
      static constexpr std::uint64_t kept_seconds = 24ULL * 60 * 60;
      static constexpr std::size_t swept = 256;
    };

    // Makes the directory of one more drag below `root`, which is made too, each for its owner
    // alone, and writes its path to `directory`. The directories of drags older than the limit
    // at `now_seconds`, by when something was last written in them, are removed first; nothing
    // else of `root` is touched, nor what a link there points at. False when it cannot be
    // made: `root` is no absolute path, something that is no directory is in its place, or the
    // disk refuses.
    bool openDragCache(ds::String<Memory>& directory, std::string_view root, std::uint64_t now_seconds);

  }
}
