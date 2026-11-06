#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "configuration_source.hpp"
#include "appearance.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <utility>
#include <string_view>
#include "../application/dependencies.hpp"
#include <array>
#include <optional>
#include "telar_client/serializers/telar_cells.hpp"
#include <cstddef>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <string>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include "telar_base/text/utf8.hpp"
#include <tuple>
#include "../core/memory.hpp"
#include <bit>
#include "telar_client/codecs/telar_wire.hpp"
#include <functional>
#include <type_traits>

#include "telar_client/serializers/telar_frame.hpp"
#include "gui_config_bootstrap.hpp"

#include <limits.h>
#include <sys/stat.h>
#include "telar_config/graphics/limits.hpp"
#include <arpa/inet.h>
#include "telar_config/terminal/control/policy.hpp"
#include <format>
#include <ghostty/vt/unicode.h>
#include <exception>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include "configuration_loader.hpp"
#include "font_resolver.hpp"
#include "../platform/window.hpp"
#include <QByteArray>
#include <QFileInfo>
#include <QFuture>
#include <QGuiApplication>
#include <QList>
#include <QPointer>
#include <QStyleHints>
#include <QtConcurrentRun>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtimer.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>

#include "application/dependencies.hpp"
#include "platform/window.hpp"


import telar.gui.application.host_effects;
import telar.gui.components.configuration;
import telar.gui.components.builtin_content;
import telar.gui.config.plugin_query;
import telar.gui.config.plugin_effects;
import telar.gui.config.gui_query;
import telar.gui.config.generation;
import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;
import telar.gui.input.key_encoder;
import telar.gui.presentation.suggestion_geometry;
import telar.config;
import telar.plugins;



namespace telar::gui::qt {

namespace {

std::optional<std::string_view> optionalText(const QByteArray &bytes) noexcept {
  if (bytes.isEmpty()) {
    return std::nullopt;
  }

  return std::string_view{bytes.constData(), static_cast<std::size_t>(bytes.size())};
}

}

static_assert(ConcurrentAllocator<ApplicationAllocator>);

ConfigurationSource::ConfigurationSource(ApplicationAllocator &memory, QObject *parent)
    : QObject(parent),
      memory_(memory),
      fonts_(memory),
      default_keymap_(default_input_.compile()),
      generation_(nullptr, AllocationDeleter<ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator>{memory}) {
  debounce_.setSingleShot(true);
  constexpr int reload_debounce_ms = 100;
  debounce_.setInterval(reload_debounce_ms);
  constexpr int dependency_poll_ms = 1000;
  poll_.setInterval(dependency_poll_ms);
  connect(&poll_, &QTimer::timeout, this, &ConfigurationSource::poll);
  connect(&debounce_, &QTimer::timeout, this, &ConfigurationSource::reload);
  connect(&task_, &QFutureWatcher<PreparedConfiguration>::finished, this, &ConfigurationSource::complete);
  configuration_.themes.base = default_theme_values;
  configuration_.theme = projectTheme(configuration_.themes.base);
  const auto *style_hints = QGuiApplication::styleHints();
  appearance_ = hostAppearance(style_hints->colorScheme());
  connect(style_hints, &QStyleHints::colorSchemeChanged, this, [this](Qt::ColorScheme scheme) {
    updateAppearance(hostAppearance(scheme));
  });
}

ConfigurationSource::~ConfigurationSource() {
  auto future = task_.future();
  if (!future.isValid()) {
    return;
  }

  try {
    future.waitForFinished();
    if (future.isValid() && future.resultCount() != 0) {
      static_cast<void>(future.takeResult());
    }
  } catch (const std::exception &error) {
    qWarning("Configuration worker failed during shutdown: %s", error.what());
  }
}

const InputConfiguration &ConfigurationSource::input() const noexcept {
  return generation_ ? generation_->input() : default_input_;
}

const components::Configuration *ConfigurationSource::components() const noexcept {
  return generation_ ? &generation_->components() : nullptr;
}

void ConfigurationSource::renderBar(components::Position position, const components::Context &context) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  generation_->renderBar(position, context);
}

