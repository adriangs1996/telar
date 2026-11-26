#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/models/projection.hpp"
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <array>
#include <cstddef>
#include <cstring>

#pragma once

import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  inline QString paletteName(PaletteRole role) {
    return QString::fromLatin1(palette_names[static_cast<std::size_t>(role)]);
  }

  inline QVariantMap metricRecord(BarMetric metric, const application::status_bar::HostMetrics& metrics) {
    constexpr ds::Array names{"cpu", "memory", "battery"};
    const auto& sample = metrics.sample();
    const auto severity = metrics.severity(metric);
    const auto ink = application::status_bar::BarMetrics::ink(severity);

    return {
        {QStringLiteral("name"), QString::fromLatin1(names[static_cast<std::size_t>(metric)])},
        {QStringLiteral("available"), application::status_bar::BarMetrics::available(metric, sample)},
        // A machine without a battery has nothing to measure; the summary leaves it out instead of showing it as unknown.
        {QStringLiteral("absent"), metric == BarMetric::battery && sample.revision != 0 && !sample.has_battery},
        {QStringLiteral("glyph"), toQString(application::status_bar::BarMetrics::glyph(metric))},
        {QStringLiteral("text"), toQString(application::status_bar::BarMetrics::value(metric, sample).view())},
        {QStringLiteral("ink"), paletteName(ink)},
        {QStringLiteral("mark"), paletteName(ink == PaletteRole::text ? PaletteRole::subtext0 : ink)},
        {QStringLiteral("percent"), application::status_bar::BarMetrics::percent(metric, sample)},
        {QStringLiteral("severity"), static_cast<int>(severity)},
    };
  }

  inline QVariantMap metricsRecord(const application::status_bar::HostMetrics& metrics) {
    application::status_bar::CpuHistory::Samples buffer;
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
