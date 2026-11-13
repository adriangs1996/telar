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

inline QVariantMap metricRecord(BarMetric metric, const HostMetrics &metrics) {
  constexpr std::array names{"cpu", "memory", "battery"};
  const auto &sample = metrics.sample();
  const auto severity = metrics.severity(metric);
  const auto ink = BarMetrics::ink(severity);

  return {
      {QStringLiteral("name"), QString::fromLatin1(names[static_cast<std::size_t>(metric)])},
      {QStringLiteral("available"), BarMetrics::available(metric, sample)},
      // A machine without a battery has nothing to measure; the summary leaves it out instead of showing it as unknown.
      {QStringLiteral("absent"), metric == BarMetric::battery && sample.revision != 0 && !sample.has_battery},
      {QStringLiteral("glyph"), toQString(BarMetrics::glyph(metric))},
      {QStringLiteral("text"), toQString(BarMetrics::value(metric, sample).view())},
      {QStringLiteral("ink"), paletteName(ink)},
      {QStringLiteral("mark"), paletteName(ink == PaletteRole::text ? PaletteRole::subtext0 : ink)},
      {QStringLiteral("percent"), BarMetrics::percent(metric, sample)},
      {QStringLiteral("severity"), static_cast<int>(severity)},
  };
}

inline QVariantMap metricsRecord(const HostMetrics &metrics) {
  CpuHistory::Samples buffer;
  QVariantList history;
  for (const auto sample : metrics.history().ordered(buffer)) {
    history.append(sample);
  }

  return {
      {QStringLiteral("cpu"), metricRecord(BarMetric::cpu, metrics)},
      {QStringLiteral("memory"), metricRecord(BarMetric::memory, metrics)},
      {QStringLiteral("battery"), metricRecord(BarMetric::battery, metrics)},
      {QStringLiteral("history"), history},
  };
}

}
