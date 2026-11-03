#pragma once

#include "telar_base/memory/allocator.hpp"
#include <atomic>
#include <chrono>
#include <sys/stat.h>

namespace telar::runtime::diagnostics {

template <Allocator Memory>
class FileStorage {
public:
  using Clock = std::chrono::steady_clock;

  explicit FileStorage(Memory &memory, std::string_view path)
      : path_(path, AllocatorRef<char, Memory>{memory}) {}

  void sample(Clock::time_point now) noexcept {
    if (now < next_sample_) {
      return;
    }
    next_sample_ = now + sample_interval;

    struct stat status;
    const bool available = !path_.empty() && path_ != ":memory:" && ::lstat(path_.c_str(), &status) == 0 && S_ISREG(status.st_mode) && status.st_size >= 0;
    bytes_.store(available ? static_cast<std::uint64_t>(status.st_size) : 0, std::memory_order_relaxed);
  }

  std::uint64_t bytes() const noexcept {
    return bytes_.load(std::memory_order_relaxed);
  }

private:
  static constexpr auto sample_interval = std::chrono::seconds{1};
  String<Memory> path_;
  Clock::time_point next_sample_{};
  std::atomic<std::uint64_t> bytes_{0};
};

}
