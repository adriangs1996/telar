module telar.gui.foundation.system;

import std;

import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

  namespace {

    // Joins `parts` into `Text`, which has room for all of them.
    template <typename Text, std::size_t Capacity>
    Text joined(std::initializer_list<std::string_view> parts) {
      ds::Array<char, Capacity> bytes{};
      std::size_t length = 0;

      for (const auto part : parts) {
        std::ranges::copy(part, bytes.viewMut().subspan(length).begin());
        length += part.size();
      }

      Text text;

      text.assign({bytes.data(), length});
      return text;
    }

  }

  DirectoryCompletion::Path DirectoryCompletion::query(TypedDirectory typed) {
    const bool children = typed.text.empty() || typed.text.ends_with('/');
    const bool separator = children && !typed.expanded.empty() && !typed.expanded.ends_with('/');
    if (typed.expanded.size() + (separator ? 1 : 0) > PATH_MAX) {
      throw std::length_error{"the directory is longer than a path"};
    }

    return joined<Path, PATH_MAX>({typed.expanded, separator ? "/" : ""});
  }

  DirectoryCompletion DirectoryCompletion::list(std::string_view query) {
    DirectoryCompletion result;

    if (!query.starts_with('/') || query.size() > PATH_MAX) {
      return result;
    }

    const auto split = query.rfind('/');

    result.base.assign(split == 0 ? std::string_view{"/"} : query.substr(0, split));
    const auto partial = query.substr(split + 1);
    std::error_code error;

    result.exact_exists = partial.empty() || std::filesystem::is_directory(std::filesystem::path{query}, error);

    std::filesystem::directory_iterator directory{
        std::filesystem::path{result.base.view()},
        std::filesystem::directory_options::skip_permission_denied,
        error,
    };

    for (const std::filesystem::directory_iterator end; !error && directory != end; directory.increment(error)) {
      // The entry's own path, read in place: its name is what follows the last '/'.
      const std::string_view path{directory->path().native()};
      const auto name = path.substr(path.rfind('/') + 1);
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

    std::ranges::sort(result.names_.viewMut().first(result.count_), {}, &Name::view);

    return result;
  }

  std::string_view DirectoryCompletion::basename(std::string_view path) {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');

    return split == std::string_view::npos ? path : path.substr(split + 1);
  }

  DirectoryCompletion::Joined DirectoryCompletion::join(std::size_t index) const {
    const auto directory = base.view();

    return joined<Joined, PATH_MAX + maximum_name_bytes + 2>({directory, directory.ends_with('/') ? "" : "/", entries()[index].view(), "/"});
  }

  void DirectoryCompletion::keep(std::string_view name) {
    if (name.empty() || name.size() > maximum_name_bytes) {
      return;
    }

    if (count_ < maximum_entries) {
      names_.atMut(count_++).assign(name);

      return;
    }

    const auto last = std::ranges::max_element(names_.viewMut(), {}, &Name::view);
    if (name < last->view()) {
      last->assign(name);
    }
  }

}
