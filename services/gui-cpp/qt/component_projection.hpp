#pragma once

#include "components/clock.hpp"
#include "components/content.hpp"
#include "components/icon.hpp"
#include "components/invocation.hpp"
#include "components/node.hpp"
#include "core/color.hpp"
#include "core/color_name.hpp"
#include "core/theme_values.hpp"
#include "input/action.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <QColor>
#include <QString>
#include <QStringLiteral>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <optional>
#include <string_view>
#include <variant>

namespace telar::gui::qt {

inline QString componentText(std::string_view text) {
  return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
}

inline QColor componentColor(Color color) {
  return QColor::fromRgbF(color.r, color.g, color.b, color.a);
}

inline QColor componentColor(const std::optional<ColorName::Value> &value, const Theme &theme, Color fallback) {
  if (!value) {
    return componentColor(fallback);
  }

  const auto *role = std::get_if<PaletteRole>(&*value);

  return componentColor(role == nullptr ? theme.resolve(std::get<CellColor>(*value), fallback) : theme.chromeColor(*role));
}

inline components::Icon componentIcon(const components::Node &node) {
  if (node.mark) {
    constexpr std::array names{"provider_claude", "provider_codex", "provider_pi", "telar_mark"};

    return components::Icon::find(names[static_cast<std::size_t>(*node.mark)]);
  }

  return components::Icon::find(node.icon ? node.icon->view() : std::string_view{});
}

inline QString componentActionIdentity(const std::optional<BindingAction> &action, std::string_view url) {
  if (action) {
    return QStringLiteral("action:%1:%2:%3:%4").arg(static_cast<unsigned>(action->kind)).arg(action->parameter).arg(action->reference).arg(action->generation);
  }

  return url.empty() ? QString{} : QStringLiteral("url:") + componentText(url);
}

template <components::Capacity Bounds>
QVariantList componentRecords(const components::Content<Bounds> &content, const Theme &theme, const components::Time &time) {
  constexpr std::array names{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
  constexpr std::array tones{PaletteRole::text, PaletteRole::subtext0, PaletteRole::accent, PaletteRole::green, PaletteRole::yellow, PaletteRole::red};
  QVariantList result;
  result.reserve(static_cast<qsizetype>(content.nodes().size()));
  for (std::size_t index = 0; index < content.nodes().size(); ++index) {
    const auto &node = content.nodes()[index];
    const auto icon = componentIcon(node);
    const auto ink = theme.chromeColor(tones[static_cast<std::size_t>(node.tone)]);
    const auto text = node.kind == components::Kind::clock ? componentText(components::Clock::format(content.text(node.text), time).view()) : componentText(content.text(node.text));
    QVariantList samples;
    for (const auto sample : content.samples(node)) {
      samples.append(sample);
    }

    const auto glyph = !icon.glyph.empty() ? componentText(icon.glyph) : QString{};
    const auto action = content.action(node);
    const QVariantMap record{
        {QStringLiteral("index"), static_cast<int>(index)},
        {QStringLiteral("parent"), node.parent == components::Node::no_parent ? -1 : static_cast<int>(node.parent)},
        {QStringLiteral("kind"), QString::fromLatin1(names[static_cast<std::size_t>(node.kind)])},
        {QStringLiteral("tooltip"), node.tooltip},
        {QStringLiteral("text"), text},
        {QStringLiteral("detail"), componentText(content.text(node.detail))},
        {QStringLiteral("clickable"), action.has_value() || node.url.length != 0},
        {QStringLiteral("actionIdentity"), componentActionIdentity(action, content.text(node.url))},
        {QStringLiteral("ink"), componentColor(node.style.foreground, theme, ink)},
        {QStringLiteral("background"), componentColor(node.style.background, theme, Color{.a = 0})},
        {QStringLiteral("bold"), node.style.bold},
        {QStringLiteral("italic"), node.style.italic},
        {QStringLiteral("faint"), node.style.faint},
        {QStringLiteral("underline"), node.style.underline},
        {QStringLiteral("strikethrough"), node.style.strikethrough},
        {QStringLiteral("primary"), node.primary},
        {QStringLiteral("value"), static_cast<qreal>(node.value) / components::Node::full_scale},
        {QStringLiteral("marker"), node.marker ? QVariant{static_cast<qreal>(*node.marker) / components::Node::full_scale} : QVariant{}},
        {QStringLiteral("samples"), samples},
        {QStringLiteral("priority"), node.effectivePriority()},
        {QStringLiteral("glyph"), node.kind == components::Kind::icon && glyph.isEmpty() ? text : glyph},
        {QStringLiteral("providerMark"), static_cast<int>(icon.provider)},
        {QStringLiteral("telarMark"), icon.telar},
        {QStringLiteral("metric"), static_cast<int>(node.metric)},
    };
    result.append(record);
  }

  return result;
}

}
