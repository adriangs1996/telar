#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <climits>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>

import std;
import telar.testing;
import telar.gui.foundation.system;

namespace {

  using telar::gui::DirectoryCompletion;
  using telar::testing::check;

  struct Fixture {
    std::filesystem::path root;

    Fixture() {
      std::string pattern = (std::filesystem::temp_directory_path() / "telar-directories-XXXXXX").string();

      check(::mkdtemp(pattern.data()) != nullptr, "temporary directory");
      root = std::filesystem::canonical(pattern);
    }

    ~Fixture() {
      std::error_code ignored;

      std::filesystem::remove_all(root, ignored);
    }

    Fixture(const Fixture&) = delete;
    Fixture& operator=(const Fixture&) = delete;
    Fixture(Fixture&&) = delete;
    Fixture& operator=(Fixture&&) = delete;

    [[nodiscard]] std::string path(const char* name) const {
      return (root / name).string();
    }
  };

  // The listing crosses to a worker and back through a QFuture, which copies its result.
  static_assert(std::is_nothrow_default_constructible_v<DirectoryCompletion> && std::is_copy_constructible_v<DirectoryCompletion>);

  // Whether the listing holds exactly `expected`, in order.
  bool lists(const DirectoryCompletion& completion, std::initializer_list<std::string_view> expected) {
    return std::ranges::equal(completion.entries(), expected, {}, &DirectoryCompletion::Name::view);
  }

  void queriesAskForChildrenOnlyAfterASeparator() {
    check(DirectoryCompletion::query({.text = "", .expanded = "/work"}).view() == "/work/", "an empty field lists the base directory");
    check(DirectoryCompletion::query({.text = "projects/", .expanded = "/work/projects"}).view() == "/work/projects/", "a trailing separator lists children");
    check(DirectoryCompletion::query({.text = "proj", .expanded = "/work/proj"}).view() == "/work/proj", "a partial name filters its parent");
    check(DirectoryCompletion::query({.text = "/", .expanded = "/"}).view() == "/", "the root keeps one separator");

    // A path one byte too long for a path, once its separator is added, is refused whole.
    const std::string longest(PATH_MAX, 'x');
    bool refused = false;

    try {
      static_cast<void>(DirectoryCompletion::query({.text = "", .expanded = longest}));
    } catch (const std::length_error&) {
      refused = true;
    }

    check(refused, "a directory longer than a path is refused, not cut");
    check(DirectoryCompletion::list("/" + longest).entries().empty(), "and lists nothing");
  }

  void listsMatchingDirectoriesOnly() {
    const Fixture fixture;

    for (const auto* name : {"telar", "tools", "notes", ".hidden", ".tooling"}) {
      std::filesystem::create_directory(fixture.root / name);
    }

    std::ofstream{fixture.root / "todo.txt"} << "file";
    std::filesystem::create_directory_symlink(fixture.root / "telar", fixture.root / "terminal");

    const auto prefix = DirectoryCompletion::list(fixture.path("t"));

    check(prefix.base.view() == fixture.root.string(), "the base is the directory listed");
    check(lists(prefix, {"telar", "terminal", "tools"}), "directories and links to them, sorted, files left out");
    check(!prefix.exact_exists, "a partial name is not a directory");

    const auto children = DirectoryCompletion::list(fixture.path("") + "/");

    check(lists(children, {"notes", "telar", "terminal", "tools"}), "hidden directories stay out without a leading dot");
    check(children.exact_exists, "the listed directory exists");

    const auto hidden = DirectoryCompletion::list(fixture.path(".t"));

    check(lists(hidden, {".tooling"}), "a leading dot lists hidden directories");

    check(DirectoryCompletion::list(fixture.path("telar")).exact_exists, "an exact name is a directory");
    check(prefix.join(0).view() == fixture.path("telar") + "/", "joined paths end in a separator");

    const auto& copied = prefix;

    check(lists(copied, {"telar", "terminal", "tools"}) && copied.base.view() == prefix.base.view(), "a copy holds the same listing");
  }

  void keepsTheFirstNamesOfALargeDirectory() {
    const Fixture fixture;
    const auto total = DirectoryCompletion::maximum_entries + 6;

    for (std::size_t index = total; index > 0; --index) {
      std::filesystem::create_directory(fixture.root / std::format("d{:03}", index));
    }

    const auto result = DirectoryCompletion::list(fixture.path("") + "/");

    check(result.matched == total, "every match is counted");
    check(result.entries().size() == DirectoryCompletion::maximum_entries, "the result is bounded");
    check(result.entries().front().view() == "d001" && result.entries().back().view() == "d064", "the first names by order are kept");
  }

  void rejectsRelativeAndMissingQueries() {
    check(DirectoryCompletion::list("relative/path").entries().empty(), "relative queries list nothing");
    const auto missing = DirectoryCompletion::list("/telar-missing-directory/child");

    check(missing.entries().empty() && !missing.exact_exists, "a missing directory lists nothing");
  }

  void basenamesIgnoreTrailingSeparators() {
    check(DirectoryCompletion::basename("/work/telar/") == "telar", "a trailing separator is ignored");
    check(DirectoryCompletion::basename("/work/telar") == "telar", "the last component names the directory");
    check(DirectoryCompletion::basename("/").empty(), "the root has no name");
  }

  const telar::testing::Case case_queries_ask_for_children_only_after_a_separator{"directory_completion.queries_ask_for_children_only_after_a_separator", queriesAskForChildrenOnlyAfterASeparator};
  const telar::testing::Case case_lists_matching_directories_only{"directory_completion.lists_matching_directories_only", listsMatchingDirectoriesOnly};
  const telar::testing::Case case_keeps_the_first_names_of_a_large_directory{"directory_completion.keeps_the_first_names_of_a_large_directory", keepsTheFirstNamesOfALargeDirectory};
  const telar::testing::Case case_rejects_relative_and_missing_queries{"directory_completion.rejects_relative_and_missing_queries", rejectsRelativeAndMissingQueries};
  const telar::testing::Case case_basenames_ignore_trailing_separators{"directory_completion.basenames_ignore_trailing_separators", basenamesIgnoreTrailingSeparators};

}
