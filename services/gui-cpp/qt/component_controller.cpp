#include "application.hpp"
#include "application/host_metrics.hpp"
#include "application/records.hpp"
#include "component_projection.hpp"
#include "component_surface_state.hpp"
#include "components/builtin_content.hpp"
#include "components/clock.hpp"
#include "components/configuration.hpp"
#include "components/content.hpp"
#include "components/invocation.hpp"
#include "components/node.hpp"
#include "components/source.hpp"
#include "configuration_source.hpp"
#include "links/link_target.hpp"
#include "machine_client.hpp"
#include "machine_client_key.hpp"
#include "projection.hpp"
#include "surface_command.hpp"
#include <QByteArray>
#include <QDateTime>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QPointF>
#include <QString>
#include <QStringLiteral>
#include <QTimer>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtmetamacros.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {

namespace {

using Clock = ComponentSlotState::Clock;

void registerComponentFonts() {
  static const bool ready = [] {
    constexpr std::array paths{":/telar/fonts/IBMPlexSans-Regular.ttf", ":/telar/fonts/IBMPlexSans-SemiBold.ttf", ":/telar/fonts/SymbolsNerdFontMono-Regular.ttf", ":/telar/fonts/JetBrainsMono-Regular.ttf"};
    for (const auto *const path : paths) {
      if (QFontDatabase::addApplicationFont(QString::fromLatin1(path)) < 0) {
        throw std::runtime_error{"Could not register a bundled UI font"};
      }
    }

    return true;
  }();
  static_cast<void>(ready);
}

ComponentSlotState &surfaceState(ComponentSurfaceState &state, std::size_t index, bool panel) {
  return panel ? state.panel : state.bars.at(index);
}

const components::Source &surfaceSource(const components::Configuration &configuration, std::size_t index, bool panel) {
  if (!panel) {
    return configuration.definitions().source(static_cast<components::Position>(index));
  }

  const auto panels = configuration.definitions().panels();
  if (index >= panels.size()) {
    throw std::out_of_range{"Panel is no longer configured"};
  }

  return panels[index].source;
}

QString commandError(SurfaceCommandFailure failure) {
  switch (failure) {
  case SurfaceCommandFailure::launch:
    return QStringLiteral("Could not launch command");
  case SurfaceCommandFailure::process:
    return QStringLiteral("Command failed");
  case SurfaceCommandFailure::timeout:
    return QStringLiteral("Command timed out");
  case SurfaceCommandFailure::cancelled:
    return QStringLiteral("Command cancelled");
  case SurfaceCommandFailure::invalid_output:
    return QStringLiteral("Command returned invalid text");
  }

  return {};
}

template <components::Capacity Bounds>
Clock::time_point nextClock(const components::Content<Bounds> &content) {
  constexpr auto second = std::chrono::milliseconds{1000};
  constexpr auto minute = second * 60;
  auto period = minute;
  bool found = false;
  for (const auto &node : content.nodes()) {
    if (node.kind == components::Kind::clock) {
      found = true;
      if (components::Clock::showsSeconds(content.text(node.text))) {
        period = second;
        break;
      }
    }
  }

  if (!found) {
    return Clock::time_point::max();
  }

  const auto wall = QDateTime::currentMSecsSinceEpoch();

  return Clock::now() + std::chrono::milliseconds{period.count() - (wall % period.count())};
}

}

void Application::initializeComponents() {
  registerComponentFonts();
  component_timer_.setSingleShot(true);
  connect(&component_timer_, &QTimer::timeout, this, &Application::tickComponents);
  connect(this, &Application::configurationChanged, this, &Application::resetComponents);
  connect(this, &Application::machineChanged, this, &Application::resetComponents);
  connect(this, &Application::dialogChanged, this, [this] {
    if (!dialog_.isEmpty() && component_surfaces_.open_panel) {
      closeComponentPanel();
    }
  });
  connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
    if (state == Qt::ApplicationActive) {
      projectComponents();
      tickComponents();
    }
  });
}