void ConfigurationSource::renderPanel(std::size_t index, const components::Context &context) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  generation_->renderPanel(index, context);
}

void ConfigurationSource::closePanel() noexcept {
  if (generation_) {
    generation_->closePanel();
  }
}

void ConfigurationSource::renderPick(std::size_t index, const components::Context &context, components::PickItems &items) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  generation_->renderPick(index, context, items);
}

QList<QByteArray> ConfigurationSource::commandArguments(int reference, const char *field) const {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  QList<QByteArray> result;
  generation_->visitArguments(reference, field, [&](std::string_view argument) {
    result.append(QByteArray{argument.data(), static_cast<qsizetype>(argument.size())});
  });

  return result;
}

std::optional<DefinitionActionDescription> ConfigurationSource::definitionAction(BindingAction action) const {
  return generation_ ? generation_->definitionAction(action) : std::nullopt;
}

std::optional<NamedActionDescription> ConfigurationSource::namedAction(BindingAction action) const {
  return generation_ ? generation_->namedAction(action) : std::nullopt;
}

std::uint64_t ConfigurationSource::configurationGeneration() const noexcept {
  return generation_ ? generation_->number() : 0;
}

std::optional<PluginActionDescription> ConfigurationSource::pluginAction(BindingAction action) const {
  return generation_ ? generation_->pluginAction(action) : std::nullopt;
}

PluginInvocation ConfigurationSource::pluginInvocation(const ClientCommand &request, BindingContext context) const {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  if (!plugins_) {
    throw std::runtime_error{"PluginRegistryUnavailable"};
  }

  const PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages()};
  const auto *package = catalog.package(catalog.find(request.text));
  if (package == nullptr) {
    throw std::runtime_error{"PluginDisabled"};
  }

  return pluginInvocation(PluginActionDescription{.plugin = runtime::plugins::stableId(package->manifest.id.view()), .action = request.target_id}, context);
}

PluginInvocation ConfigurationSource::pluginInvocation(PluginActionDescription action, BindingContext context) const {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  if (!plugins_) {
    throw std::runtime_error{"PluginRegistryUnavailable"};
  }

  const auto packages = plugins_->packages();
  const PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), packages};
  const auto &package = catalog.resolve(action);
  for (const auto &name : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
    if (runtime::plugins::stableId(name.view()) == action.action) {
      return {.package = package, .action = name, .context = context, .configuration_generation = generation_->number(), .package_index = static_cast<std::size_t>(&package - packages.data())};
    }
  }

  throw std::invalid_argument{"UnknownPluginAction"};
}

void ConfigurationSource::authorizePlugin(const PluginInvocation &invocation, const PluginEffects &effects) const {
  if (!generation_ || generation_->number() != invocation.configuration_generation) {
    throw std::runtime_error{"StalePluginWorker"};
  }

  if (!plugins_ || invocation.package_index >= plugins_->packages().size()) {
    throw std::runtime_error{"PluginNotConfigured"};
  }

  const auto &package = plugins_->packages()[invocation.package_index];
  if (package.manifest.id.view() != invocation.package.manifest.id.view() || package.digest != invocation.package.digest) {
    throw std::runtime_error{"StalePluginWorker"};
  }

  effects.authorize(package, trust_);
}

const BindingMap<BindingAction> &ConfigurationSource::keymap() const noexcept {
  return generation_ ? generation_->keymap() : default_keymap_;
}

BindingEffects ConfigurationSource::invoke(BindingAction action, BindingContext context) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  try {
    const auto effects = generation_->invoke(action, context);
    trackModules();

    return effects;
  } catch (...) {
    trackModules();
    throw;
  }
}

InputExpression ConfigurationSource::expression(BindingAction action, BindingContext context) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  try {
    auto expression = generation_->expression(action, context);
    trackModules();

    return expression;
  } catch (...) {
    trackModules();
    throw;
  }
}

std::optional<runtime::config::CommandTabView> ConfigurationSource::commandTab(BindingAction action) const {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  return generation_->commandTab(action);
}

