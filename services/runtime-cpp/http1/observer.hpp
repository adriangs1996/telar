#pragma once

#include <concepts>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::runtime {

enum class Http1Line {
  chunk_size,
  trailer
};

template <typename Observer>
concept Http1Observer = requires(Observer &observer, std::string_view head, std::span<const std::uint8_t> payload, Http1Line line) {
  { observer.headStarted() } noexcept -> std::same_as<void>;
  { observer.head(head) } noexcept -> std::same_as<void>;
  { observer.payload(payload) } noexcept -> std::same_as<void>;
  { observer.lineTooLong(line) } noexcept -> std::same_as<void>;
};

}
