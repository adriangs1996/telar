module telar.platform.primitives;

import std;
import telar.tbc;
import telar.base.text;
import telar.platform.error;
import telar.sys.posix;
import telar.base.ds;
#ifdef __APPLE__
import telar.sys.apple;
#else
import telar.sys.linux_api;
#endif

// The owned header declares these in the global module, so their definitions belong to it too.
extern "C++" {
namespace telar::runtime {

  FileDescriptor duplicateCloseOnExec(int descriptor, int minimum) {
    const int copied = ::fcntl(descriptor, F_DUPFD_CLOEXEC, minimum);
    if (copied < 0) {
      throw SystemError{"duplicate close-on-exec descriptor"};
    }

    return FileDescriptor{copied};
  }

  void setNonblocking(int descriptor) {
    const int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0) {
      throw SystemError{"set nonblocking descriptor"};
    }
  }

  void setCloseOnExec(int descriptor) {
    const int flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) < 0) {
      throw SystemError{"set close-on-exec descriptor"};
    }
  }

}
}

namespace telar::runtime {

  void randomBytes(void* data, std::size_t size) noexcept {
#ifdef __linux__
    auto* cursor = static_cast<unsigned char*>(data);
    while (size != 0) {
      const auto count = ::getrandom(cursor, size, 0);
      if (count < 0) {
        if (sys::lastError() == EINTR) {
          continue;
        }

        std::abort();
      }

      cursor += count;
      size -= static_cast<std::size_t>(count);
    }
#else
    ::arc4random_buf(data, size);
#endif
  }

}

namespace telar::runtime {

  MappedRegion::MappedRegion(int descriptor, std::size_t length, int protection) noexcept {
    void* address = ::mmap(nullptr, length, protection, MAP_SHARED, descriptor, 0);
    if (address != MAP_FAILED) {
      bytes_ = {static_cast<std::uint8_t*>(address), length};
    }
  }

  MappedRegion::~MappedRegion() {
    reset();
  }

  MappedRegion& MappedRegion::operator=(MappedRegion&& other) noexcept {
    if (this != &other) {
      reset();
      bytes_ = std::exchange(other.bytes_, {});
    }

    return *this;
  }

  bool MappedRegion::protect(int protection) noexcept {
    return ::mprotect(bytes_.data(), bytes_.size(), protection) == 0;
  }

  void MappedRegion::reset() noexcept {
    if (!bytes_.empty()) {
      ::munmap(bytes_.data(), bytes_.size());
      bytes_ = {};
    }
  }

  tbc::val_a<const char*> copyGraphicsName(std::span<const std::uint8_t> decoded, tbc::val_a<std::span<std::uint8_t>> destination) noexcept {
    if (decoded.empty() || decoded.size() >= destination.size() || std::find(decoded.begin(), decoded.end(), 0) != decoded.end()) {
      return nullptr;
    }

    std::copy(decoded.begin(), decoded.end(), destination.begin());
    destination[decoded.size()] = 0;
    return reinterpret_cast<const char*>(destination.data());
  }

  tbc::val_a<const char*> decodeGraphicsName(std::string_view encoded, tbc::val_a<std::span<std::uint8_t>> destination) noexcept {
    if (destination.empty()) {
      return nullptr;
    }

    const auto length = base64::decode(encoded, destination.first(destination.size() - 1));
    if (!length || *length == 0 || std::find(destination.begin(), destination.begin() + *length, 0) != destination.begin() + *length) {
      return nullptr;
    }

    destination[*length] = 0;
    return reinterpret_cast<const char*>(destination.data());
  }

  FileDescriptor GraphicsChildSharedMemory::open(std::string_view encoded_name, std::span<std::uint8_t> name) noexcept {
    const auto* decoded = decodeGraphicsName(encoded_name, name);
    FileDescriptor descriptor{decoded == nullptr ? -1 : ::shm_open(decoded, O_RDONLY, 0)};
    if (descriptor && ::fcntl(descriptor.get(), F_SETFD, FD_CLOEXEC) != 0) {
      return FileDescriptor{};
    }

    return descriptor;
  }

  FileDescriptor GraphicsChildSharedMemory::openDecoded(std::span<const std::uint8_t> decoded_name, std::span<std::uint8_t> name) noexcept {
    const auto* decoded = copyGraphicsName(decoded_name, name);
    FileDescriptor descriptor{decoded == nullptr ? -1 : ::shm_open(decoded, O_RDONLY, 0)};
    if (descriptor && ::fcntl(descriptor.get(), F_SETFD, FD_CLOEXEC) != 0) {
      return FileDescriptor{};
    }

    return descriptor;
  }

  bool GraphicsChildSharedMemory::read(int descriptor, std::span<std::uint8_t> output, std::uint64_t offset) noexcept {
    if (output.empty()) {
      return true;
    }

#ifdef __APPLE__
    // Darwin POSIX shared-memory descriptors do not support pread. Copy via
    // the kernel so invalid backing pages return an error instead of delivering
    // SIGBUS while the runtime dereferences a peer-controlled mapping.
    const auto page = ::sysconf(_SC_PAGESIZE);
    if (page <= 0) {
      return false;
    }

    const auto aligned = offset / page * page;
    const auto delta = static_cast<std::size_t>(offset - aligned);
    if (aligned > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max()) || output.size() > std::numeric_limits<std::size_t>::max() - delta) {
      return false;
    }

    const auto length = output.size() + delta;
    void* mapping = ::mmap(nullptr, length, PROT_READ, MAP_SHARED, descriptor, static_cast<off_t>(aligned));
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
      if (count < 0 && sys::lastError() == EINTR) {
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

  void GraphicsChildSharedMemory::release(std::string_view encoded_name) noexcept {
    ds::Array<std::uint8_t, PATH_MAX + 1> name;
    const auto descriptor = open(encoded_name, name.viewMut());
    if (descriptor) {
      ::shm_unlink(reinterpret_cast<const char*>(name.data()));
    }
  }

}
