#pragma once

#include "kitty_framing.hpp"
#include <array>
#include <string_view>

namespace telar::runtime {

struct KittyCommandView {
  std::size_t end;
  std::string_view control;
  std::string_view payload_prefix;
  bool truncated;
};

class KittyCommandScanner {
public:
  bool canSkip(std::span<const std::uint8_t> bytes) const noexcept {
    return framing_.canSkip(bytes);
  }

  bool canSkipCsi(std::span<const std::uint8_t> bytes) const noexcept {
    return framing_.canSkipCsi(bytes);
  }

  std::optional<KittyCommandView> next(std::span<const std::uint8_t> bytes) noexcept {
    std::size_t position = 0;
    for (;;) {
      const auto start = position;
      const bool inside = framing_.inside();
      const auto transition = framing_.advance(bytes, position);
      if (!transition) {
        if (inside) {
          capture(bytes.subspan(start));
        }
        return std::nullopt;
      }
      if (*transition == KittyFraming::Transition::started) {
        control_length_ = 0;
        payload_length_ = 0;
        in_payload_ = false;
        truncated_ = false;
      } else {
        capture(bytes.subspan(start, position - start - 1));
        return KittyCommandView{position, {control_.data(), control_length_}, {payload_.data(), payload_length_}, truncated_};
      }
    }
  }

private:
  void capture(std::span<const std::uint8_t> bytes) noexcept {
    for (const auto byte : bytes) {
      if (!KittyFraming::content(byte)) {
        continue;
      }
      if (!in_payload_) {
        if (byte == ';') {
          in_payload_ = true;
        } else if (control_length_ < control_.size()) {
          control_[control_length_++] = static_cast<char>(byte);
        } else {
          truncated_ = true;
        }
      } else if (payload_length_ < payload_.size()) {
        payload_[payload_length_++] = static_cast<char>(byte);
      } else {
        return;
      }
    }
  }

  KittyFraming framing_;
  std::array<char, 256> control_;
  std::array<char, 64> payload_;
  std::size_t control_length_ = 0;
  std::size_t payload_length_ = 0;
  bool in_payload_ = false;
  bool truncated_ = false;
};

}
