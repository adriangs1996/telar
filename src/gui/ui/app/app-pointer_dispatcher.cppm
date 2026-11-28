export module telar.gui.ui.app:pointer_dispatcher;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.input;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.app.chrome.activity;
import telar.gui.ui.app.panes.attachments;
import telar.gui.ui.app.panes.terminal.history;
import telar.gui.ui.kit.store;
import telar.gui.ui.app.chrome.tabs;
import telar.gui.ui.app.panes.terminal;
import telar.gui.foundation.core;

export namespace telar::gui::qt {

  class WindowDisplay;

  // Routes the window's pointer before the items under it: the tab strip, the history modal, the
  // attachment shelf, the activity list, and the terminals that hold a button. It holds every
  // recipient a pointer event can have.
  class [[qt::object]] PointerDispatcher final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    struct Parts {
      WindowDisplay& display;
      ApplicationAllocator& memory;
      Store& store;
      TabsController& tabs;
      HistoryController& history;
      ActivityController& activity;
      AttachmentsController& attachments;
      TerminalController& terminals;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit PointerDispatcher(tbc::holds<const Parts&, tbc::lt::a> parts);
    ~PointerDispatcher() override = default;
    PointerDispatcher(const PointerDispatcher&) = delete;
    PointerDispatcher& operator=(const PointerDispatcher&) = delete;
    PointerDispatcher(PointerDispatcher&&) = delete;
    PointerDispatcher& operator=(PointerDispatcher&&) = delete;
    void setWindow(QQuickWindow& window);
    void presentHistoryActions(const application::history::HistoryActionSurface& surface);
    void ungrab(TerminalItem& terminal);
    bool eventFilter(QObject* watched, QEvent* event) override;
    bool handleNativeScroll(std::string_view event_type, const void* message);

    [[qt::signal]] void failed(const QString& message);

  private:
    // The history actions a press holds, by button; the terminals hold theirs in their controller.
    [[nodiscard]] application::history::HistoryActionCapture* capture(Qt::MouseButton button) noexcept;
    [[nodiscard]] bool occupied() const noexcept;
    void cancel();
    bool press(QMouseEvent& event);
    bool move(QMouseEvent& event);
    bool release(QMouseEvent& event);

    tbc::mut_a<WindowDisplay> display_;
    tbc::mut_a<Store> store_;
    tbc::mut_a<TabsController> tabs_;
    tbc::mut_a<HistoryController> history_;
    tbc::mut_a<ActivityController> activity_;
    tbc::mut_a<AttachmentsController> attachments_;
    tbc::mut_a<TerminalController> terminals_;
    NativePointerEvents native_events_;
    tbc::val_self<ActiveHistoryScrollEvents<PointerDispatcher>> history_scroll_events_;
    QPointer<QQuickWindow> window_;
    ds::Array<application::history::HistoryActionCapture, static_cast<std::size_t>(application::terminal::input::MouseButton::none)> captures_;
    bool delivering_ = false;
    bool handing_off_ = false;
  };

}
