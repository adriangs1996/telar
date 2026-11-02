#pragma once

#include <cstdint>
#include <limits>

namespace telar::runtime::traffic {

class KernelDrops {
public:
  struct Sample {
    std::uint32_t buffer = 0;
    std::uint32_t interface = 0;
  };

  void observe(Sample &previous, std::uint32_t buffer, std::uint32_t interface) noexcept {
    // libpcap counters are cumulative within one capture handle and can wrap.
    // A reopened handle gets a fresh Sample; the session total stays intact.
    const auto delta = std::uint64_t{static_cast<std::uint32_t>(buffer - previous.buffer)} + static_cast<std::uint32_t>(interface - previous.interface);
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    total_ = delta > maximum - total_ ? maximum : total_ + delta;
    previous = {.buffer = buffer, .interface = interface};
  }

  std::uint64_t count() const noexcept { return total_; }

private:
  std::uint64_t total_ = 0;
};

}
