module;
#include <climits>

export module telar.gui.foundation.system:directory_completion;

import std;

import telar.base.ds;
import telar.base.memory.containers;

// Interface: paths/directory_completion.cppm
export {
  namespace telar::gui::inline foundation::inline system {

    struct TypedDirectory {
      std::string_view text;
      std::string_view expanded;
    };

    // The directories one expanded path can complete to, as the workspace form
    // lists them. A listing may block on the filesystem, so it runs on a
    // worker and keeps at most maximum_entries names, the first ones by name.
    struct DirectoryCompletion {
      static constexpr std::size_t maximum_entries = 64;
      static constexpr std::size_t maximum_name_bytes = 255;

      using Name = runtime::FixedText<maximum_name_bytes>;
      using Path = runtime::FixedText<PATH_MAX>;
      // A listed directory's path with the entry's name and a '/' after each.
      using Joined = runtime::FixedText<PATH_MAX + maximum_name_bytes + 2>;

      // A value of fixed size, so a worker hands it back without the heap.
      Path base;
      std::size_t matched = 0;
      bool exact_exists = false;

      [[nodiscard]] std::span<const Name> entries() const noexcept {
        return names_.view().first(count_);
      }

      // The query for what the user typed: a field that is empty or ends with
      // '/' asks for the children of the expanded directory.
      // Throws when the path is longer than a path can be.
      [[nodiscard]] static Path query(TypedDirectory typed);

      // Splits the query at its last '/': the part before is listed and the rest
      // filters names by prefix. Hidden directories are listed only when the
      // filter itself starts with '.'.
      [[nodiscard]] static DirectoryCompletion list(std::string_view query);

      // The last component of an expanded directory, ignoring a trailing '/'.
      [[nodiscard]] static std::string_view basename(std::string_view path);

      // The directory an entry names, ending in '/' so the next listing shows
      // its children.
      [[nodiscard]] Joined join(std::size_t index) const;

    private:
      // Keeps the first maximum_entries names whatever order the listing finds
      // them in: a full result gives up its last name for one that sorts before.
      void keep(std::string_view name);

      ds::Array<Name, maximum_entries> names_;
      std::size_t count_ = 0;
    };

  }
}
