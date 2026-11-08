#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "../application/dependencies.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include <cstddef>
#include <span>
#include <array>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <algorithm>
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include <sys/stat.h>
#include "plugin_packages.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <limits.h>
#include <charconv>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <QByteArray>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <utility>

#pragma once

#include "application/dependencies.hpp"
#include "core/memory.hpp"


import telar.gui.components.builtin_content;
import telar.gui.config.plugin_query;
import telar.gui.core.metrics;
import telar.gui.platform.profile_file;
import telar.gui.platform.private_file_stamp;
import telar.plugins;

namespace telar::gui {

template <Allocator Memory>
class ConfigurationGeneration;

}

namespace telar::gui::qt {

struct ConfigurationSelection {
  QString path;
  QString profile;
  QString theme;
  QString trust_path{};
};

struct ConfigurationDependency {
  QString path;
  std::optional<platform::FileStamp> stamp;

  bool operator==(const ConfigurationDependency &) const = default;
};

struct ConfigurationWatch {
  using Modules = QMap<QString, ConfigurationDependency>;

  Modules modules;
  std::optional<platform::FileStamp> root;
  std::optional<platform::PrivateFileStamp> trust;

  bool operator==(const ConfigurationWatch &) const = default;
};

struct ConfigurationReloadRequest {
  ConfigurationSelection selection;
  ConfigurationWatch watch;
  PluginOverrides plugin_overrides{};
  std::uint64_t revision = 0;
  std::uint64_t generation = 0;
  bool force = false;
};

// Read before the Lua thread owns the VM: the window keeps these instead of reading it.
struct ConfigurationSnapshot {
  using BarRender = Owned<RenderedContent<components::BarContent::capacity, ApplicationAllocator>, ApplicationAllocator>;
  using CommandArguments = QMap<std::pair<int, QByteArray>, QList<QByteArray>>;

  explicit ConfigurationSnapshot(ApplicationAllocator &memory)
      : commands(nullptr, AllocationDeleter<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator>{memory}) {}

  Owned<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator> commands;
  std::array<std::optional<BarRender>, components::Definitions::positions> fixed_bars{};
  CommandArguments arguments;
};

struct ConfigurationPreparation {
  enum class State : std::uint8_t {
    unchanged,
    ready,
    failed,
  };

  explicit ConfigurationPreparation(ApplicationAllocator &memory);
  ~ConfigurationPreparation();
  ConfigurationPreparation(const ConfigurationPreparation &) = delete;
  ConfigurationPreparation &operator=(const ConfigurationPreparation &) = delete;
  ConfigurationPreparation(ConfigurationPreparation &&) = delete;
  ConfigurationPreparation &operator=(ConfigurationPreparation &&) = delete;

  ConfigurationWatch observed;
  ConfigurationWatch::Modules modules;
  Configuration configuration;
  std::optional<ThemeValues> locked_theme;
  Owned<ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator> generation;
  ConfigurationSnapshot snapshot;
  std::optional<PluginPackages> plugins;
  runtime::plugins::TrustStore trust;
  QString directory;
  QString error;
  std::uint64_t revision = 0;
  State state = State::unchanged;
};

using PreparedConfiguration = Owned<ConfigurationPreparation, ApplicationAllocator>;

class ConfigurationLoader {
public:
  // The preparation is allocated from memory.
  [[nodiscard]] static tbc::view<PreparedConfiguration, tbc::lt::a> prepare(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, const ConfigurationReloadRequest &request);
  static void trackModules(const ConfigurationGeneration<ApplicationAllocator> &generation, const QString &root, ConfigurationWatch::Modules &modules);
  static void trackModuleNames(const QStringList &names, const QString &root, ConfigurationWatch::Modules &modules);

private:
  // The preparation keeps what it allocates from memory, region `a`.
  static void load(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, const ConfigurationReloadRequest &request, tbc::view<ConfigurationPreparation &, tbc::lt::a> result);
  static void snapshot(tbc::view<ApplicationAllocator &, tbc::lt::a> memory, const ConfigurationGeneration<ApplicationAllocator> &generation, tbc::view<ConfigurationSnapshot &, tbc::lt::a> result);
};

}
