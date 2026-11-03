#pragma once

#include "arguments.hpp"
#include "cli_install.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/write_descriptor.hpp"
#include <algorithm>
#include <fcntl.h>
#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

namespace telar::runtime::cli::config_receive {

inline constexpr std::size_t max_file_bytes = 1024 * 1024;
inline constexpr std::size_t max_total_bytes = 16 * max_file_bytes;
inline constexpr std::size_t max_files = 4096;
inline constexpr std::size_t max_line_bytes = PATH_MAX + 64;

inline std::string lower(std::string_view text) {
  std::string result{text};
  for (auto &byte : result) {
    if (byte >= 'A' && byte <= 'Z') {
      byte += 'a' - 'A';
    }
  }

  return result;
}

inline bool acceptable(std::string_view path) {
  if (path.empty() || path.size() > PATH_MAX || path.front() == '/' || std::ranges::any_of(path, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f || byte == '\\'; })) {
    return false;
  }

  static constexpr auto roots = std::to_array<std::string_view>({".claude/", ".codex/", ".pi/agent/", ".config/opencode/", ".cursor/", ".agents/skills/"});
  static constexpr auto credential_directories = std::to_array<std::string_view>({".ssh", ".gnupg", ".aws", ".kube", ".docker", "keychains", "gcloud", ".password-store"});
  static constexpr auto session_directories = std::to_array<std::string_view>({"projects", "sessions", "history", "todos", "shell-snapshots", "file-history", "statsig", "logs", "cache", "plans"});
  static constexpr auto credential_names = std::to_array<std::string_view>({".claude.json", ".credentials.json", "auth.json", "mcp-auth.json", "credentials", ".netrc", ".npmrc", ".pypirc", ".pgpass", ".vault-token", ".git-credentials", "hosts.yml", "models.json", "keys.json", "sa.json"});
  static constexpr auto extensions = std::to_array<std::string_view>({".pem", ".key", ".p12", ".pfx", ".keychain", ".keychain-db", ".jsonl", ".db", ".sqlite", ".sqlite3", ".log"});
  static constexpr auto fragments = std::to_array<std::string_view>({"credential", "secret", "token", "password", "passwd"});
  const auto name = lower(path.substr(path.rfind('/') == std::string_view::npos ? 0 : path.rfind('/') + 1));
  if (std::ranges::find(credential_names, name) != credential_names.end() || std::ranges::any_of(extensions, [&](auto extension) { return name.ends_with(extension); }) || std::ranges::any_of(fragments, [&](auto fragment) { return name.contains(fragment); }) || name == ".env" || name.starts_with(".env.") || name.ends_with(".env") || name.starts_with("id_rsa") || name.starts_with("id_ed25519") || name.starts_with("id_ecdsa") || name.starts_with("id_dsa")) {
    return false;
  }

  for (const auto root : roots) {
    if (!path.starts_with(root) || path.size() == root.size()) {
      continue;
    }

    auto tail = path.substr(root.size());
    const auto first = lower(tail.substr(0, tail.find('/')));
    if (std::ranges::find(session_directories, first) != session_directories.end()) {
      return false;
    }

    while (!tail.empty()) {
      const auto separator = tail.find('/');
      const auto component = tail.substr(0, separator);
      if (component.empty() || component.front() == '.' || std::ranges::find(credential_directories, lower(component)) != credential_directories.end()) {
        return false;
      }

      if (separator == std::string_view::npos) {
        return true;
      }

      tail.remove_prefix(separator + 1);
    }

    return false;
  }

  return false;
}

inline std::string line() {
  std::string result;
  char byte;
  while (std::cin.get(byte)) {
    if (byte == '\n') {
      return result;
    }

    if (result.size() == max_line_bytes) {
      throw CommandError{"InvalidConfigStream"};
    }

    result += byte;
  }

  throw CommandError{"InvalidConfigStream"};
}

