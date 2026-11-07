module;
#include <cstdio>

#include <cmath>

#include <cstddef>
#include <cstdint>

#include <cstring>

export module telar.gui.core.json_writer;

import std;

import telar.base.text;
import telar.client.protocol;


// Interface: core/cosine.cppm
export {
namespace telar::gui {

template <typename Function>
concept Cosine = requires(float angle) {
  { Function::evaluate(angle) } noexcept -> std::same_as<float>;
};

struct StandardCosine {
  [[nodiscard]] inline static float evaluate(float angle) noexcept {
    return std::cos(angle);
  }
};

}
}

// Interface: core/cpu_history.cppm
export {
namespace telar::gui {

class CpuHistory {
public:
  static constexpr std::size_t capacity = 32;
  using Samples = std::array<std::uint8_t, capacity>;

  inline void push(std::uint8_t percent) noexcept {
    samples_[next_] = percent;
    next_ = (next_ + 1) % capacity;
    count_ = count_ < capacity ? count_ + 1 : capacity;
  }

  [[nodiscard]] inline std::span<const std::uint8_t> ordered(Samples &buffer) const noexcept {
    const auto start = (next_ + capacity - count_) % capacity;
    for (std::size_t index = 0; index < count_; ++index) {
      buffer[index] = samples_[(start + index) % capacity];
    }

    return std::span{buffer}.first(count_);
  }

private:
  Samples samples_{};
  std::size_t count_ = 0;
  std::size_t next_ = 0;
};

}
}

// Interface: core/json_writer.cppm
export {
namespace telar::gui {

class JsonWriter {
public:
  inline explicit JsonWriter(std::span<char> buffer) noexcept
      : buffer_(buffer) {}

  template <typename Consumer>
  inline void object(Consumer &&consume) {
    container(Container::object, std::forward<Consumer>(consume));
  }

  template <typename Consumer>
  inline void array(Consumer &&consume) {
    container(Container::array, std::forward<Consumer>(consume));
  }

  template <typename Value>
  inline void member(std::string_view name, const Value &value) {
    separator();
    write(name);
    append(":");
    write(value);
  }

  template <typename Value>
  inline void element(const Value &value) {
    separator();
    write(value);
  }

  [[nodiscard]] inline std::string_view view() const noexcept {
    return {buffer_.data(), length_};
  }

  template <typename Value>
  inline void value(const Value &value) {
    write(value);
  }

  inline void bytes(std::span<const Byte> bytes) {
    const auto text = textView(bytes);
    if (inspectUtf8(text) == Utf8Validation::valid) {
      writeString(text);
    } else {
      array([&](JsonWriter &items) {
        for (const auto byte : bytes) {
          items.element(byte);
        }
      });
    }
  }

private:
  enum class Container : std::uint8_t {
    object,
    array,
  };

  template <typename Consumer>
  inline void container(Container kind, Consumer &&consume) {
    append(kind == Container::object ? "{" : "[");
    const auto previous = std::exchange(first_, true);
    std::invoke(std::forward<Consumer>(consume), *this);
    append(kind == Container::object ? "}" : "]");
    first_ = previous;
  }

  inline void separator() {
    if (!std::exchange(first_, false)) {
      append(",");
    }
  }

  inline void append(std::string_view text) {
    if (text.size() > buffer_.size() - length_) {
      throw std::length_error{"WriteFailed"};
    }

    if (!text.empty()) {
      std::memcpy(buffer_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  inline void write(std::string_view text) {
    validateUtf8(text);

    writeString(text);
  }

  inline void writeString(std::string_view text) {
    constexpr std::string_view hex_digits = "0123456789abcdef";
    constexpr unsigned printable_start = 0x20;
    constexpr unsigned nibble_bits = 4;
    constexpr unsigned nibble_mask = 0xf;
    append("\"");
    for (const unsigned char byte : text) {
      if (byte == '"' || byte == '\\') {
        const std::array escaped{'\\', static_cast<char>(byte)};
        append({escaped.data(), escaped.size()});
      } else if (byte < printable_start) {
        if (const auto shorthand = controlEscape(byte)) {
          const std::array escaped{'\\', *shorthand};
          append({escaped.data(), escaped.size()});
        } else {
          const std::array escaped{'\\', 'u', '0', '0', hex_digits[byte >> nibble_bits], hex_digits[byte & nibble_mask]};
          append({escaped.data(), escaped.size()});
        }
      } else {
        const auto character = static_cast<char>(byte);
        append({&character, 1});
      }
    }

    append("\"");
  }

  inline static std::optional<char> controlEscape(unsigned char byte) noexcept {
    switch (byte) {
    case '\b':
      return 'b';
    case '\f':
      return 'f';
    case '\n':
      return 'n';
    case '\r':
      return 'r';
    case '\t':
      return 't';
    default:
      return std::nullopt;
    }
  }

  template <typename Text>
    requires(std::is_array_v<Text> && std::same_as<std::remove_extent_t<Text>, char>)
  void write(const Text &text) {
    const auto bytes = std::span{text};
    const auto end = std::ranges::find(bytes, '\0');
    write(std::string_view{bytes.data(), static_cast<std::size_t>(end - bytes.begin())});
  }

  template <std::same_as<bool> Boolean>
  inline void write(Boolean value) {
    append(value ? "true" : "false");
  }

  inline void write(std::nullptr_t) {
    append("null");
  }

  template <typename Value>
  inline void write(const std::optional<Value> &value) {
    if (value) {
      write(*value);
    } else {
      write(nullptr);
    }
  }

  template <std::integral Number>
    requires(!std::same_as<Number, bool>)
  void write(Number value) {
    const auto output = buffer_.subspan(length_);
    if (output.empty()) {
      throw std::length_error{"WriteFailed"};
    }

    const auto result = std::to_chars(output.data(), output.data() + output.size(), value);
    if (result.ec != std::errc{}) {
      throw std::length_error{"WriteFailed"};
    }

    length_ += static_cast<std::size_t>(result.ptr - output.data());
  }

  inline void write(float value) {
    write(static_cast<double>(value));
  }

  inline void write(double value) {
    if (!std::isfinite(value)) {
      throw std::invalid_argument{"InvalidJsonNumber"};
    }

    constexpr std::size_t capacity = std::numeric_limits<double>::max_exponent10 + std::numeric_limits<double>::max_digits10 + sizeof("-0.");
    std::array<char, capacity> encoded{};
    const auto result = std::to_chars(encoded.data(), encoded.data() + encoded.size(), value, std::chars_format::fixed);
    if (result.ec != std::errc{}) {
      throw std::length_error{"WriteFailed"};
    }

    append({encoded.data(), static_cast<std::size_t>(result.ptr - encoded.data())});
  }

  template <typename Consumer>
    requires std::invocable<Consumer, JsonWriter &>
  void write(Consumer &&consume) {
    std::invoke(std::forward<Consumer>(consume), *this);
  }

  std::span<char> buffer_;
  std::size_t length_ = 0;
  bool first_ = true;
};

}
}

// Interface: core/placeholder_prefix.cppm
export {
namespace telar::gui {

inline constexpr std::string_view placeholder_prefix = "\xf4\x8e\xbb\xae";

}
}
