#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/design/elements/element_slots.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/store/store.hpp"
#include <QAbstractItemModel>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QObject>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class TabStripLayout;

  // The tabs of the active workspace, in their order, with what a mod draws for each, and the
  // strip that shows them: which workspace it shows, where its tabs were presented and the drag
  // that reorders them.
  //
  // It reads the active session in the store. Each synchronize() compares the versions it
  // projected last with the current ones and rebuilds the records only when one moved. The
  // window pushes the window the strip lives in and the tab surface of each presented frame; the
  // pointer dispatcher routes the window's pointer and Escape key here first.
  class TabsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(TabsController)
    QML_UNCREATABLE("Use the window's tabs")
    Q_PROPERTY(QAbstractItemModel* rows READ rows CONSTANT)

  public:
    TabsController(Store& store, ElementSlots& elements, QObject* parent = nullptr);
    ~TabsController() override = default;
    TabsController(const TabsController&) = delete;
    TabsController& operator=(const TabsController&) = delete;
    TabsController(TabsController&&) = delete;
    TabsController& operator=(TabsController&&) = delete;

    void synchronize();
    // The active session is about to change: nothing projected belongs to the next one.
    void forget();
    [[nodiscard]] QAbstractItemModel* rows() noexcept;
    [[nodiscard]] int count() const noexcept;
    // How many synchronize() calls rebuilt the records, for tests and probes that check what a
    // change costs.
    [[nodiscard]] std::uint64_t rebuilds() const noexcept;

    // A mod may place its own strip; the visible one owns dragging.
    Q_INVOKABLE void registerStrip(QQuickItem* strip);
    // Tells the strip which machine view and workspace it shows.
    void synchronizeStrip();
    void setWindow(QQuickWindow& window);
    // Where the strip's tabs and its new tab button sit in the window, in physical pixels, for
    // the frame being prepared. `ratio` is the window's chrome ratio.
    [[nodiscard]] application::workbench::TabDropSurface dropSurface(qreal ratio) const;
    // The tab surface of the frame the window presented: pointer hits test against it.
    void present(const application::workbench::TabDropSurface& surface);
    // A press on a tab selects it, when the tab the pointer captured still shows where the
    // window presented it.
    Q_INVOKABLE void selectCaptured();

    [[nodiscard]] ds::Option<TabLocation> capturedTab() const noexcept {
      return drag_.source();
    }

    void observeHover(ds::Option<QPointF> position);
    // Escape cancels a drag and swallows its own release. False leaves the key to the window.
    [[nodiscard]] bool key(QKeyEvent& event);
    // A left press on a presented tab captures it. `ratio` is the window's chrome ratio.
    [[nodiscard]] bool press(QMouseEvent& event, qreal ratio);
    // Moves or drops the captured tab; a drop asks the session to move it.
    [[nodiscard]] bool drag(QMouseEvent& event, bool released);
    // The pointer left the window: the drag keeps its tab and loses its destination.
    void leave();
    void cancelDrag();

  signals:
    void selectRequested(qulonglong tab_id);

  private:
    struct Inputs {
      std::uint64_t machine_view = 0;
      std::uint64_t runtime_generation = 0;
      std::uint64_t tabs = 0;
      std::uint64_t active_tab = 0;
      std::uint64_t panes = 0;
      std::uint64_t configuration = 0;
      std::uint64_t chrome = 0;
      std::uint64_t agents = 0;
      std::uint64_t elements = 0;

      bool operator==(const Inputs&) const = default;
    };

    [[nodiscard]] Inputs inputs() const;
    // Retires the drag and the pending move the presented tabs no longer hold.
    void validateDrag();
    void updateDragVisual();

    Store& store_;
    ElementSlots& elements_;
    ListModel rows_;
    ds::Option<Inputs> synchronized_;
    std::uint64_t rebuilds_ = 0;
    QPointer<TabStripLayout> strip_;
    QPointer<QQuickWindow> window_;
    application::workbench::TabDropSurface presented_;
    application::workbench::TabDrag drag_;
    application::workbench::TabDropSlots drop_slots_;
    ds::Option<application::workbench::TabDragMove> pending_move_;
    application::workbench::TabDropSurface capture_surface_;
    QPointF pointer_;
    qreal grab_offset_ = 0;
    bool escape_held_ = false;
  };

}
