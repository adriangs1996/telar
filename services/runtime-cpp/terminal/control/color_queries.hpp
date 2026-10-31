#pragma once

#include "classification.hpp"
#include "color_value.hpp"
#include "policy.hpp"
#include "reply.hpp"
#include "vt_state.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <charconv>
#include <limits>

namespace telar::runtime::control {

// All references belong to the enclosing nonmovable controller. Sequence and
// setter views are borrowed only for this synchronous call.
template <Allocator Memory>
class ColorQueries {
public:
  void discard() noexcept {
    palette_active_ = false;
    palette_publishing_ = false;
    palette_offset_ = 0;
  }

  explicit ColorQueries(VtState &state, Reply<Memory> &reply, const Policy &policy)
      : state_(state), reply_(reply), policy_(policy) {}

  bool handle(Sequence sequence, bool enabled) {
    enabled_ = enabled;
    auto remaining = sequence.body();
    const auto operation = oscOperation(takeField(remaining));
    if (!operation) {
      return false;
    }

    if (*operation == 21) {
      kittyColors(remaining, sequence.terminator());
      return true;
    }
    if (*operation >= 10 && *operation <= 19) {
      for (unsigned selector = *operation; selector <= 19 && !remaining.empty(); ++selector) {
        const auto value = takeField(remaining);
        if (value == "?") {
          if (selector <= 12) {
            traditionalColor(selector, std::nullopt, sequence.terminator());
          }
        } else {
          forwardOsc(selector, value);
        }
      }
      return true;
    }
    return false;
  }

  // The parser retains the input while blocked. Only offsets survive a call;
  // no borrowed input or state is retained across queue retries.
  template <typename Sink>
  bool palette(Sequence sequence, bool enabled, Sink &queue) {
    enabled_ = enabled;
    auto body = sequence.body();
    const auto operation = oscOperation(takeField(body));
    if (!palette_active_) {
      palette_active_ = true;
      palette_offset_ = 0;
      reply_.clear();
    }
    while (true) {
      if (palette_publishing_) {
        if (!reply_.publish(queue)) {
          return false;
        }
        reply_.clear();
        palette_publishing_ = false;
      }
      auto remaining = body.substr(palette_offset_);
      if (remaining.empty()) {
        palette_active_ = false;
        return true;
      }
      while (!remaining.empty()) {
        const auto index_field = takeField(remaining);
        const auto index = decimal(index_field);
        const auto value = takeField(remaining);
        palette_offset_ = body.size() - remaining.size();
        if (index && *index < 256 && !value.empty()) {
          if (value == "?") {
            if (*operation == 4) {
              traditionalColor(4, *index, sequence.terminator());
            }
          } else {
            queue.release();
            const auto count = static_cast<std::size_t>(value.data() + value.size() - index_field.data());
            forwardOsc(*operation, {index_field.data(), count});
          }
        }
        if (reply_.size() > PtyResponseQueue::message_byte_capacity - maximum_color_reply) {
          break;
        }
      }
      palette_publishing_ = true;
    }
  }

private:
  static constexpr std::size_t maximum_color_reply = 64;
  static constexpr std::size_t inline_osc_bytes = 64;

  void forwardOsc(unsigned operation, std::string_view payload) {
    constexpr std::string_view introducer = "\x1b]";
    constexpr std::string_view terminator = "\x1b\\";
    static_assert(introducer.size() + std::numeric_limits<unsigned>::digits10 + 2 + terminator.size() <= inline_osc_bytes);
    std::array<char, inline_osc_bytes> packet;
    auto *position = std::copy(introducer.begin(), introducer.end(), packet.data());
    const auto number = std::to_chars(position, packet.data() + packet.size() - 1, operation);
    assert(number.ec == std::errc{});
    *number.ptr = ';';
    position = number.ptr + 1;
    const auto header_size = static_cast<std::size_t>(position - packet.data());

    if (payload.size() <= packet.size() - header_size - terminator.size()) {
      if (!payload.empty()) {
        std::memcpy(position, payload.data(), payload.size());
        position += payload.size();
      }
      position = std::copy(terminator.begin(), terminator.end(), position);
      state_.write({reinterpret_cast<const std::uint8_t *>(packet.data()), static_cast<std::size_t>(position - packet.data())});
      return;
    }

    state_.write({reinterpret_cast<const std::uint8_t *>(packet.data()), header_size});
    state_.write({reinterpret_cast<const std::uint8_t *>(payload.data()), payload.size()});
    state_.write({reinterpret_cast<const std::uint8_t *>(terminator.data()), terminator.size()});
  }

  void kittyColorItem(unsigned selector, std::string_view key) {
    // Supported keys are at most ten bytes (numeric selectors use <=3).
    // The longest complete item is 24 bytes, including a present RGB value.
    static_assert(std::string_view{";foreground=rgb:00/00/00"}.size() <= maximum_color_reply);
    std::array<char, maximum_color_reply> encoded;
    auto *position = encoded.data();
    *position++ = ';';
    if (selector < VtState::foreground) {
      const auto number = std::to_chars(position, encoded.data() + encoded.size(), selector);
      assert(number.ec == std::errc{});
      position = number.ptr;
    } else {
      position = std::copy(key.begin(), key.end(), position);
    }
    *position++ = '=';

    if (const auto color = state_.color(selector)) {
      position = std::copy_n("rgb:", 4, position);
      constexpr std::string_view digits = "0123456789abcdef";
      const std::array components{color->r, color->g, color->b};
      for (std::size_t index = 0; index < components.size(); ++index) {
        if (index != 0) {
          *position++ = '/';
        }
        *position++ = digits[components[index] >> 4];
        *position++ = digits[components[index] & 0x0f];
      }
    }

    reply_.append({encoded.data(), static_cast<std::size_t>(position - encoded.data())});
  }