std::optional<NotificationActionDescription> ConfigurationSource::notificationAction(BindingAction action) const {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  return generation_->notificationAction(action);
}

void ConfigurationSource::open(const ConfigurationSelection &selection) {
  debounce_.stop();
  poll_.stop();
  watch_ = {};
  loaded_ = false;
  pending_poll_ = false;
  pending_reload_ = false;
  ++revision_;
  path_ = selection.path.isEmpty() ? QString{} : QFileInfo{selection.path}.absoluteFilePath();
  profile_ = selection.profile;
  source_path_ = selection.path.toUtf8();
  profile_name_ = selection.profile.toUtf8();
  theme_ = selection.theme;
  trust_path_ = selection.trust_path.isEmpty() ? QString{} : QFileInfo{selection.trust_path}.absoluteFilePath();
  const QPointer<ConfigurationSource> lifetime{this};

  try {
    adopt(ConfigurationLoader::prepare(memory_, request(true)));
  } catch (const std::exception &error) {
    fail(error);
  }

  if (lifetime != nullptr && !path_.isEmpty()) {
    poll_.start();
  }
}

void ConfigurationSource::requestReload() {
  if (!loaded_ || path_.isEmpty()) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  ++revision_;
  debounce_.start();
}

const Configuration &ConfigurationSource::configuration() const noexcept {
  return configuration_;
}

ResolvedFont ConfigurationSource::resolveFont(const FontConfiguration &font, qreal scale) {
  return fonts_.resolve(font, scale);
}

QString ConfigurationSource::error() const {
  return error_;
}

std::string_view ConfigurationSource::query(ConfigurationQuery query, const ClientViewState &view) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  if (query.section != ConfigurationQuery::Section::client && query.index < 0) {
    throw std::invalid_argument{"InvalidIndex"};
  }

  switch (query.section) {
  case ConfigurationQuery::Section::client: {
    const ClientQueryContext context{
        .source = optionalText(source_path_),
        .profile = optionalText(profile_name_),
        .generation = generation_->number(),
        .view = view,
    };

    return ClientQuery::write(generation_->configuration(), context, query_buffer_);
  }
  case ConfigurationQuery::Section::binding:
    if (!std::in_range<std::size_t>(query.index)) {
      throw std::runtime_error{"BindingNotFound"};
    }

    return BindingQuery::write(generation_->input(), static_cast<std::size_t>(query.index), generation_->actionDescriptions(), generation_->commandTabs(), query_buffer_);
  case ConfigurationQuery::Section::runtime:
    return RuntimeQuery::write(generation_->runtimeValues(), query_buffer_);
  case ConfigurationQuery::Section::gui:
    return GuiQuery::write(generation_->configuration(), query_buffer_, platform::defaultTitlebar());
  case ConfigurationQuery::Section::input:
    return InputQuery::write(generation_->input(), query_buffer_);
  case ConfigurationQuery::Section::theme:
    return ThemeQuery::write(generation_->configuration().themes, query_buffer_);
  default:
    throw std::runtime_error{"ConfigurationSectionUnavailable"};
  }
}

PluginPage ConfigurationSource::queryPlugins(const ClientCommand &request) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  if (!plugins_) {
    throw std::runtime_error{"PluginRegistryUnavailable"};
  }

  const PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages(), &plugin_overrides_};
  if (request.action == ClientAction::plugin_list) {
    return PluginQuery::list(catalog, request, query_buffer_);
  }

  return PluginQuery::get(catalog, request, query_buffer_);
}

void ConfigurationSource::setPluginEnabled(const ClientCommand &request, bool enabled) {
  if (!generation_) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  if (!plugins_) {
    throw std::runtime_error{"PluginRegistryUnavailable"};
  }

  if (!loaded_ || path_.isEmpty() || trust_path_.isEmpty()) {
    throw std::runtime_error{"ConfigurationNotLoaded"};
  }

  const PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages()};
  const auto index = catalog.find(request.text);
  auto specification = catalog.specification(index);
  specification.enabled = enabled;
  const auto *package = catalog.package(index);
  plugin_overrides_.set(specification, package == nullptr ? std::nullopt : std::optional{runtime::plugins::stableId(package->manifest.id.view())});
  requestReload();
}

