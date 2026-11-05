#pragma once

#include <algorithm>
#include <cstddef>
#include <filesystem>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

namespace telar::gui {

struct TypedDirectory {
  std::string_view text;
  std::string_view expanded;
};

// The directories one expanded path can complete to, as the Zig workspace
// form lists them. A listing may block on the filesystem, so it runs on a
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
  [[nodiscard]] static std::string query(TypedDirectory typed) {
    const bool children = typed.text.empty() || typed.text.ends_with('/');
    std::string result{typed.expanded};
    if (children && !result.empty() && !result.ends_with('/')) {
      result.push_back('/');
    }

    return result;
  }

  // Splits the query at its last '/': the part before is listed and the rest
  // filters names by prefix. Hidden directories are listed only when the
  // filter itself starts with '.'.
  [[nodiscard]] static DirectoryCompletion list(std::string_view query) {
    DirectoryCompletion result;
    if (!query.starts_with('/')) {
      return result;
    }

    const auto split = query.rfind('/');
    result.base = split == 0 ? std::string{"/"} : std::string{query.substr(0, split)};
    const auto partial = query.substr(split + 1);
    std::error_code error;
    result.exact_exists = partial.empty() || std::filesystem::is_directory(std::filesystem::path{std::string{query}}, error);

    std::filesystem::directory_iterator directory{result.base, std::filesystem::directory_options::skip_permission_denied, error};
    for (const std::filesystem::directory_iterator end; !error && directory != end; directory.increment(error)) {
      const auto name = directory->path().filename().string();
      if (!name.starts_with(partial) || (name.starts_with('.') && !partial.starts_with('.'))) {
        continue;
      }

      std::error_code status;
      if (!directory->is_directory(status)) {
        continue;
      }

      ++result.matched;
      result.keep(name);
    }

    std::ranges::sort(result.entries);

    return result;
  }

  // The last component of an expanded directory, ignoring a trailing '/'.
  [[nodiscard]] static std::string_view basename(std::string_view path) {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');

    return split == std::string_view::npos ? path : path.substr(split + 1);
  }

  // The directory an entry names, ending in '/' so the next listing shows
  // its children.
  [[nodiscard]] std::string join(std::size_t index) const {
    std::string path = base;
    if (!path.ends_with('/')) {
      path.push_back('/');
    }

    path.append(entries.at(index));
    path.push_back('/');

    return path;
  }

private:
  // Keeps the first maximum_entries names whatever order the listing finds
  // them in: a full result gives up its last name for one that sorts before.
  void keep(const std::string &name) {
    if (name.empty() || name.size() > maximum_name_bytes) {
      return;
    }

    if (entries.size() < maximum_entries) {
      entries.push_back(name);

      return;
    }

    const auto last = std::ranges::max_element(entries);
    if (name < *last) {
      *last = name;
    }
  }
};

}
