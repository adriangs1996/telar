#pragma once

#include "../platform/file_descriptor.hpp"
#include "session_host.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

namespace telar::runtime {

inline bool codexHooksInstalled(const char *override_directory, const char *home) noexcept {
  std::array<char, PATH_MAX> path;
  int length = 0;
  if (override_directory != nullptr && *override_directory != '\0') {
    length = std::snprintf(path.data(), path.size(), "%s/hooks.json", override_directory);
  } else if (home != nullptr && *home != '\0') {
    length = std::snprintf(path.data(), path.size(), "%s/.codex/hooks.json", home);
  } else {
    return false;
  }

  if (length < 0 || static_cast<std::size_t>(length) >= path.size()) {
    return false;
  }

  FileDescriptor file{::open(path.data(), O_RDONLY | O_NONBLOCK | O_CLOEXEC)};
  struct stat metadata;
  if (!file || ::fstat(file.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
    return false;
  }

  constexpr std::size_t maximum_settings_bytes = 32 * 1024;
  std::array<char, maximum_settings_bytes> bytes;
  const auto count = ::read(file.get(), bytes.data(), bytes.size());
  return count > 0 && std::string_view{bytes.data(), static_cast<std::size_t>(count)}.contains(" hook codex");
}

inline bool hooksInstalled(AgentProvider provider, SessionHost host) noexcept {
  return provider == AgentProvider::codex && host == SessionHost::shared_server && codexHooksInstalled(std::getenv("CODEX_HOME"), std::getenv("HOME"));
}

}
