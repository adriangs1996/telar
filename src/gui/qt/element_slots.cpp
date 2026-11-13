#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "element_slots.hpp"
#include "component_projection.hpp"
#include "configuration_source.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <QColor>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringLiteral>
#include <QVariant>

import telar.gui.presentation.application_mark;

namespace telar::gui::qt {

namespace {

QString text(std::string_view value) {
  return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

QVariant paint(const components::ElementColor &color, const Theme &theme, std::optional<Color> fallback = std::nullopt) {
  if (!color.value && !fallback) {
    return {};
  }

  auto resolved = componentColor(color.value, theme, fallback.value_or(Color{}));
  resolved.setAlphaF(resolved.alphaF() * color.alpha / std::numeric_limits<std::uint8_t>::max());

  return resolved;
}

QString normalizedIcon(std::string_view name) {
  QString result = text(name).toLower();
  result.replace(QLatin1Char{'-'}, QLatin1Char{'_'});

  return result;
}

}

ElementSlots::ElementSlots(ConfigurationSource &source, Context context, QObject *parent)
    : QObject(parent),
      source_(source),
      context_(std::move(context)) {
  // Results of one Lua pass arrive close together; project them once.
  settle_.setSingleShot(true);
  settle_.setInterval(0);
  connect(&settle_, &QTimer::timeout, this, &ElementSlots::contentChanged);
}

bool ElementSlots::configured(components::Slot slot) const noexcept {
  const auto *definitions = source_.definitions();

  return definitions != nullptr && definitions->slot(slot) != LUA_NOREF;
}

bool ElementSlots::active() const noexcept {
  const auto *definitions = source_.definitions();

  return definitions != nullptr && definitions->drawsAny();
}

void ElementSlots::adopt(std::uint64_t generation) {
  if (generation == generation_) {
    return;
  }

  generation_ = generation;
  ++epoch_;
  instances_.clear();
}

void ElementSlots::begin() {
  for (auto &instance : instances_) {
    instance.seen = false;
  }
}

std::uint64_t ElementSlots::identity(components::Slot slot, const QString &key) noexcept {
  return qHash(key, static_cast<std::size_t>(slot) + 1);
}

QVariantMap ElementSlots::attach(components::Slot slot, const QString &key, const QVariantMap &item) {
  if (!configured(slot)) {
    return {};
  }

  const auto id = identity(slot, key);
  auto &instance = instances_[id];
  if (instance.id == 0) {
    instance.slot = slot;
    instance.key = key;
    instance.id = id;
  }

  instance.seen = true;
  auto bytes = QJsonDocument{QJsonObject::fromVariantMap(item)}.toJson(QJsonDocument::Compact);
  if (bytes != instance.item) {
    instance.item = std::move(bytes);
    instance.dirty = true;
    if (!instance.rendering && instance.failures < failure_limit) {
      render(id);
    }
  }

  // A render that finishes at once replaces the instance's nodes.
  const auto &current = *instances_.constFind(id);
  if (current.failures >= failure_limit || !current.rendered) {
    return {};
  }

  return {
      {QStringLiteral("slot"), QString::fromLatin1(components::slot_names[static_cast<std::size_t>(slot)].data(), static_cast<qsizetype>(components::slot_names[static_cast<std::size_t>(slot)].size()))},
      {QStringLiteral("key"), key},
      {QStringLiteral("revision"), QString::number(current.revision)},
      {QStringLiteral("nodes"), current.nodes},
      {QStringLiteral("error"), current.error},
  };
}

void ElementSlots::finish() {
  for (auto iterator = instances_.begin(); iterator != instances_.end();) {
    if (iterator->seen) {
      ++iterator;
      continue;
    }

    source_.forgetElements(iterator->id);
    iterator = instances_.erase(iterator);
  }
}

void ElementSlots::retain(std::initializer_list<components::Slot> pieces) {
  for (auto &instance : instances_) {
    if (std::ranges::find(pieces, instance.slot) != pieces.end()) {
      instance.seen = true;
    }
  }
}

const ElementSlots::Instance *ElementSlots::find(const QString &slot, const QString &key) const {
  const auto *const found = std::ranges::find_if(components::slot_names, [&](std::string_view name) {
    return slot == QLatin1StringView{name.data(), static_cast<qsizetype>(name.size())};
  });
  if (found == components::slot_names.end()) {
    return nullptr;
  }

  const auto entry = instances_.constFind(identity(static_cast<components::Slot>(found - components::slot_names.begin()), key));

  return entry == instances_.cend() ? nullptr : &*entry;
}

bool ElementSlots::owns(const ResolvedActions<ApplicationAllocator> &actions) const noexcept {
  return std::ranges::any_of(instances_, [&](const Instance &instance) {
    return instance.rendered && &instance.rendered->actions == &actions;
  });
}

void ElementSlots::invalidate() {
  // A render may finish at once and change its instance, so each is found again by its id.
  for (const auto id : instances_.keys()) {
    auto &instance = *instances_.find(id);
    instance.dirty = true;
    if (!instance.rendering && instance.failures < failure_limit) {
      render(id);
    }
  }
}

void ElementSlots::render(std::uint64_t id) {
  auto &instance = *instances_.find(id);
  instance.rendering = true;
  instance.dirty = false;
  const auto slot = instance.slot;
  const auto item = instance.item;
  const auto epoch = epoch_;
  const auto context = context_();
  try {
    source_.renderElements(slot, id, context, item, [this, id, epoch](LuaOutcome<ConfigurationSource::ElementsRender> outcome) {
      const auto found = instances_.find(id);
      if (epoch != epoch_ || found == instances_.end()) {
        return;
      }

      auto &current = *found;
      current.rendering = false;
      if (outcome.stale) {
        return;
      }

      if (!outcome.value) {
        current.error = outcome.error;
        if (++current.failures == failure_limit) {
          emit failed(QStringLiteral("components.%1 failed %2 times and fell back to the built-in piece: %3").arg(text(components::slot_names[static_cast<std::size_t>(current.slot)])).arg(failure_limit).arg(outcome.error));
        }
      } else {
        current.failures = 0;
        current.error.clear();
        current.rendered = std::shared_ptr<const Rendered>{std::move(*outcome.value)};
        current.nodes = project(*current.rendered, source_.configuration().theme);
        current.revision = ++next_revision_;
      }

      if (current.dirty && current.failures < failure_limit) {
        render(id);
      }

      settle_.start();
    });
  } catch (const std::exception &error) {
    if (const auto found = instances_.find(id); found != instances_.end()) {
      found->rendering = false;
      found->error = QString::fromUtf8(error.what());
    }
  }
}

QVariantList ElementSlots::project(const Rendered &rendered, const Theme &theme) {
  constexpr std::array tones{PaletteRole::text, PaletteRole::subtext0, PaletteRole::accent, PaletteRole::green, PaletteRole::yellow, PaletteRole::red};
  QVariantList result;
  result.reserve(static_cast<qsizetype>(rendered.elements.size()));
  for (std::size_t index = 0; index < rendered.elements.size(); ++index) {
    const auto &element = rendered.elements[index];
    const auto kind = element.kind;
    const auto ink = theme.chromeColor(tones[static_cast<std::size_t>(element.tone)]);
    QVariantMap record{
        {QStringLiteral("index"), static_cast<int>(index)},
        {QStringLiteral("parent"), element.parent == components::Element::none ? -1 : static_cast<int>(element.parent)},
        {QStringLiteral("kind"), QString::fromLatin1(components::element_kind_names[static_cast<std::size_t>(kind)])},
        {QStringLiteral("key"), text(rendered.view(element.key))},
        {QStringLiteral("text"), text(rendered.view(element.text))},
        {QStringLiteral("tooltip"), text(rendered.view(element.tooltip))},
        {QStringLiteral("padding"), QVariantList{element.padding[0], element.padding[1], element.padding[2], element.padding[3]}},
        {QStringLiteral("gap"), element.gap},
        {QStringLiteral("width"), element.width},
        {QStringLiteral("height"), element.height},
        {QStringLiteral("minWidth"), element.min_width},
        {QStringLiteral("minHeight"), element.min_height},
        {QStringLiteral("grow"), element.grow},
        {QStringLiteral("x"), element.x},
        {QStringLiteral("y"), element.y},
        {QStringLiteral("rotation"), element.rotation},
        {QStringLiteral("scale"), element.scale},
        {QStringLiteral("opacity"), element.opacity},
        {QStringLiteral("z"), element.z},
        {QStringLiteral("transition"), element.transition_ms},
        {QStringLiteral("easing"), element.easing},
        {QStringLiteral("radius"), element.radius},
        {QStringLiteral("borderWidth"), element.border_width},
        {QStringLiteral("background"), paint(element.background, theme)},
        {QStringLiteral("border"), paint(element.border, theme)},
        {QStringLiteral("hover"), paint(element.hover, theme)},
        {QStringLiteral("color"), paint(element.color, theme, ink)},
        {QStringLiteral("align"), element.align},
        {QStringLiteral("justify"), element.justify},
        {QStringLiteral("sizeRole"), element.size_role},
        {QStringLiteral("size"), element.size},
        {QStringLiteral("bold"), element.bold},
        {QStringLiteral("italic"), element.italic},
        {QStringLiteral("maxLines"), element.max_lines},
        {QStringLiteral("clip"), element.clip},
        {QStringLiteral("shadow"), element.shadow},
        {QStringLiteral("action"), element.action == components::Element::none ? -1 : static_cast<int>(element.action)},
        {QStringLiteral("callback"), element.callback == components::Element::none ? -1 : static_cast<int>(element.callback)},
        {QStringLiteral("url"), text(rendered.view(element.url))},
        {QStringLiteral("since"), static_cast<qint64>(element.since)},
    };
    record.insert(QStringLiteral("clickable"), element.action != components::Element::none || element.callback != components::Element::none || element.url.length != 0);
    if (element.max_width >= 0) {
      record.insert(QStringLiteral("maxWidth"), element.max_width);
    }

    if (element.max_height >= 0) {
      record.insert(QStringLiteral("maxHeight"), element.max_height);
    }

    if (element.align_self) {
      record.insert(QStringLiteral("alignSelf"), *element.align_self);
    }

    if (kind == components::ElementKind::icon) {
      const auto glyph = element.named ? components::Icon::find(normalizedIcon(rendered.view(element.text)).toStdString()).glyph : rendered.view(element.text);
      record.insert(QStringLiteral("glyph"), text(glyph));
    } else if (kind == components::ElementKind::mark) {
      const auto name = rendered.view(element.text);
      const auto icon = components::Icon::find(name == "telar" ? std::string_view{"telar_mark"} : (QStringLiteral("provider_") + text(name)).toStdString());
      record.insert(QStringLiteral("glyph"), text(icon.glyph));
      record.insert(QStringLiteral("providerMark"), static_cast<int>(icon.provider));
      record.insert(QStringLiteral("telarMark"), icon.telar);
    } else if (kind == components::ElementKind::tile) {
      const auto mark = ApplicationMark::forApplication(rendered.view(element.text));
      record.insert(QStringLiteral("glyph"), text(mark.glyph));
      record.insert(QStringLiteral("tile"), text(mark.tile));
      record.insert(QStringLiteral("ink"), text(mark.ink));
      record.insert(QStringLiteral("providerMark"), static_cast<int>(mark.provider));
    } else if (kind == components::ElementKind::canvas) {
      QVariantList operations;
      operations.reserve(static_cast<qsizetype>(element.steps_count));
      for (std::uint32_t step_index = element.steps_offset; step_index < element.steps_offset + element.steps_count && step_index < rendered.steps.size(); ++step_index) {
        const auto &step = rendered.steps[step_index];
        QVariantList values;
        for (std::uint8_t value = 0; value < step.count; ++value) {
          values.append(step.values[value]);
        }

        operations.append(QVariantMap{
            {QStringLiteral("op"), step.op},
            {QStringLiteral("values"), values},
            {QStringLiteral("color"), paint(step.color, theme, ink)},
            {QStringLiteral("text"), text(rendered.view(step.text))},
        });
      }

      record.insert(QStringLiteral("operations"), operations);
    }

    result.append(std::move(record));
  }

  return result;
}

}
