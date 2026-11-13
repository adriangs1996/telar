#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include <algorithm>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <lua.h>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "telar_client/serializers/telar_cells.hpp"
#include <variant>
#include <limits>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../core/memory.hpp"
#include <QColor>
#include <QString>
#include <QStringLiteral>
#include <QVariant>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtypes.h>

#pragma once


import telar.gui.components.builtin_content;
import telar.gui.components.configuration;
import telar.gui.config.plugin_query;
import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;

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

inline QString componentActionIdentity(const std::optional<BindingAction> &action, std::string_view url, std::optional<NamedActionDescription> named = std::nullopt) {
  if (action) {
    if (named) {
      if (const auto *definition = std::get_if<DefinitionActionDescription>(&*named)) {
        return QStringLiteral("definition:%1:%2").arg(static_cast<unsigned>(definition->kind)).arg(definition->index);
      }

      const auto &plugin = std::get<PluginActionDescription>(*named);

      return QStringLiteral("plugin:%1:%2").arg(plugin.plugin).arg(plugin.action);
    }

    return QStringLiteral("action:%1:%2:%3:%4").arg(static_cast<unsigned>(action->kind)).arg(action->parameter).arg(action->reference).arg(action->generation);
  }

  return url.empty() ? QString{} : QStringLiteral("url:") + componentText(url);
}

inline void appendComponentAccessibleName(QString &name, const QString &text) {
  if (!name.isEmpty()) {
    name += QLatin1Char{' '};
  }

  name += text;
}

template <components::Capacity Bounds, typename Resolve>
  requires std::invocable<const Resolve &, BindingAction>
QVariantList componentRecords(const components::Content<Bounds> &content, const Theme &theme, const components::Time &time, const Resolve &resolve) {
  constexpr std::array names{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
  constexpr std::array tones{PaletteRole::text, PaletteRole::subtext0, PaletteRole::accent, PaletteRole::green, PaletteRole::yellow, PaletteRole::red};
  std::array<QString, Bounds.nodes> group_names;
  QVariantList result;
  result.reserve(static_cast<qsizetype>(content.nodes().size()));
  for (std::size_t index = 0; index < content.nodes().size(); ++index) {
    const auto &node = content.nodes()[index];
    const auto icon = componentIcon(node);
    const auto ink = theme.chromeColor(tones[static_cast<std::size_t>(node.tone)]);
    const auto text = node.kind == components::Kind::clock ? componentText(components::Clock::format(content.text(node.text), time).view()) : componentText(content.text(node.text));
    if (!node.tooltip && node.parent < index && content.nodes()[node.parent].kind == components::Kind::group && !text.isEmpty()) {
      appendComponentAccessibleName(group_names.at(node.parent), text);
    }

    QVariantList samples;
    for (const auto sample : content.samples(node)) {
      samples.append(sample);
    }

    const auto glyph = !icon.glyph.empty() ? componentText(icon.glyph) : QString{};
    const auto action = content.action(node);
    const auto named = action && action->kind == BindingActionKind::extended ? resolve(*action) : std::nullopt;
    const QVariantMap record{
        {QStringLiteral("index"), static_cast<int>(index)},
        {QStringLiteral("parent"), node.parent == components::Node::no_parent ? -1 : static_cast<int>(node.parent)},
        {QStringLiteral("kind"), QString::fromLatin1(names[static_cast<std::size_t>(node.kind)])},
        {QStringLiteral("tooltip"), node.tooltip},
        {QStringLiteral("text"), text},
        {QStringLiteral("accessibleName"), text},
        {QStringLiteral("detail"), componentText(content.text(node.detail))},
        {QStringLiteral("clickable"), action.has_value() || node.url.length != 0},
        {QStringLiteral("actionIdentity"), componentActionIdentity(action, content.text(node.url), named)},
        {QStringLiteral("ink"), componentColor(node.style.foreground, theme, ink)},
        // 0 neutral, 1 muted, 2 accent, 3 success, 4 warning, 5 danger: bar chrome tints by the worst of a group.
        {QStringLiteral("tone"), static_cast<int>(node.tone)},
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

  for (std::size_t index = 0; index < content.nodes().size(); ++index) {
    if (content.nodes()[index].kind == components::Kind::group) {
      auto record = result.at(static_cast<qsizetype>(index)).toMap();
      record.insert(QStringLiteral("accessibleName"), std::move(group_names.at(index)));
      result[static_cast<qsizetype>(index)] = record;
    }
  }

  return result;
}
}
