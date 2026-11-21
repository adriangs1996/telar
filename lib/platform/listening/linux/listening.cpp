module telar.platform.listening;

import telar.base.ds;
import telar.base.text;
import telar.platform.primitives;
import telar.sys.process;

namespace telar::runtime {

  namespace {

    constexpr int hexadecimal = 16;

    // One row of /proc/net/tcp or tcp6: `sl local remote st tx:rx tr:when retransmits uid timeout inode`.
    ds::Option<ListeningSocket> parseListening(std::string_view line, uid_t user) noexcept {
      constexpr unsigned listen_state = 0x0a;
      ds::Array<std::string_view, 10> fields;

      for (auto& field : fields.viewMut()) {
        const auto first = line.find_first_not_of(' ');
        if (first == std::string_view::npos) {
          return ds::none;
        }

        line.remove_prefix(first);
        field = line.substr(0, line.find(' '));
        line.remove_prefix(field.size());
      }

      const auto separator = fields[1].rfind(':');
      if (separator == std::string_view::npos) {
        return ds::none;
      }

      const auto state = parseExact<unsigned>(fields[3], hexadecimal);
      const auto owner = parseExact<uid_t>(fields[7]);
      const auto port = parseExact<std::uint16_t>(fields[1].substr(separator + 1), hexadecimal);
      const auto inode = parseExact<std::uint64_t>(fields[9]);
      if (state != listen_state || owner != user || !port || !inode || *inode == 0) {
        return ds::none;
      }

      return ListeningSocket{.inode = *inode, .port = *port};
    }

    // Appends the listening sockets `user` owns in one kernel TCP table.
    std::size_t readListening(const char* path, uid_t user, std::span<ListeningSocket> sockets, std::size_t count) noexcept {
      constexpr std::size_t buffer_bytes = std::size_t{16} * 1024;
      const FileDescriptor file{::open(path, combineFlags(O_RDONLY, O_CLOEXEC, O_NOFOLLOW))}; // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
      if (!file) {
        return count;
      }

      ds::Array<char, buffer_bytes> buffer;
      std::size_t kept = 0;
      bool header = true;

      while (count < sockets.size()) {
        const auto read = ::read(file.get(), buffer.dataMut() + kept, buffer.size() - kept);
        if (read < 0 && sys::lastError() == EINTR) {
          continue;
        }

        if (read <= 0) {
          break;
        }

        std::string_view text{buffer.data(), kept + static_cast<std::size_t>(read)};

        for (auto newline = text.find('\n'); newline != std::string_view::npos && count < sockets.size(); newline = text.find('\n')) {
          if (!header) {
            if (const auto socket = parseListening(text.substr(0, newline), user)) {
              sockets[count++] = *socket;
            }
          }

          header = false;
          text.remove_prefix(newline + 1);
        }

        // A row longer than the buffer is not a TCP table row.
        if (text.size() == buffer.size()) {
          break;
        }

        kept = text.size();
        std::memmove(buffer.dataMut(), text.data(), kept);
      }

      return count;
    }

  }

  std::size_t listeningSockets(uid_t user, std::span<ListeningSocket> sockets) noexcept {
    const auto count = readListening("/proc/net/tcp", user, sockets, 0);

    return readListening("/proc/net/tcp6", user, sockets, count);
  }

  std::size_t processGroupMembers(pid_t group, std::span<pid_t> members) noexcept {
    auto* directory = ::opendir("/proc");
    std::size_t count = 0;

    if (directory == nullptr) {
      return 0;
    }

    while (const auto* entry = ::readdir(directory)) {
      const auto process = parseExact<pid_t>(std::string_view{entry->d_name}).valueOr(0);
      if (process <= 0 || count == members.size()) {
        continue;
      }

      if (::getpgid(process) == group) {
        members[count++] = process;
      }
    }

    ::closedir(directory);
    return count;
  }

  std::size_t groupListeningPorts(uid_t user, pid_t group, std::span<std::uint16_t> ports) noexcept {
    constexpr std::size_t maximum_group_processes = 64;
    constexpr std::size_t maximum_sockets = 256;
    constexpr std::size_t link_bytes = 64;
    constexpr std::string_view prefix = "socket:[";
    ds::Array<ListeningSocket, maximum_sockets> sockets;
    const auto listening = std::span{sockets}.first(listeningSockets(user, sockets.viewMut()));
    ds::Array<pid_t, maximum_group_processes> members;
    std::size_t count = 0;

    if (listening.empty()) {
      return 0;
    }

    // A process holds a listening socket when one of its descriptors names the socket's inode.
    for (const auto member : std::span{members}.first(processGroupMembers(group, members.viewMut()))) {
      ds::Array<char, sizeof("/proc//fd") + std::numeric_limits<pid_t>::digits10 + 1> path{};

      std::format_to_n(path.dataMut(), path.size() - 1, "/proc/{}/fd", member);
      auto* directory = ::opendir(path.data());
      if (directory == nullptr) {
        continue;
      }

      while (const auto* entry = ::readdir(directory)) {
        ds::Array<char, link_bytes> target;
        const auto length = ::readlinkat(::dirfd(directory), entry->d_name, target.dataMut(), target.size());
        const std::string_view link{target.data(), length > 0 ? static_cast<std::size_t>(length) : 0};
        if (!link.starts_with(prefix) || !link.ends_with(']')) {
          continue;
        }

        const auto inode = parseExact<std::uint64_t>(link.substr(prefix.size(), link.size() - prefix.size() - 1));
        const auto found = inode ? std::ranges::find(listening, *inode, &ListeningSocket::inode) : listening.end();
        if (found != listening.end() && count < ports.size()) {
          ports[count++] = found->port;
        }
      }

      ::closedir(directory);
    }

    return count;
  }

  std::size_t userListeningPorts(uid_t user, std::span<std::uint16_t> ports) noexcept {
    constexpr std::size_t maximum_sockets = 512;
    ds::Array<ListeningSocket, maximum_sockets> sockets;
    const auto listening = sockets.viewMut().first(listeningSockets(user, sockets.viewMut()));

    // A port bound on both families listens twice and is told once.
    std::ranges::sort(listening, {}, &ListeningSocket::port);
    std::size_t count = 0;

    for (const auto& socket : listening) {
      if (count == ports.size()) {
        break;
      }

      if (count == 0 || ports[count - 1] != socket.port) {
        ports[count++] = socket.port;
      }
    }

    return count;
  }

}
