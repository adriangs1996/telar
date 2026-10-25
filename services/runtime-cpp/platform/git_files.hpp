#pragma once

#include "read_regular_file.hpp"

namespace telar::runtime {

class GitFiles {
public:
  static std::optional<std::string_view> join(std::string_view directory, std::string_view suffix, std::span<char> buffer) noexcept {
    while (directory.ends_with('/')) {
      directory.remove_suffix(1);
    }
    const auto length = directory.size() + 1 + suffix.size();
    if (length >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), directory.data(), directory.size());
    buffer[directory.size()] = '/';
    std::memcpy(buffer.data() + directory.size() + 1, suffix.data(), suffix.size());
    buffer[length] = '\0';
    return std::string_view{buffer.data(), length};
  }

  static std::optional<std::string_view> resolve(std::string_view directory, std::string_view path, std::span<char> buffer) noexcept {
    if (path.empty() || path.contains('\0')) {
      return std::nullopt;
    }
    if (!path.starts_with('/')) {
      return join(directory, path, buffer);
    }
    if (path.size() >= buffer.size()) {
      return std::nullopt;
    }

    std::memcpy(buffer.data(), path.data(), path.size());
    buffer[path.size()] = '\0';
    return std::string_view{buffer.data(), path.size()};
  }

  static std::optional<std::string_view> directory(std::string_view root, std::span<char> buffer) noexcept {
    std::array<char, PATH_MAX> path;
    const auto dot_git = join(root, ".git", path);
    std::array<char, PATH_MAX + 16> bytes;
    const auto pointer = dot_git ? readRegularFile(*dot_git, bytes) : std::nullopt;
    if (!pointer) {
      return std::nullopt;
    }

    const auto contents = trim(*pointer, " \t\r\n");
    constexpr std::string_view prefix = "gitdir:";
    if (!contents.starts_with(prefix)) {
      return std::nullopt;
    }

    return resolve(root, trim(contents.substr(prefix.size()), " \t"), buffer);
  }

  static std::string_view trim(std::string_view value, std::string_view characters) noexcept {
    const auto first = value.find_first_not_of(characters);
    if (first == std::string_view::npos) {
      return {};
    }

    return value.substr(first, value.find_last_not_of(characters) - first + 1);
  }
};

}
