#pragma once

#include "tcp_table.hpp"
#include "telar_platform/directory_stream.hpp"
#include <cstdio>

namespace telar::runtime::redirect {

inline SocketOwners::Result SocketOwners::find(const FlowKey &flow) noexcept {
  Result result;
  try {
    std::optional<std::uint64_t> inode;
    visitLinuxTcpSockets([&](const LinuxTcpSocket &socket) {
      if (socket.inode != 0 && socket.matches(flow.source, flow.destination)) {
        inode = socket.inode;
        return false;
      }
      return true;
    });
    if (!inode) {
      return result;
    }

    for (const auto &selected : processes()) {
      const auto current = inspector_.identity(selected.pid);
      if (!current || !current->sameInstance(selected)) {
        continue;
      }

      std::array<char, PATH_MAX> path;
      std::snprintf(path.data(), path.size(), "/proc/%d/fd", selected.pid);
      DirectoryStream directory{FileDescriptor{::open(path.data(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)}};
      std::size_t count = 0;
      while (const auto *entry = directory.next()) {
        if (++count > maximum_descriptors) {
          result.complete = false;
          break;
        }
        std::array<char, 64> target;
        const auto length = ::readlinkat(directory.descriptor(), entry->d_name, target.data(), target.size());
        if (length < 0 && errno == ENOENT) {
          continue;
        }
        if (length <= 0 || static_cast<std::size_t>(length) >= target.size()) {
          result.complete = false;
          continue;
        }

        std::string_view name{target.data(), static_cast<std::size_t>(length)};
        if (!name.starts_with("socket:[") || !name.ends_with(']')) {
          continue;
        }
        name = name.substr(sizeof("socket:[") - 1, name.size() - sizeof("socket:["));
        std::uint64_t descriptor_inode = 0;
        const auto parsed = std::from_chars(name.data(), name.data() + name.size(), descriptor_inode);
        if (parsed.ec != std::errc{} || parsed.ptr != name.data() + name.size() || descriptor_inode != *inode) {
          continue;
        }
        const auto verified = inspector_.identity(selected.pid);
        if (verified && verified->sameInstance(selected)) {
          result.process = *verified;
          result.complete = true;
          return result;
        }
      }
    }
  } catch (...) {
    result.complete = false;
  }
  return result;
}

}
