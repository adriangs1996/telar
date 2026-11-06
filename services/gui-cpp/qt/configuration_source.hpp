#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include <algorithm>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <tuple>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <lua.h>
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include <cstdio>
#include <limits>
#include "telar_client/serializers/telar_cells.hpp"
#include <variant>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lualib.h>
#include <chrono>
#include <cmath>
#include <initializer_list>
#include <string>
#include "font_cache.hpp"
#include "../application/dependencies.hpp"
#include "../core/memory.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <exception>
#include <limits.h>
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"
#include <fcntl.h>
#include <sys/stat.h>
#include <bit>
#include <functional>
#include <type_traits>
#include "configuration_loader.hpp"
#include "telar_client/serializers/telar_frame.hpp"

#include <QByteArray>
#include <QFutureWatcher>
#include <QList>
#include <QString>
#include <QTimer>

#pragma once
#include "application/dependencies.hpp"


import telar.gui.components.builtin_content;
import telar.gui.components.configuration;
import telar.gui.application.host_effects;
import telar.gui.config.plugin_query;
import telar.gui.config.plugin_effects;
import telar.gui.config.gui_query;
import telar.gui.core.metrics;
import telar.gui.input.copy_pointer;
import telar.gui.input.configuration;
import telar.config;


namespace telar::gui {

template <Allocator Memory>
class ConfigurationGeneration;

}

namespace telar::gui::qt {

class ConfigurationSource final : public QObject {
  Q_OBJECT

public:
  explicit ConfigurationSource(ApplicationAllocator &memory, QObject *parent = nullptr);
  ~ConfigurationSource() override;
  ConfigurationSource(const ConfigurationSource &) = delete;
  ConfigurationSource &operator=(const ConfigurationSource &) = delete;
  ConfigurationSource(ConfigurationSource &&) = delete;
  ConfigurationSource &operator=(ConfigurationSource &&) = delete;
  void open(const ConfigurationSelection &selection);
  void requestReload();
  void poll();
  [[nodiscard]] const Configuration &configuration() const noexcept;
  [[nodiscard]] ResolvedFont resolveFont(const FontConfiguration &font, qreal scale);
  [[nodiscard]] QString error() const;
  [[nodiscard]] const InputConfiguration &input() const noexcept;
  [[nodiscard]] const BindingMap<BindingAction> &keymap() const noexcept;
  BindingEffects invoke(BindingAction action, BindingContext context);
  InputExpression expression(BindingAction action, BindingContext context);
  [[nodiscard]] std::optional<runtime::config::CommandTabView> commandTab(BindingAction action) const;
  [[nodiscard]] std::optional<NotificationActionDescription> notificationAction(BindingAction action) const;
  [[nodiscard]] std::optional<DefinitionActionDescription> definitionAction(BindingAction action) const;
  [[nodiscard]] std::optional<NamedActionDescription> namedAction(BindingAction action) const;
  [[nodiscard]] const components::Configuration *components() const noexcept;
  void renderBar(components::Position position, const components::Context &context);
  void renderPanel(std::size_t index, const components::Context &context);
  void renderPick(std::size_t index, const components::Context &context, components::PickItems &items);
  void closePanel() noexcept;
  [[nodiscard]] QList<QByteArray> commandArguments(int reference, const char *field) const;
  [[nodiscard]] std::string_view query(ConfigurationQuery query, const ClientViewState &view = {});
  [[nodiscard]] PluginPage queryPlugins(const ClientCommand &request);
  void setPluginEnabled(const ClientCommand &request, bool enabled);
  [[nodiscard]] std::uint64_t configurationGeneration() const noexcept;
  [[nodiscard]] std::optional<PluginActionDescription> pluginAction(BindingAction action) const;
  [[nodiscard]] PluginInvocation pluginInvocation(const ClientCommand &request, BindingContext context) const;
  [[nodiscard]] PluginInvocation pluginInvocation(PluginActionDescription action, BindingContext context) const;
  void authorizePlugin(const PluginInvocation &invocation, const PluginEffects &effects) const;

signals:
  void changed();
  void themeChanged();
  void failed();

private:
  void trackModules();
  [[nodiscard]] ConfigurationReloadRequest request(bool force);
  void schedule(bool force);
  void complete();
  void adopt(PreparedConfiguration result);
  void fail(const std::exception &error);
  void updateAppearance(Appearance appearance);
  void reload();

  ApplicationAllocator &memory_;
  FontCache<ApplicationAllocator> fonts_;
  QTimer poll_;
  QTimer debounce_;
  ConfigurationWatch watch_;
  Configuration configuration_;
  Appearance appearance_ = Appearance::unknown;
  std::optional<ThemeValues> locked_theme_;
  InputConfiguration default_input_;
  BindingMap<BindingAction> default_keymap_;
  Owned<ConfigurationGeneration<ApplicationAllocator>, ApplicationAllocator> generation_;
  std::optional<PluginPackages> plugins_;
  PluginOverrides plugin_overrides_;
  runtime::plugins::TrustStore trust_;
  std::uint64_t next_generation_ = 1;
  std::uint64_t revision_ = 0;
  std::uint64_t active_revision_ = 0;
  QString path_;
  QString profile_;
  QByteArray source_path_;
  QByteArray profile_name_;
  QString theme_;
  QString trust_path_;
  QString module_root_;
  QString error_;
  bool loaded_ = false;
  bool busy_ = false;
  bool pending_reload_ = false;
  bool pending_poll_ = false;
  QFutureWatcher<PreparedConfiguration> task_;
  std::array<char, ConfigurationQuery::capacity> query_buffer_{};
};

}
