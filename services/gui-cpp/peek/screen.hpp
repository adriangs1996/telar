#pragma once

#include "core/memory.hpp"
#include "limits.hpp"
#include "target.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <Allocator Memory>
class PeekScreen {
public:
  explicit PeekScreen(Memory &memory)
      : text_(AllocatorRef<char, Memory>{memory}) {}

  void show(PeekTarget target) noexcept {
    target_ = target;
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  void close() noexcept {
    target_.reset();
    text_.clear();
    request_id_ = 0;
    ++revision_;
  }

  [[nodiscard]] const auto &target() const noexcept {
    return target_;
  }

  [[nodiscard]] std::string_view text() const noexcept {
    return text_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] bool reading() const noexcept {
    return request_id_ != 0;
  }

  [[nodiscard]] bool owns(std::uint64_t request) const noexcept {
    return request != 0 && request_id_ == request;
  }

  [[nodiscard]] std::optional<ReadPane> request(std::uint64_t identity) {
    if (!target_ || reading()) {
      return std::nullopt;
    }

    if (identity == 0) {
      throw std::invalid_argument{"InvalidPeekRequest"};
    }

    request_id_ = identity;

    return ReadPane{.request_id = identity, .pane_id = target_->agent.pane_id, .pane_generation = target_->agent.pane_generation, .rows = PeekLimits::rows, .source = PaneTextSource::recent};
  }

  bool fail(std::uint64_t identity) noexcept {
    if (!owns(identity)) {
      return false;
    }

    request_id_ = 0;

    return true;
  }

  [[nodiscard]] std::optional<std::size_t> store(const PaneText &reply) {
    if (!owns(reply.request_id)) {
      return std::nullopt;
    }

    request_id_ = 0;
    if (!target_ || target_->agent.pane_id != reply.pane_id) {
      return std::nullopt;
    }

    auto start = reply.text.size() - std::min(reply.text.size(), PeekLimits::text_bytes);
    constexpr unsigned char continuation_mask = 0xc0;
    constexpr unsigned char continuation_bits = 0x80;
    while (start > 0 && start < reply.text.size() && (static_cast<unsigned char>(reply.text[start]) & continuation_mask) == continuation_bits) {
      ++start;
    }

    text_ = reply.text.substr(start);
    ++revision_;

    return start;
  }

  [[nodiscard]] static std::string_view lastLines(std::string_view text, std::uint16_t count) noexcept {
    const auto last = text.find_last_not_of(" \n\r\t");
    if (last == std::string_view::npos) {
      return {};
    }

    text.remove_suffix(text.size() - last - 1);
    auto start = text.size();
    std::uint16_t seen = 0;
    while (start > 0 && seen < count) {
      --start;
      if (text[start] == '\n') {
        ++seen;
        if (seen == count) {
          ++start;
          break;
        }
      }
    }

    text.remove_prefix(start);

    return text;
  }

private:
  String<Memory> text_;
  std::optional<PeekTarget> target_;
  std::uint64_t request_id_ = 0;
  std::uint64_t revision_ = 0;
};

}
