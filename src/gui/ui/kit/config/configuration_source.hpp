#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "configuration_loader.hpp"
#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "lua_host.hpp"
#include "tbc/view.hpp"
#include "telar_base/memory/allocator.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_platform/file_descriptor.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/kit/fonts/font_cache.hpp"
#include <algorithm>
#include <array>
#include <bit>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cinttypes>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <fcntl.h>
#include <initializer_list>
#include <lauxlib.h>
#include <limits.h>
#include <limits>
#include <lua.h>
#include <lualib.h>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <system_error>
#include <tuple>
#include <type_traits>
#include <utility>
#include <variant>

#include <QByteArray>
#include <QFutureWatcher>
#include <QList>
#include <QString>
#include <QTimer>

#pragma once

import telar.gui.application;
import telar.gui.foundation.actions;
import telar.gui.foundation.core;
import telar.gui.foundation.keys;
import telar.config.client;
import telar.base.ds;

namespace telar::gui::qt {

  // Owns the client configuration. Its Lua VM lives on the Lua thread: everything here that
  // runs Lua is asynchronous, and everything synchronous reads data fixed at load or copied
  // out of a Lua result.
  class ConfigurationSource final : public QObject {
    Q_OBJECT

  public:
    using BarRender = ConfigurationSnapshot::BarRender;
    using PanelRender = ds::Box<application::components::RenderedContent<application::components::PanelContent::capacity, ApplicationAllocator>, ApplicationAllocator>;
    using PickRender = ds::Box<application::components::PickItems, ApplicationAllocator>;
    using Effects = ds::Box<application::components::ResolvedEffects<ApplicationAllocator>, ApplicationAllocator>;
    using Actions = application::components::ResolvedActions<ApplicationAllocator>;
    using ElementsRender = ds::Box<application::components::RenderedElements<ApplicationAllocator>, ApplicationAllocator>;
    // A callback held inline, never on the heap; what it captures fits in eight pointers.
    static constexpr std::size_t done_capture_pointers = 8;
    template <typename Value>
    using Done = ds::Function<void(LuaOutcome<Value>), done_capture_pointers * sizeof(void*)>;

