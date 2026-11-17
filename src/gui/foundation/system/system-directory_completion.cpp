module telar.gui.foundation.system;

import std;

namespace telar::gui::inline foundation::inline system {

  std::string DirectoryCompletion::query(TypedDirectory typed) {
    const bool children = typed.text.empty() || typed.text.ends_with('/');
    std::string result{typed.expanded};
    if (children && !result.empty() && !result.ends_with('/')) {
      result.push_back('/');
    }

    return result;
  }

  DirectoryCompletion DirectoryCompletion::list(std::string_view query) {
    DirectoryCompletion result;

    if (!query.starts_with('/')) {
      return result;
    }

    const auto split = query.rfind('/');

    result.base = split == 0 ? std::string{"/"} : std::string{query.substr(0, split)};
    const auto partial = query.substr(split + 1);
    std::error_code error;

    result.exact_exists = partial.empty() || std::filesystem::is_directory(std::filesystem::path{std::string{query}}, error);

    std::filesystem::directory_iterator directory{
        result.base,
        std::filesystem::directory_options::skip_permission_denied,
        error,
    };

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

  std::string_view DirectoryCompletion::basename(std::string_view path) {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');

    return split == std::string_view::npos ? path : path.substr(split + 1);
  }

  std::string DirectoryCompletion::join(std::size_t index) const {
    std::string path = base;
    if (!path.ends_with('/')) {
      path.push_back('/');
    }

    path.append(entries.at(index));
    path.push_back('/');

    return path;
  }

  void DirectoryCompletion::keep(const std::string& name) {
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

}