components::Context Application::componentContext() const {
  const auto local = QDateTime::currentDateTime();
  const auto date = local.date();
  const auto time = local.time();
  constexpr int days_per_week = 7;
  components::Context context;
  context.client = bindingContext();
  context.time = {
      .unix_seconds = local.toSecsSinceEpoch(),
      .year = static_cast<std::uint16_t>(date.year()),
      .month = static_cast<std::uint8_t>(date.month()),
      .day = static_cast<std::uint8_t>(date.day()),
      .hour = static_cast<std::uint8_t>(time.hour()),
      .minute = static_cast<std::uint8_t>(time.minute()),
      .second = static_cast<std::uint8_t>(time.second()),
      .weekday = static_cast<std::uint8_t>(date.dayOfWeek() % days_per_week),
  };
  const auto &sample = session().hostMetrics().sample();
  if (sample.revision != 0) {
    context.metrics = sample;
  }

  if (const auto *pane = session().focusedPane()) {
    context.pane_title = pane->title;
  }

  return context;
}

void Application::resetComponents() {
  component_command_.cancel();
  configuration_source_.closePanel();
  component_surfaces_ = {};
  component_surfaces_.generation = configuration_source_.configurationGeneration();
  const auto *configuration = configuration_source_.components();
  if (configuration != nullptr) {
    for (std::size_t index = 0; index < component_surfaces_.bars.size(); ++index) {
      auto &state = component_surfaces_.bars[index];
      state.revision = ++next_component_revision_;
      const auto kind = configuration->definitions().source(static_cast<components::Position>(index)).kind;
      if (kind == components::SourceKind::fixed || components::builtinSource(kind)) {
        projectComponentSource(index, false);
      }
    }
  }

  emit componentsChanged();
  component_timer_.start(std::chrono::milliseconds{0});
}

void Application::projectComponentSource(std::size_t index, bool panel) {
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr) {
    return;
  }

  auto &state = surfaceState(component_surfaces_, index, panel);
  const auto time = componentContext().time;
  if (panel) {
    state.nodes = componentRecords(configuration->panel(), configuration_source_.configuration().theme, time);
    state.clock_next = nextClock(configuration->panel());
  } else if (const auto kind = configuration->definitions().source(static_cast<components::Position>(index)).kind; components::builtinSource(kind)) {
    const auto content = components::builtinContent(kind);
    state.nodes = componentRecords(content, configuration_source_.configuration().theme, time);
    state.clock_next = Clock::time_point::max();
  } else {
    const auto &content = configuration->bar(static_cast<components::Position>(index));
    state.nodes = componentRecords(content, configuration_source_.configuration().theme, time);
    state.clock_next = nextClock(content);
  }

  state.revision = ++next_component_revision_;
}

void Application::projectComponents() {
  for (std::size_t index = 0; index < component_surfaces_.bars.size(); ++index) {
    projectComponentSource(index, false);
  }

  if (component_surfaces_.open_panel) {
    projectComponentSource(*component_surfaces_.open_panel, true);
  }

  emit componentsChanged();
}

bool Application::componentCommandCurrent(std::uint64_t generation, MachineClientKey source, std::uint64_t runtime) const {
  const auto *client = findClient(source);

  return generation == configuration_source_.configurationGeneration() && client != nullptr && client->key.machine.slot == machines_.active() && client->runtime_generation == runtime;
}

void Application::renderComponentSource(std::size_t index, bool panel) {
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr) {
    return;
  }

  const auto &source = surfaceSource(*configuration, index, panel);
  auto &state = surfaceState(component_surfaces_, index, panel);
  if (source.kind == components::SourceKind::command && component_command_.active()) {
    return;
  }

  state.next = source.interval ? Clock::now() + *source.interval : Clock::time_point::max();
  try {
    if (source.kind == components::SourceKind::dynamic) {
      applyComponentRender(index, panel, componentContext());
    } else if (source.kind == components::SourceKind::command) {
      const auto &client = clientAt(machines_.active());
      const ComponentCommandOwner owner{
          .index = index,
          .panel = panel,
          .generation = configuration_source_.configurationGeneration(),
          .panel_identity = component_surfaces_.panel_identity,
          .source = client.key,
          .runtime = client.runtime_generation,
      };
      SurfaceCommandRequest request;
      request.arguments = configuration_source_.commandArguments(source.reference, "command");
      request.timeout = source.timeout;
      request.output = source.has_render ? SurfaceOutputUse::lines : SurfaceOutputUse::line;
      component_command_owner_ = owner;
      component_command_.start(request, [this, owner](SurfaceCommandResult result) {
        componentCommandFinished(owner, std::move(result));
      });
    }
  } catch (const std::exception &error) {
    state.error = toQString(error.what());
  }

  emit componentsChanged();
}

