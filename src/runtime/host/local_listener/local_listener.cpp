module telar.runtime.host.local_listener;

import std;
import telar.sys.socket;

import telar.platform.net;
import telar.platform.error;
import telar.platform.primitives;
import telar.platform.fs;
import telar.sys.posix;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // Only the owner may read or write the socket and its lock.
    constexpr mode_t owner_only_mode = 0600;
    // The permission bits of the group and of everyone else.
    constexpr mode_t shared_mode_bits = 0077;
    constexpr int listen_backlog = 32;

    const sockaddr* genericAddress(const sockaddr_un& address) noexcept {
      return reinterpret_cast<const sockaddr*>(&address); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the socket API passes every address family as a sockaddr
    }

    // Whether accept found no connection to take yet. POSIX lets EWOULDBLOCK differ from EAGAIN,
    // though Linux and macOS spell one error twice.
    bool nothingPending(int error) noexcept {
      constexpr bool distinct_would_block = EWOULDBLOCK != EAGAIN;

      return error == EAGAIN || (distinct_would_block && error == EWOULDBLOCK) || error == EINTR;
    }

    // Readies an accepted connection for the event loop; false when its peer may not connect, or
    // when it closed during admission.
    bool admit(int connection, LocalPeerPolicy policy) {
      const auto peer = peerCredentials(connection);
      if (!peer || (peer->user != ::geteuid() && (policy != LocalPeerPolicy::same_user_or_root || peer->user != 0))) {
        return false;
      }

      setCloseOnExec(connection);
      setNonblocking(connection);
      try {
        suppressSocketSignals(connection);
      } catch (const SystemError& error) {
        // A peer closing during admission can invalidate its socket options on macOS.
        if (error.code() != EINVAL) {
          throw;
        }

        return false;
      }

      return true;
    }

  }

  LocalListener::LocalListener(std::string_view path) {
    const auto separator = path.rfind('/');
    if (path.empty() || path.front() != '/' || path.size() >= path_.size() || separator == path.size() - 1) {
      throw SystemError{"invalid absolute runtime socket path", EINVAL};
    }

    std::ranges::copy(path, path_.viewMut().begin());
    auto parent = openPrivateParent(path);

    constexpr std::string_view lock_suffix = ".lock";
    // Zeroed, so the path ends terminated.
    ds::Array<char, sizeof(sockaddr_un::sun_path) + lock_suffix.size() + 1> lock_path{};

    std::ranges::copy(path, lock_path.viewMut().begin());
    std::ranges::copy(lock_suffix, lock_path.viewMut().subspan(path.size()).begin());
    lock_.reset(::open(lock_path.data(), combineFlags(O_RDWR, O_CREAT, O_CLOEXEC, O_NOFOLLOW), owner_only_mode)); // NOLINT(cppcoreguidelines-pro-type-vararg): open's C signature is variadic
    struct stat lock_info{};
    if (!lock_ || ::fstat(lock_.get(), &lock_info) != 0) {
      throw SystemError{"open runtime socket lock"};
    }

    if (!S_ISREG(lock_info.st_mode) || lock_info.st_uid != ::geteuid() || lock_info.st_nlink != 1 || (lock_info.st_mode & shared_mode_bits) != 0) {
      throw SystemError{"unsafe runtime socket lock", EACCES};
    }

    if (::flock(lock_.get(), combineFlags(LOCK_EX, LOCK_NB)) != 0) {
      throw SystemError{"runtime is already running"};
    }

    sockaddr_un address{};

    address.sun_family = AF_UNIX;
    // The address is zeroed, so the path ends terminated.
    std::ranges::copy(path, std::span{address.sun_path}.begin());
    removeStaleSocket(address);
    socket_.reset(::socket(AF_UNIX, SOCK_STREAM, 0));
    if (!socket_) {
      throw SystemError{"create runtime socket"};
    }

    setCloseOnExec(socket_.get());
    setNonblocking(socket_.get());
    if (::bind(socket_.get(), genericAddress(address), sizeof(address)) != 0) {
      throw SystemError{"bind runtime socket"};
    }

    struct stat socket_info{};
    if (::lstat(path_.data(), &socket_info) != 0) {
      throw SystemError{"inspect runtime socket"};
    }

    device_ = socket_info.st_dev;
    inode_ = socket_info.st_ino;
    bound_ = true;

    if (::chmod(path_.data(), owner_only_mode) != 0 || ::listen(socket_.get(), listen_backlog) != 0) {
      const int failure = sys::lastError();

      cleanup();
      throw SystemError{"listen on runtime socket", failure};
    }
  }

  void LocalListener::removeStaleSocket(const sockaddr_un& address) {
    struct stat existing{};
    if (::lstat(path_.data(), &existing) != 0) {
      if (sys::lastError() == ENOENT) {
        return;
      }

      throw SystemError{"inspect existing runtime socket"};
    }

    if (!S_ISSOCK(existing.st_mode) || existing.st_uid != ::geteuid()) {
      throw SystemError{"runtime endpoint is not an owned socket", EACCES};
    }

    FileDescriptor probe{::socket(AF_UNIX, SOCK_STREAM, 0)};
    if (!probe) {
      throw SystemError{"probe runtime socket"};
    }

    setNonblocking(probe.get());
    if (::connect(probe.get(), genericAddress(address), sizeof(address)) == 0 || sys::lastError() != ECONNREFUSED) {
      throw SystemError{"runtime endpoint is in use", EADDRINUSE};
    }

    struct stat current{};
    if (::lstat(path_.data(), &current) != 0 || current.st_dev != existing.st_dev || current.st_ino != existing.st_ino) {
      throw SystemError{"runtime endpoint changed during recovery", EAGAIN};
    }

    if (::unlink(path_.data()) != 0) {
      throw SystemError{"remove stale runtime socket"};
    }
  }

  LocalListener::~LocalListener() {
    cleanup();
  }

  void LocalListener::cleanup() noexcept {
    if (!bound_) {
      return;
    }

    struct stat current{};
    if (::lstat(path_.data(), &current) == 0 && current.st_dev == device_ && current.st_ino == inode_) {
      ::unlink(path_.data());
    }

    bound_ = false;
  }

  int LocalListener::descriptor() const noexcept {
    return socket_.get();
  }

  FileDescriptor LocalListener::accept(LocalPeerPolicy policy) {
    FileDescriptor connection{::accept(socket_.get(), nullptr, nullptr)};
    if (!connection) {
      if (nothingPending(sys::lastError())) {
        return connection;
      }

      throw SystemError{"accept runtime client"};
    }

    if (!admit(connection.get(), policy)) {
      connection.reset();
    }

    return connection;
  }

  std::string_view LocalListener::path() const noexcept {
    return path_.data();
  }

}
