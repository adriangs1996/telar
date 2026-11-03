#pragma once

#include "machines/connection_policy.hpp"
#include "machines/failure.hpp"
#include "machines/machine_row.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "text/bounded_text.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace telar::gui {

struct RuntimeLink {
  static constexpr std::size_t failure_bytes = 256;
  static constexpr std::size_t target_bytes = 255;
  static constexpr std::size_t headline_bytes = 320;
  static constexpr int first_retry_ms = 500;
  static constexpr int longest_retry_ms = 30000;
  static constexpr unsigned maximum_backoff_doublings = 16;
  static constexpr auto healthy_after_ns = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::seconds{60}).count());
  using Headline = BoundedText<headline_bytes>;

  MachinePhase phase = MachinePhase::connecting;
  std::uint16_t attempt = 0;
  std::uint32_t sessions = 0;
  bool setup_repairs = false;
  std::uint64_t connected_at_ns = 0;
  BoundedText<failure_bytes> failure_storage;
  BoundedText<target_bytes> target_storage;

  void name(std::string_view text) {
    target_storage.truncate(0);
    target_storage.append(validPrefix(text, target_bytes));
  }

  [[nodiscard]] std::string_view target() const noexcept {
    return target_storage.view();
  }

  void fail(std::string_view text) {
    failure_storage.truncate(0);
    const auto first = text.find_first_not_of(" \t\r\n");
    if (first == std::string_view::npos) {
      return;
    }

    const auto last = text.find_last_not_of(" \t\r\n");
    const auto kept = validPrefix(text.substr(first, last - first + 1), failure_bytes);
    std::array<char, failure_bytes> cleaned{};
    for (std::size_t index = 0; index < kept.size(); ++index) {
      const auto byte = static_cast<unsigned char>(kept[index]);
      cleaned[index] = byte < static_cast<unsigned char>(' ') || byte == static_cast<unsigned char>(ControlByte::delete_character) ? ' ' : kept[index];
    }

    failure_storage.append({cleaned.data(), kept.size()});
  }

  [[nodiscard]] std::optional<std::string_view> failure() const noexcept {
    return failure_storage.view().empty() ? std::nullopt : std::optional{failure_storage.view()};
  }

  void clearFailure() noexcept {
    failure_storage = {};
    setup_repairs = false;
  }

  void start(std::string_view text) {
    name(text);
    phase = MachinePhase::connecting;
    clearFailure();
  }

  void adopt(std::uint64_t now_ns) {
    connected_at_ns = now_ns;
    phase = MachinePhase::connected;
    if (sessions != std::numeric_limits<std::uint32_t>::max()) {
      ++sessions;
    }

    clearFailure();
  }

  void lose(std::string_view text, std::uint64_t now_ns) {
    if (phase != MachinePhase::connected) {
      return;
    }

    if (now_ns >= connected_at_ns && now_ns - connected_at_ns >= healthy_after_ns) {
      attempt = 0;
    }

    fail(text);
    setup_repairs = false;
    phase = MachinePhase::lost;
  }

  void connectionFailed(MachineError error, std::string_view text) {
    fail(text);
    setup_repairs = MachineConnectionPolicy::setupRepairs(error);
    phase = MachineConnectionPolicy::permanent(error) ? MachinePhase::failed : MachinePhase::lost;
  }

  bool retry() {
    if (phase != MachinePhase::lost) {
      return false;
    }

    phase = MachinePhase::connecting;
    if (attempt != std::numeric_limits<std::uint16_t>::max()) {
      ++attempt;
    }

    return true;
  }

  bool retryNow() {
    if (phase != MachinePhase::lost && phase != MachinePhase::failed) {
      return false;
    }

    phase = MachinePhase::connecting;
    attempt = 0;

    return true;
  }

  void stop() noexcept {
    phase = MachinePhase::stopped;
    clearFailure();
  }

  [[nodiscard]] int retryDelayMilliseconds() const noexcept {
    const auto shift = std::min(static_cast<unsigned>(attempt), maximum_backoff_doublings);
    return static_cast<int>(std::min(std::uint64_t{first_retry_ms} << shift, std::uint64_t{longest_retry_ms}));
  }

  [[nodiscard]] Headline headline() const {
    switch (phase) {
    case MachinePhase::connected:
      return {};
    case MachinePhase::connecting:
      if (sessions == 0 && attempt == 0) {
        return assemble({.prefix = "Connecting to ", .suffix = "…", .fallback = "Connecting…"});
      }

      {
        auto result = assemble({.prefix = "Reconnecting to ", .suffix = "", .fallback = "Reconnecting…"});
        result.append(" (attempt ");
        result.appendDecimal(static_cast<std::uint32_t>(attempt) + 1);
        result.append(")…");

        return result;
      }
    case MachinePhase::lost:
      return assemble({.prefix = "", .suffix = " is unreachable; trying again shortly", .fallback = "The runtime is unreachable"});
    case MachinePhase::failed:
      return setup_repairs ? assemble({.prefix = "", .suffix = " lacks this telar build; choose it in the machine list to set it up", .fallback = "This machine lacks this telar build"}) : assemble({.prefix = "Cannot connect to ", .suffix = "; retry it from the machine list", .fallback = "Cannot connect to the runtime"});
    case MachinePhase::stopped:
      return assemble({.prefix = "", .suffix = " is disabled", .fallback = "The machine is disabled"});
    }

    return {};
  }

private:
  enum class ControlByte : unsigned char {
    delete_character = 0x7f,
  };

  [[nodiscard]] static std::string_view validPrefix(std::string_view text, std::size_t capacity) noexcept {
    const auto prefix = runtime::utf8Prefix(text, capacity);

    return inspectUtf8(prefix) == Utf8Validation::valid ? prefix : std::string_view{};
  }

  struct Label {
    std::string_view prefix;
    std::string_view suffix;
    std::string_view fallback;
  };

  [[nodiscard]] Headline assemble(Label label) const {
    Headline result;
    if (label.prefix.size() + target().size() + label.suffix.size() > headline_bytes) {
      result.append(label.fallback);
    } else {
      result.append(label.prefix);
      result.append(target());
      result.append(label.suffix);
    }

    return result;
  }
};

}
