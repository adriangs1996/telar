#pragma once

#include "description_capture.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <chrono>

namespace telar::runtime {

enum class DescriptionPhase {
  waiting_query,
  waiting_work,
  queued,
  running,
  finished,
  failed
};

enum class DescriptionStatus {
  success,
  unavailable,
  timeout,
  invalid_output,
  failed
};

struct DescriptionOptions {
  std::span<const std::string_view> arguments;
  std::chrono::milliseconds timeout{15'000};
};

struct DescriptionIdentity {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  std::array<Byte, 16> session{};
  std::uint64_t revision = 0;

  bool operator==(const DescriptionIdentity &) const = default;
};

struct DescriptionRequest {
  DescriptionIdentity identity;
  DescriptionQuery query{};
};

struct DescriptionResult {
  DescriptionIdentity identity;
  DescriptionStatus status = DescriptionStatus::failed;
  FixedText<96> title{};
};

inline FixedText<96> normalizeDescriptionTitle(std::string_view output) {
  constexpr std::string_view whitespace = " \t\r\n";
  const auto first = output.find_first_not_of(whitespace);
  if (first == std::string_view::npos) {
    throw EncodingError{"Empty generated title"};
  }

  output = output.substr(first, output.find_last_not_of(whitespace) - first + 1);
  if (output.size() >= 2 && (output.front() == '"' || output.front() == '\'') && output.back() == output.front()) {
    output.remove_prefix(1);
    output.remove_suffix(1);
    const auto first_character = output.find_first_not_of(" \t");
    output = first_character == std::string_view::npos ? std::string_view{} : output.substr(first_character, output.find_last_not_of(" \t") - first_character + 1);
  }

  if (output.empty() || output.size() > 96 || std::ranges::any_of(output, [](unsigned char byte) { return byte < 0x20 || byte == 0x7f; })) {
    throw EncodingError{"Invalid generated title"};
  }

  validateUtf8(output);
  FixedText<96> title;
  title.assign(output);
  return title;
}

}