void Application::applyComponentRender(std::size_t index, bool panel, const components::Context &context) {
  if (panel) {
    configuration_source_.renderPanel(index, context);
    component_surfaces_.last_render = QDateTime::currentDateTime().toString(QStringLiteral("HH:mm:ss"));
  } else {
    configuration_source_.renderBar(static_cast<components::Position>(index), context);
  }

  surfaceState(component_surfaces_, index, panel).error.clear();
  projectComponentSource(index, panel);
}

void Application::componentCommandFinished(const ComponentCommandOwner &owner, SurfaceCommandResult result) {
  component_command_owner_.reset();
  const bool same_panel = !owner.panel || (component_surfaces_.open_panel == owner.index && component_surfaces_.panel_identity == owner.panel_identity);
  if (!componentCommandCurrent(owner.generation, owner.source, owner.runtime) || !same_panel) {
    component_timer_.start(std::chrono::milliseconds{0});
    return;
  }

  auto &state = surfaceState(component_surfaces_, owner.index, owner.panel);
  try {
    if (result.failure) {
      state.error = commandError(*result.failure);
    } else {
      auto context = componentContext();
      context.output = std::string_view{result.output.constData(), static_cast<std::size_t>(result.output.size())};
      applyComponentRender(owner.index, owner.panel, context);
      if (result.truncated) {
        state.error = QStringLiteral("Command output exceeded its limit; showing what fits");
      }
    }
  } catch (const std::exception &error) {
    state.error = toQString(error.what());
  }

  emit componentsChanged();

  component_timer_.start(std::chrono::milliseconds{0});
}

void Application::tickComponents() {
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr) {
    return;
  }

  const auto now = Clock::now();
  bool rendered = false;
  const auto tick = [&](std::size_t index, bool panel) {
    const auto &state = surfaceState(component_surfaces_, index, panel);
    const auto &source = surfaceSource(*configuration, index, panel);
    if (state.clock_next <= now) {
      projectComponentSource(index, panel);
      emit componentsChanged();
    }

    const bool live = source.kind == components::SourceKind::dynamic || source.kind == components::SourceKind::command;
    if (!rendered && live && state.next <= now && (source.kind != components::SourceKind::command || !component_command_.active())) {
      rendered = true;
      renderComponentSource(index, panel);
    }
  };
  if (component_surfaces_.open_panel) {
    tick(*component_surfaces_.open_panel, true);
  }

  for (std::size_t index = 0; index < component_surfaces_.bars.size(); ++index) {
    tick(index, false);
  }

  armComponents();
}

void Application::armComponents() {
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr) {
    return;
  }

  auto next = Clock::time_point::max();
  const auto consider = [&](std::size_t index, bool panel) {
    const auto &state = surfaceState(component_surfaces_, index, panel);
    const auto &source = surfaceSource(*configuration, index, panel);
    next = std::min(next, state.clock_next);
    const bool live = source.kind == components::SourceKind::dynamic || source.kind == components::SourceKind::command;
    if (live && (source.kind != components::SourceKind::command || !component_command_.active())) {
      next = std::min(next, state.next);
    }
  };
  for (std::size_t index = 0; index < component_surfaces_.bars.size(); ++index) {
    consider(index, false);
  }

  if (component_surfaces_.open_panel) {
    consider(*component_surfaces_.open_panel, true);
  }

  if (next != Clock::time_point::max()) {
    const auto delay = std::max(std::chrono::milliseconds{0}, std::chrono::ceil<std::chrono::milliseconds>(next - Clock::now()));
    component_timer_.start(delay);
  }
}

QVariantMap Application::componentBars() const {
  constexpr std::array names{"left", "center", "right", "top", "footerLeft", "footerCenter", "footerRight"};
  constexpr std::array kinds{"empty", "tabs", "metrics", "machines", "content", "content", "content"};
  const components::Definitions defaults;
  const auto *configuration = configuration_source_.components();
  const auto &definitions = configuration == nullptr ? defaults : configuration->definitions();
  QVariantMap result;
  for (std::size_t index = 0; index < names.size(); ++index) {
    const auto &state = component_surfaces_.bars[index];
    result.insert(QString::fromLatin1(names[index]), QVariantMap{
                                                         {QStringLiteral("kind"), QString::fromLatin1(kinds[static_cast<std::size_t>(definitions.source(static_cast<components::Position>(index)).kind)])},
                                                         {QStringLiteral("source"), static_cast<int>(index)},
                                                         {QStringLiteral("nodes"), state.nodes},
                                                         {QStringLiteral("error"), state.error},
                                                         {QStringLiteral("generation"), QString::number(component_surfaces_.generation)},
                                                         {QStringLiteral("revision"), QString::number(state.revision)},
                                                     });
  }

  return result;
}

