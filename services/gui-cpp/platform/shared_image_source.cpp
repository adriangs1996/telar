#include "shared_image_source.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <algorithm>
#include <array>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace telar::gui::platform {

namespace {

bool sharedStorage(const struct stat &status) noexcept {
#if defined(__APPLE__)
  // Darwin reports permission bits but no regular-file type for shm_open objects.
  return (status.st_mode & S_IFMT) == 0;
#else
  return S_ISREG(status.st_mode);
#endif
}

}

SharedImageSource::SharedImageSource(std::string_view name) {
  validateSharedImageName(name);
  constexpr std::size_t name_capacity = 32;
  constexpr mode_t nonprivate_permissions = 0077;
  std::array<char, name_capacity> terminated{};
  std::ranges::copy(name, terminated.begin());
#if defined(__linux__)
  constexpr int open_flags = O_RDONLY | O_NONBLOCK;
#else
  constexpr int open_flags = O_RDONLY;
#endif
  runtime::FileDescriptor descriptor{::shm_open(terminated.data(), open_flags, 0)};
  if (!descriptor) {
    return;
  }

  struct stat status{};
  if (::fstat(descriptor.get(), &status) != 0 || !sharedStorage(status) || status.st_uid != ::geteuid() || (status.st_mode & nonprivate_permissions) != 0) {
    return;
  }

  const bool close_on_exec = ::fcntl(descriptor.get(), F_SETFD, FD_CLOEXEC) == 0;
  const bool unlinked = ::shm_unlink(terminated.data()) == 0;
  if (close_on_exec && unlinked) {
    descriptor_ = std::move(descriptor);
  }
}

bool SharedImageSource::read(std::span<std::uint8_t> destination) const noexcept {
  struct stat status{};
  if (!descriptor_ || destination.empty() || ::fstat(descriptor_.get(), &status) != 0 || status.st_size < 0 || std::cmp_less(status.st_size, destination.size())) {
    return false;
  }

  // Kernel-mediated reads retain owned pixels and reject backing-store truncation
  // without dereferencing a peer-controlled mapping on the GUI thread.
  return runtime::GraphicsChildSharedMemory::read(descriptor_.get(), destination, 0);
}

}
