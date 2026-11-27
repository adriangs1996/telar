module;
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.terminal.control:color_queries;

import std;
import telar.base.memory.allocators;
import telar.config.runtime;
import :classification;
import :color_value;
import :parameters;
import :pty_response_queue;
import :reply;
import :sequence;
import :vt_state;
import telar.base.text;
import telar.base.ds;

export namespace telar::runtime::control {

  // The engine lends its state and reply to each call. Sequence and setter
  // views are borrowed only for this synchronous call.
  // Generic over the caller's allocator and response sink, so it stays here.
  template <Allocator Memory>
  class [[tbc::generic]] ColorQueries {
  public:
    // The engine state a query reads and the reply it writes, lent to each call.
    struct Context {
      VtState& state;
      Reply<Memory>& reply;
      const Policy& policy;
    };

    void discard() noexcept {
      palette_active_ = false;
      palette_publishing_ = false;
      palette_offset_ = 0;
    }

    bool handle(Context context, Sequence sequence, bool enabled) {
      enabled_ = enabled;
      auto remaining = sequence.body();
      const auto operation = oscOperation(takeField(remaining));
      if (!operation) {
        return false;
      }

      if (*operation == kitty_colors_operation) {
        kittyColors(context, remaining, sequence);
        return true;
      }

      if (*operation >= first_dynamic_color && *operation <= last_dynamic_color) {
        dynamicColors(context, *operation, remaining, sequence);
        return true;
      }

      return false;
    }

    // The parser retains the input while blocked. Only offsets survive a call;
    // no borrowed input or state is retained across queue retries.
    template <typename Sink>
    bool palette(Context context, Sequence sequence, bool enabled, Sink& queue) {
      enabled_ = enabled;
      auto body = sequence.body();
      const auto operation = oscOperation(takeField(body));

      if (!palette_active_) {
        palette_active_ = true;
        palette_offset_ = 0;
        context.reply.clear();
      }

      while (true) {
        if (palette_publishing_) {
          if (!context.reply.publish(queue)) {
            return false;
          }

          context.reply.clear();
          palette_publishing_ = false;
        }

        auto remaining = body.substr(palette_offset_);
        if (remaining.empty()) {
          palette_active_ = false;
          return true;
        }

        while (!remaining.empty()) {
          const auto index = takeField(remaining);
          const auto value = takeField(remaining);

          palette_offset_ = body.size() - remaining.size();
          paletteItem(context, {.operation = *operation, .index = index, .value = value, .terminator = sequence.terminator()}, queue);
          if (context.reply.size() > PtyResponseQueue::message_byte_capacity - maximum_color_reply) {
            break;
          }
        }

        palette_publishing_ = true;
      }
    }

  private:
    // The OSC operations this class answers or forwards.
    static constexpr unsigned palette_operation = 4;
    static constexpr unsigned first_dynamic_color = 10;
    static constexpr unsigned cursor_color_operation = 12;
    static constexpr unsigned last_dynamic_color = 19;
    static constexpr unsigned kitty_colors_operation = 21;
    static constexpr std::size_t maximum_color_reply = 64;
    static constexpr std::size_t inline_osc_bytes = 64;
    static constexpr std::string_view hexadecimal_digits = "0123456789abcdef";
    static constexpr std::uint8_t low_nibble = 0x0f;

    // One index=value pair of an OSC 4 palette sequence.
    struct PaletteItem {
      unsigned operation = 0;
      std::string_view index;
      std::string_view value;
      std::string_view terminator;
    };

    // OSC 10 to 19 each set or query one dynamic color, from `first` on; ghostty answers only the
    // queries up to the cursor color.
    void dynamicColors(Context context, unsigned first, std::string_view remaining, Sequence sequence) {
      for (unsigned selector = first; selector <= last_dynamic_color && !remaining.empty(); ++selector) {
        const auto value = takeField(remaining);
        if (value == "?") {
          if (selector <= cursor_color_operation) {
            traditionalColor(context, selector, ds::none, sequence.terminator());
          }
        } else {
          forwardOsc(context, selector, value);
        }
      }
    }

