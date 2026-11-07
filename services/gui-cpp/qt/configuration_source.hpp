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
#include <memory>
#include <type_traits>
#include "configuration_loader.hpp"
#include "lua_host.hpp"
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

// Owns the client configuration. Its Lua VM lives on the Lua thread: everything here that
// runs Lua is asynchronous, and everything synchronous reads data fixed at load or copied
// out of a Lua result.
class ConfigurationSource final : public QObject {
  Q_OBJECT

public:
  using BarRender = ConfigurationPreparation::BarRender;
  using PanelRender = Owned<RenderedContent<components::PanelContent::capacity, ApplicationAllocator>, ApplicationAllocator>;
  using PickRender = Owned<components::PickItems, ApplicationAllocator>;
  using Effects = Owned<ResolvedEffects<ApplicationAllocator>, ApplicationAllocator>;
  using Actions = ResolvedActions<ApplicationAllocator>;
  using ElementsRender = Owned<RenderedElements<ApplicationAllocator>, ApplicationAllocator>;
  template <typename Value>
  using Done = std::function<void(LuaOutcome<Value>)>;

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
  void invoke(BindingAction action, BindingContext context, Done<Effects> done);
  void expression(BindingAction action, BindingContext context, Done<InputExpression> done);
  [[nodiscard]] std::optional<runtime::config::CommandTabView> commandTab(BindingAction action, const Actions *resolved = nullptr) const;
  [[nodiscard]] std::optional<NotificationActionDescription> notificationAction(BindingAction action, const Actions *resolved = nullptr) const;
  [[nodiscard]] std::optional<DefinitionActionDescription> definitionAction(BindingAction action, const Actions *resolved = nullptr) const;
  [[nodiscard]] std::optional<NamedActionDescription> namedAction(BindingAction action, const Actions *resolved = nullptr) const;
  [[nodiscard]] const components::Definitions *definitions() const noexcept;
  [[nodiscard]] const RenderedContent<components::BarContent::capacity, ApplicationAllocator> *fixedBar(components::Position position) const noexcept;
  void renderBar(components::Position position, const components::Context &context, Done<BarRender> done);
  void renderPanel(std::size_t index, const components::Context &context, Done<PanelRender> done);
  void renderPick(std::size_t index, const components::Context &context, Done<PickRender> done);
  void closePanel();
  void renderElements(components::Slot slot, std::uint64_t instance, const components::Context &context, const QByteArray &item, Done<ElementsRender> done);
  void invokeElement(std::uint64_t instance, std::uint32_t callback, const components::Context &context, const QByteArray &item, Done<Effects> done);
  void forgetElements(std::uint64_t instance);
  [[nodiscard]] QList<QByteArray> commandArguments(int reference, const char *field) const;
  [[nodiscard]] std::string_view query(ConfigurationQuery query, const ClientViewState &view = {});
  [[nodiscard]] PluginPage queryPlugins(const ClientCommand &request);
  void setPluginEnabled(const ClientCommand &request, bool enabled);
  [[nodiscard]] std::uint64_t configurationGeneration() const noexcept;
  // No Lua call is queued or running, so every result has been delivered.
  [[nodiscard]] bool luaIdle() const noexcept;
  [[nodiscard]] std::optional<PluginActionDescription> pluginAction(BindingAction action, const Actions *resolved = nullptr) const;
  [[nodiscard]] PluginInvocation pluginInvocation(const ClientCommand &request, BindingContext context) const;
  [[nodiscard]] PluginInvocation pluginInvocation(PluginActionDescription action, BindingContext context) const;
  void authorizePlugin(const PluginInvocation &invocation, const PluginEffects &effects) const;

signals:
  void changed();
  void themeChanged();
  void failed();

private:
  using Generation = ConfigurationGeneration<ApplicationAllocator>;

  // Runs `work` with the current generation on the Lua thread and marks results that
  // arrive after that generation was replaced.
  template <typename Value, typename Work>
  void run(Work work, Done<Value> done);
  [[nodiscard]] std::optional<ExtendedActionDescription> extendedAction(BindingAction action, const Actions *resolved) const;
  void retire();
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
  Owned<Generation, ApplicationAllocator> generation_;
  Owned<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator> commands_;
  std::array<std::optional<BarRender>, components::Definitions::positions> fixed_bars_{};
  ConfigurationPreparation::CommandArguments arguments_;
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
  // Declared last so it stops, finishing its current call, before the generation it runs dies.
  LuaHost lua_;
};

}
