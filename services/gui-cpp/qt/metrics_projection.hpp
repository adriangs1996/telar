#pragma once

#include "application/host_metrics.hpp"
#include "core/cpu_history.hpp"
#include "core/theme_values.hpp"
#include "presentation/bar_metrics.hpp"
#include "projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <cstddef>

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
