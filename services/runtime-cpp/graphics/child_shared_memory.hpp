#pragma once

#include "../platform/file_descriptor.hpp"
#include "child_name.hpp"
#include <array>
#include <fcntl.h>
#include <limits.h>
#include <sys/mman.h>
#include <limits>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

namespace telar::runtime {

class GraphicsChildSharedMemory {
public:
  static FileDescriptor open(std::string_view encoded_name, std::span<std::uint8_t> name) noexcept {
    const auto *decoded = decodeGraphicsName(encoded_name, name);
    return FileDescriptor{decoded == nullptr ? -1 : ::shm_open(decoded, O_RDONLY, 0)};
  }

  static FileDescriptor openDecoded(std::span<const std::uint8_t> decoded_name, std::span<std::uint8_t> name) noexcept {
    const auto *decoded = copyGraphicsName(decoded_name, name);
    FileDescriptor descriptor{decoded == nullptr ? -1 : ::shm_open(decoded, O_RDONLY, 0)};
    if (descriptor && ::fcntl(descriptor.get(), F_SETFD, FD_CLOEXEC) != 0) {
      return FileDescriptor{};
    }
    return descriptor;
  }

  static bool read(int descriptor, std::span<std::uint8_t> output, std::uint64_t offset) noexcept {
    if (output.empty()) {
      return true;
    }
#if defined(__APPLE__)
    // Darwin POSIX shared-memory descriptors do not support pread. Copy via
    // the kernel so invalid backing pages return an error instead of delivering
    // SIGBUS while the runtime dereferences a peer-controlled mapping.
    const auto page = ::sysconf(_SC_PAGESIZE);
    if (page <= 0) {
      return false;
    }
    const auto aligned = offset / page * page;
    const auto delta = static_cast<std::size_t>(offset - aligned);
    if (aligned > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max()) || output.size() > SIZE_MAX - delta) {
      return false;
    }
    const auto length = output.size() + delta;
    void *mapping = ::mmap(nullptr, length, PROT_READ, MAP_SHARED, descriptor, static_cast<off_t>(aligned));
    if (mapping == MAP_FAILED) {
      return false;
    }
    mach_vm_size_t copied = 0;
    const auto result = ::mach_vm_read_overwrite(::mach_task_self(), reinterpret_cast<mach_vm_address_t>(mapping) + delta, output.size(), reinterpret_cast<mach_vm_address_t>(output.data()), &copied);
    ::munmap(mapping, length);
    return result == KERN_SUCCESS && copied == output.size();
#else
    std::size_t filled = 0;
    while (filled < output.size()) {
      if (offset > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max()) - filled) {
        return false;
      }
      const auto count = ::pread(descriptor, output.data() + filled, output.size() - filled, static_cast<off_t>(offset + filled));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        return false;
      }
      filled += static_cast<std::size_t>(count);
    }
    return true;
#endif
  }

  static void release(std::string_view encoded_name) noexcept {
    std::array<std::uint8_t, PATH_MAX + 1> name;
    const auto descriptor = open(encoded_name, name);
    if (descriptor) {
      ::shm_unlink(reinterpret_cast<const char *>(name.data()));
    }
  }
};

}
