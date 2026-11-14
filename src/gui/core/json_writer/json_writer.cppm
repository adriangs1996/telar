module;
#include "tbc/annotations.hpp"

export module telar.gui.core.json_writer;

import std;
import telar.tbc;

import telar.base.text.json;
import telar.base.text.utf8;
import telar.wire.vocabulary;

// Interface: core/cosine.cppm
export {
  namespace telar::gui {

    template <typename Function>
    concept Cosine = requires(float angle) {
      { Function::evaluate(angle) } noexcept -> std::same_as<float>;
    };

    struct StandardCosine {
      [[nodiscard]] static float evaluate(float angle) noexcept;
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

      void push(std::uint8_t percent) noexcept;

      // The samples are copied into the buffer, region `a`, in the order they were taken.
      [[nodiscard]] tbc::view<std::span<const std::uint8_t>, tbc::lt::a> ordered(tbc::view<Samples&, tbc::lt::a> buffer) const noexcept;

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

      [[nodiscard]] static bool available(BarMetric metric, const SystemMetrics& sample) noexcept;

      // How full the metric is, 0..100: memory in use of the total, or the battery's charge.
      [[nodiscard]] static std::uint8_t percent(BarMetric metric, const SystemMetrics& sample) noexcept;

      // The severity the thresholds give. `margin` moves every threshold that many
      // points away from the current value, so a level is kept until the value has
      // clearly left it.
      [[nodiscard]] static MetricSeverity severity(BarMetric metric, const SystemMetrics& sample, int margin = 0) noexcept;
    };

    // Each metric's severity, debounced: a CPU or memory peak must last
    // `confirm_samples` samples before it raises the level, and a level falls only
    // once the value is `release_margin` points past its threshold. The battery
    // moves slowly, so its rises are immediate.
    class MetricAlerts {
    public:
      static constexpr std::uint8_t confirm_samples = 3;
      static constexpr int release_margin = 5;

      void update(const SystemMetrics& sample) noexcept;

      [[nodiscard]] MetricSeverity severity(BarMetric metric) const noexcept;

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
      explicit JsonWriter(tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept;

      template <typename Consumer>
      TBC_GENERIC void object(Consumer&& consume) {
        container(Container::object, std::forward<Consumer>(consume));
      }

      template <typename Consumer>
      TBC_GENERIC void array(Consumer&& consume) {
        container(Container::array, std::forward<Consumer>(consume));
      }

      template <typename Value>
      TBC_GENERIC void member(std::string_view name, const Value& value) {
        separator();
        write(name);
        append(":");
        write(value);
      }

      template <typename Value>
      TBC_GENERIC void element(const Value& value) {
        separator();
        write(value);
      }

      [[nodiscard]] tbc::view<std::string_view, tbc::lt::a> view() const noexcept;

      template <typename Value>
      TBC_GENERIC void value(const Value& value) {
        write(value);
      }

      void bytes(std::span<const Byte> bytes);

    private:
      enum class Container : std::uint8_t {
        object,
        array,
      };

      template <typename Consumer>
      TBC_GENERIC void container(Container kind, Consumer&& consume) {
        open(kind);
        const auto previous = std::exchange(first_, true);

        std::invoke(std::forward<Consumer>(consume), *this);
        close(kind);
        first_ = previous;
      }

      void open(Container kind);
      void close(Container kind);
      void separator();
      void append(std::string_view text);
      void write(std::string_view text);
      void writeString(std::string_view text);
      void writeSigned(std::int64_t value);
      void writeUnsigned(std::uint64_t value);

      template <typename Text>
        requires(std::is_array_v<Text> && std::same_as<std::remove_extent_t<Text>, char>)
      TBC_GENERIC void write(const Text& text) {
        const auto bytes = std::span{text};
        const auto end = std::ranges::find(bytes, '\0');

        write(std::string_view{bytes.data(), static_cast<std::size_t>(end - bytes.begin())});
      }

      // A template so that no pointer or number converts to it; instantiated only for bool.
      template <std::same_as<bool> Boolean>
      void write(Boolean value);

      void write(std::nullptr_t);

      template <typename Value>
      TBC_GENERIC void write(const std::optional<Value>& value) {
        if (value) {
          write(*value);
        } else {
          write(nullptr);
        }
      }

      template <std::integral Number>
        requires(!std::same_as<Number, bool>)
      TBC_GENERIC void write(Number value) {
        if constexpr (std::is_signed_v<Number>) {
          writeSigned(value);
        } else {
          writeUnsigned(value);
        }
      }

      void write(float value);
      void write(double value);

      template <typename Consumer>
        requires std::invocable<Consumer, JsonWriter&>
      TBC_GENERIC void write(Consumer&& consume) {
        std::invoke(std::forward<Consumer>(consume), *this);
      }

      tbc::view<std::span<char>, tbc::lt::a> buffer_;
      std::size_t length_ = 0;
      bool first_ = true;
    };

    extern template void JsonWriter::write<bool>(bool value);

  }
}

// Interface: core/placeholder_prefix.cppm
export {
  namespace telar::gui {

    inline constexpr std::string_view placeholder_prefix = "\xf4\x8e\xbb\xae";

  }
}