// Each directory is held by descriptor and opened with O_NOFOLLOW. A symlink
// swapped in while receiving can never redirect the write outside HOME.
inline bool place(int home, const std::string &path, std::string_view bytes, mode_t mode) {
  FileDescriptor parent{::openat(home, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)};
  if (!parent) {
    throw fileError(errno);
  }

  std::string_view tail{path};
  for (;;) {
    const auto slash = tail.find('/');
    if (slash == std::string_view::npos) {
      break;
    }

    const std::string component{tail.substr(0, slash)};
    auto next = ::openat(parent.get(), component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (next < 0 && errno == ENOENT) {
      if (::mkdirat(parent.get(), component.c_str(), 0700) != 0 && errno != EEXIST) {
        throw fileError(errno);
      }

      next = ::openat(parent.get(), component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }

    if (next < 0) {
      if (errno == ELOOP || errno == ENOTDIR) {
        throw CommandError{"SymlinkOnTheWay"};
      }

      throw fileError(errno);
    }

    parent.reset(next);
    tail.remove_prefix(slash + 1);
  }

  const std::string name{tail};
  struct stat state{};
  if (::fstatat(parent.get(), name.c_str(), &state, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(state.st_mode)) {
      throw CommandError{"NotARegularFile"};
    }

    if (state.st_size == static_cast<off_t>(bytes.size()) && (state.st_mode & 0777) == mode) {
      FileDescriptor existing{::openat(parent.get(), name.c_str(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)};
      if (!existing) {
        throw fileError(errno);
      }

      std::array<char, 16 * 1024> buffer;
      std::size_t offset = 0;
      bool same = true;
      for (;;) {
        const auto count = ::read(existing.get(), buffer.data(), buffer.size());
        if (count < 0 && errno == EINTR) {
          continue;
        }

        if (count < 0) {
          throw fileError(errno);
        }

        if (count == 0) {
          break;
        }

        const auto size = static_cast<std::size_t>(count);
        if (offset > bytes.size() || size > bytes.size() - offset || bytes.substr(offset, size) != std::string_view{buffer.data(), size}) {
          same = false;
          break;
        }

        offset += size;
      }

      if (same && offset == bytes.size()) {
        return false;
      }
    }
  } else if (errno != ENOENT) {
    throw fileError(errno);
  }

  std::uint64_t nonce;
  ::arc4random_buf(&nonce, sizeof(nonce));
  std::array<char, 64> temporary;
  std::snprintf(temporary.data(), temporary.size(), ".telar-%016llx", static_cast<unsigned long long>(nonce));
  FileDescriptor file{::openat(parent.get(), temporary.data(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)};
  if (!file) {
    throw fileError(errno);
  }

  try {
    const auto error = writeDescriptor(file.get(), {reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()});
    if (error != 0) {
      throw fileError(error);
    }

    if (::fchmod(file.get(), mode) != 0 || ::fsync(file.get()) != 0) {
      throw fileError(errno);
    }

    file.reset();
    if (::renameat(parent.get(), temporary.data(), parent.get(), name.c_str()) != 0) {
      throw fileError(errno);
    }
  } catch (...) {
    ::unlinkat(parent.get(), temporary.data(), 0);
    throw;
  }

  return true;
}

inline int run() {
  const auto *home_path = std::getenv("HOME");
  if (!home_path) {
    throw CommandError{"HomeUnavailable"};
  }

  FileDescriptor home{::open(home_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)};
  if (!home) {
    throw fileError(errno);
  }

  if (line() != "telar-config 1") {
    throw CommandError{"InvalidConfigStream"};
  }

  std::size_t files = 0;
  std::size_t total = 0;
  std::string output;
  for (;;) {
    auto header = line();
    if (header == "end") {
      std::fwrite(output.data(), 1, output.size(), stdout);
      return 0;
    }

    std::string_view fields{header};
    std::array<std::string_view, 3> prefix;
    for (auto &field : prefix) {
      const auto end = fields.find(' ');
      if (end == std::string_view::npos) {
        throw CommandError{"InvalidConfigStream"};
      }

      field = fields.substr(0, end);
      fields.remove_prefix(end + 1);
    }

    const std::string path{fields};
    if (prefix[0] != "file") {
      throw CommandError{"InvalidConfigStream"};
    }

    std::size_t size = 0;
    try {
      size = parseInt<std::size_t>(prefix[2]);
    } catch (const std::invalid_argument &) {
      throw CommandError{"InvalidConfigStream"};
    }

    if (size > max_file_bytes || size > max_total_bytes - total || ++files > max_files) {
      throw CommandError{"ConfigStreamTooLarge"};
    }

    total += size;
    const mode_t mode = prefix[1] == "644" ? 0644 : prefix[1] == "755" ? 0755
                                                                       : 0;
    if (mode == 0 || path.size() > PATH_MAX) {
      throw CommandError{"InvalidConfigStream"};
    }

    std::string bytes(size, '\0');
    char separator = 0;
    if (!std::cin.read(bytes.data(), static_cast<std::streamsize>(size)) || !std::cin.get(separator) || separator != '\n') {
      throw CommandError{"InvalidConfigStream"};
    }

    if (!acceptable(path)) {
      output += "refused " + path + ": not a path the sync may write\n";
    } else {
      try {
        const auto written = place(home.get(), path, bytes, mode);
        output += std::string{written ? "written " : "unchanged "} + path + "\n";
      } catch (const std::exception &error) {
        output += "refused " + path + ": " + error.what() + "\n";
      }
    }

    constexpr std::size_t output_buffer = 4096;
    if (output.size() >= output_buffer) {
      std::fwrite(output.data(), 1, output.size(), stdout);
      output.clear();
    }
  }
}

}
