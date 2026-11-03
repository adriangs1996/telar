#pragma once

#include "telar_platform/git_files.hpp"
#include "telar_platform/git_head.hpp"

namespace telar::runtime {

class LinkedWorktree {
public:
  struct Found {
    std::size_t root_length;
    std::string_view branch;
  };

  std::optional<Found> find(std::string_view directory) noexcept {
    if (!directory.starts_with('/') || directory.contains('\0')) {
      return std::nullopt;
    }

    constexpr unsigned maximum_depth = 64;
    for (unsigned depth = 0; depth < maximum_depth; ++depth) {
      const auto dot_git = GitFiles::join(directory, ".git", path_);
      if (!dot_git) {
        return std::nullopt;
      }
      struct stat status{};
      if (::stat(dot_git->data(), &status) == 0) {
        if (S_ISDIR(status.st_mode)) {
          return std::nullopt;
        }
        const auto branch = linkedBranch(directory);
        return branch ? std::optional{Found{directory.size(), *branch}} : std::nullopt;
      }

      while (directory.size() > 1 && directory.ends_with('/')) {
        directory.remove_suffix(1);
      }
      const auto separator = directory.rfind('/');
      if (directory.size() <= 1 || separator == std::string_view::npos) {
        return std::nullopt;
      }
      directory = directory.substr(0, std::max<std::size_t>(1, separator));
    }

    return std::nullopt;
  }

  std::optional<std::string_view> mainBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> contents;
    const auto common = common_path ? readRegularFile(*common_path, contents) : std::nullopt;
    std::array<char, PATH_MAX> resolved;
    const auto common_directory = common ? GitFiles::resolve(*directory, GitFiles::trim(*common, " \t\r\n"), resolved) : std::nullopt;
    const auto head_path = common_directory ? GitFiles::join(*common_directory, "HEAD", path_) : std::nullopt;
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto text = GitFiles::trim(*head, " \r\n");
    constexpr std::string_view prefix = "ref: refs/heads/";
    return text.starts_with(prefix) && text.size() > prefix.size() ? std::optional{text.substr(prefix.size())} : std::nullopt;
  }

private:
  std::optional<std::string_view> linkedBranch(std::string_view root) noexcept {
    std::array<char, PATH_MAX> git_directory;
    const auto directory = GitFiles::directory(root, git_directory);
    if (!directory) {
      return std::nullopt;
    }

    const auto common_path = GitFiles::join(*directory, "commondir", path_);
    std::array<char, PATH_MAX> common;
    if (!common_path || !readRegularFile(*common_path, common)) {
      return std::nullopt;
    }
    const auto head_path = GitFiles::join(*directory, "HEAD", path_);
    const auto head = head_path ? readRegularFile(*head_path, head_) : std::nullopt;
    if (!head) {
      return std::nullopt;
    }

    const auto branch = GitHead::parse(*head);
    return branch.empty() ? std::nullopt : std::optional{branch};
  }

  std::array<char, PATH_MAX> path_;
  std::array<char, 256> head_;
};

}
