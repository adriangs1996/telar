export module telar.gui.ui.design.elements:component_projection;

import std;
import telar.gui.qt;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.gui.foundation.actions;
import telar.base.ds;
import telar.wire.vocabulary;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  [[tbc::hot_path]] inline QString componentText(std::string_view text) {
    return QString::fromUtf8(text.data(), static_cast<qsizetype>(text.size()));
  }

  [[tbc::hot_path]] inline QColor componentColor(Color color) {
    return QColor::fromRgbF(color.r, color.g, color.b, color.a);
  }

  [[tbc::hot_path]] inline QColor componentColor(const ds::Option<ColorName::Value>& value, const Theme& theme, Color fallback) {
    if (!value) {
      return componentColor(fallback);
    }

    const auto* role = std::get_if<PaletteRole>(&*value);

    return componentColor(role == nullptr ? theme.resolve(std::get<CellColor>(*value), fallback) : theme.chromeColor(*role));
  }

  [[tbc::hot_path]] inline application::components::Icon componentIcon(const application::components::Node& node) {
    if (node.mark) {
      constexpr ds::Array names{"provider_claude", "provider_codex", "provider_pi", "telar_mark"};

      return application::components::Icon::find(names[static_cast<std::size_t>(*node.mark)]);
    }

    return application::components::Icon::find(node.icon ? node.icon->view() : std::string_view{});
  }

  [[tbc::hot_path]] inline QString componentActionIdentity(const ds::Option<BindingAction>& action, std::string_view url, ds::Option<NamedActionDescription> named = ds::none) {
    if (action) {
      if (named) {
        if (const auto* definition = std::get_if<DefinitionActionDescription>(&*named)) {
          return u"definition:%1:%2"_s.arg(static_cast<unsigned>(definition->kind)).arg(definition->index);
        }

        const auto& plugin = std::get<PluginActionDescription>(*named);

        return u"plugin:%1:%2"_s.arg(plugin.plugin).arg(plugin.action);
      }

      return u"action:%1:%2:%3:%4"_s.arg(static_cast<unsigned>(action->kind)).arg(action->parameter).arg(action->reference).arg(action->generation);
    }

    return url.empty() ? QString{} : u"url:"_s + componentText(url);
  }

  [[tbc::hot_path]] inline void appendComponentAccessibleName(QString& name, const QString& text) {
    if (!name.isEmpty()) {
      name += QLatin1Char{' '};
    }

    name += text;
  }

  template <application::components::Capacity Bounds, typename Resolve>
    requires std::invocable<const Resolve&, BindingAction>
  [[tbc::generic]] QVariantList componentRecords(const application::components::Content<Bounds>& content, const Theme& theme, const application::components::Time& time, const Resolve& resolve) {
    constexpr ds::Array names{"label", "icon", "mark", "meter", "sparkline", "badge", "clock", "metric", "machines", "group", "heading", "text", "meter_row", "kv", "callout", "actions", "button", "divider"};
    constexpr ds::Array tones{PaletteRole::text, PaletteRole::subtext0, PaletteRole::accent, PaletteRole::green, PaletteRole::yellow, PaletteRole::red};
    ds::Array<QString, Bounds.nodes> group_names;
    QVariantList result;

    result.reserve(static_cast<qsizetype>(content.nodes().size()));
    for (std::size_t index = 0; index < content.nodes().size(); ++index) {
      const auto& node = content.nodes()[index];
      const auto icon = componentIcon(node);
      const auto ink = theme.chromeColor(tones[static_cast<std::size_t>(node.tone)]);
      const auto text = node.kind == application::components::Kind::clock ? componentText(application::components::Clock::format(content.text(node.text), time).view()) : componentText(content.text(node.text));
      if (!node.tooltip && node.parent < index && content.nodes()[node.parent].kind == application::components::Kind::group && !text.isEmpty()) {
        appendComponentAccessibleName(group_names.atCheckedMut(node.parent), text);
      }

      QVariantList samples;

      for (const auto sample : content.samples(node)) {
        samples.append(sample);
      }

      const auto glyph = !icon.glyph.empty() ? componentText(icon.glyph) : QString{};
      const auto action = content.action(node);
      const auto named = action && action->kind == BindingActionKind::extended ? resolve(*action) : ds::none;
      const QVariantMap record{
          {u"index"_s, static_cast<int>(index)},
          {u"parent"_s, node.parent == application::components::Node::no_parent ? -1 : static_cast<int>(node.parent)},
          {u"kind"_s, QString::fromLatin1(names[static_cast<std::size_t>(node.kind)])},
          {u"tooltip"_s, node.tooltip},
          {u"text"_s, text},
          {u"accessibleName"_s, text},
          {u"detail"_s, componentText(content.text(node.detail))},
          {u"clickable"_s, action.hasValue() || node.url.length != 0},
          {u"link"_s, !action.hasValue() && node.url.length != 0},
          {u"actionIdentity"_s, componentActionIdentity(action, content.text(node.url), named)},
          {u"ink"_s, componentColor(node.style.foreground, theme, ink)},
          // 0 neutral, 1 muted, 2 accent, 3 success, 4 warning, 5 danger: bar chrome tints by the worst of a group.
          {u"tone"_s, static_cast<int>(node.tone)},
          {u"background"_s, componentColor(node.style.background, theme, Color{.a = 0})},
          {u"bold"_s, node.style.bold},
          {u"italic"_s, node.style.italic},
          {u"faint"_s, node.style.faint},
          {u"underline"_s, node.style.underline},
          {u"strikethrough"_s, node.style.strikethrough},
          {u"primary"_s, node.primary},
          {u"value"_s, static_cast<qreal>(node.value) / application::components::Node::full_scale},
          {u"marker"_s, node.marker ? QVariant{static_cast<qreal>(*node.marker) / application::components::Node::full_scale} : QVariant{}},
          {u"samples"_s, samples},
          {u"priority"_s, node.effectivePriority()},
          {u"glyph"_s, node.kind == application::components::Kind::icon && glyph.isEmpty() ? text : glyph},
          {u"providerMark"_s, static_cast<int>(icon.provider)},
          {u"telarMark"_s, icon.telar},
          {u"metric"_s, static_cast<int>(node.metric)},
      };

      result.append(record);
    }

    for (std::size_t index = 0; index < content.nodes().size(); ++index) {
      if (content.nodes()[index].kind == application::components::Kind::group) {
        auto record = result.at(static_cast<qsizetype>(index)).toMap();

        record.insert(u"accessibleName"_s, std::move(group_names.atCheckedMut(index)));
        result[static_cast<qsizetype>(index)] = record;
      }
    }

    return result;
  }
}
