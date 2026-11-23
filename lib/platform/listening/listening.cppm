export module telar.platform.listening;

// The TCP ports a user's processes listen on, as the system tells them: Linux from its socket
// tables, macOS from the descriptors of each process.
import std;

import telar.sys.posix;

// Interface: telar_platform/listening.cppm
export {
  namespace telar::runtime {

#ifdef __linux__

    // A TCP socket in the listen state. Its inode tells which process holds it: the same number
    // names the socket among that process's descriptors.
    struct ListeningSocket {
      std::uint64_t inode = 0;
      std::uint16_t port = 0;
    };

    // The listening TCP sockets `user` owns, of either address family, into `sockets`; returns
    // how many it wrote.
    std::size_t listeningSockets(uid_t user, std::span<ListeningSocket> sockets) noexcept;

#else

    // The TCP ports `process` listens on, into `ports`; returns how many it wrote. A port two
    // of its sockets listen on comes twice.
    std::size_t processListeningPorts(pid_t process, std::span<std::uint16_t> ports) noexcept;

#endif

    // The processes of the process group `group`, into `members`; returns how many it wrote.
    std::size_t processGroupMembers(pid_t group, std::span<pid_t> members) noexcept;

    // The TCP ports the processes of the group `group`, which `user` runs, listen on, into
    // `ports`; returns how many it wrote. A port two of its sockets listen on comes twice.
    std::size_t groupListeningPorts(uid_t user, pid_t group, std::span<std::uint16_t> ports) noexcept;

    // The TCP ports the processes of `user` listen on, each once and ascending, into `ports`;
    // returns how many it wrote.
    std::size_t userListeningPorts(uid_t user, std::span<std::uint16_t> ports) noexcept;

  }
}
