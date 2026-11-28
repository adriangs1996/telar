module telar.gui.ui.design.elements;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.config;
import telar.gui.application;
import telar.base.ds;
import telar.lua;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    QString text(std::string_view value) {
      return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
    }

    QVariant paint(const application::components::ElementColor& color, const Theme& theme, ds::Option<Color> fallback = ds::none) {
      if (!color.value && !fallback) {
        return {};
      }

      auto resolved = componentColor(color.value, theme, fallback.valueOr(Color{}));

      resolved.setAlphaF(resolved.alphaF() * static_cast<float>(color.alpha) / std::numeric_limits<std::uint8_t>::max());

      return resolved;
    }

    QString normalizedIcon(std::string_view name) {
      QString result = text(name).toLower();

      result.replace(QLatin1Char{'-'}, QLatin1Char{'_'});

      return result;
    }

    QString statusName(const QVariant& code) {
      constexpr ds::Array names{"unknown", "working", "blocked", "ready", "failed", "done"};
      const auto index = code.toInt();

      return QString::fromLatin1(index >= 0 && static_cast<std::size_t>(index) < names.size() ? names[static_cast<std::size_t>(index)] : names.front());
    }

    QVariantList canvasOperations(const ElementSlots::Rendered& rendered, const application::components::Element& element, const Theme& theme, Color ink) {
      QVariantList operations;

      operations.reserve(static_cast<qsizetype>(element.steps_count));
      for (std::uint32_t step_index = element.steps_offset; step_index < element.steps_offset + element.steps_count && step_index < rendered.steps.size(); ++step_index) {
        const auto& step = rendered.steps[step_index];
        QVariantList values;

        for (std::uint8_t value = 0; value < step.count; ++value) {
          values.append(step.values[value]);
        }

        operations.append(QVariantMap{
            {u"op"_s, step.op},
            {u"values"_s, values},
            {u"color"_s, paint(step.color, theme, ink)},
            {u"text"_s, text(rendered.view(step.text))},
        });
      }

      return operations;
    }

    // The fields only one kind of element carries: its glyph, mark or drawing.
    void addKindFields(QVariantMap& record, const ElementSlots::Rendered& rendered, const application::components::Element& element, const Theme& theme, Color ink) {
      const auto kind = element.kind;

      if (kind == application::components::ElementKind::icon) {
        const auto glyph = element.named ? application::components::Icon::find(normalizedIcon(rendered.view(element.text)).toStdString()).glyph : rendered.view(element.text);

        record.insert(u"glyph"_s, text(glyph));
      } else if (kind == application::components::ElementKind::mark) {
        const auto name = rendered.view(element.text);
        const auto icon = application::components::Icon::find(name == "telar" ? std::string_view{"telar_mark"} : (u"provider_"_s + text(name)).toStdString());

        record.insert(u"glyph"_s, text(icon.glyph));
        record.insert(u"providerMark"_s, static_cast<int>(icon.provider));
        record.insert(u"telarMark"_s, icon.telar);
      } else if (kind == application::components::ElementKind::tile) {
        const auto mark = application::activity::ApplicationMark::forApplication(rendered.view(element.text));

        record.insert(u"glyph"_s, text(mark.glyph));
        record.insert(u"tile"_s, text(mark.tile));
        record.insert(u"ink"_s, text(mark.ink));
        record.insert(u"providerMark"_s, static_cast<int>(mark.provider));
      } else if (kind == application::components::ElementKind::canvas) {
        record.insert(u"operations"_s, canvasOperations(rendered, element, theme, ink));
      }
    }
  }

  ElementSlots::ElementSlots(ConfigurationSource& source, Context context, QObject* parent)
      : QObject(parent),
        source_(source),
        context_(std::move(context)) {
    // Results of one Lua pass arrive close together; project them once.
    settle_.setSingleShot(true);
    settle_.setInterval(0);
    connect(&settle_, &QTimer::timeout, this, [this] {
      ++revision_;
      contentChanged();
    });
  }

  bool ElementSlots::configured(application::components::Slot slot) const noexcept {
    const auto* definitions = source_.definitions();

    return definitions != nullptr && definitions->slot(slot) != LUA_NOREF;
  }

  bool ElementSlots::active() const noexcept {
    const auto* definitions = source_.definitions();

    return definitions != nullptr && definitions->drawsAny();
  }

  void ElementSlots::adopt(std::uint64_t generation) {
    if (generation == generation_) {
      return;
    }

    generation_ = generation;
    ++epoch_;
    ++revision_;
    instances_.clear();
  }

  void ElementSlots::begin(std::span<const application::components::Slot> family) {
    for (auto& instance : instances_) {
      if (std::ranges::find(family, instance.slot) != family.end()) {
        instance.seen = false;
      }
    }
  }

  std::uint64_t ElementSlots::revision() const noexcept {
    return revision_;
  }

  std::uint64_t ElementSlots::identity(application::components::Slot slot, const QString& key) noexcept {
    return qHash(key, static_cast<std::size_t>(slot) + 1);
  }

  QVariantMap ElementSlots::attach(application::components::Slot slot, const QString& key, const QVariantMap& item) {
    if (!configured(slot)) {
      return {};
    }

    const auto id = identity(slot, key);
    auto& instance = instances_[id];
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
    const auto& current = *instances_.constFind(id);
    if (current.failures >= failure_limit || !current.rendered) {
      return {};
    }

    return {
        {u"slot"_s, QString::fromLatin1(application::components::slot_names[static_cast<std::size_t>(slot)].data(), static_cast<qsizetype>(application::components::slot_names[static_cast<std::size_t>(slot)].size()))},
        {u"key"_s, key},
        {u"revision"_s, QString::number(current.revision)},
        {u"nodes"_s, current.nodes},
        {u"error"_s, current.error},
    };
  }

  QVariantMap ElementSlots::elements(std::span<const application::components::Slot> family, const QString& key, const QVariantMap& item) {
    if (!active()) {
      return {};
    }

    QVariantMap result;

    for (const auto slot : family) {
      auto content = attach(slot, key, item);
      if (!content.isEmpty()) {
        const auto name = application::components::slot_names[static_cast<std::size_t>(slot)];

        result.insert(QString::fromLatin1(name.data(), static_cast<qsizetype>(name.size())), std::move(content));
      }
    }

    return result;
  }

  void ElementSlots::finish(std::span<const application::components::Slot> family) {
    for (auto iterator = instances_.begin(); iterator != instances_.end();) {
      if (iterator->seen || std::ranges::find(family, iterator->slot) == family.end()) {
        ++iterator;
        continue;
      }

      source_.forgetElements(iterator->id);
      iterator = instances_.erase(iterator);
    }
  }

  const ElementSlots::Instance* ElementSlots::find(QStringView slot, const QString& key) const {
    const auto* const found = std::ranges::find_if(application::components::slot_names, [&](std::string_view name) {
      return slot == QLatin1StringView{name.data(), static_cast<qsizetype>(name.size())};
    });
    if (found == application::components::slot_names.end()) {
      return nullptr;
    }

    const auto entry = instances_.constFind(identity(static_cast<application::components::Slot>(found - application::components::slot_names.begin()), key));

    return entry == instances_.cend() ? nullptr : &*entry;
  }

  bool ElementSlots::owns(const application::components::ResolvedActions<ApplicationAllocator>& actions) const noexcept {
    return std::ranges::any_of(instances_, [&](const Instance& instance) {
      return instance.rendered && &instance.rendered->actions == &actions;
    });
  }

  void ElementSlots::invalidate() {
    ++revision_;
    // A render may finish at once and change its instance, so each is found again by its id.
    for (const auto id : instances_.keys()) {
      auto& instance = *instances_.find(id);

      instance.dirty = true;
      if (!instance.rendering && instance.failures < failure_limit) {
        render(id);
      }
    }
  }

  void ElementSlots::render(std::uint64_t id) {
    auto& instance = *instances_.find(id);

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

        auto& current = *found;

        current.rendering = false;
        if (outcome.stale) {
          return;
        }

        const bool succeeded = outcome.value.hasValue();

        if (succeeded) {
          current.failures = 0;
          current.error.clear();
          current.rendered = std::move(outcome.value.getMut()).intoShared();
          current.nodes = project(*current.rendered, source_.configuration().theme);
          current.revision = ++next_revision_;
        } else {
          current.error = outcome.error;
          ++current.failures;
        }

        if (!succeeded && current.failures == failure_limit) {
          failed(u"components.%1 failed %2 times and fell back to the built-in piece: %3"_s.arg(text(application::components::slot_names[static_cast<std::size_t>(current.slot)])).arg(failure_limit).arg(outcome.error));
        }

        if (current.dirty && current.failures < failure_limit) {
          render(id);
        }

        settle_.start();
      });
    } catch (const std::exception& error) {
      if (const auto found = instances_.find(id); found != instances_.end()) {
        found->rendering = false;
        found->error = QString::fromUtf8(error.what());
      }
    }
  }

  QVariantList ElementSlots::project(const Rendered& rendered, const Theme& theme) {
    constexpr ds::Array tones{PaletteRole::text, PaletteRole::subtext0, PaletteRole::accent, PaletteRole::green, PaletteRole::yellow, PaletteRole::red};
    QVariantList result;

    result.reserve(static_cast<qsizetype>(rendered.elements.size()));
    for (std::size_t index = 0; index < rendered.elements.size(); ++index) {
      const auto& element = rendered.elements[index];
      const auto kind = element.kind;
      const auto ink = theme.chromeColor(tones[static_cast<std::size_t>(element.tone)]);
      QVariantMap record{
          {u"index"_s, static_cast<int>(index)},
          {u"parent"_s, element.parent == application::components::Element::none ? -1 : static_cast<int>(element.parent)},
          {u"kind"_s, QString::fromLatin1(application::components::element_kind_names[static_cast<std::size_t>(kind)])},
          {u"key"_s, text(rendered.view(element.key))},
          {u"text"_s, text(rendered.view(element.text))},
          {u"tooltip"_s, text(rendered.view(element.tooltip))},
          {u"padding"_s, QVariantList{element.padding[0], element.padding[1], element.padding[2], element.padding[3]}},
          {u"gap"_s, element.gap},
          {u"width"_s, element.width},
          {u"height"_s, element.height},
          {u"minWidth"_s, element.min_width},
          {u"minHeight"_s, element.min_height},
          {u"grow"_s, element.grow},
          {u"x"_s, element.x},
          {u"y"_s, element.y},
          {u"rotation"_s, element.rotation},
          {u"scale"_s, element.scale},
          {u"opacity"_s, element.opacity},
          {u"z"_s, element.z},
          {u"transition"_s, element.transition_ms},
          {u"easing"_s, element.easing},
          {u"radius"_s, element.radius},
          {u"borderWidth"_s, element.border_width},
          {u"background"_s, paint(element.background, theme)},
          {u"border"_s, paint(element.border, theme)},
          {u"hover"_s, paint(element.hover, theme)},
          {u"color"_s, paint(element.color, theme, ink)},
          {u"align"_s, element.align},
          {u"justify"_s, element.justify},
          {u"sizeRole"_s, element.size_role},
          {u"size"_s, element.size},
          {u"bold"_s, element.bold},
          {u"italic"_s, element.italic},
          {u"maxLines"_s, element.max_lines},
          {u"clip"_s, element.clip},
          {u"shadow"_s, element.shadow},
          {u"action"_s, element.action == application::components::Element::none ? -1 : static_cast<int>(element.action)},
          {u"callback"_s, element.callback == application::components::Element::none ? -1 : static_cast<int>(element.callback)},
          {u"url"_s, text(rendered.view(element.url))},
          {u"since"_s, static_cast<qint64>(element.since)},
      };

      record.insert(u"clickable"_s, element.action != application::components::Element::none || element.callback != application::components::Element::none || element.url.length != 0);
      if (element.max_width >= 0) {
        record.insert(u"maxWidth"_s, element.max_width);
      }

      if (element.max_height >= 0) {
        record.insert(u"maxHeight"_s, element.max_height);
      }

      if (element.align_self) {
        record.insert(u"alignSelf"_s, *element.align_self);
      }

      addKindFields(record, rendered, element, theme, ink);

      result.append(std::move(record));
    }

    return result;
  }

  QVariantMap ElementSlots::tabItem(const QVariantMap& record, int position) {
    QVariantList panes;

    for (const auto& entry : record.value(u"cards"_s).toList()) {
      const auto card = entry.toMap();

      panes.append(QVariantMap{
          {u"key"_s, card.value(u"key"_s)},
          {u"program"_s, card.value(u"program"_s)},
          {u"focused"_s, card.value(u"focused"_s)},
          {u"attention"_s, !card.value(u"attentionColor"_s).toString().isEmpty()},
      });
    }

    return {
        {u"index"_s, position + 1},
        {u"key"_s, record.value(u"key"_s)},
        {u"title"_s, record.value(u"title"_s)},
        {u"label"_s, record.value(u"label"_s)},
        {u"path"_s, record.value(u"path"_s)},
        {u"application"_s, record.value(u"application"_s)},
        {u"selected"_s, record.value(u"selected"_s)},
        {u"attention"_s, !record.value(u"attentionColor"_s).toString().isEmpty()},
        {u"panes"_s, panes},
    };
  }

  QVariantMap ElementSlots::paneItem(const QVariantMap& pane, const QVariantMap& chrome) {
    QVariantMap item{
        {u"id"_s, pane.value(u"key"_s)},
        {u"index"_s, chrome.value(u"index"_s).toInt()},
        {u"program"_s, chrome.value(u"program"_s)},
        {u"context"_s, chrome.value(u"context"_s)},
        {u"focused"_s, pane.value(u"focused"_s)},
        {u"fullscreen"_s, pane.value(u"fullscreen"_s)},
        {u"images_paused"_s, chrome.value(u"imagesPaused"_s)},
        {u"needs_attention"_s, chrome.value(u"needsAttention"_s)},
        {u"progress"_s, chrome.value(u"progressText"_s)},
    };

    const auto agent = chrome.value(u"agent"_s).toMap();
    if (!agent.isEmpty()) {
      item.insert(u"agent"_s, QVariantMap{
                                  {u"status"_s, statusName(agent.value(u"statusCode"_s))},
                                  {u"blocked_reason"_s, agent.value(u"blockedReason"_s)},
                              });
    }

    return item;
  }

  QVariantMap ElementSlots::agentItem(const QVariantMap& record) {
    return {
        {u"key"_s, record.value(u"key"_s)},
        {u"title"_s, record.value(u"title"_s)},
        {u"project"_s, record.value(u"project"_s)},
        {u"detail"_s, record.value(u"detail"_s)},
        {u"provider"_s, record.value(u"provider"_s)},
        {u"status"_s, statusName(record.value(u"statusCode"_s))},
        {u"selected"_s, record.value(u"selected"_s)},
        {
            u"plan"_s,
            QVariantMap{
                {u"done"_s, record.value(u"planDone"_s)},
                {u"total"_s, record.value(u"planTotal"_s)},
                {u"step"_s, record.value(u"planStep"_s)},
            },
        },
    };
  }

}
