module telar.gui.platform;

import telar.tbc;
import std;
import telar.base.memory.allocators;
import telar.sys.posix;

namespace telar::gui::platform {

  template <Allocator Memory>
  tbc::view<SensitiveBytes<Memory>, tbc::lt::a> ClipboardImagePipe::read(tbc::view<Memory&, tbc::lt::a> memory, int descriptor, ClipboardImagePipeLimits limits) {
    if (descriptor < 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    SensitiveBytes<Memory> bytes{memory};
    Chunk chunk;
    const auto deadline = now() + timeout;

    while (true) {
      waitReadable(descriptor, deadline);
      const auto count = ::read(descriptor, chunk.bytes.dataMut(), chunk.bytes.size());
      if (count < 0 && (sys::lastError() == EINTR || sys::lastError() == EAGAIN)) {
        continue;
      }

      if (count < 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      if (count == 0) {
        if (bytes.size() == 0) {
          throw ClipboardImageFailure{ClipboardImageError::no_image};
        }

        return bytes;
      }

      const auto size = static_cast<std::size_t>(count);
      if (size > limits.source_bytes - bytes.size()) {
        throw ClipboardImageFailure{ClipboardImageError::source_bytes};
      }

      if (size > limits.png_bytes - bytes.size()) {
        throw ClipboardImageFailure{ClipboardImageError::png_bytes};
      }

      bytes.append(std::span{chunk.bytes}.first(size), std::min(limits.source_bytes, limits.png_bytes));
    }
  }

  template SensitiveBytes<telar::Memory> ClipboardImagePipe::read<telar::Memory>(telar::Memory& memory, int descriptor, ClipboardImagePipeLimits limits);
  template SensitiveBytes<telar::ConcurrentMemory> ClipboardImagePipe::read<telar::ConcurrentMemory>(telar::ConcurrentMemory& memory, int descriptor, ClipboardImagePipeLimits limits);

  ClipboardImagePipe::Chunk::~Chunk() {
    eraseSensitiveBytes(bytes.viewMut());
  }

  std::chrono::milliseconds ClipboardImagePipe::now() {
    timespec time{};
    if (::clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
      throw std::runtime_error{"ClockFailed"};
    }

    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::seconds{time.tv_sec}) + std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::nanoseconds{time.tv_nsec});
  }

  void ClipboardImagePipe::waitReadable(int descriptor, std::chrono::milliseconds deadline) {
    while (true) {
      const auto remaining = deadline - now();
      if (remaining.count() <= 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      pollfd waiting{.fd = descriptor, .events = POLLIN, .revents = 0};
      const auto ready = ::poll(&waiting, 1, static_cast<int>(remaining.count()));
      if (ready < 0 && sys::lastError() == EINTR) {
        continue;
      }

      if (ready <= 0 || (static_cast<unsigned>(waiting.revents) & static_cast<unsigned>(POLLERR | POLLNVAL)) != 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      return;
    }
  }

}
