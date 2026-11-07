#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application.hpp"
#include "configuration_source.hpp"
#include "element_slots.hpp"
#include <array>
#include <cstddef>
#include <exception>
#include <stdexcept>
#include <QString>
#include <QStringLiteral>
#include <QVariantList>
#include <QVariantMap>

import telar.gui.components.builtin_content;
import telar.gui.components.configuration;
import telar.gui.links.cell_links;

namespace telar::gui::qt {

namespace {

QString slotName(components::Slot slot) {
  const auto name = components::slot_names[static_cast<std::size_t>(slot)];

  return QString::fromLatin1(name.data(), static_cast<qsizetype>(name.size()));
}

QString statusName(const QVariant &code) {
  constexpr std::array names{"unknown", "working", "blocked", "ready", "failed", "done"};
  const auto index = code.toInt();

  return QString::fromLatin1(index >= 0 && static_cast<std::size_t>(index) < names.size() ? names[static_cast<std::size_t>(index)] : names.front());
}

}

void Application::initializeElements() {
  // Layout changes share this signal; only a new Lua generation owns new functions.
  connect(this, &Application::configurationChanged, this, [this] {
    element_slots_.adopt(configuration_source_.configurationGeneration());
  });
  connect(&configuration_source_, &ConfigurationSource::themeChanged, this, [this] {
    element_slots_.invalidate();
  });
  connect(&element_slots_, &ElementSlots::contentChanged, this, [this] {
    // Agent records skip unchanged activity; mod content is a change of its own.
    activity_versions_ = {};
    refresh();
  });
  connect(&element_slots_, &ElementSlots::failed, this, [this](const QString &message) {
    fail(std::runtime_error{message.toStdString()});
  });
}

QVariantMap Application::elementsFor(std::initializer_list<components::Slot> pieces, const QString &key, const QVariantMap &item) {
  if (!element_slots_.active()) {
    return {};
  }

  QVariantMap result;
  for (const auto slot : pieces) {
    auto content = element_slots_.attach(slot, key, item);
    if (!content.isEmpty()) {
      result.insert(slotName(slot), std::move(content));
    }
  }

  return result;
}

void Application::refreshElementBars() {
  if (!element_slots_.active()) {
    element_bars_.clear();
    return;
  }

  const QVariantMap item{
      {QStringLiteral("workspace"), workspace_context_.value(QStringLiteral("name"))},
      {QStringLiteral("machine"), machineContext().value(QStringLiteral("label"))},
      {QStringLiteral("tab_count"), tabs_.rowCount()},
      {QStringLiteral("sidebar_visible"), sidebarVisible()},
  };
  element_bars_ = elementsFor({components::Slot::top_bar, components::Slot::bottom_bar}, QStringLiteral("window"), item);
}

QVariantMap Application::elementBars() const {
  return element_bars_;
}

QVariantMap ElementSlots::tabItem(const QVariantMap &record, int position) {
  QVariantList panes;
  for (const auto &entry : record.value(QStringLiteral("cards")).toList()) {
    const auto card = entry.toMap();
    panes.append(QVariantMap{
        {QStringLiteral("key"), card.value(QStringLiteral("key"))},
        {QStringLiteral("program"), card.value(QStringLiteral("program"))},
        {QStringLiteral("focused"), card.value(QStringLiteral("focused"))},
        {QStringLiteral("attention"), !card.value(QStringLiteral("attentionColor")).toString().isEmpty()},
    });
  }

  return {
      {QStringLiteral("index"), position + 1},
      {QStringLiteral("key"), record.value(QStringLiteral("key"))},
      {QStringLiteral("title"), record.value(QStringLiteral("title"))},
      {QStringLiteral("label"), record.value(QStringLiteral("label"))},
      {QStringLiteral("path"), record.value(QStringLiteral("path"))},
      {QStringLiteral("application"), record.value(QStringLiteral("application"))},
      {QStringLiteral("selected"), record.value(QStringLiteral("selected"))},
      {QStringLiteral("attention"), !record.value(QStringLiteral("attentionColor")).toString().isEmpty()},
      {QStringLiteral("panes"), panes},
  };
}

QVariantMap ElementSlots::paneItem(const QVariantMap &pane, const QVariantMap &chrome) {
  QVariantMap item{
      {QStringLiteral("id"), pane.value(QStringLiteral("key"))},
      {QStringLiteral("index"), chrome.value(QStringLiteral("index")).toInt()},
      {QStringLiteral("program"), chrome.value(QStringLiteral("program"))},
      {QStringLiteral("context"), chrome.value(QStringLiteral("context"))},
      {QStringLiteral("focused"), pane.value(QStringLiteral("focused"))},
      {QStringLiteral("fullscreen"), pane.value(QStringLiteral("fullscreen"))},
      {QStringLiteral("images_paused"), chrome.value(QStringLiteral("imagesPaused"))},
      {QStringLiteral("needs_attention"), chrome.value(QStringLiteral("needsAttention"))},
      {QStringLiteral("progress"), chrome.value(QStringLiteral("progressText"))},
  };
  const auto agent = chrome.value(QStringLiteral("agent")).toMap();
  if (!agent.isEmpty()) {
    item.insert(QStringLiteral("agent"), QVariantMap{
                                             {QStringLiteral("status"), statusName(agent.value(QStringLiteral("statusCode")))},
                                             {QStringLiteral("blocked_reason"), agent.value(QStringLiteral("blockedReason"))},
                                         });
  }

  return item;
}

QVariantMap ElementSlots::agentItem(const QVariantMap &record) {
  return {
      {QStringLiteral("key"), record.value(QStringLiteral("key"))},
      {QStringLiteral("title"), record.value(QStringLiteral("title"))},
      {QStringLiteral("project"), record.value(QStringLiteral("project"))},
      {QStringLiteral("detail"), record.value(QStringLiteral("detail"))},
      {QStringLiteral("provider"), record.value(QStringLiteral("provider"))},
      {QStringLiteral("status"), statusName(record.value(QStringLiteral("statusCode")))},
      {QStringLiteral("selected"), record.value(QStringLiteral("selected"))},
      {QStringLiteral("compact"), record.value(QStringLiteral("compact"))},
      {QStringLiteral("depth"), record.value(QStringLiteral("depth"))},
      {QStringLiteral("plan"), QVariantMap{
                                   {QStringLiteral("done"), record.value(QStringLiteral("planDone"))},
                                   {QStringLiteral("total"), record.value(QStringLiteral("planTotal"))},
                                   {QStringLiteral("step"), record.value(QStringLiteral("planStep"))},
                               }},
  };
}

void Application::activateElement(const QString &slot, const QString &key, const QString &revision, int element) {
  const auto *instance = element_slots_.find(slot, key);
  if (instance == nullptr || !instance->rendered || QString::number(instance->revision) != revision || element < 0 || static_cast<std::size_t>(element) >= instance->rendered->elements.size()) {
    return;
  }

  // Hold the content: a render may replace the instance while the click runs.
  const auto rendered = instance->rendered;
  const auto &node = rendered->elements[static_cast<std::size_t>(element)];
  try {
    if (node.callback != components::Element::none) {
      const auto hold = key_bindings_.hold();
      configuration_source_.invokeElement(instance->id, node.callback, componentContext(), instance->item, [this, hold](LuaOutcome<ConfigurationSource::Effects> outcome) {
              luaBindingFinished(hold, outcome.stale, outcome.error, [&] {
          applyEffects(**outcome.value);
        });
        // The function may have changed state any slot reads.
        element_slots_.invalidate();
      });
    } else if (node.action != components::Element::none && node.action < rendered->bindings.size()) {
      static_cast<void>(runBinding(rendered->bindings[node.action], &rendered->actions));
    } else if (const auto url = rendered->view(node.url); !url.empty()) {
      if (const auto target = LinkTarget::fromUri(url)) {
        static_cast<void>(openLink(*target));
      }
    }
  } catch (const std::exception &error) {
    fail(error);
  }
}

}
