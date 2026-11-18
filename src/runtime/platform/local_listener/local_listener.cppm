export module telar.runtime.platform.local_listener;

import std;
import telar.sys.posix;
import telar.sys.socket;

import telar.platform.primitives;
import telar.base.ds;

// Interface: platform/local_listener.cppm
export {
  namespace telar::runtime {

    enum class LocalPeerPolicy {
      same_user,
      same_user_or_root,
    };

    class LocalListener {
    public:
      explicit LocalListener(std::string_view path);
      ~LocalListener();
      LocalListener(const LocalListener&) = delete;
      LocalListener& operator=(const LocalListener&) = delete;

      int descriptor() const noexcept;

      FileDescriptor accept(LocalPeerPolicy policy = LocalPeerPolicy::same_user);

      std::string_view path() const noexcept;

    private:
      void removeStaleSocket(const sockaddr_un& address);
      void cleanup() noexcept;

      ds::Array<char, sizeof(sockaddr_un::sun_path)> path_{};
      FileDescriptor lock_;
      FileDescriptor socket_;
      dev_t device_ = 0;
      ino_t inode_ = 0;
      bool bound_ = false;
    };

  }
}
