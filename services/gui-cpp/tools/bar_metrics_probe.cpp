#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include <string_view>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include <bit>
#include <cstdio>
#include <exception>
#include <limits>
#include <memory>



import telar.gui.core.json_writer;
import telar.gui.core.metrics;
import telar.gui.presentation.history_filter_geometry;

namespace {

using namespace telar::gui;

static_assert(std::endian::native == std::endian::little);

enum class RequestKind : std::uint8_t {
  metric,
  history,
};

struct MetricRequest {
  std::uint32_t metric = 0;
  std::uint32_t present = 0;
  std::uint32_t cpu = 0;
  std::uint32_t memory = 0;
  std::uint32_t battery_present = 0;
  std::uint32_t battery = 0;
};

template <typename Value>
Value read() {
  Value value;
  if (std::fread(std::addressof(value), sizeof(Value), 1, stdin) != 1) {
    throw std::runtime_error{"IncompleteBarMetricsRequest"};
  }

  return value;
}

void writeBytes(const void *data, std::size_t size) {
  const auto length = static_cast<std::uint32_t>(size);
  if (std::fwrite(&length, sizeof(length), 1, stdout) != 1 || (size != 0 && std::fwrite(data, sizeof(char), size, stdout) != size)) {
    throw std::runtime_error{"BarMetricsWriteFailed"};
  }
}

void write(std::string_view text) {
  writeBytes(text.data(), text.size());
}

void metric() {
  const auto request = read<MetricRequest>();
  constexpr std::uint32_t full_percent = 100;
  if (request.metric > static_cast<std::uint32_t>(BarMetric::battery) || request.present > 1 || request.cpu > full_percent || request.memory > std::numeric_limits<std::uint16_t>::max() || request.battery_present > 1 || request.battery > full_percent) {
    throw std::invalid_argument{"InvalidBarMetricsRequest"};
  }

  const auto name = static_cast<BarMetric>(request.metric);
  const telar::SystemMetrics sample{
      .revision = request.present,
      .cpu_percent = static_cast<std::uint8_t>(request.cpu),
      .memory_used_decigib = static_cast<std::uint16_t>(request.memory),
      .has_battery = request.battery_present != 0,
      .battery_percent = static_cast<std::uint8_t>(request.battery),
      .cpu_count = 0,
      .memory_total_decigib = 0,
  };
  write(BarMetrics::available(name, sample) ? "1" : "0");
  write(BarMetrics::glyph(name));
  write(BarMetrics::value(name, sample).view());
  write(palette_names[static_cast<std::size_t>(BarMetrics::ink(name, sample))]);
}

void history() {
  const auto count = read<std::uint32_t>();
  constexpr std::uint32_t maximum_samples = 1024;
  constexpr std::uint8_t full_percent = 100;
  if (count > maximum_samples) {
    throw std::invalid_argument{"InvalidCpuHistoryRequest"};
  }

  CpuHistory history;
  CpuHistory::Samples buffer;
  for (std::uint32_t index = 0; index < count; ++index) {
    const auto percent = read<std::uint8_t>();
    if (percent > full_percent) {
      throw std::invalid_argument{"InvalidCpuHistoryRequest"};
    }

    history.push(percent);
    const auto ordered = history.ordered(buffer);
    writeBytes(ordered.data(), ordered.size());
  }
}

}

int main() {
  try {
    RequestKind kind{};
    while (std::fread(&kind, sizeof(kind), 1, stdin) == 1) {
      switch (kind) {
      case RequestKind::metric:
        metric();
        break;
      case RequestKind::history:
        history();
        break;
      default:
        throw std::invalid_argument{"UnknownBarMetricsRequest"};
      }
    }

    return std::feof(stdin) != 0 && std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    static_cast<void>(std::fputs(error.what(), stderr));

    return 1;
  }
}
