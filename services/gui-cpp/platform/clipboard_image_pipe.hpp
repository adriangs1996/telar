#pragma once

#include "attachments/secure_erase.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"
#include "core/memory.hpp"
#include "platform/clipboard_image_source.hpp"
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <poll.h>
#include <span>
#include <stdexcept>
#include <time.h>
#include <unistd.h>

namespace telar::gui::platform {

struct ClipboardImagePipeLimits {
  std::size_t source_bytes = AttachmentLimits::maximum_source_bytes;
  std::size_t png_bytes = AttachmentLimits::maximum_png_bytes;
};

class ClipboardImagePipe {
public:
  static constexpr std::chrono::milliseconds timeout{5000};

  template <Allocator Memory>
  [[nodiscard]] static SensitiveBytes<Memory> read(Memory &memory, int descriptor, ClipboardImagePipeLimits limits = {}) {
    if (descriptor < 0) {
      throw ClipboardImageFailure{ClipboardImageError::read_failed};
    }

    SensitiveBytes<Memory> bytes{memory};
    Chunk chunk;
    const auto deadline = now() + timeout;
    while (true) {
      waitReadable(descriptor, deadline);
      const auto count = ::read(descriptor, chunk.bytes.data(), chunk.bytes.size());
      if (count < 0 && (errno == EINTR || errno == EAGAIN)) {
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

private:
  static constexpr std::size_t chunk_bytes = std::size_t{16} * 1024;

  struct Chunk {
    std::array<std::byte, chunk_bytes> bytes{};

    Chunk() = default;
    Chunk(const Chunk &) = delete;
    Chunk &operator=(const Chunk &) = delete;
    Chunk(Chunk &&) = delete;
    Chunk &operator=(Chunk &&) = delete;

    ~Chunk() {
      eraseSensitiveBytes(bytes);
    }
  };

  [[nodiscard]] static std::chrono::milliseconds now() {
    timespec time{};
    if (::clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
      throw std::runtime_error{"ClockFailed"};
    }

    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::seconds{time.tv_sec}) + std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::nanoseconds{time.tv_nsec});
  }

  static void waitReadable(int descriptor, std::chrono::milliseconds deadline) {
    while (true) {
      const auto remaining = deadline - now();
      if (remaining.count() <= 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      pollfd waiting{.fd = descriptor, .events = POLLIN, .revents = 0};
      const auto ready = ::poll(&waiting, 1, static_cast<int>(remaining.count()));
      if (ready < 0 && errno == EINTR) {
        continue;
      }

      if (ready <= 0 || (static_cast<unsigned>(waiting.revents) & static_cast<unsigned>(POLLERR | POLLNVAL)) != 0) {
        throw ClipboardImageFailure{ClipboardImageError::read_failed};
      }

      return;
    }
  }
};

}
