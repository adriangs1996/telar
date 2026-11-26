#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "configuration_source.hpp"
#include "appearance.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <variant>

#include "configuration_loader.hpp"
#include "platform/window.hpp"
#include "ui/kit/fonts/font_resolver.hpp"
#include <QByteArray>
#include <QFileInfo>
#include <QFuture>
#include <QGuiApplication>
#include <QList>
#include <QPointer>
#include <QStringList>
#include <QStyleHints>
#include <QtConcurrentRun>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qtimer.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <climits>
#include <exception>
#include <fcntl.h>

import telar.gui.application;
import telar.config.client;
import telar.plugins;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.config.runtime;
import telar.wire.vocabulary;

namespace telar::gui::qt {

  namespace {

    ds::Option<std::string_view> optionalText(const QByteArray& bytes) noexcept {
      if (bytes.isEmpty()) {
        return ds::none;
      }

      return std::string_view{bytes.constData(), static_cast<std::size_t>(bytes.size())};
    }

  }

  static_assert(ConcurrentAllocator<ApplicationAllocator>);

  ConfigurationSource::ConfigurationSource(tbc::mut_a<ApplicationAllocator> memory, QObject* parent)
      : QObject(parent),
        memory_(memory),
        fonts_(memory),
        default_theme_picker_(ds::makeBox<application::configuration::ThemePicker>(memory)),
        default_keymap_(default_input_.compile()) {
    debounce_.setSingleShot(true);
    constexpr int reload_debounce_ms = 100;

    debounce_.setInterval(reload_debounce_ms);
    constexpr int dependency_poll_ms = 1000;

    poll_.setInterval(dependency_poll_ms);
    connect(&poll_, &QTimer::timeout, this, &ConfigurationSource::poll);
    connect(&debounce_, &QTimer::timeout, this, &ConfigurationSource::reload);
    connect(&task_, &QFutureWatcher<PreparedConfiguration>::finished, this, &ConfigurationSource::complete);
    configuration_.themes.base = application::configuration::default_theme_values;
    configuration_.theme = projectTheme(configuration_.themes.base);
    const auto* style_hints = QGuiApplication::styleHints();

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
    } catch (const std::exception& error) {
      qWarning() << "Configuration worker failed during shutdown:" << error.what();
    }
  }

  namespace {

    // A render context whose borrowed text is copied so it can cross to the Lua thread.
    struct ContextCopy {
      explicit ContextCopy(const application::components::Context& source)
          : context(source),
            output(source.output ? QByteArray{source.output->data(), static_cast<qsizetype>(source.output->size())} : QByteArray{}),
            pane_title(source.pane_title.data(), static_cast<qsizetype>(source.pane_title.size())),
            has_output(source.output.hasValue()) {}

      [[nodiscard]] application::components::Context view() const {
        auto result = context;

        result.output = has_output ? ds::Option{std::string_view{output.constData(), static_cast<std::size_t>(output.size())}} : ds::none;
        result.pane_title = {pane_title.constData(), static_cast<std::size_t>(pane_title.size())};

        return result;
      }

      application::components::Context context;
      QByteArray output;
      QByteArray pane_title;
      bool has_output = false;
    };

  }

  namespace {

    // A Lua result with the modules its call required, read in the same job so a file edited
    // right after the call is already watched.
    template <typename Value>
    struct TrackedResult {
      ds::Option<Value> value;
      QString error;
      QStringList modules;
    };

    template <typename Generation>
    QStringList loadedModules(const Generation& generation, std::size_t known) {
      QStringList names;

      if (generation.localModuleCount() != known) {
        generation.visitLocalModules([&](std::string_view name) {
          names.append(QString::fromUtf8(name.data(), static_cast<qsizetype>(name.size())));
        });
      }

      return names;
    }

  }

  template <typename Value, typename Work>
  void ConfigurationSource::run(Work work, Done<Value> done) {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    auto* generation = &generation_.getMut();
    const auto number = generation->number();
    const auto known = static_cast<std::size_t>(watch_.modules.size());

    lua_.post([generation, known, job = std::move(work)] mutable -> TrackedResult<Value> {
      TrackedResult<Value> result;

      try {
        result.value.emplace(job(*generation));
      } catch (const std::exception& error) {
        result.error = QString::fromUtf8(error.what());
      }

      result.modules = loadedModules(*generation, known);

      return result;
    },
        [this, number, finish = std::move(done)](LuaOutcome<TrackedResult<Value>> tracked) mutable {
          LuaOutcome<Value> outcome;

          outcome.stale = configurationGeneration() != number;
          if (tracked.value) {
            outcome.value = std::move(tracked.value.getMut().value);
            outcome.error = std::move(tracked.value.getMut().error);
            if (!outcome.stale) {
              ConfigurationLoader::trackModuleNames(tracked.value->modules, module_root_, watch_.modules);
            }
          } else {
            outcome.error = std::move(tracked.error);
          }

          finish(std::move(outcome));
        });
  }

  const InputConfiguration& ConfigurationSource::input() const noexcept {
    return generation_ ? generation_->input() : default_input_;
  }

  const application::components::Definitions* ConfigurationSource::definitions() const noexcept {
    return generation_ ? &generation_->components().definitions() : nullptr;
  }

  const application::components::RenderedContent<application::components::BarContent::capacity, ApplicationAllocator>* ConfigurationSource::fixedBar(application::components::Position position) const noexcept {
    const auto index = static_cast<std::size_t>(position);
    if (index >= fixed_bars_.size()) {
      return nullptr;
    }

    const auto& bar = fixed_bars_[index];

    return bar ? &bar->get() : nullptr;
  }

  void ConfigurationSource::renderBar(application::components::Position position, const application::components::Context& context, Done<BarRender> done) {
    run<BarRender>([position, copied = ContextCopy{context}](Generation& generation) {
      return generation.renderedBar(position, copied.view());
    },
        std::move(done));
  }

  void ConfigurationSource::renderPanel(std::size_t index, const application::components::Context& context, Done<PanelRender> done) {
    run<PanelRender>([index, copied = ContextCopy{context}](Generation& generation) {
      return generation.renderedPanel(index, copied.view());
    },
        std::move(done));
  }

  void ConfigurationSource::closePanel() {
    if (generation_) {
      run<bool>([](Generation& generation) {
        generation.closePanel();

        return true;
      },
          [](const LuaOutcome<bool>&) {});
    }
  }

  void ConfigurationSource::renderElements(application::components::Slot slot, std::uint64_t instance, const application::components::Context& context, const QByteArray& item, Done<ElementsRender> done) {
    run<ElementsRender>([slot, instance, item, copied = ContextCopy{context}](Generation& generation) {
      return generation.renderElements(slot, instance, copied.view(), {item.constData(), static_cast<std::size_t>(item.size())});
    },
        std::move(done));
  }

  void ConfigurationSource::invokeElement(std::uint64_t instance, std::uint32_t callback, const application::components::Context& context, const QByteArray& item, Done<Effects> done) {
    run<Effects>([instance, callback, item, copied = ContextCopy{context}](Generation& generation) {
      return generation.invokeElement({.instance = instance, .callback = callback}, copied.view(), {item.constData(), static_cast<std::size_t>(item.size())});
    },
        std::move(done));
  }

  void ConfigurationSource::forgetElements(std::uint64_t instance) {
    if (generation_) {
      run<bool>([instance](Generation& generation) {
        generation.forgetElements(instance);

        return true;
      },
          [](const LuaOutcome<bool>&) {});
    }
  }

  void ConfigurationSource::renderPick(std::size_t index, const application::components::Context& context, Done<PickRender> done) {
    run<PickRender>([this, index, copied = ContextCopy{context}](Generation& generation) {
      auto items = ds::makeBox<application::components::PickItems>(memory_);

      generation.renderPick(index, copied.view(), items.getMut());

      return items;
    },
        std::move(done));
  }

  QList<QByteArray> ConfigurationSource::commandArguments(int reference, const char* field) const {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    const auto found = arguments_.constFind({reference, QByteArray{field}});
    if (found == arguments_.cend()) {
      throw std::invalid_argument{"Command is no longer configured"};
    }

    return *found;
  }

  ds::Option<ExtendedActionDescription> ConfigurationSource::extendedAction(BindingAction action, const Actions* resolved) const {
    if (!generation_ || action.kind != BindingActionKind::extended) {
      return ds::none;
    }

    if (auto configured = generation_->configuredAction(action)) {
      return configured;
    }

    const auto* entry = resolved == nullptr ? nullptr : resolved->find(action);

    return entry == nullptr ? ds::none : entry->description;
  }

  ds::Option<DefinitionActionDescription> ConfigurationSource::definitionAction(BindingAction action, const Actions* resolved) const {
    const auto description = extendedAction(action, resolved);
    const auto* definition = description ? std::get_if<DefinitionActionDescription>(&*description) : nullptr;

    return definition == nullptr ? ds::none : ds::Option{*definition};
  }

  ds::Option<NamedActionDescription> ConfigurationSource::namedAction(BindingAction action, const Actions* resolved) const {
    const auto description = extendedAction(action, resolved);
    if (!description) {
      return ds::none;
    }

    if (const auto* definition = std::get_if<DefinitionActionDescription>(&*description)) {
      return *definition;
    }

    if (const auto* plugin = std::get_if<PluginActionDescription>(&*description)) {
      return *plugin;
    }

    return ds::none;
  }

  bool ConfigurationSource::luaIdle() const noexcept {
    return lua_.idle();
  }

  std::uint64_t ConfigurationSource::configurationGeneration() const noexcept {
    return generation_ ? generation_->number() : 0;
  }

  ds::Option<PluginActionDescription> ConfigurationSource::pluginAction(BindingAction action, const Actions* resolved) const {
    const auto description = extendedAction(action, resolved);
    const auto* plugin = description ? std::get_if<PluginActionDescription>(&*description) : nullptr;

    return plugin == nullptr ? ds::none : ds::Option{*plugin};
  }

  application::plugins::PluginInvocation ConfigurationSource::pluginInvocation(const ClientCommand& request, BindingContext context) const {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    if (!plugins_) {
      throw std::runtime_error{"PluginRegistryUnavailable"};
    }

    const application::plugins::PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages()};
    const auto* package = catalog.package(catalog.find(request.text));
    if (package == nullptr) {
      throw std::runtime_error{"PluginDisabled"};
    }

    return pluginInvocation(PluginActionDescription{.plugin = runtime::plugins::stableId(package->manifest.id.view()), .action = request.target_id}, context);
  }

  application::plugins::PluginInvocation ConfigurationSource::pluginInvocation(PluginActionDescription action, BindingContext context) const {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    if (!plugins_) {
      throw std::runtime_error{"PluginRegistryUnavailable"};
    }

    const auto packages = plugins_->packages();
    const application::plugins::PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), packages};
    const auto& package = catalog.resolve(action);

    for (const auto& name : std::span{package.manifest.actions}.first(package.manifest.action_count)) {
      if (runtime::plugins::stableId(name.view()) == action.action) {
        return {.package = package, .action = name, .context = context, .configuration_generation = generation_->number(), .package_index = static_cast<std::size_t>(&package - packages.data())};
      }
    }

    throw std::invalid_argument{"UnknownPluginAction"};
  }

  void ConfigurationSource::authorizePlugin(const application::plugins::PluginInvocation& invocation, const application::plugins::PluginEffects& effects) const {
    if (!generation_ || generation_->number() != invocation.configuration_generation) {
      throw std::runtime_error{"StalePluginWorker"};
    }

    if (!plugins_ || invocation.package_index >= plugins_->packages().size()) {
      throw std::runtime_error{"PluginNotConfigured"};
    }

    const auto& package = plugins_->packages()[invocation.package_index];
    if (package.manifest.id.view() != invocation.package.manifest.id.view() || package.digest != invocation.package.digest) {
      throw std::runtime_error{"StalePluginWorker"};
    }

    effects.authorize(package, trust_);
  }

  const BindingMap<BindingAction>& ConfigurationSource::keymap() const noexcept {
    return generation_ ? generation_->keymap() : default_keymap_;
  }

  void ConfigurationSource::invoke(BindingAction action, BindingContext context, Done<Effects> done) {
    run<Effects>([action, context](Generation& generation) {
      return generation.invokeResolved(action, context);
    },
        std::move(done));
  }

  void ConfigurationSource::expression(BindingAction action, BindingContext context, Done<InputExpression> done) {
    run<InputExpression>([action, context](Generation& generation) {
      return generation.expression(action, context);
    },
        std::move(done));
  }

  ds::Option<runtime::config::CommandTabView> ConfigurationSource::commandTab(BindingAction action, const Actions* resolved) const {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    if (action.generation != generation_->number() || action.kind != BindingActionKind::command_tab) {
      throw std::invalid_argument{"Command belongs to an obsolete configuration or a different binding kind"};
    }

    const auto reference = application::configuration::commandTabReference(action);
    if (!reference) {
      return ds::none;
    }

    // Configured rows never change; rows a render added travel with that render's result.
    if (reference->epoch == 0) {
      return commands_ ? commands_->load(*reference) : ds::none;
    }

    const auto* entry = resolved == nullptr ? nullptr : resolved->find(action);

    return entry == nullptr || !entry->command ? ds::none : ds::Option{entry->command->view()};
  }

  ds::Option<NotificationActionDescription> ConfigurationSource::notificationAction(BindingAction action, const Actions* resolved) const {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    const auto description = extendedAction(action, resolved);
    const auto* notification = description ? std::get_if<NotificationActionDescription>(&*description) : nullptr;

    return notification == nullptr ? ds::none : ds::Option{*notification};
  }

  void ConfigurationSource::open(const ConfigurationSelection& selection) {
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
    theme_choice_file_.open(selection.theme_choice_path);
    theme_choice_ = theme_choice_file_.read();
    const QPointer<ConfigurationSource> lifetime{this};

    try {
      adopt(ConfigurationLoader::prepare(memory_, request(true)));
    } catch (const std::exception& error) {
      fail(error);
    }

    if (lifetime != nullptr && (!path_.isEmpty() || theme_choice_file_.enabled())) {
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

  const Configuration& ConfigurationSource::configuration() const noexcept {
    return configuration_;
  }

  ResolvedFont ConfigurationSource::resolveFont(const FontConfiguration& font, qreal scale) {
    return fonts_.resolve(font, scale);
  }

  QString ConfigurationSource::error() const {
    return error_;
  }

  std::string_view ConfigurationSource::query(application::configuration::ConfigurationQuery query, const application::ClientViewState& view) {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    const application::ClientQueryContext context{
        .source = optionalText(source_path_),
        .profile = optionalText(profile_name_),
        .generation = generation_->number(),
        .view = view,
        .default_titlebar = platform::defaultTitlebar(),
    };

    return application::configuration::query(*generation_, *commands_, query, context, query_buffer_.viewMut());
  }

  application::plugins::PluginPage ConfigurationSource::queryPlugins(const ClientCommand& request) {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    if (!plugins_) {
      throw std::runtime_error{"PluginRegistryUnavailable"};
    }

    const application::plugins::PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages(), &plugin_overrides_};

    if (request.action == ClientAction::plugin_list) {
      return application::plugins::PluginQuery::list(catalog, request, query_buffer_.viewMut());
    }

    return application::plugins::PluginQuery::get(catalog, request, query_buffer_.viewMut());
  }

  void ConfigurationSource::setPluginEnabled(const ClientCommand& request, bool enabled) {
    if (!generation_) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    if (!plugins_) {
      throw std::runtime_error{"PluginRegistryUnavailable"};
    }

    if (!loaded_ || path_.isEmpty() || trust_path_.isEmpty()) {
      throw std::runtime_error{"ConfigurationNotLoaded"};
    }

    const application::plugins::PluginCatalog catalog{generation_->number(), generation_->runtimeValues().plugins.configured(), plugins_->packages()};
    const auto index = catalog.find(request.text);
    auto specification = catalog.specification(index);

    specification.enabled = enabled;
    const auto* package = catalog.package(index);

    plugin_overrides_.set(specification, package == nullptr ? ds::none : ds::Option{runtime::plugins::stableId(package->manifest.id.view())});
    requestReload();
  }

  void ConfigurationSource::poll() {
    followThemeChoice();
    if (!debounce_.isActive() && !path_.isEmpty()) {
      schedule(false);
    }
  }

  // The previous VM dies on the Lua thread after every call already queued for it.
  void ConfigurationSource::retire() {
    if (!generation_) {
      return;
    }

    lua_.post([previous = std::move(generation_)] mutable {
      previous.reset();
    },
        [](const LuaOutcome<void>&) {});
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

      const auto future = QtConcurrent::run([memory = &memory_, job = std::move(work)] {
        return ConfigurationLoader::prepare(*memory, job);
      });

      busy_ = true;
      task_.setFuture(future);
    } catch (const std::exception& error) {
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
    } catch (const std::exception& error) {
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

  void ConfigurationSource::adopt(tbc::val_a<PreparedConfiguration> result) {
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
      error_ = std::move(result.getMut().error);
      result.reset();
      emit failed();

      return;
    case ConfigurationPreparation::State::ready:
      break;
    }

    static_cast<void>(fonts_.resolve(result->configuration.font, 1));
    configuration_ = std::move(result.getMut().configuration);
    locked_theme_ = result->locked_theme;
    retire();
    generation_ = std::move(result.getMut().generation);
    // The picker's choice is found in the new generation's catalog.
    configuration_.theme = projectTheme(resolvedTheme());
    commands_ = std::move(result.getMut().snapshot.commands);
    fixed_bars_ = std::move(result.getMut().snapshot.fixed_bars);
    arguments_ = std::move(result.getMut().snapshot.arguments);
    plugins_ = std::move(result.getMut().plugins);
    trust_ = result->trust;
    if (generation_) {
      next_generation_ = generation_->number() + 1;
    }

    module_root_ = std::move(result.getMut().directory);
    watch_.modules = std::move(result.getMut().modules);
    loaded_ = !path_.isEmpty();
    error_.clear();
    result.reset();
    emit changed();
  }

  void ConfigurationSource::reload() {
    schedule(true);
  }

  void ConfigurationSource::fail(const std::exception& error) {
    error_ = QString::fromUtf8(error.what());
    emit failed();
  }

  void ConfigurationSource::updateAppearance(Appearance appearance) {
    appearance_ = appearance;
    showTheme();
  }

  const application::configuration::ThemePicker& ConfigurationSource::themePicker() const noexcept {
    return generation_ ? generation_->themePicker() : *default_theme_picker_;
  }

  const application::configuration::ThemeEntry* ConfigurationSource::chosenTheme() const {
    // A choice made over another theme of the configuration gives way to the configuration.
    if (locked_theme_ || !theme_choice_ || theme_choice_->fingerprint != application::configuration::themeFingerprint(configuration_.themes)) {
      return nullptr;
    }

    return themePicker().catalog.find(theme_choice_->name.view());
  }

  ThemeValues ConfigurationSource::configuredTheme() const {
    return configuration_.themes.resolve(appearance_);
  }

  ThemeValues ConfigurationSource::resolvedTheme() const {
    if (preview_theme_) {
      return *preview_theme_;
    }

    if (const auto* chosen = chosenTheme()) {
      return chosen->values;
    }

    return configuration_.themes.resolve(appearance_, locked_theme_);
  }

  void ConfigurationSource::showTheme() {
    const auto selected = projectTheme(resolvedTheme());
    if (selected == configuration_.theme) {
      return;
    }

    configuration_.theme = selected;
    emit themeChanged();
  }

  void ConfigurationSource::previewTheme(const ds::Option<ThemeValues>& theme) {
    preview_theme_ = theme;
    showTheme();
  }

  void ConfigurationSource::chooseTheme(ds::Option<std::string_view> name) {
    if (!name) {
      theme_choice_file_.remove();
      theme_choice_.reset();
    } else {
      const auto* entry = themePicker().catalog.find(*name);
      if (entry == nullptr) {
        throw std::invalid_argument{"The theme is no longer configured"};
      }

      application::configuration::ThemeChoice choice;

      choice.name.assign(entry->name.view());
      choice.fingerprint = application::configuration::themeFingerprint(configuration_.themes);
      theme_choice_file_.write(choice);
      theme_choice_ = choice;
    }

    // A theme chosen in the window outranks the one it was started with.
    theme_.clear();
    locked_theme_.reset();
    showTheme();
  }

  void ConfigurationSource::followThemeChoice() {
    if (!theme_choice_file_.changed()) {
      return;
    }

    theme_choice_ = theme_choice_file_.read();
    showTheme();
  }

}
