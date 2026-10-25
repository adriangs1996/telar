#pragma once

#include "file_descriptor.hpp"
#include <array>
#include <cstdint>
#include <string_view>
#include <sys/stat.h>
#include <sys/un.h>

namespace telar::runtime {

enum class LocalPeerPolicy { same_user, same_user_or_root };

class LocalListener {
public:
  explicit LocalListener(std::string_view path);
  ~LocalListener();
  LocalListener(const LocalListener &) = delete;
  LocalListener &operator=(const LocalListener &) = delete;

  int descriptor() const noexcept {
    return socket_.get();
  }

  FileDescriptor accept(LocalPeerPolicy policy = LocalPeerPolicy::same_user);

  std::string_view path() const noexcept {
    return path_.data();
  }

private:
  void removeStaleSocket(const sockaddr_un &address);
  void cleanup() noexcept;

  std::array<char, sizeof(sockaddr_un::sun_path)> path_{};
  FileDescriptor lock_;
  FileDescriptor socket_;
  dev_t device_ = 0;
  ino_t inode_ = 0;
  bool bound_ = false;
};

}
