#pragma once

#include "git_files.hpp"
#include <algorithm>

namespace telar::runtime {

class GitHead {
public:
  std::optional<std::string_view> read(std::string_view root) noexcept {
    const auto direct = GitFiles::join(root, ".git/HEAD", path_);
    if (!direct) {
      return std::nullopt;
    }
    if (const auto contents = readRegularFile(*direct, head_)) {
      return parse(*contents);
    }

    std::array<char, PATH_MAX> resolved;
    const auto directory = GitFiles::directory(root, resolved);
    if (!directory) {
      return std::nullopt;
    }

    const auto linked = GitFiles::join(*directory, "HEAD", path_);
    const auto head = linked ? readRegularFile(*linked, head_) : std::nullopt;
    return head ? std::optional{parse(*head)} : std::nullopt;
  }

  static std::string_view parse(std::string_view contents) noexcept {
    contents = GitFiles::trim(contents, " \r\n");
    constexpr std::string_view reference = "ref:";
    constexpr std::string_view branch = "refs/heads/";
    if (contents.starts_with(reference)) {
      contents = GitFiles::trim(contents.substr(reference.size()), " ");
      return contents.starts_with(branch) ? contents.substr(branch.size()) : contents;
    }

    constexpr std::size_t abbreviated_hash_length = 8;
    return contents.substr(0, abbreviated_hash_length);
  }

private:
  std::array<char, PATH_MAX> path_;
  std::array<char, 4096> head_;
};

}