    // A query is answered in the reply; a color set is forwarded once the queue no longer holds
    // the parser's input.
    template <typename Sink>
    void paletteItem(Context context, PaletteItem item, Sink& queue) {
      const auto index = decimal(item.index);
      if (!index || *index >= VtState::palette_colors || item.value.empty()) {
        return;
      }

      if (item.value == "?") {
        if (item.operation == palette_operation) {
          traditionalColor(context, palette_operation, *index, item.terminator);
        }

        return;
      }

      queue.release();
      const auto count = static_cast<std::size_t>(std::to_address(item.value.end()) - item.index.data());

      forwardOsc(context, item.operation, {item.index.data(), count});
    }

    void forwardOsc(Context context, unsigned operation, std::string_view payload) {
      constexpr std::string_view introducer = "\x1b]";
      constexpr std::string_view terminator = "\x1b\\";
      static_assert(introducer.size() + std::numeric_limits<unsigned>::digits10 + 2 + terminator.size() <= inline_osc_bytes);
      ds::Array<char, inline_osc_bytes> packet{};
      const auto output = packet.viewMut();

      std::ranges::copy(introducer, output.begin());
      const auto digits = output.subspan(introducer.size()).first(output.size() - introducer.size() - 1);
      const auto number = std::to_chars(digits.data(), std::to_address(digits.end()), operation);

      // to_chars reports success as the errc of value 0, which names no error.
      TELAR_ASSERT(std::to_underlying(number.ec) == 0);
      auto header_size = static_cast<std::size_t>(number.ptr - output.data());

      output[header_size++] = ';';
      if (payload.size() <= output.size() - header_size - terminator.size()) {
        const auto rest = output.subspan(header_size);

        std::ranges::copy(payload, rest.begin());
        std::ranges::copy(terminator, rest.subspan(payload.size()).begin());
        context.state.write(byteView(std::string_view{std::span<const char>{output}.first(header_size + payload.size() + terminator.size())}));
        return;
      }

      context.state.write(byteView(std::string_view{std::span<const char>{output}.first(header_size)}));
      context.state.write(byteView(payload));
      context.state.write(byteView(terminator));
    }

    void kittyColorItem(Context context, unsigned selector, std::string_view key) {
      // Supported keys are at most ten bytes (numeric selectors use <=3).
      // The longest complete item is 24 bytes, including a present RGB value.
      constexpr std::size_t longest_item = std::string_view{";foreground=rgb:00/00/00"}.size();
      static_assert(longest_item <= maximum_color_reply);
      ds::Array<char, maximum_color_reply> encoded{};
      // One mutable borrow of the buffer, which `position` walks.
      const std::span<char> output{encoded.dataMut(), encoded.size()};
      auto* position = output.data();

      *position++ = ';';
      if (selector < VtState::foreground) {
        const auto number = std::to_chars(position, output.data() + output.size(), selector);

        // to_chars reports success as the errc of value 0, which names no error.
        TELAR_ASSERT(std::to_underlying(number.ec) == 0);
        position = number.ptr;
      } else {
        position = std::ranges::copy(key, position).out;
      }

      *position++ = '=';

      if (const auto color = context.state.color(selector)) {
        position = std::copy_n("rgb:", 4, position);
        const ds::Array components{color->r, color->g, color->b};

        for (std::size_t index = 0; index < components.size(); ++index) {
          if (index != 0) {
            *position++ = '/';
          }

          *position++ = hexadecimal_digits[components[index] >> 4];
          *position++ = hexadecimal_digits[components[index] & low_nibble];
        }
      }

      context.reply.append({output.data(), static_cast<std::size_t>(position - output.data())});
    }

