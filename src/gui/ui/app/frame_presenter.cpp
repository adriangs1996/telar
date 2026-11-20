#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "frame_presenter.hpp"
#include "foundation/core/application_memory.hpp"
#include "foundation/core/memory.hpp"
#include "platform/window.hpp"
#include "pointer_dispatcher.hpp"
#include "ui/app/chrome/tabs/tabs_controller.hpp"
#include "ui/app/panes/terminal/scene/window_images.hpp"
#include "ui/app/panes/terminal/terminal_controller.hpp"
#include "ui/app/panes/terminal/terminal_item.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"
#include "window_display.hpp"
#include "window_status.hpp"
#include <QPointer>
#include <QQuickWindow>
#include <array>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <memory>
#include <optional>
#include <span>
#include <utility>

import telar.gui.application;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::qt {

  FramePresenter::FramePresenter(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent)
      : QObject(parent),
        memory_(parts.memory),
        store_(parts.store),
        display_(parts.display),
        tabs_(parts.tabs),
        history_(parts.history),
        terminals_(parts.terminals),
        pointers_(parts.pointers),
        status_(parts.status) {}

  void FramePresenter::setWindow(QQuickWindow& window, std::uint64_t generation) {
    window_ = &window;
    window_generation_ = generation;
    frame_pacer_.reset();
    frame_pacer_.emplace(window);
  }

  void FramePresenter::stop() {
    frame_pacer_.reset();
  }

  void FramePresenter::restart() {
    frame_pacer_.reset();
    if (window_) {
      frame_pacer_.emplace(*window_);
      configure();
    }
  }

  bool FramePresenter::defer() {
    ds::Array<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes;
    const auto count = collectPacingPanes(panes.viewMut());

    return frame_pacer_.getMut().defer(std::span{panes}.first(count));
  }

  ds::Option<WindowFramePacer<>>& FramePresenter::pacer() noexcept {
    return frame_pacer_;
  }

  void FramePresenter::observeFrames(QQuickWindow& window) {
    WindowImages::forWindow(window);
    const auto generation = window_generation_;
    // Preparation runs while the scene graph synchronizes, with the GUI thread blocked, so it
    // never overlaps a present on the GUI thread.
    const auto frames = std::allocate_shared<PresentedFrames>(AllocatorRef<PresentedFrames, ApplicationAllocator>{memory_});

    connect(&window, &QQuickWindow::beforeSynchronizing, this, [this, frames, generation] mutable {
      if (generation == window_generation_) {
        prepareFrame(frames->next());
      }
    },
        Qt::DirectConnection);
    connect(&window, &QQuickWindow::afterSynchronizing, this, [this, frames, generation] mutable {
      if (generation == window_generation_) {
        auto& frame = frames->prepared.atMut(frames->current);

        prepareTerminalFrames(frame);
        recordPreparedFrame(frame);
      }
    },
        Qt::DirectConnection);

    connect(
        &window,
        &QQuickWindow::frameSwapped,
        this,
        [this, frames, generation] {
          const auto slot = frames->current;

          QMetaObject::invokeMethod(
              this,
              [this, frames, slot, sequence = frames->sequences[slot], generation] {
                if (window_ != nullptr && generation == window_generation_ && frames->sequences[slot] == sequence) {
                  present(frames->prepared[slot]);
                }
              },
              Qt::QueuedConnection
          );
        },
        Qt::DirectConnection
    );
  }

  void FramePresenter::prepareFrame(PresentedFrame& frame) {
    frame = {};
    frame.machine_view = store_.machineView();
    frame.preparation_ns = system::AwakeClock::nowNanoseconds();
    frame.tabs = tabs_.dropSurface(WindowDisplay::chromeRatio());
    if (window_ == nullptr) {
      return;
    }

    auto* images = WindowImages::findWindow(*window_);
    if (images != nullptr && !images->empty()) {
      images->beginCatalogSnapshot();
      for (const auto& pane : std::as_const(store_).session().panes) {
        images->observeCatalog(pane->graphics);
      }
    }

    history_.prepare(frame.history);
  }

  void FramePresenter::prepareTerminalFrames(PresentedFrame& frame) {
    if (window_ == nullptr) {
      return;
    }

    const auto* tab = store_.session().activeTab();
    if (tab == nullptr) {
      return;
    }

    forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
      const auto* pane = store_.session().findPane(leaf.pane_id);
      auto* terminal = pane != nullptr && pane->attached ? terminals_.visible(pane->id) : nullptr;
      if (terminal == nullptr) {
        return;
      }

      const auto& prepared = terminal->preparedFrame();
      if (prepared.pane.attached && prepared.pane.pane_id == pane->id && prepared.pane.attachment_generation == pane->attachment_generation) {
        frame.panes.atMut(frame.pane_count++) = {.frame = prepared, .terminal = terminal};
      }
    });
  }

  std::size_t FramePresenter::collectPacingPanes(std::span<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes) const {
    const auto* tab = store_.session().activeTab();
    if (window_ == nullptr || tab == nullptr) {
      return 0;
    }

    std::size_t count = 0;

    forEachLeaf(*tab, true, [&](const ClientLayoutPane& leaf) {
      if (terminals_.visible(leaf.pane_id) == nullptr) {
        return;
      }

      if (const auto* pane = store_.session().findPane(leaf.pane_id); pane != nullptr && pane->attached) {
        panes[count++] = {.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = true, .attachment_generation = pane->attachment_generation, .graphics_revision = pane->graphics.revision()};
      }
    });

    return count;
  }

  void FramePresenter::recordPreparedFrame(const PresentedFrame& frame) {
    if (!frame_pacer_) {
      return;
    }

    ds::Array<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes;

    for (std::size_t index = 0; index < frame.pane_count; ++index) {
      panes.atMut(index) = frame.panes[index].frame.pane;
    }

    frame_pacer_.getMut().record(std::span{panes}.first(frame.pane_count), frame.preparation_ns);
  }

  void FramePresenter::reconsider() {
    if (!frame_pacer_ || !frame_pacer_->pending()) {
      return;
    }

    ds::Array<application::window::FramePacer::Pane, PaneLayout::maximum_panes> panes;
    const auto count = collectPacingPanes(panes.viewMut());

    frame_pacer_.getMut().reconsider(std::span{panes}.first(count));
  }

  void FramePresenter::request() {
    if (!platform::supportsImmediateWindowUpdates()) {
      reconsider();

      return;
    }

    if (!frame_pacer_) {
      return;
    }

    if (frame_pacer_->pending()) {
      reconsider();

      return;
    }

    const auto pane_id = store_.session().changedPane();
    const auto* tab = store_.session().activeTab();
    if (tab == nullptr || !tab->layout.contains(pane_id) || (tab->fullscreen && tab->focused_pane != pane_id) || terminals_.visible(pane_id) == nullptr) {
      return;
    }

    if (const auto* pane = store_.session().findPane(pane_id); pane != nullptr && pane->attached && frame_pacer_) {
      frame_pacer_.getMut().requestInputFrame({.pane_id = pane->id, .frame_id = pane->screen.frameId(), .attached = true, .attachment_generation = pane->attachment_generation, .graphics_revision = pane->graphics.revision()});
    }
  }

  void FramePresenter::configure() {
    if (frame_pacer_ && window_ != nullptr) {
      frame_pacer_.getMut().configure(WindowAnimationClock::forWindow(*window_).frameInterval(), ds::none);
    }
  }

  void FramePresenter::present(const PresentedFrame& frame) {
    if (frame.machine_view != store_.machineView()) {
      return;
    }

    tabs_.present(frame.tabs);
    history_.present(frame.history);
    pointers_.presentHistoryActions(history_.presentedActions());

    try {
      for (const auto& pane : std::span{frame.panes}.first(frame.pane_count)) {
        const auto& identity = pane.frame.pane;
        const auto* current = store_.session().findPane(identity.pane_id);
        if (current == nullptr || !current->attached || current->attachment_generation != identity.attachment_generation) {
          continue;
        }

        auto* const terminal = pane.terminal.data();
        if (terminal != nullptr && terminal->controller() == &terminals_ && terminal->paneIdentity() == identity.pane_id) {
          terminal->presentFrame(pane.frame);
        }

        store_.sessionMut().presented(identity.pane_id, identity.frame_id);
      }
    } catch (const std::exception& error) {
      status_.fail(error);
    }
  }

}
