#pragma once

#include <chrono>
#include <cstddef>

namespace telar::runtime {

struct ProxyCaptureLimits {
  static constexpr std::size_t mebibyte = 1024 * 1024;
  static constexpr std::size_t maximum_exchange_bytes = 64 * mebibyte;
  static constexpr std::size_t maximum_total_bytes = 1024 * mebibyte;
  static constexpr auto maximum_join_timeout = std::chrono::hours{1};

  std::size_t part_bytes = 16 * mebibyte;
  std::size_t exchange_bytes = 32 * mebibyte;
  std::size_t total_bytes = 128 * mebibyte;
  std::chrono::milliseconds join_timeout{std::chrono::minutes{15}};
  bool enabled = false;

  bool valid() const noexcept {
    return part_bytes != 0 && exchange_bytes >= 2 && total_bytes != 0 && part_bytes <= exchange_bytes && exchange_bytes <= total_bytes && exchange_bytes <= maximum_exchange_bytes && total_bytes <= maximum_total_bytes && join_timeout.count() > 0 && join_timeout <= maximum_join_timeout;
  }
};

}
