#pragma once

#include "application/dependencies.hpp"
#include "config/plugin_overrides.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "platform/file_stamp.hpp"
#include "platform/private_file_stamp.hpp"
#include "plugin_packages.hpp"
#include "telar_plugins/trust_store.hpp"
#include <QMap>
#include <QString>
#include <cstdint>
#include <optional>

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
  [[nodiscard]] static PreparedConfiguration prepare(ApplicationAllocator &memory, const ConfigurationReloadRequest &request);
  static void trackModules(const ConfigurationGeneration<ApplicationAllocator> &generation, const QString &root, ConfigurationWatch::Modules &modules);

private:
  static void load(ApplicationAllocator &memory, const ConfigurationReloadRequest &request, ConfigurationPreparation &result);
};

}