void ConfigurationSource::poll() {
  if (!debounce_.isActive() && !path_.isEmpty()) {
    schedule(false);
  }
}

void ConfigurationSource::trackModules() {
  if (generation_ && generation_->localModuleCount() != static_cast<std::size_t>(watch_.modules.size())) {
    ConfigurationLoader::trackModules(*generation_, module_root_, watch_.modules);
  }
}

ConfigurationReloadRequest ConfigurationSource::request(bool force) {
  return {.selection = {.path = path_, .profile = profile_, .theme = theme_, .trust_path = trust_path_}, .watch = watch_, .plugin_overrides = plugin_overrides_, .revision = revision_, .generation = next_generation_, .force = force};
}

void ConfigurationSource::schedule(bool force) {
  if (busy_) {
    pending_reload_ = pending_reload_ || force;
    pending_poll_ = pending_poll_ || !force;

    return;
  }

  try {
    auto work = request(force);
    active_revision_ = work.revision;

    const auto future = QtConcurrent::run([memory = &memory_, work = std::move(work)] {
      return ConfigurationLoader::prepare(*memory, work);
    });

    busy_ = true;
    task_.setFuture(future);
  } catch (const std::exception &error) {
    busy_ = false;
    fail(error);
  }
}

void ConfigurationSource::complete() {
  busy_ = false;
  const auto completed_revision = active_revision_;
  const QPointer<ConfigurationSource> lifetime{this};

  try {
    adopt(task_.future().takeResult());
  } catch (const std::exception &error) {
    if (completed_revision == revision_) {
      fail(error);
    }
  }

  if (lifetime == nullptr || busy_ || debounce_.isActive()) {
    return;
  }

  if (std::exchange(pending_reload_, false)) {
    pending_poll_ = false;
    schedule(true);
  } else if (std::exchange(pending_poll_, false)) {
    schedule(false);
  }
}

void ConfigurationSource::adopt(PreparedConfiguration result) {
  if (!result || result->revision != revision_) {
    return;
  }

  watch_.root = result->observed.root;
  watch_.trust = result->observed.trust;
  for (auto iterator = result->observed.modules.cbegin(); iterator != result->observed.modules.cend(); ++iterator) {
    const auto found = watch_.modules.find(iterator.key());
    if (found != watch_.modules.end() && found->path == iterator->path) {
      found->stamp = iterator->stamp;
    }
  }

  switch (result->state) {
  case ConfigurationPreparation::State::unchanged:
    return;
  case ConfigurationPreparation::State::failed:
    error_ = std::move(result->error);
    result.reset();
    emit failed();

    return;
  case ConfigurationPreparation::State::ready:
    break;
  }

  static_cast<void>(fonts_.resolve(result->configuration.font, 1));
  configuration_ = std::move(result->configuration);
  locked_theme_ = result->locked_theme;
  configuration_.theme = projectTheme(configuration_.themes.resolve(appearance_, locked_theme_));
  generation_ = std::move(result->generation);
  plugins_ = std::move(result->plugins);
  trust_ = result->trust;
  if (generation_) {
    next_generation_ = generation_->number() + 1;
  }
  module_root_ = std::move(result->directory);
  watch_.modules = std::move(result->modules);
  loaded_ = !path_.isEmpty();
  error_.clear();
  result.reset();
  emit changed();
}

void ConfigurationSource::reload() {
  schedule(true);
}

void ConfigurationSource::fail(const std::exception &error) {
  error_ = QString::fromUtf8(error.what());
  emit failed();
}

void ConfigurationSource::updateAppearance(Appearance appearance) {
  appearance_ = appearance;
  const auto selected = projectTheme(configuration_.themes.resolve(appearance_, locked_theme_));
  if (selected == configuration_.theme) {
    return;
  }

  configuration_.theme = selected;
  emit themeChanged();
}

}
