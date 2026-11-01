#pragma once

#include "components/invocation.hpp"
#include "components/pick_items.hpp"
#include "components/source.hpp"
#include "font_cache.hpp"

#include "application/client_view_state.hpp"
#include "application/dependencies.hpp"
#include "config/action_descriptions.hpp"
#include "config/callback.hpp"
#include "config/command_tab_view.hpp"
#include "config/plugin_effects.hpp"
#include "config/plugin_invocation.hpp"
#include "config/plugin_query.hpp"
#include "config/query.hpp"
#include "configuration_loader.hpp"
#include "core/configuration.hpp"
#include "input/action.hpp"
#include "input/configuration.hpp"
#include <QByteArray>
#include <QFutureWatcher>
#include <QList>
#include <QString>
#include <QTimer>
#include <array>
#include <cstddef>
#include <exception>
#include <optional>
#include <string_view>

namespace telar::gui {

namespace components {
class Configuration;
}

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
