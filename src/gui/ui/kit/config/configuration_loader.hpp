#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
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

import telar.gui.foundation.core;
import telar.gui.foundation.system;
import telar.plugins;
import telar.config.client;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  struct ConfigurationSelection {
    QString path;
    QString profile;
    QString theme;
    QString trust_path{};
  };

  struct ConfigurationDependency {
    QString path;
    ds::Option<system::FileStamp> stamp;

    bool operator==(const ConfigurationDependency&) const = default;
  };

  struct ConfigurationWatch {
    using Modules = QMap<QString, ConfigurationDependency>;

    Modules modules;
    ds::Option<system::FileStamp> root;
    ds::Option<system::PrivateFileStamp> trust;

    bool operator==(const ConfigurationWatch&) const = default;
  };

  struct ConfigurationReloadRequest {
    ConfigurationSelection selection;
    ConfigurationWatch watch;
    application::plugins::PluginOverrides plugin_overrides{};
    std::uint64_t revision = 0;
    std::uint64_t generation = 0;
    bool force = false;
  };

  // Read before the Lua thread owns the VM: the window keeps these instead of reading it.
  struct ConfigurationSnapshot {
    using BarRender = ds::Box<application::components::RenderedContent<application::components::BarContent::capacity, ApplicationAllocator>, ApplicationAllocator>;
    using CommandArguments = QMap<std::pair<int, QByteArray>, QList<QByteArray>>;

    ds::Box<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator> commands;
    ds::Array<ds::Option<BarRender>, application::components::Definitions::positions> fixed_bars{};
    CommandArguments arguments;
  };

  struct ConfigurationPreparation {
    enum class State : std::uint8_t {
      unchanged,
      ready,
      failed,
    };

    ConfigurationPreparation();
    ~ConfigurationPreparation();
    ConfigurationPreparation(const ConfigurationPreparation&) = delete;
    ConfigurationPreparation& operator=(const ConfigurationPreparation&) = delete;
    ConfigurationPreparation(ConfigurationPreparation&&) = delete;
    ConfigurationPreparation& operator=(ConfigurationPreparation&&) = delete;

    ConfigurationWatch observed;
    ConfigurationWatch::Modules modules;
    Configuration configuration;
    ds::Option<ThemeValues> locked_theme;
    ds::Box<application::ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator> generation;
    ConfigurationSnapshot snapshot;
    ds::Option<PluginPackages> plugins;
    runtime::plugins::TrustStore trust;
    QString directory;
    QString error;
    std::uint64_t revision = 0;
    State state = State::unchanged;
  };

  using PreparedConfiguration = ds::Box<ConfigurationPreparation, ApplicationAllocator>;

  class ConfigurationLoader {
  public:
    // The preparation is allocated from memory.
    [[nodiscard]] static tbc::val_a<PreparedConfiguration> prepare(tbc::mut_a<ApplicationAllocator> memory, const ConfigurationReloadRequest& request);
    static void trackModules(const application::ConfigurationGeneration<ApplicationAllocator>& generation, const QString& root, ConfigurationWatch::Modules& modules);
    static void trackModuleNames(const QStringList& names, const QString& root, ConfigurationWatch::Modules& modules);

  private:
    // The preparation keeps what it allocates from memory, region `a`.
    static void load(tbc::mut_a<ApplicationAllocator> memory, const ConfigurationReloadRequest& request, tbc::mut_a<ConfigurationPreparation> result);
    static void snapshot(tbc::mut_a<ApplicationAllocator> memory, const application::ConfigurationGeneration<ApplicationAllocator>& generation, tbc::mut_a<ConfigurationSnapshot> result);
  };

}
