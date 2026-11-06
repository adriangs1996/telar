#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <optional>
#include <string_view>
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>

#pragma once


import telar.gui.application.host_effects;
import telar.gui.core.json_writer;
import telar.gui.core.metrics;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

inline QString paletteName(PaletteRole role) {
  return QString::fromLatin1(palette_names[static_cast<std::size_t>(role)]);
}

inline QVariantMap metricRecord(BarMetric metric, const SystemMetrics &sample) {
  const auto ink = BarMetrics::ink(metric, sample);

  return {
      {QStringLiteral("available"), BarMetrics::available(metric, sample)},
      {QStringLiteral("glyph"), toQString(BarMetrics::glyph(metric))},
      {QStringLiteral("text"), toQString(BarMetrics::value(metric, sample).view())},
      {QStringLiteral("ink"), paletteName(ink)},
      {QStringLiteral("mark"), paletteName(ink == PaletteRole::text ? PaletteRole::subtext0 : ink)},
      {QStringLiteral("percent"), metric == BarMetric::battery ? sample.battery_percent : sample.cpu_percent},
  };
}

inline QVariantMap metricsRecord(const HostMetrics &metrics) {
  CpuHistory::Samples buffer;
  QVariantList history;
  for (const auto sample : metrics.history().ordered(buffer)) {
    history.append(sample);
  }

  return {
      {QStringLiteral("cpu"), metricRecord(BarMetric::cpu, metrics.sample())},
      {QStringLiteral("memory"), metricRecord(BarMetric::memory, metrics.sample())},
      {QStringLiteral("battery"), metricRecord(BarMetric::battery, metrics.sample())},
      {QStringLiteral("history"), history},
  };
}

}
