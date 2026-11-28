export module telar.gui.ui.app.chrome.components:components_controller;

import std;
import telar.gui.qt;
import telar.gui.foundation.actions;
import telar.gui.ui.kit.machines;
import telar.tbc;
import :component_surface_state;
import :pick_controller;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.config;
import telar.gui.ui.kit.process.surface_command;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;

extern "C++" namespace telar::gui::test {
  struct ComponentActions;
}

export namespace telar::gui::qt {

  // What a binding reads of the active session: its tab, its pane and whether the sidebar shows.
  [[nodiscard]] BindingContext sessionBindingContext(const GuiSession& session);

  // The surfaces mods draw in the window's chrome: the bars, the panel one of them opens, the
  // pick a binding opens over them, and the element bars.
  //
  // Each surface is fixed, built in, rendered by Lua or by a command, on its own clock. It reads
  // the store and the configuration. A pressed node's binding acts on the session or the window,
  // and its link opens with the window's, so it asks the window to run them. The pick gives the
  // keyboard back to the panel it was opened over, or asks the window for the terminal.
  class [[qt::object, qt_qml_named("ComponentsController"), qt_qml_uncreatable("Use the window's components")]] ComponentsController final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

    // Mod content for the top and bottom bars, by slot name; empty while QML draws them.
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
    [[qt::invokable]] void closePanel();
    [[qt::invokable]] void refreshPanel();
    [[qt::invokable]] void filterPick(const QString& query);

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
    [[qt::invokable]] void activate(int source, int node, const QString& generation, const QString& revision, const QPointF& anchor);

    void setWindow(QQuickWindow& window);
    // The display the pick measures its palette geometry against.
    void setDisplay(const application::window::DisplayMetrics& display);
    // Remembers what has the keyboard, to give it back when the pick closes, unless the pick is
    // open already.
    void rememberPickFocus();
    void openPick(std::size_t index);
    [[qt::invokable]] void closePick();
    [[qt::invokable]] void choosePick(int row, const QString& identity);
    [[nodiscard]] bool pickOpen() const;

    // The element bars render `item`, what a mod reads of the window.
    void refreshElementBars(const QVariantMap& item);

    [[qt::signal]] void changed();
    [[qt::signal]] void pickChanged();
    [[qt::signal]] void elementBarsChanged();
    [[qt::signal]] void failed(const QString& message);
    // A pressed node runs a binding, where it was pressed, or opens a link; the window does both.
    [[qt::signal]] void bindingRequested(const telar::gui::BindingAction& action, const telar::gui::qt::ConfigurationSource::Actions& actions, QPointF anchor);
    [[qt::signal]] void linkRequested(const telar::gui::application::terminal::links::LinkTarget& target);
    // The pick closed with no panel to give the keyboard back to.
    [[qt::signal]] void focusRestoreRequested();

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

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("bars", &ComponentsController::bars).withNotify(&ComponentsController::changed),
        telar::qt::property("panel", &ComponentsController::panel).withNotify(&ComponentsController::changed),
        telar::qt::property("pick", &ComponentsController::pick).withNotify(&ComponentsController::pickChanged),
        telar::qt::property("elementBars", &ComponentsController::elementBars).withNotify(&ComponentsController::elementBarsChanged)
    );
  };

}
