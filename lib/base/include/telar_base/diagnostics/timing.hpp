#pragma once

#include <cstdint>
#include <limits>

namespace telar {

  inline void accumulate(std::uint64_t& counter, std::uint64_t amount = 1) noexcept {
    const auto room = std::numeric_limits<std::uint64_t>::max() - counter;

    counter += amount < room ? amount : room;
  }

  struct Timing {
    std::uint64_t count = 0;
    std::uint64_t total_ns = 0;
    std::uint64_t maximum_ns = 0;

    void observe(std::uint64_t duration) noexcept {
      accumulate(count);
      accumulate(total_ns, duration);
      maximum_ns = duration > maximum_ns ? duration : maximum_ns;
    }

    [[nodiscard]] std::uint64_t average() const noexcept {
      return count == 0 ? 0 : total_ns / count;
    }

    void merge(const Timing& sample) noexcept {
      accumulate(count, sample.count);
      accumulate(total_ns, sample.total_ns);
      maximum_ns = sample.maximum_ns > maximum_ns ? sample.maximum_ns : maximum_ns;
    }
  };

}
