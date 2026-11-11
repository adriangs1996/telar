module;
#include "tbc/view.hpp"
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

  // The samples are copied into the buffer, region `a`, in the order they were taken.
  [[nodiscard]] inline tbc::view<std::span<const std::uint8_t>, tbc::lt::a> ordered(tbc::view<Samples &, tbc::lt::a> buffer) const noexcept {
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

// Interface: core/metric_levels.cppm
export {
namespace telar::gui {

enum class BarMetric : std::uint8_t {
  cpu,
  memory,
  battery,
};

enum class MetricSeverity : std::uint8_t {
  normal,
  warning,
  danger,
};

// The thresholds that turn a host metric into a warning or a danger.
struct MetricLevels {
  static constexpr std::uint8_t cpu_warning = 90;
  static constexpr std::uint8_t cpu_danger = 98;
  static constexpr std::uint8_t memory_warning = 85;
  static constexpr std::uint8_t memory_danger = 95;
  static constexpr std::uint8_t battery_warning = 20;
  static constexpr std::uint8_t battery_danger = 10;

  [[nodiscard]] inline static bool available(BarMetric metric, const SystemMetrics &sample) noexcept {
    return sample.revision != 0 && (metric != BarMetric::battery || sample.has_battery);
  }

  // How full the metric is, 0..100: memory in use of the total, or the battery's charge.
  [[nodiscard]] inline static std::uint8_t percent(BarMetric metric, const SystemMetrics &sample) noexcept {
    switch (metric) {
    case BarMetric::cpu:
      return sample.cpu_percent;
    case BarMetric::memory:
      if (sample.memory_total_decigib == 0) {
        return 0;
      }

      return static_cast<std::uint8_t>(std::min<unsigned>(100, ((sample.memory_used_decigib * 100U) + (sample.memory_total_decigib / 2U)) / sample.memory_total_decigib));
    case BarMetric::battery:
      return sample.battery_percent;
    }

    return 0;
  }

  // The severity the thresholds give. `margin` moves every threshold that many
  // points away from the current value, so a level is kept until the value has
  // clearly left it.
  [[nodiscard]] inline static MetricSeverity severity(BarMetric metric, const SystemMetrics &sample, int margin = 0) noexcept {
    if (!available(metric, sample) || (metric == BarMetric::memory && sample.memory_total_decigib == 0)) {
      return MetricSeverity::normal;
    }

    const int value = percent(metric, sample);
    const auto rising = [&](int warning, int danger) noexcept {
      return value + margin >= danger ? MetricSeverity::danger : value + margin >= warning ? MetricSeverity::warning
                                                                                            : MetricSeverity::normal;
    };
    switch (metric) {
    case BarMetric::cpu:
      return rising(cpu_warning, cpu_danger);
    case BarMetric::memory:
      return rising(memory_warning, memory_danger);
    case BarMetric::battery:
      return value - margin <= battery_danger ? MetricSeverity::danger : value - margin <= battery_warning ? MetricSeverity::warning
                                                                                                        : MetricSeverity::normal;
    }

    return MetricSeverity::normal;
  }
};

// Each metric's severity, debounced: a CPU or memory peak must last
// `confirm_samples` samples before it raises the level, and a level falls only
// once the value is `release_margin` points past its threshold. The battery
// moves slowly, so its rises are immediate.
class MetricAlerts {
public:
  static constexpr std::uint8_t confirm_samples = 3;
  static constexpr int release_margin = 5;

  inline void update(const SystemMetrics &sample) noexcept {
    for (std::size_t index = 0; index < states_.size(); ++index) {
      const auto metric = static_cast<BarMetric>(index);
      auto &state = states_[index];
      if (!MetricLevels::available(metric, sample)) {
        state = {};
        continue;
      }

      const auto raw = MetricLevels::severity(metric, sample);
      if (raw > state.current) {
        state.pending_count = raw == state.pending ? state.pending_count + 1 : 1;
        state.pending = raw;
        if (metric == BarMetric::battery || state.pending_count >= confirm_samples) {
          state.current = raw;
          state.pending_count = 0;
        }
        continue;
      }

      state.pending_count = 0;
      state.current = std::min(state.current, MetricLevels::severity(metric, sample, release_margin));
    }
  }

  [[nodiscard]] inline MetricSeverity severity(BarMetric metric) const noexcept {
    return states_[static_cast<std::size_t>(metric)].current;
  }

private:
  struct State {
    MetricSeverity current = MetricSeverity::normal;
    MetricSeverity pending = MetricSeverity::normal;
    std::uint8_t pending_count = 0;
  };

  std::array<State, 3> states_{};
};

}
}

// Interface: core/json_writer.cppm
export {
namespace telar::gui {

// Writes JSON into the caller's buffer, region `a`, which the written text views.
class JsonWriter {
public:
  inline explicit JsonWriter(tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept
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

  [[nodiscard]] inline tbc::view<std::string_view, tbc::lt::a> view() const noexcept {
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

  tbc::view<std::span<char>, tbc::lt::a> buffer_;
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
