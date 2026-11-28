export module telar.gui.ui.app:frame_presenter;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.app.panes.terminal.history;
import telar.gui.ui.kit.store;
import telar.gui.ui.kit.timing;
import telar.gui.foundation.model;
import telar.gui.application;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.ui.app.chrome.tabs;
import telar.gui.ui.app.panes.terminal;

extern "C++" namespace telar::gui::test {
  struct FramePacing;
  struct MachineWindow;
}

export namespace telar::gui::qt {

  class PointerDispatcher;
  class WindowDisplay;
  class WindowStatus;

  // The frames of the window: what the terminals, the tab strip and the history draw is
  // prepared while the scene graph synchronizes, presented once the frame is swapped, and paced
  // so a terminal's output never asks for more frames than the display shows.
  //
  // It reads the store and holds the recipients of a frame. The window tells it which window it
  // observes and when a pane asks for a frame.
  class [[qt::object]] FramePresenter final : public QObject {
    friend struct test::FramePacing;
    friend struct test::MachineWindow;

  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    struct Parts {
      ApplicationAllocator& memory;
      Store& store;
      WindowDisplay& display;
      TabsController& tabs;
      HistoryController& history;
      TerminalController& terminals;
      PointerDispatcher& pointers;
      WindowStatus& status;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit FramePresenter(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent = nullptr);
    ~FramePresenter() override = default;
    FramePresenter(const FramePresenter&) = delete;
    FramePresenter& operator=(const FramePresenter&) = delete;
    FramePresenter(FramePresenter&&) = delete;
    FramePresenter& operator=(FramePresenter&&) = delete;

    // Paces the frames of a window; `generation` names it among the windows the application had.
    void setWindow(QQuickWindow& window, std::uint64_t generation);
    // Prepares and presents the frames the window renders from now on.
    void observeFrames(QQuickWindow& window);
    // Stops pacing: the window is going away.
    void stop();
    // Paces the window again from nothing: the session it showed is another one.
    void restart();
    // Adopts the window's frame interval.
    void configure();

    [[tbc::hot_path]] [[nodiscard]] inline bool pacing() const noexcept {
      return frame_pacer_.hasValue();
    }

    // Whether the update the window asked for waits for a later frame.
    [[nodiscard]] bool defer();
    // Lets a frame that waited go out if what the panes show moved.
    void reconsider();
    // The pane the session last changed asks for a frame.
    void request();
    // The pacer the clients' sessions ask frames from.
    [[nodiscard]] ds::Option<WindowFramePacer<>>& pacer() noexcept;

  private:
    struct PresentedPane {
      application::TerminalPreparation frame;
      QPointer<TerminalItem> terminal;
    };

    struct PresentedFrame {
      std::uint64_t machine_view = 0;
      ds::Array<PresentedPane, PaneLayout::maximum_panes> panes;
      std::size_t pane_count = 0;
      std::uint64_t preparation_ns = 0;
      application::workbench::TabDropSurface tabs;
      HistoryController::Frame history;
    };

    // The render thread prepares each frame into the slot after the last one while the GUI
    // thread presents, and posts the slot and the sequence it prepared there. A slot prepared
    // again before its frame was presented holds a newer frame, whose own post presents it.
    // The frames the scene graph's synchronization prepares, shared by its before and after callbacks,
    // which run in turn on the render thread while the GUI thread is blocked, as Rust's
    // Rc<RefCell<…>> lets two closures share one value.
    struct [[tbc::shared]] PresentedFrames {
      ds::Array<PresentedFrame, 2> prepared;
      ds::Array<std::uint64_t, 2> sequences{};
      std::uint64_t sequence = 0;
      std::size_t current = 0;

      [[tbc::hot_path]] inline PresentedFrame& next() noexcept {
        current = ++sequence % prepared.size();
        sequences.atMut(current) = sequence;
        return prepared.atMut(current);
      }
    };

    void prepareFrame(PresentedFrame& frame);
    void prepareTerminalFrames(PresentedFrame& frame);
    void recordPreparedFrame(const PresentedFrame& frame);
    void present(const PresentedFrame& frame);
    [[nodiscard]] std::size_t collectPacingPanes(std::span<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes) const;

    tbc::mut_a<ApplicationAllocator> memory_;
    tbc::mut_a<Store> store_;
    tbc::mut_a<WindowDisplay> display_;
    tbc::mut_a<TabsController> tabs_;
    tbc::mut_a<HistoryController> history_;
    tbc::mut_a<TerminalController> terminals_;
    tbc::mut_a<PointerDispatcher> pointers_;
    tbc::mut_a<WindowStatus> status_;
    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
    ds::Option<WindowFramePacer<>> frame_pacer_;
  };

}
