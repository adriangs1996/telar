#pragma once

#include "telar_client/codecs/telar_wire.hpp"

namespace telar::runtime::plugins {

template <typename Output>
concept FrameOutput = requires(Output &output, std::span<const Byte> bytes, std::string_view text) {
  { output.integer(std::uint64_t{}) } -> std::same_as<void>;
  { output.integer(std::uint32_t{}) } -> std::same_as<void>;
  { output.integer(std::uint16_t{}) } -> std::same_as<void>;
  { output.integer(Byte{}) } -> std::same_as<void>;
  { output.tag(std::byte{}) } -> std::same_as<void>;
  { output.timestamp(std::int64_t{}) } -> std::same_as<void>;
  { output.boolean(false) } -> std::same_as<void>;
  { output.bytes(bytes) } -> std::same_as<void>;
  { output.text(text) } -> std::same_as<void>;
};

}
