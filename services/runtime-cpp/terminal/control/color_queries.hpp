#pragma once

#include "classification.hpp"
#include "policy.hpp"
#include "reply.hpp"
#include "vt_state.hpp"

namespace telar::runtime::control {

// All references belong to the enclosing nonmovable controller. Sequence and
// setter views are borrowed only for this synchronous call.
template <Allocator Memory>
class ColorQueries {
public:
  explicit ColorQueries(VtState &state, Reply<Memory> &reply, const Policy &policy)
      : state_(state), reply_(reply), policy_(policy) {}

  bool handle(Sequence sequence, bool enabled) {
    enabled_ = enabled;
    auto remaining = sequence.body();
    const auto operation = decimal(takeField(remaining));
    if (!operation) {
      return false;
    }

    if (*operation == 21) {
      kittyColors(remaining, sequence.terminator());
      return true;
    }
    if (*operation == 4 || *operation == 5) {
      while (!remaining.empty()) {
        const auto index_field = takeField(remaining);
        const auto index = decimal(index_field);
        const auto value = takeField(remaining);
        if (!index || *index >= 256 || value.empty()) {
          continue;
        }

        if (value == "?") {
          if (*operation == 4) {
            traditionalColor(4, *index, sequence.terminator());
          }
        } else {
          // Each value is a single token: the forwarded setter cannot contain
          // a later query or a control-string terminator.
          const auto start = index_field.data();
          const auto count = static_cast<std::size_t>(value.data() + value.size() - start);
          forwardOsc(*operation, {start, count});
        }
      }
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

private:
  void forwardOsc(unsigned operation, std::string_view payload) {
    std::array<char, 16> header;
    const auto start = std::copy_n("\x1b]", 2, header.data());
    const auto number = std::to_chars(start, header.data() + header.size() - 1, operation);
    *number.ptr = ';';
    state_.write({reinterpret_cast<const std::uint8_t *>(header.data()), static_cast<std::size_t>(number.ptr + 1 - header.data())});
    state_.write({reinterpret_cast<const std::uint8_t *>(payload.data()), payload.size()});
    constexpr std::string_view terminator = "\x1b\\";
    state_.write({reinterpret_cast<const std::uint8_t *>(terminator.data()), terminator.size()});
  }

  void rgb(GhosttyColorRgb color, bool sixteen_bit) {
    const unsigned factor = sixteen_bit ? 257 : 1;
    const unsigned width = sixteen_bit ? 4 : 2;
    reply_.append("rgb:");
    reply_.hex(color.r * factor, width);
    reply_.append("/");
    reply_.hex(color.g * factor, width);
    reply_.append("/");
    reply_.hex(color.b * factor, width);
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

    reply_.append("\x1b]");
    reply_.number(operation);
    reply_.append(";");
    if (index) {
      reply_.number(*index);
      reply_.append(";");
    }
    rgb(*color, policy_.color_format == ColorFormat::sixteen_bit);
    reply_.append(terminator);
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

  void kittyColors(std::string_view remaining, std::string_view terminator) {
    constexpr unsigned maximum_keys = (256 + 8) * 2;
    unsigned keys = 0;
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
        constexpr std::array unsupported{"selection_foreground", "selection_background", "cursor_text", "visual_bell", "second_transparent_background"};
        if (enabled_ && value == "?" && std::find(unsupported.begin(), unsupported.end(), key) != unsupported.end() && reply_.size() == 0) {
          reply_.append("\x1b]21");
        }
        continue;
      }
      if (++keys > maximum_keys) {
        reply_.clear();
        return;
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
      reply_.append(";");
      if (*selector < 256) {
        reply_.number(*selector);
      } else {
        reply_.append(key);
      }
      reply_.append("=");
      if (const auto color = state_.color(*selector)) {
        rgb(*color, false);
      }
    }

    if (reply_.size() != 0) {
      reply_.append(terminator);
    }
  }

  VtState &state_;
  Reply<Memory> &reply_;
  const Policy &policy_;
  bool enabled_ = false;
};

}
