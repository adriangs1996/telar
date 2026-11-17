#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "core/memory.hpp"
#include "plugin_packages.hpp"
#include "tbc/view.hpp"
#include "telar_base/memory/allocator.hpp"
#include <QByteArray>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>
#include <array>
#include <cstdint>
#include <fcntl.h>
#include <limits.h>
#include <optional>
#include <utility>

#pragma once

import telar.gui.config.plugin_query;
import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.plugins;
import telar.config.client;
import telar.gui.application;

namespace telar::gui::qt {

  struct ConfigurationSelection {
    QString path;
    QString profile;
    QString theme;
    QString trust_path{};
  };

  struct ConfigurationDependency {
    QString path;
    std::optional<system::FileStamp> stamp;

    bool operator==(const ConfigurationDependency&) const = default;
  };

  struct ConfigurationWatch {
    using Modules = QMap<QString, ConfigurationDependency>;

    Modules modules;
    std::optional<system::FileStamp> root;
    std::optional<system::PrivateFileStamp> trust;

    bool operator==(const ConfigurationWatch&) const = default;
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
    using BarRender = Owned<application::components::RenderedContent<application::components::BarContent::capacity, ApplicationAllocator>, ApplicationAllocator>;
    using CommandArguments = QMap<std::pair<int, QByteArray>, QList<QByteArray>>;

    explicit ConfigurationSnapshot(ApplicationAllocator& memory)
        : commands(nullptr, AllocationDeleter<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator>{memory}) {}

    Owned<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator> commands;
    std::array<std::optional<BarRender>, application::components::Definitions::positions> fixed_bars{};
    CommandArguments arguments;
  };

  struct ConfigurationPreparation {
    enum class State : std::uint8_t {
      unchanged,
      ready,
      failed,
    };

    explicit ConfigurationPreparation(ApplicationAllocator& memory);
    ~ConfigurationPreparation();
    ConfigurationPreparation(const ConfigurationPreparation&) = delete;
    ConfigurationPreparation& operator=(const ConfigurationPreparation&) = delete;
    ConfigurationPreparation(ConfigurationPreparation&&) = delete;
    ConfigurationPreparation& operator=(ConfigurationPreparation&&) = delete;

    ConfigurationWatch observed;
    ConfigurationWatch::Modules modules;
    Configuration configuration;
    std::optional<ThemeValues> locked_theme;
    Owned<application::ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator> generation;
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
    [[nodiscard]] static tbc::view<PreparedConfiguration, tbc::lt::a> prepare(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, const ConfigurationReloadRequest& request);
    static void trackModules(const application::ConfigurationGeneration<ApplicationAllocator>& generation, const QString& root, ConfigurationWatch::Modules& modules);
    static void trackModuleNames(const QStringList& names, const QString& root, ConfigurationWatch::Modules& modules);

  private:
    // The preparation keeps what it allocates from memory, region `a`.
    static void load(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, const ConfigurationReloadRequest& request, tbc::view<ConfigurationPreparation&, tbc::lt::a> result);
    static void snapshot(tbc::view<ApplicationAllocator&, tbc::lt::a> memory, const application::ConfigurationGeneration<ApplicationAllocator>& generation, tbc::view<ConfigurationSnapshot&, tbc::lt::a> result);
  };

}
