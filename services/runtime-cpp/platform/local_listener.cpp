#include "local_listener.hpp"
#include "socket_signals.hpp"
#include "telar_platform/error.hpp"
#include "telar_platform/peer_credentials.hpp"
#include "telar_platform/private_directory.hpp"
#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/socket.h>

namespace telar::runtime {

LocalListener::LocalListener(std::string_view path) {
  const auto separator = path.rfind('/');
  if (path.empty() || path.front() != '/' || path.size() >= path_.size() || separator == path.size() - 1) {
    throw SystemError{"invalid absolute runtime socket path", EINVAL};
  }

  std::copy(path.begin(), path.end(), path_.begin());
  auto parent = openPrivateParent(path);

  std::array<char, sizeof(sockaddr_un::sun_path) + sizeof(".lock")> lock_path{};
  std::copy(path.begin(), path.end(), lock_path.begin());
  std::memcpy(lock_path.data() + path.size(), ".lock", sizeof(".lock"));
  lock_.reset(::open(lock_path.data(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600));
  struct stat lock_info{};
  if (!lock_ || ::fstat(lock_.get(), &lock_info) != 0) {
    throw SystemError{"open runtime socket lock"};
  }

  if (!S_ISREG(lock_info.st_mode) || lock_info.st_uid != ::geteuid() || lock_info.st_nlink != 1 || (lock_info.st_mode & 0077) != 0) {
    throw SystemError{"unsafe runtime socket lock", EACCES};
  }

  if (::flock(lock_.get(), LOCK_EX | LOCK_NB) != 0) {
    throw SystemError{"runtime is already running"};
  }

  sockaddr_un address{};
  address.sun_family = AF_UNIX;
  std::memcpy(address.sun_path, path_.data(), path.size() + 1);
  removeStaleSocket(address);
  socket_.reset(::socket(AF_UNIX, SOCK_STREAM, 0));
  if (!socket_) {
    throw SystemError{"create runtime socket"};
  }

  setCloseOnExec(socket_.get());
  setNonblocking(socket_.get());
  if (::bind(socket_.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) != 0) {
    throw SystemError{"bind runtime socket"};
  }

  struct stat socket_info{};
  if (::lstat(path_.data(), &socket_info) != 0) {
    throw SystemError{"inspect runtime socket"};
  }

  device_ = socket_info.st_dev;
  inode_ = socket_info.st_ino;
  bound_ = true;

  if (::chmod(path_.data(), 0600) != 0 || ::listen(socket_.get(), 32) != 0) {
    const int failure = errno;
    cleanup();
    throw SystemError{"listen on runtime socket", failure};
  }
}

void LocalListener::removeStaleSocket(const sockaddr_un &address) {
  struct stat existing{};
  if (::lstat(path_.data(), &existing) != 0) {
    if (errno == ENOENT) {
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
  if (::connect(probe.get(), reinterpret_cast<const sockaddr *>(&address), sizeof(address)) == 0 || errno != ECONNREFUSED) {
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

FileDescriptor LocalListener::accept(LocalPeerPolicy policy) {
  FileDescriptor connection{::accept(socket_.get(), nullptr, nullptr)};
  if (!connection) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
      return connection;
    }

    throw SystemError{"accept runtime client"};
  }

  const auto peer = peerCredentials(connection.get());
  if (!peer || (peer->user != ::geteuid() && !(policy == LocalPeerPolicy::same_user_or_root && peer->user == 0))) {
    return FileDescriptor{};
  }

  setCloseOnExec(connection.get());
  setNonblocking(connection.get());
  suppressSocketSignals(connection.get());

  return connection;
}

}