    // The source keeps the application's allocator, and what is prepared with it, region `a`.
    explicit ConfigurationSource(tbc::mut_a<ApplicationAllocator> memory, QObject* parent = nullptr);
    ~ConfigurationSource() override;
    ConfigurationSource(const ConfigurationSource&) = delete;
    ConfigurationSource& operator=(const ConfigurationSource&) = delete;
    ConfigurationSource(ConfigurationSource&&) = delete;
    ConfigurationSource& operator=(ConfigurationSource&&) = delete;
    void open(const ConfigurationSelection& selection);
    void requestReload();
    void poll();
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] ResolvedFont resolveFont(const FontConfiguration& font, qreal scale);
    [[nodiscard]] QString error() const;
    [[nodiscard]] const InputConfiguration& input() const noexcept;
    [[nodiscard]] const BindingMap<BindingAction>& keymap() const noexcept;
    void invoke(BindingAction action, BindingContext context, Done<Effects> done);
    void expression(BindingAction action, BindingContext context, Done<InputExpression> done);
    // A command tab comes from the configured rows or from the actions a render resolved.
    [[nodiscard]] tbc::val_a<ds::Option<runtime::config::CommandTabView>> commandTab(BindingAction action, tbc::val_a<const Actions*> resolved = nullptr) const;
    [[nodiscard]] ds::Option<NotificationActionDescription> notificationAction(BindingAction action, const Actions* resolved = nullptr) const;
    [[nodiscard]] ds::Option<DefinitionActionDescription> definitionAction(BindingAction action, const Actions* resolved = nullptr) const;
    [[nodiscard]] ds::Option<NamedActionDescription> namedAction(BindingAction action, const Actions* resolved = nullptr) const;
    [[nodiscard]] const application::components::Definitions* definitions() const noexcept;
    [[nodiscard]] const application::components::RenderedContent<application::components::BarContent::capacity, ApplicationAllocator>* fixedBar(application::components::Position position) const noexcept;
    void renderBar(application::components::Position position, const application::components::Context& context, Done<BarRender> done);
    void renderPanel(std::size_t index, const application::components::Context& context, Done<PanelRender> done);
    void renderPick(std::size_t index, const application::components::Context& context, Done<PickRender> done);
    void closePanel();
    void renderElements(application::components::Slot slot, std::uint64_t instance, const application::components::Context& context, const QByteArray& item, Done<ElementsRender> done);
    void invokeElement(std::uint64_t instance, std::uint32_t callback, const application::components::Context& context, const QByteArray& item, Done<Effects> done);
    void forgetElements(std::uint64_t instance);
    [[nodiscard]] QList<QByteArray> commandArguments(int reference, const char* field) const;
    [[nodiscard]] std::string_view query(application::configuration::ConfigurationQuery query, const application::ClientViewState& view = {});
    [[nodiscard]] application::plugins::PluginPage queryPlugins(const ClientCommand& request);
    void setPluginEnabled(const ClientCommand& request, bool enabled);
    [[nodiscard]] std::uint64_t configurationGeneration() const noexcept;
    // No Lua call is queued or running, so every result has been delivered.
    [[nodiscard]] bool luaIdle() const noexcept;
    [[nodiscard]] ds::Option<PluginActionDescription> pluginAction(BindingAction action, const Actions* resolved = nullptr) const;
    [[nodiscard]] application::plugins::PluginInvocation pluginInvocation(const ClientCommand& request, BindingContext context) const;
    [[nodiscard]] application::plugins::PluginInvocation pluginInvocation(PluginActionDescription action, BindingContext context) const;
    void authorizePlugin(const application::plugins::PluginInvocation& invocation, const application::plugins::PluginEffects& effects) const;

  signals:
    void changed();
    void themeChanged();
    void failed();

  private:
    using Generation = application::ConfigurationGeneration<ApplicationAllocator>;

    // Runs `work` with the current generation on the Lua thread and marks results that
    // arrive after that generation was replaced.
    template <typename Value, typename Work>
    void run(Work work, Done<Value> done);
    [[nodiscard]] ds::Option<ExtendedActionDescription> extendedAction(BindingAction action, const Actions* resolved) const;
    void retire();
    [[nodiscard]] ConfigurationReloadRequest request(bool force);
    void schedule(bool force);
    void complete();
    void adopt(tbc::val_a<PreparedConfiguration> result);
    void fail(const std::exception& error);
    void updateAppearance(Appearance appearance);
    void reload();

    tbc::mut_a<ApplicationAllocator> memory_;
    tbc::val_a<FontCache<ApplicationAllocator>> fonts_;
    QTimer poll_;
    QTimer debounce_;
    ConfigurationWatch watch_;
    Configuration configuration_;
    Appearance appearance_ = Appearance::unknown;
    ds::Option<ThemeValues> locked_theme_;
    InputConfiguration default_input_;
    // The default keymap is compiled from the input beside it, so the source stays where Qt made it.
    tbc::val_self<BindingMap<BindingAction>> default_keymap_;
    tbc::val_a<ds::Box<Generation, ApplicationAllocator>> generation_;
    tbc::val_a<ds::Box<runtime::config::RetainedCommandTabRegistry, ApplicationAllocator>> commands_;
    tbc::val_a<ds::Array<ds::Option<BarRender>, application::components::Definitions::positions>> fixed_bars_{};
    ConfigurationSnapshot::CommandArguments arguments_;
    tbc::val_a<ds::Option<PluginPackages>> plugins_;
    application::plugins::PluginOverrides plugin_overrides_;
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
    ds::Array<char, application::configuration::ConfigurationQuery::capacity> query_buffer_{};
    // Declared last so it stops, finishing its current call, before the generation it runs dies.
    LuaHost lua_;
  };

}
