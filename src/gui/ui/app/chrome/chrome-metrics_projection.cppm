export module telar.gui.ui.app.chrome:metrics_projection;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.gui.foundation.core;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QString paletteName(PaletteRole role) {
    return QString::fromLatin1(palette_names[static_cast<std::size_t>(role)]);
  }

  [[tbc::hot_path]] inline QVariantMap metricRecord(BarMetric metric, const application::status_bar::HostMetrics& metrics) {
    constexpr ds::Array names{"cpu", "memory", "battery"};
    const auto& sample = metrics.sample();
    const auto severity = metrics.severity(metric);
    const auto ink = application::status_bar::BarMetrics::ink(severity);

    return {
        {u"name"_s, QString::fromLatin1(names[static_cast<std::size_t>(metric)])},
        {u"available"_s, application::status_bar::BarMetrics::available(metric, sample)},
        // A machine without a battery has nothing to measure; the summary leaves it out instead of showing it as unknown.
        {u"absent"_s, metric == BarMetric::battery && sample.revision != 0 && !sample.has_battery},
        {u"glyph"_s, toQString(application::status_bar::BarMetrics::glyph(metric))},
        {u"text"_s, toQString(application::status_bar::BarMetrics::value(metric, sample).view())},
        {u"ink"_s, paletteName(ink)},
        {u"mark"_s, paletteName(ink == PaletteRole::text ? PaletteRole::subtext0 : ink)},
        {u"percent"_s, application::status_bar::BarMetrics::percent(metric, sample)},
        {u"severity"_s, static_cast<int>(severity)},
    };
  }

  [[tbc::hot_path]] inline QVariantMap metricsRecord(const application::status_bar::HostMetrics& metrics) {
    application::status_bar::CpuHistory::Samples buffer;
    QVariantList history;

    for (const auto sample : metrics.history().ordered(buffer)) {
      history.append(sample);
    }

    return {
        {u"cpu"_s, metricRecord(BarMetric::cpu, metrics)},
        {u"memory"_s, metricRecord(BarMetric::memory, metrics)},
        {u"battery"_s, metricRecord(BarMetric::battery, metrics)},
        {u"history"_s, history},
    };
  }

}
