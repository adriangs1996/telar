#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/application_memory.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/foundation/store/store.hpp"
#include "ui/foundation/timing/window_frame_pacer.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

#pragma once

import telar.gui.foundation.model;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::test {
  struct FramePacing;
  struct MachineWindow;
}

namespace telar::gui::qt {

  class PointerDispatcher;
  class TabsController;
  class TerminalController;
  class TerminalItem;
  class WindowDisplay;
  class WindowStatus;

  // The frames of the window: what the terminals, the tab strip and the history draw is
  // prepared while the scene graph synchronizes, presented once the frame is swapped, and paced
  // so a terminal's output never asks for more frames than the display shows.
  //
  // It reads the store and holds the recipients of a frame. The window tells it which window it
  // observes and when a pane asks for a frame.
  class FramePresenter final : public QObject {
    friend struct test::FramePacing;
    friend struct test::MachineWindow;

    Q_OBJECT

  public:
    FramePresenter(ApplicationAllocator& memory, Store& store, WindowDisplay& display, TabsController& tabs, HistoryController& history, TerminalController& terminals, PointerDispatcher& pointers, WindowStatus& status, QObject* parent = nullptr);
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

    [[nodiscard]] bool pacing() const noexcept {
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
      std::array<PresentedPane, PaneLayout::maximum_panes> panes;
      std::size_t pane_count = 0;
      std::uint64_t preparation_ns = 0;
      application::workbench::TabDropSurface tabs;
      HistoryController::Frame history;
    };

    // The render thread prepares each frame into the slot after the last one while the GUI
    // thread presents, and posts the slot and the sequence it prepared there. A slot prepared
    // again before its frame was presented holds a newer frame, whose own post presents it.
    struct PresentedFrames {
      std::array<PresentedFrame, 2> prepared;
      std::array<std::uint64_t, 2> sequences{};
      std::uint64_t sequence = 0;
      std::size_t current = 0;

      PresentedFrame& next() noexcept {
        current = ++sequence % prepared.size();
        sequences[current] = sequence;
        return prepared[current];
      }
    };

    void prepareFrame(PresentedFrame& frame);
    void prepareTerminalFrames(PresentedFrame& frame);
    void recordPreparedFrame(const PresentedFrame& frame);
    void present(const PresentedFrame& frame);
    [[nodiscard]] std::size_t collectPacingPanes(std::span<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes) const;

    ApplicationAllocator& memory_;
    Store& store_;
    WindowDisplay& display_;
    TabsController& tabs_;
    HistoryController& history_;
    TerminalController& terminals_;
    PointerDispatcher& pointers_;
    WindowStatus& status_;
    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
    ds::Option<WindowFramePacer<>> frame_pacer_;
  };

}