    void traditionalColor(Context context, unsigned operation, ds::Option<unsigned> index, std::string_view terminator) {
      if (!enabled_ || context.policy.color_format == ColorFormat::none) {
        return;
      }

      const auto selector = index.valueOr(VtState::foreground + operation - first_dynamic_color);
      auto color = context.state.color(selector);
      if (!color && operation == cursor_color_operation) {
        color = context.state.color(VtState::foreground);
      }

      if (!color) {
        return;
      }

      ds::Array<char, maximum_color_reply> encoded{};
      // One mutable borrow of the buffer, which `position` walks.
      const std::span<char> output{encoded.dataMut(), encoded.size()};
      auto* position = std::copy_n("\x1b]", 2, output.data());
      const auto number = [&](unsigned value) {
        const auto formatted = std::to_chars(position, output.data() + output.size(), value);

        // to_chars reports success as the errc of value 0, which names no error.
        TELAR_ASSERT(std::to_underlying(formatted.ec) == 0);
        position = formatted.ptr;
      };

      number(operation);
      *position++ = ';';
      if (index) {
        number(*index);
        *position++ = ';';
      }

      position = std::copy_n("rgb:", 4, position);
      const ds::Array components{color->r, color->g, color->b};
      const bool sixteen_bit = context.policy.color_format == ColorFormat::sixteen_bit;

      for (std::size_t component = 0; component < components.size(); ++component) {
        if (component != 0) {
          *position++ = '/';
        }

        const auto high = hexadecimal_digits[components[component] >> 4];
        const auto low = hexadecimal_digits[components[component] & low_nibble];

        *position++ = high;
        *position++ = low;
        if (sixteen_bit) {
          *position++ = high;
          *position++ = low;
        }
      }

      position = std::ranges::copy(terminator, position).out;
      context.reply.append({output.data(), static_cast<std::size_t>(position - output.data())});
    }

    static ds::Option<unsigned> colorKey(std::string_view key) noexcept {
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

      return index && *index < VtState::palette_colors ? index : ds::none;
    }

    // The frozen application bounds the complete transaction at 526 items.
    static constexpr unsigned maximum_keys = 526;
    static constexpr ds::Array unsupported_colors{"selection_foreground", "selection_background", "cursor_text", "visual_bell", "second_transparent_background"};

    static bool validKittyColors(std::string_view remaining) noexcept {
      if (std::count(remaining.begin(), remaining.end(), ';') < maximum_keys) {
        return true;
      }

      unsigned keys = 0;

      while (true) {
        if (keys == maximum_keys) {
          return false;
        }

        const bool had_separator = remaining.contains(';');
        const auto pair = takeField(remaining);
        const auto equal = pair.find('=');
        const auto key = textPrefix(pair, equal);
        auto value = equal == std::string_view::npos ? std::string_view{} : textAfter(pair, equal + 1);
        const auto first = value.find_first_not_of(' ');

        value = first == std::string_view::npos ? std::string_view{} : textPrefix(textAfter(value, first), value.find_last_not_of(' ') - first + 1);
        const bool known = colorKey(key).hasValue() || std::ranges::find(unsupported_colors, key) != unsupported_colors.end();
        if (known && (value.empty() || value == "?" || colorValue(value))) {
          ++keys;
        }

        if (remaining.empty()) {
          return keys != maximum_keys || !had_separator;
        }
      }
    }

    void kittyColors(Context context, std::string_view remaining, Sequence sequence) {
      constexpr std::size_t maximum_kitty_color_bytes = 2048;
      if (remaining.size() > maximum_kitty_color_bytes || !validKittyColors(remaining)) {
        return;
      }

      while (!remaining.empty()) {
        const auto pair = takeField(remaining);
        const auto separator = pair.find('=');
        const auto key = textPrefix(pair, separator);
        auto value = separator == std::string_view::npos ? std::string_view{} : textAfter(pair, separator + 1);

        while (!value.empty() && value.front() == ' ') {
          value.remove_prefix(1);
        }

        while (!value.empty() && value.back() == ' ') {
          value.remove_suffix(1);
        }

        const auto selector = colorKey(key);
        if (!selector) {
          if (enabled_ && value == "?" && std::ranges::find(unsupported_colors, key) != unsupported_colors.end() && context.reply.size() == 0) {
            context.reply.append("\x1b]21");
          }

          continue;
        }

        if (value != "?") {
          forwardOsc(context, kitty_colors_operation, pair);
          continue;
        }

        if (!enabled_) {
          continue;
        }

        if (context.reply.size() == 0) {
          context.reply.append("\x1b]21");
        }

        kittyColorItem(context, *selector, key);
      }

      if (context.reply.size() != 0) {
        context.reply.append(sequence.terminator());
      }
    }

    bool enabled_ = false;
    bool palette_active_ = false;
    bool palette_publishing_ = false;
    std::size_t palette_offset_ = 0;
  };

}
