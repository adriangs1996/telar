#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "configuration_loader.hpp"
#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "telar_base/memory/allocator.hpp"
#include <array>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>

#include "telar_config/terminal/control/policy.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QLatin1StringView>
#include <QtCore/qchar.h>
#include <QtCore/qstring.h>
#include <QtCore/qtypes.h>
#include <exception>
#include <limits.h>

import telar.gui.config.plugin_query;
import telar.gui.foundation.actions;
import telar.gui.config.generation;

import telar.gui.config.gui_query;
import telar.gui.application;

namespace telar::gui::qt {

  namespace {

    std::optional<system::FileStamp> fileStamp(const QString& path) {
      const auto encoded = QFile::encodeName(path);

      return system::FileStamp::read(encoded.constData());
    }

  }

  ConfigurationPreparation::ConfigurationPreparation(ApplicationAllocator& memory)
      : generation(nullptr, AllocationDeleter<application::ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator>{memory}),
        snapshot(memory) {
  }

  ConfigurationPreparation::~ConfigurationPreparation() = default;

  PreparedConfiguration ConfigurationLoader::prepare(ApplicationAllocator& memory, const ConfigurationReloadRequest& request) {
    auto observed = request.watch;

    observed.root = request.selection.path.isEmpty() ? std::nullopt : fileStamp(request.selection.path);
    const auto trust_path = QFile::encodeName(request.selection.trust_path);

    observed.trust = trust_path.isEmpty() ? std::nullopt : system::PrivateFileStamp::read(trust_path.constData());
    for (auto iterator = request.watch.modules.cbegin(); iterator != request.watch.modules.cend(); ++iterator) {
      const auto stamp = fileStamp(iterator->path);
      if (stamp != iterator->stamp) {
        observed.modules[iterator.key()].stamp = stamp;
      }
    }

    if (!request.force && observed == request.watch) {
      return PreparedConfiguration{nullptr, AllocationDeleter<ConfigurationPreparation, ApplicationAllocator>{memory}};
    }

    auto result = makeOwned<ConfigurationPreparation>(memory, memory);

    result->revision = request.revision;
    result->observed = std::move(observed);

    try {
      load(memory, request, *result);
      result->state = ConfigurationPreparation::State::ready;
    } catch (const std::exception& error) {
      result->state = ConfigurationPreparation::State::failed;
      result->error = QString::fromUtf8(error.what());
    }

    return result;
  }

  void ConfigurationLoader::load(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, const ConfigurationReloadRequest& request, tbc::view<ConfigurationPreparation&, tbc::lt::a> result) {
    result.configuration.themes.base = default_theme_values;
    result.configuration.theme = projectTheme(result.configuration.themes.base);
    if (!request.selection.trust_path.isEmpty()) {
      const auto path = QFile::encodeName(request.selection.trust_path);

      result.trust = runtime::plugins::TrustStore::load(memory, {path.constData(), static_cast<std::size_t>(path.size())});
    }

    if (!request.selection.path.isEmpty()) {
      const QFileInfo information{request.selection.path};
      constexpr qint64 maximum_source_bytes = qint64{1024} * 1024;
      if (!information.isFile() || information.size() > maximum_source_bytes) {
        throw std::runtime_error{"Configuration must be a regular file of at most 1 MiB"};
      }

      QFile file{information.canonicalFilePath()};
      if (!file.open(QIODevice::ReadOnly)) {
        throw std::runtime_error{"Cannot open GUI configuration"};
      }

      const auto source = file.read(maximum_source_bytes + 1);
      if (source.size() > maximum_source_bytes || !file.atEnd()) {
        throw std::runtime_error{"GUI configuration exceeds its byte capacity"};
      }

      result.directory = information.canonicalPath();
      const auto directory = result.directory.toUtf8();
      const auto profile = request.selection.profile.toUtf8();
      const application::ConfigurationSourceText generation_source{
          .source = {source.constData(), static_cast<std::size_t>(source.size())},
          .directory = {directory.constData(), static_cast<std::size_t>(directory.size())},
          .profile = {profile.constData(), static_cast<std::size_t>(profile.size())},
          .generation = request.generation,
          .plugin_overrides = &request.plugin_overrides,
      };

      result.generation = makeOwned<application::ConfigurationGeneration<ApplicationAllocator>>(memory, memory, generation_source);
      const auto& generation = *result.generation;
      const auto& configured = generation.runtimeValues().plugins.configured();

      result.plugins.emplace(memory, generation_source.directory, configured);
      const PluginCatalog catalog{generation.number(), configured, result.plugins->packages()};

      generation.visitPluginActions([&](const PluginActionDescription& action) {
        if (!request.plugin_overrides.disabled(action.plugin, configured)) {
          static_cast<void>(catalog.resolve(action));
        }
      });

      result.configuration = generation.configuration();
      trackModules(generation, result.directory, result.modules);
      snapshot(memory, generation, result.snapshot);
    }

    if (!request.selection.theme.isEmpty()) {
      const auto name = request.selection.theme.toLower().toUtf8();

      result.locked_theme = themeValuesByName({name.constData(), static_cast<std::size_t>(name.size())});
      result.configuration.theme = projectTheme(*result.locked_theme);
    }
  }

