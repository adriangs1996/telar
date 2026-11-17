export module telar.gui.foundation.system:directory_completion;

import std;

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

      std::string base;
      std::vector<std::string> entries;
      std::size_t matched = 0;
      bool exact_exists = false;

      // The query for what the user typed: a field that is empty or ends with
      // '/' asks for the children of the expanded directory.
      [[nodiscard]] static std::string query(TypedDirectory typed);

      // Splits the query at its last '/': the part before is listed and the rest
      // filters names by prefix. Hidden directories are listed only when the
      // filter itself starts with '.'.
      [[nodiscard]] static DirectoryCompletion list(std::string_view query);

      // The last component of an expanded directory, ignoring a trailing '/'.
      [[nodiscard]] static std::string_view basename(std::string_view path);

      // The directory an entry names, ending in '/' so the next listing shows
      // its children.
      [[nodiscard]] std::string join(std::size_t index) const;

    private:
      // Keeps the first maximum_entries names whatever order the listing finds
      // them in: a full result gives up its last name for one that sorts before.
      void keep(const std::string& name);
    };

  }
}
