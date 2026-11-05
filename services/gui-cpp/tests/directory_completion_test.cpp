#include "paths/directory_completion.hpp"
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <format>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace {

using telar::gui::DirectoryCompletion;

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

struct Fixture {
  std::filesystem::path root;

  Fixture() {
    std::string pattern = (std::filesystem::temp_directory_path() / "telar-directories-XXXXXX").string();
    require(::mkdtemp(pattern.data()) != nullptr, "temporary directory");
    root = std::filesystem::canonical(pattern);
  }

  ~Fixture() {
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
  }

  Fixture(const Fixture &) = delete;
  Fixture &operator=(const Fixture &) = delete;
  Fixture(Fixture &&) = delete;
  Fixture &operator=(Fixture &&) = delete;

  [[nodiscard]] std::string path(const char *name) const {
    return (root / name).string();
  }
};

void queriesAskForChildrenOnlyAfterASeparator() {
  require(DirectoryCompletion::query({.text = "", .expanded = "/work"}) == "/work/", "an empty field lists the base directory");
  require(DirectoryCompletion::query({.text = "projects/", .expanded = "/work/projects"}) == "/work/projects/", "a trailing separator lists children");
  require(DirectoryCompletion::query({.text = "proj", .expanded = "/work/proj"}) == "/work/proj", "a partial name filters its parent");
  require(DirectoryCompletion::query({.text = "/", .expanded = "/"}) == "/", "the root keeps one separator");
}

void listsMatchingDirectoriesOnly() {
  const Fixture fixture;
  for (const auto *name : {"telar", "tools", "notes", ".hidden", ".tooling"}) {
    std::filesystem::create_directory(fixture.root / name);
  }

  std::ofstream{fixture.root / "todo.txt"} << "file";
  std::filesystem::create_directory_symlink(fixture.root / "telar", fixture.root / "terminal");

  const auto prefix = DirectoryCompletion::list(fixture.path("t"));
  require(prefix.base == fixture.root.string(), "the base is the directory listed");
  require(prefix.entries == std::vector<std::string>{"telar", "terminal", "tools"}, "directories and links to them, sorted, files left out");
  require(!prefix.exact_exists, "a partial name is not a directory");

  const auto children = DirectoryCompletion::list(fixture.path("") + "/");
  require(children.entries == std::vector<std::string>{"notes", "telar", "terminal", "tools"}, "hidden directories stay out without a leading dot");
  require(children.exact_exists, "the listed directory exists");

  const auto hidden = DirectoryCompletion::list(fixture.path(".t"));
  require(hidden.entries == std::vector<std::string>{".tooling"}, "a leading dot lists hidden directories");

  require(DirectoryCompletion::list(fixture.path("telar")).exact_exists, "an exact name is a directory");
  require(prefix.join(0) == fixture.path("telar") + "/", "joined paths end in a separator");
}

void keepsTheFirstNamesOfALargeDirectory() {
  const Fixture fixture;
  const auto total = DirectoryCompletion::maximum_entries + 6;
  for (std::size_t index = total; index > 0; --index) {
    std::filesystem::create_directory(fixture.root / std::format("d{:03}", index));
  }

  const auto result = DirectoryCompletion::list(fixture.path("") + "/");
  require(result.matched == total, "every match is counted");
  require(result.entries.size() == DirectoryCompletion::maximum_entries, "the result is bounded");
  require(result.entries.front() == "d001" && result.entries.back() == "d064", "the first names by order are kept");
}

void rejectsRelativeAndMissingQueries() {
  require(DirectoryCompletion::list("relative/path").entries.empty(), "relative queries list nothing");
  const auto missing = DirectoryCompletion::list("/telar-missing-directory/child");
  require(missing.entries.empty() && !missing.exact_exists, "a missing directory lists nothing");
}

void basenamesIgnoreTrailingSeparators() {
  require(DirectoryCompletion::basename("/work/telar/") == "telar", "a trailing separator is ignored");
  require(DirectoryCompletion::basename("/work/telar") == "telar", "the last component names the directory");
  require(DirectoryCompletion::basename("/").empty(), "the root has no name");
}

}

int main() {
  try {
    queriesAskForChildrenOnlyAfterASeparator();
    listsMatchingDirectoriesOnly();
    keepsTheFirstNamesOfALargeDirectory();
    rejectsRelativeAndMissingQueries();
    basenamesIgnoreTrailingSeparators();
    std::puts("gui-directory-completion: passed");
  } catch (const std::exception &error) {
    std::cerr << "gui-directory-completion: " << error.what() << '\n';

    return EXIT_FAILURE;
  }

  return EXIT_SUCCESS;
}
