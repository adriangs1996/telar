export module telar.runtime.host.local_listener;

import std;
import telar.sys.posix;
import telar.sys.socket;

import telar.platform.primitives;
import telar.base.ds;

// Interface: platform/local_listener.cppm
export {
  namespace telar::runtime {

    enum class LocalPeerPolicy : std::uint8_t {
      same_user,
      same_user_or_root,
    };

    class LocalListener {
    public:
      explicit LocalListener(std::string_view path);
      ~LocalListener();
      LocalListener(const LocalListener&) = delete;
      LocalListener& operator=(const LocalListener&) = delete;
      LocalListener(LocalListener&&) = delete;
      LocalListener& operator=(LocalListener&&) = delete;

      [[nodiscard]] int descriptor() const noexcept;

      // The descriptor to wait on for a connection, or -1 for a moment after accept ran out of
      // descriptors or memory: a loop that waited on the listener would wake again at once for
      // each connection still pending, until other connections close.
      [[nodiscard]] int waitDescriptor() const noexcept;

      // Nothing while no connection is pending, or while the process lacks a descriptor or memory
      // to take one.
      FileDescriptor accept(LocalPeerPolicy policy = LocalPeerPolicy::same_user);

      [[nodiscard]] std::string_view path() const noexcept;

    private:
      void removeStaleSocket(const sockaddr_un& address);
      void cleanup() noexcept;

      ds::Array<char, sizeof(sockaddr_un::sun_path)> path_{};
      FileDescriptor lock_;
      FileDescriptor socket_;
      dev_t device_ = 0;
      ino_t inode_ = 0;
      bool bound_ = false;
      // When accept may run again after it ran out of descriptors or memory.
      std::chrono::steady_clock::time_point resting_until_{};
    };

  }
}
