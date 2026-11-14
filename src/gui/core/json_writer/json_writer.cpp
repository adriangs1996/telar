module telar.gui.core.json_writer;

import std;
import telar.tbc;

import telar.base.text.json;
import telar.base.text.utf8;
import telar.wire.vocabulary;

namespace telar::gui {

  float StandardCosine::evaluate(float angle) noexcept {
    return std::cos(angle);
  }

  void CpuHistory::push(std::uint8_t percent) noexcept {
    samples_[next_] = percent;
    next_ = (next_ + 1) % capacity;
    count_ = count_ < capacity ? count_ + 1 : capacity;
  }

  tbc::view<std::span<const std::uint8_t>, tbc::lt::a> CpuHistory::ordered(tbc::view<Samples&, tbc::lt::a> buffer) const noexcept {
    const auto start = (next_ + capacity - count_) % capacity;

    for (std::size_t index = 0; index < count_; ++index) {
      buffer[index] = samples_[(start + index) % capacity];
    }

    return std::span{buffer}.first(count_);
  }

  bool MetricLevels::available(BarMetric metric, const SystemMetrics& sample) noexcept {
    return sample.revision != 0 && (metric != BarMetric::battery || sample.has_battery);
  }

  std::uint8_t MetricLevels::percent(BarMetric metric, const SystemMetrics& sample) noexcept {
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

  MetricSeverity MetricLevels::severity(BarMetric metric, const SystemMetrics& sample, int margin) noexcept {
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

  void MetricAlerts::update(const SystemMetrics& sample) noexcept {
    for (std::size_t index = 0; index < states_.size(); ++index) {
      const auto metric = static_cast<BarMetric>(index);
      auto& state = states_[index];

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

  MetricSeverity MetricAlerts::severity(BarMetric metric) const noexcept {
    return states_[static_cast<std::size_t>(metric)].current;
  }

  JsonWriter::JsonWriter(tbc::view<std::span<char>, tbc::lt::a> buffer) noexcept
      : buffer_(buffer) {}

  tbc::view<std::string_view, tbc::lt::a> JsonWriter::view() const noexcept {
    return {buffer_.data(), length_};
  }

  void JsonWriter::bytes(std::span<const Byte> bytes) {
    const auto text = textView(bytes);
    if (inspectUtf8(text) == Utf8Validation::valid) {
      writeString(text);
    } else {
      array([&](JsonWriter& items) {
        for (const auto byte : bytes) {
          items.element(byte);
        }
      });
    }
  }

  void JsonWriter::open(Container kind) {
    append(kind == Container::object ? "{" : "[");
  }

  void JsonWriter::close(Container kind) {
    append(kind == Container::object ? "}" : "]");
  }

  void JsonWriter::separator() {
    if (!std::exchange(first_, false)) {
      append(",");
    }
  }

  void JsonWriter::append(std::string_view text) {
    if (text.size() > buffer_.size() - length_) {
      throw std::length_error{"WriteFailed"};
    }

    if (!text.empty()) {
      std::memcpy(buffer_.data() + length_, text.data(), text.size());
      length_ += text.size();
    }
  }

  void JsonWriter::write(std::string_view text) {
    validateUtf8(text);

    writeString(text);
  }

  void JsonWriter::writeString(std::string_view text) {
    append("\"");
    runtime::escapeJson(text, runtime::JsonEscapes::standard, [&](std::string_view piece) {
      append(piece);
    });

    append("\"");
  }

  namespace {

    template <typename Number>
    std::size_t writeNumber(std::span<char> output, Number value) {
      if (output.empty()) {
        throw std::length_error{"WriteFailed"};
      }

      const auto result = std::to_chars(output.data(), output.data() + output.size(), value);
      if (result.ec != std::errc{}) {
        throw std::length_error{"WriteFailed"};
      }

      return static_cast<std::size_t>(result.ptr - output.data());
    }

  }

  void JsonWriter::writeSigned(std::int64_t value) {
    length_ += writeNumber(buffer_.subspan(length_), value);
  }

  void JsonWriter::writeUnsigned(std::uint64_t value) {
    length_ += writeNumber(buffer_.subspan(length_), value);
  }

  template <std::same_as<bool> Boolean>
  void JsonWriter::write(Boolean value) {
    append(value ? "true" : "false");
  }

  template void JsonWriter::write<bool>(bool value);

  void JsonWriter::write(std::nullptr_t) {
    append("null");
  }

  void JsonWriter::write(float value) {
    write(static_cast<double>(value));
  }

  void JsonWriter::write(double value) {
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

}