QVariantMap Application::componentPanel() const {
  const auto *configuration = configuration_source_.components();
  if (!component_surfaces_.open_panel || configuration == nullptr || *component_surfaces_.open_panel >= configuration->definitions().panels().size()) {
    return {{QStringLiteral("open"), false}};
  }

  const auto &definition = configuration->definitions().panels()[*component_surfaces_.open_panel];
  const auto &state = component_surfaces_.panel;

  return {
      {QStringLiteral("open"), true},
      {QStringLiteral("title"), toQString(definition.heading.title.view())},
      {QStringLiteral("width"), definition.width},
      {QStringLiteral("nodes"), state.nodes},
      {QStringLiteral("error"), state.error},
      {QStringLiteral("lastRender"), component_surfaces_.last_render},
      {QStringLiteral("generation"), QString::number(component_surfaces_.generation)},
      {QStringLiteral("revision"), QString::number(state.revision)},
      {QStringLiteral("source"), static_cast<int>(ComponentSurfaceState::bar_slots)},
      {QStringLiteral("anchor"), component_surfaces_.panel_anchor},
  };
}

void Application::toggleComponentPanel(std::size_t index) {
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr || index >= configuration->definitions().panels().size()) {
    return;
  }

  if (component_surfaces_.open_panel == index) {
    closeComponentPanel();
    return;
  }

  closeComponentPanel();
  component_surfaces_.open_panel = index;
  component_surfaces_.panel_anchor = component_action_anchor_.value_or(QPointF{-1, -1});
  component_surfaces_.panel_identity = ++next_component_revision_;
  component_surfaces_.panel.revision = component_surfaces_.panel_identity;
  component_timer_.start(std::chrono::milliseconds{0});
  emit componentsChanged();
}

void Application::closeComponentPanel() {
  if (component_command_owner_ && component_command_owner_->panel) {
    component_command_.cancel();
  }

  component_surfaces_.open_panel.reset();
  component_surfaces_.panel = {};
  component_surfaces_.last_render.clear();
  configuration_source_.closePanel();
  emit componentsChanged();
  armComponents();
}

void Application::refreshComponentPanel() {
  if (component_surfaces_.open_panel) {
    component_surfaces_.panel.next = Clock::now();
    component_timer_.start(std::chrono::milliseconds{0});
  }
}

void Application::activateComponent(int source, int node, const QString &generation, const QString &revision, const QPointF &anchor) {
  if (source < 0 || node < 0 || generation != QString::number(component_surfaces_.generation)) {
    return;
  }

  const auto index = static_cast<std::size_t>(source);
  const bool panel = index == ComponentSurfaceState::bar_slots;
  const auto *configuration = configuration_source_.components();
  if (configuration == nullptr || index > ComponentSurfaceState::bar_slots || (panel && !component_surfaces_.open_panel)) {
    return;
  }

  const auto &state = surfaceState(component_surfaces_, index, panel);
  if (revision != QString::number(state.revision)) {
    return;
  }

  const auto activate = [&](const auto &content) {
    if (static_cast<std::size_t>(node) >= content.nodes().size()) {
      return;
    }

    const auto &item = content.nodes()[static_cast<std::size_t>(node)];
    const auto url = content.text(item.url);
    if (!url.empty()) {
      if (const auto target = LinkTarget::fromUri(url)) {
        static_cast<void>(openLink(*target));
      }
    } else if (const auto action = content.action(item)) {
      const auto previous = std::exchange(component_action_anchor_, anchor);
      const auto restore = qScopeGuard([&] {
        component_action_anchor_ = previous;
      });
      static_cast<void>(runBinding(*action));
    }
  };
  if (panel) {
    activate(configuration->panel());
  } else {
    activate(configuration->bar(static_cast<components::Position>(index)));
  }
}

}
