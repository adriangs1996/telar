#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "component_surface_state.hpp"
#include "foundation/core/application_memory.hpp"
#include "pick_controller.hpp"
#include "tbc/view.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/kit/config/configuration_source.hpp"
#include "ui/kit/process/surface_command.hpp"
#include "ui/kit/store/store.hpp"
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::test {
  struct ComponentActions;
}

namespace telar::gui::qt {

  // What a binding reads of the active session: its tab, its pane and whether the sidebar shows.
  [[nodiscard]] BindingContext sessionBindingContext(const GuiSession& session);

  // The surfaces mods draw in the window's chrome: the bars, the panel one of them opens, the
  // pick a binding opens over them, and the element bars.
  //
  // Each surface is fixed, built in, rendered by Lua or by a command, on its own clock. It reads
  // the store and the configuration. A pressed node's binding acts on the session or the window,
  // and its link opens with the window's, so it asks the window to run them. The pick gives the
  // keyboard back to the panel it was opened over, or asks the window for the terminal.
  class ComponentsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(ComponentsController)
    QML_UNCREATABLE("Use the window's components")
    Q_PROPERTY(QVariantMap bars READ bars NOTIFY changed)
    Q_PROPERTY(QVariantMap panel READ panel NOTIFY changed)
    Q_PROPERTY(QVariantMap pick READ pick NOTIFY pickChanged)
    // Mod content for the top and bottom bars, by slot name; empty while QML draws them.
    Q_PROPERTY(QVariantMap elementBars READ elementBars NOTIFY elementBarsChanged)

  public:
    ComponentsController(Store& store, ConfigurationSource& configuration, ElementSlots& elements, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~ComponentsController() override = default;
    ComponentsController(const ComponentsController&) = delete;
    ComponentsController& operator=(const ComponentsController&) = delete;
    ComponentsController(ComponentsController&&) = delete;
    ComponentsController& operator=(ComponentsController&&) = delete;

    [[nodiscard]] QVariantMap bars() const;
    [[nodiscard]] QVariantMap panel() const;
    [[nodiscard]] QVariantMap pick() const;
    [[nodiscard]] QVariantMap elementBars() const;
    Q_INVOKABLE void closePanel();
    Q_INVOKABLE void refreshPanel();
    Q_INVOKABLE void filterPick(const QString& query);

    // What the surfaces render with: the session's binding context, the time, the host's
    // metrics and the focused pane's title.
    [[nodiscard]] application::components::Context context() const;
    // A configuration loaded: a new Lua generation retires the surfaces; a theme projects them.
    void configure();
    // The surfaces start over, as the active machine changed or the configuration replaced them.
    void reset();
    // Opens the panel at `index` where the action that opened it was pressed, or closes it.
    void togglePanel(std::size_t index, QPointF anchor);
    [[nodiscard]] bool panelOpen() const noexcept;
    // Whether the open panel belongs to the configuration loaded now.
    [[nodiscard]] bool panelCurrent() const noexcept;
    // Whether the content that offered these actions is still on screen.
    [[nodiscard]] bool actionsLive(const ConfigurationSource::Actions& actions) const;
    // Runs the node a press in QML names, while its surface still shows it and its action is
    // still the one shown; `anchor` is where it was pressed.
    Q_INVOKABLE void activate(int source, int node, const QString& generation, const QString& revision, const QPointF& anchor);

    void setWindow(QQuickWindow& window);
    // The display the pick measures its palette geometry against.
    void setDisplay(const application::window::DisplayMetrics& display);
    // Remembers what has the keyboard, to give it back when the pick closes, unless the pick is
    // open already.
    void rememberPickFocus();
    void openPick(std::size_t index);
    Q_INVOKABLE void closePick();
    Q_INVOKABLE void choosePick(int row, const QString& identity);
    [[nodiscard]] bool pickOpen() const;

    // The element bars render `item`, what a mod reads of the window.
    void refreshElementBars(const QVariantMap& item);

  signals:
    void changed();
    void pickChanged();
    void elementBarsChanged();
    void failed(const QString& message);
    // A pressed node runs a binding, where it was pressed, or opens a link; the window does both.
    void bindingRequested(const telar::gui::BindingAction& action, const telar::gui::qt::ConfigurationSource::Actions& actions, QPointF anchor);
    void linkRequested(const telar::gui::application::terminal::links::LinkTarget& target);
    // The pick closed with no panel to give the keyboard back to.
    void focusRestoreRequested();

  private:
    // What a surface's node runs when it is pressed.
    struct Activation {
      ds::Option<BindingAction> action;
      std::string_view url;
      QString identity;
      const ConfigurationSource::Actions* actions = nullptr;
    };

    friend struct test::ComponentActions;
    template <typename Host, Allocator Memory, typename Source>
    friend class PickController;

    // The node a press in QML names, while its surface still shows it.
    [[nodiscard]] ds::Option<Activation> activation(int source, int node, const QString& generation, const QString& revision) const;
    // The panel the pick was opened over takes the keyboard back; without one, the terminal does.
    void restorePickFocus();
    // Where the pick's bands sit, as the palette lays out a nested list.
    [[nodiscard]] QVariantMap pickGeometry() const;
    void tick();
    void arm();
    void project();
    void projectSource(std::size_t index, bool panel);
    void render(std::size_t index, bool panel);
    void applyRender(std::size_t index, bool panel, const application::components::Context& context, bool truncated = false);
    void commandFinished(const ComponentCommandOwner& owner, const SurfaceCommandResult& result);
    [[nodiscard]] const ComponentSlotState::Bar* bar(std::size_t index) const;
    [[nodiscard]] bool commandCurrent(std::uint64_t generation, application::machines::MachineClientKey source, std::uint64_t runtime) const;

    // What PickController asks of its host.
    [[nodiscard]] PickOwner pickOwner() const;
    [[nodiscard]] bool pickOwnerCurrent(const PickOwner& owner) const;
    [[nodiscard]] application::components::Context pickContext() const;
    void pickCommitted();
    void pickFailed(const QString& message);

    Store& store_;
    ConfigurationSource& configuration_;
    ElementSlots& elements_;
    ApplicationAllocator& memory_;
    ComponentSurfaceState surfaces_;
    QTimer timer_;
    tbc::val_self<SurfaceCommand> command_;
    ds::Option<ComponentCommandOwner> command_owner_;
    std::uint64_t next_revision_ = 0;
    tbc::val_self<PickController<ComponentsController, ApplicationAllocator, ConfigurationSource>> pick_;
    QPointer<QQuickWindow> window_;
    QPointer<QQuickItem> pick_return_focus_;
    QVariantMap element_bars_;
    application::window::DisplayMetrics display_{};
  };

}
