#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>

namespace telar::runtime::plugins {

struct Limits {
  static constexpr std::size_t workers = 16;
  static constexpr std::size_t queue_depth = 64;
  static constexpr std::size_t effects = 16;
  static constexpr std::size_t effect_bytes = 64 * 1024;
  static constexpr std::size_t frame_overhead = 64 * 1024;
  static constexpr std::size_t frame_bytes = 128 * 1024 * 1024;
  static constexpr std::size_t held_bytes = 128 * 1024 * 1024;
  static constexpr std::size_t entry_bytes = 1024 * 1024;
  static constexpr std::size_t error_bytes = 4096;
  static constexpr std::size_t stderr_bytes = 4096;
  static constexpr std::size_t restarts = 5;
  static constexpr auto restart_window = std::chrono::minutes{10};
  static constexpr auto callback_deadline = std::chrono::seconds{2};
  static constexpr auto reply_deadline = std::chrono::seconds{3};
  static constexpr auto trust_check_interval = std::chrono::milliseconds{250};
  static constexpr std::size_t lua_bytes = 64 * 1024 * 1024;
  static constexpr std::uint64_t lua_instructions = 5'000'000;
};

}