  void ConfigurationLoader::snapshot(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, const application::ConfigurationGeneration<ApplicationAllocator>& generation, tbc::view<ConfigurationSnapshot&, tbc::lt::a> result) {
    result.commands = makeOwned<runtime::config::RetainedCommandTabRegistry>(memory, generation.commandTabs());
    const auto store = [&](int reference, const char* field) {
      QList<QByteArray> arguments;

      generation.visitArguments(reference, field, [&](std::string_view argument) {
        arguments.append(QByteArray{argument.data(), static_cast<qsizetype>(argument.size())});
      });

      result.arguments.insert({reference, QByteArray{field}}, std::move(arguments));
    };

    const auto& definitions = generation.components().definitions();

    for (std::size_t index = 0; index < application::components::Definitions::positions; ++index) {
      const auto position = static_cast<application::components::Position>(index);
      const auto& source = definitions.source(position);
      if (source.kind == application::components::SourceKind::fixed) {
        result.fixed_bars.at(index).emplace(generation.copied(memory, generation.components().bar(position)));
      } else if (source.kind == application::components::SourceKind::command) {
        store(source.reference, "command");
      }
    }

    for (const auto& panel : definitions.panels()) {
      if (panel.source.kind == application::components::SourceKind::command) {
        store(panel.source.reference, "command");
      }
    }

    for (const auto& pick : definitions.picks()) {
      store(pick.reference, "on_select");
      if (pick.command) {
        store(pick.reference, "command");
      }
    }
  }

  void ConfigurationLoader::trackModules(const application::ConfigurationGeneration<ApplicationAllocator>& generation, const QString& root, ConfigurationWatch::Modules& modules) {
    QStringList names;

    generation.visitLocalModules([&](std::string_view name) {
      names.append(toQString(name));
    });

    trackModuleNames(names, root, modules);
  }

  void ConfigurationLoader::trackModuleNames(const QStringList& names, const QString& root, ConfigurationWatch::Modules& modules) {
    const QDir directory{root};

    for (const auto& key : names) {
      if (modules.contains(key)) {
        continue;
      }

      auto relative = key;

      relative.replace(QLatin1Char('.'), QLatin1Char('/'));
      auto path = QFileInfo{directory.filePath(relative + QLatin1StringView{".lua"})}.canonicalFilePath();
      if (path.isEmpty()) {
        path = QFileInfo{directory.filePath(relative + QLatin1StringView{"/init.lua"})}.canonicalFilePath();
      }

      modules.insert(key, {.path = path, .stamp = fileStamp(path)});
    }
  }

}
