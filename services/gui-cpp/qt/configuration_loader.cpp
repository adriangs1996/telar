#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "configuration_loader.hpp"
#include "../application/dependencies.hpp"
#include "../core/memory.hpp"
#include <cstdint>
#include <algorithm>
#include <array>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <variant>
#include "telar_base/text/utf8.hpp"
#include <string_view>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include <cstdio>
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cstring>
#include <cmath>
#include <initializer_list>
#include <optional>
#include <string>
#include <limits>
#include <utility>
#include <bit>
#include <concepts>

#include "telar_client/serializers/telar_cells.hpp"
#include <charconv>
#include <system_error>
#include "telar_client/codecs/telar_value_codec.hpp"
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
#include "projection.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QIODevice>
#include <QLatin1StringView>
#include <QtCore/qchar.h>
#include <QtCore/qstring.h>
#include <QtCore/qtypes.h>

#include "application/dependencies.hpp"
#include "core/memory.hpp"


import telar.gui.config.plugin_query;
import telar.gui.config.generation;
import telar.gui.core.metrics;
import telar.gui.platform.profile_file;
import telar.gui.platform.private_file_stamp;
import telar.gui.presentation.suggestion_geometry;

import telar.gui.config.gui_query;


namespace telar::gui::qt {

namespace {

std::optional<platform::FileStamp> fileStamp(const QString &path) {
  const auto encoded = QFile::encodeName(path);

  return platform::FileStamp::read(encoded.constData());
}

}

ConfigurationPreparation::ConfigurationPreparation(ApplicationAllocator &memory)
    : generation(nullptr, AllocationDeleter<ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator>{memory}) {
}

ConfigurationPreparation::~ConfigurationPreparation() = default;

PreparedConfiguration ConfigurationLoader::prepare(ApplicationAllocator &memory, const ConfigurationReloadRequest &request) {
  auto observed = request.watch;
  observed.root = request.selection.path.isEmpty() ? std::nullopt : fileStamp(request.selection.path);
  const auto trust_path = QFile::encodeName(request.selection.trust_path);
  observed.trust = trust_path.isEmpty() ? std::nullopt : platform::PrivateFileStamp::read(trust_path.constData());
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
  } catch (const std::exception &error) {
    result->state = ConfigurationPreparation::State::failed;
    result->error = QString::fromUtf8(error.what());
  }

  return result;
}

void ConfigurationLoader::load(ApplicationAllocator &memory, const ConfigurationReloadRequest &request, ConfigurationPreparation &result) {
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
    const ConfigurationSourceText generation_source{
        .source = {source.constData(), static_cast<std::size_t>(source.size())},
        .directory = {directory.constData(), static_cast<std::size_t>(directory.size())},
        .profile = {profile.constData(), static_cast<std::size_t>(profile.size())},
        .generation = request.generation,
        .plugin_overrides = &request.plugin_overrides,
    };
    result.generation = makeOwned<ConfigurationGeneration<ApplicationAllocator>>(memory, memory, generation_source);
    result.plugins.emplace(memory, generation_source.directory, result.generation->runtimeValues().plugins.configured());
    const PluginCatalog catalog{result.generation->number(), result.generation->runtimeValues().plugins.configured(), result.plugins->packages()};
    result.generation->visitPluginActions([&](const PluginActionDescription &action) {
      if (!request.plugin_overrides.disabled(action.plugin, result.generation->runtimeValues().plugins.configured())) {
        static_cast<void>(catalog.resolve(action));
      }
    });
    result.configuration = result.generation->configuration();
    trackModules(*result.generation, result.directory, result.modules);
  }

  if (!request.selection.theme.isEmpty()) {
    const auto name = request.selection.theme.toLower().toUtf8();
    result.locked_theme = themeValuesByName({name.constData(), static_cast<std::size_t>(name.size())});
    result.configuration.theme = projectTheme(*result.locked_theme);
  }
}

void ConfigurationLoader::trackModules(const ConfigurationGeneration<ApplicationAllocator> &generation, const QString &root, ConfigurationWatch::Modules &modules) {
  generation.visitLocalModules([&](std::string_view name) {
    const auto key = toQString(name);
    if (modules.contains(key)) {
      return;
    }

    auto relative = key;
    relative.replace(QLatin1Char('.'), QLatin1Char('/'));
    const auto path = QFileInfo{QDir{root}.filePath(relative + QLatin1StringView{".lua"})}.canonicalFilePath();
    modules.insert(key, {.path = path, .stamp = fileStamp(path)});
  });
}

}