  void traditionalColor(unsigned operation, std::optional<unsigned> index, std::string_view terminator) {
    if (!enabled_ || policy_.color_format == ColorFormat::none) {
      return;
    }

    const auto selector = index.value_or(VtState::foreground + operation - 10);
    auto color = state_.color(selector);
    if (!color && operation == 12) {
      color = state_.color(VtState::foreground);
    }
    if (!color) {
      return;
    }

    std::array<char, maximum_color_reply> encoded;
    auto *position = std::copy_n("\x1b]", 2, encoded.data());
    const auto number = [&](unsigned value) {
      const auto formatted = std::to_chars(position, encoded.data() + encoded.size(), value);
      assert(formatted.ec == std::errc{});
      position = formatted.ptr;
    };
    number(operation);
    *position++ = ';';
    if (index) {
      number(*index);
      *position++ = ';';
    }
    position = std::copy_n("rgb:", 4, position);
    constexpr std::string_view digits = "0123456789abcdef";
    const std::array components{color->r, color->g, color->b};
    const bool sixteen_bit = policy_.color_format == ColorFormat::sixteen_bit;
    for (std::size_t component = 0; component < components.size(); ++component) {
      if (component != 0) {
        *position++ = '/';
      }
      const auto high = digits[components[component] >> 4];
      const auto low = digits[components[component] & 0x0f];
      *position++ = high;
      *position++ = low;
      if (sixteen_bit) {
        *position++ = high;
        *position++ = low;
      }
    }
    position = std::copy(terminator.begin(), terminator.end(), position);
    reply_.append({encoded.data(), static_cast<std::size_t>(position - encoded.data())});
  }

  static std::optional<unsigned> colorKey(std::string_view key) noexcept {
    if (key == "foreground") {
      return VtState::foreground;
    }
    if (key == "background") {
      return VtState::background;
    }
    if (key == "cursor") {
      return VtState::cursor_color;
    }

    const auto index = decimal(key);
    return index && *index < 256 ? index : std::nullopt;
  }

  // The frozen application bounds the complete transaction at 526 items.
  static constexpr unsigned maximum_keys = 526;
  static constexpr std::array unsupported_colors{"selection_foreground", "selection_background", "cursor_text", "visual_bell", "second_transparent_background"};

  static bool validKittyColors(std::string_view remaining) noexcept {
    if (std::count(remaining.begin(), remaining.end(), ';') < maximum_keys) {
      return true;
    }
    unsigned keys = 0;
    while (true) {
      if (keys == maximum_keys) {
        return false;
      }
      const bool had_separator = remaining.find(';') != std::string_view::npos;
      const auto pair = takeField(remaining);
      const auto equal = pair.find('=');
      const auto key = pair.substr(0, equal);
      auto value = equal == std::string_view::npos ? std::string_view{} : pair.substr(equal + 1);
      const auto first = value.find_first_not_of(' ');
      value = first == std::string_view::npos ? std::string_view{} : value.substr(first, value.find_last_not_of(' ') - first + 1);
      const bool known = colorKey(key).has_value() || std::find(unsupported_colors.begin(), unsupported_colors.end(), key) != unsupported_colors.end();
      if (known && (value.empty() || value == "?" || colorValue(value))) {
        ++keys;
      }
      if (remaining.empty()) {
        return keys != maximum_keys || !had_separator;
      }
    }
  }

  void kittyColors(std::string_view remaining, std::string_view terminator) {
    constexpr std::size_t maximum_kitty_color_bytes = 2048;
    if (remaining.size() > maximum_kitty_color_bytes || !validKittyColors(remaining)) {
      return;
    }
    while (!remaining.empty()) {
      const auto pair = takeField(remaining);
      const auto separator = pair.find('=');
      const auto key = pair.substr(0, separator);
      auto value = separator == std::string_view::npos ? std::string_view{} : pair.substr(separator + 1);
      while (!value.empty() && value.front() == ' ') {
        value.remove_prefix(1);
      }
      while (!value.empty() && value.back() == ' ') {
        value.remove_suffix(1);
      }

      const auto selector = colorKey(key);
      if (!selector) {
        if (enabled_ && value == "?" && std::find(unsupported_colors.begin(), unsupported_colors.end(), key) != unsupported_colors.end() && reply_.size() == 0) {
          reply_.append("\x1b]21");
        }
        continue;
      }
      if (value != "?") {
        forwardOsc(21, pair);
        continue;
      }
      if (!enabled_) {
        continue;
      }

      if (reply_.size() == 0) {
        reply_.append("\x1b]21");
      }
      kittyColorItem(*selector, key);
    }

    if (reply_.size() != 0) {
      reply_.append(terminator);
    }
  }

  VtState &state_;
  Reply<Memory> &reply_;
  const Policy &policy_;
  bool enabled_ = false;
  bool palette_active_ = false;
  bool palette_publishing_ = false;
  std::size_t palette_offset_ = 0;
};

}
