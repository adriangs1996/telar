#pragma once

#include "chrome_fonts.hpp"
#include "input/tab_drag.hpp"
#include "input/tab_drop_slots.hpp"
#include "list_model.hpp"
#include "presentation/tab_motion_frame.hpp"
#include "presentation/tab_motions.hpp"
#include <QAbstractItemModel>
#include <QFont>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstddef>
#include <memory>

namespace telar::gui::qt {

class WindowAnimationClock;

class TabStripLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QAbstractItemModel *model READ model WRITE setModel NOTIFY modelChanged)
  Q_PROPERTY(QAbstractItemModel *items READ items CONSTANT)
  Q_PROPERTY(QFont font READ font WRITE setFont NOTIFY fontChanged)
  Q_PROPERTY(qreal pixelSize READ pixelSize WRITE setPixelSize NOTIFY fontChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(bool hovered READ hovered WRITE setHovered NOTIFY hoveredChanged)
  Q_PROPERTY(QRectF plus READ plus NOTIFY layoutChanged)
  Q_PROPERTY(QRectF stripBounds READ stripBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF selectionBounds READ selectionBounds NOTIFY layoutChanged)
  Q_PROPERTY(QRectF dropMarker READ dropMarker NOTIFY layoutChanged)
  Q_PROPERTY(QRectF draggedBounds READ draggedBounds NOTIFY layoutChanged)
  Q_PROPERTY(QString hoveredTab READ hoveredTab NOTIFY pointerHoverChanged)
  Q_PROPERTY(bool transitioning READ transitioning NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap counter READ counter NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap style READ style NOTIFY ratioChanged)

public:
  explicit TabStripLayout(QQuickItem *parent = nullptr);
  ~TabStripLayout() override;
  TabStripLayout(const TabStripLayout &) = delete;
  TabStripLayout &operator=(const TabStripLayout &) = delete;
  TabStripLayout(TabStripLayout &&) = delete;
  TabStripLayout &operator=(TabStripLayout &&) = delete;
  void setContext(std::uint64_t machine_view, std::optional<WorkspaceLocation> workspace);
  [[nodiscard]] QAbstractItemModel *model() const noexcept;
  void setModel(QAbstractItemModel *model);
  [[nodiscard]] QAbstractItemModel *items() noexcept;
  [[nodiscard]] QFont font() const;
  void setFont(const QFont &font);
  [[nodiscard]] qreal pixelSize() const noexcept;
  void setPixelSize(qreal size);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] bool hovered() const noexcept;
  void setHovered(bool hovered);
  [[nodiscard]] QRectF plus() const noexcept;
  [[nodiscard]] QRectF stripBounds() const noexcept {
    return strip_bounds_;
  }
  [[nodiscard]] QRectF selectionBounds() const noexcept {
    return selection_bounds_;
  }
  [[nodiscard]] QRectF dropMarker() const noexcept;
  [[nodiscard]] QRectF draggedBounds() const noexcept;
  [[nodiscard]] QString hoveredTab() const;
  void setPointerHover(std::optional<std::uint64_t> tab);

  [[nodiscard]] bool transitioning() const noexcept {
    return next_sample_ns_.has_value();
  }

  [[nodiscard]] std::size_t dropSlots(std::span<TabDropSlot> output) const;
  void setDrag(std::optional<TabDragMove> preview, std::optional<std::uint64_t> dragged, QPointF pointer, qreal grab_offset);
  [[nodiscard]] QVariantMap counter() const;
  [[nodiscard]] QVariantMap style() const;

signals:
  void modelChanged();
  void fontChanged();
  void ratioChanged();
  void hoveredChanged();
  void layoutChanged();
  void pointerHoverChanged();

protected:
  void updatePolish() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  friend class WindowAnimationClock;
  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
  void sample(std::uint64_t now_ns);
  void bindClock();
  static constexpr std::size_t model_connection_count = 6;
  [[nodiscard]] float captionAdvance(const QString &label);
  void rebuild();
  void raiseDraggedSlot();
  [[nodiscard]] QRectF placeTab(std::uint64_t id, QRectF bounds, TabMotionFrame &frame);
  [[nodiscard]] TabStripGeometry::Plan measureTabs(QList<QVariantMap> &records, std::span<TabStripGeometry::Measure> sizes, const TabStripGeometry::Room &room);

  QPointer<WindowAnimationClock> clock_;
  QMetaObject::Connection frame_connection_;
  TabMotions motions_;
  std::optional<TabMotion> selection_motion_;
  std::optional<WorkspaceLocation> workspace_;
  std::uint64_t machine_view_ = 0;
  std::optional<std::uint64_t> next_sample_ns_;
  bool frame_requested_ = false;
  QPointer<QAbstractItemModel> model_;
  std::array<QMetaObject::Connection, model_connection_count> connections_;
  ListModel items_{this};
  QFont font_;
  std::shared_ptr<ChromeFonts> fonts_;
  qreal pixel_size_ = 0;
  qreal ratio_ = 1;
  bool hovered_ = false;
  QString anchor_;
  QRectF plus_;
  QRectF strip_bounds_;
  QRectF selection_bounds_;
  QRectF drop_marker_;
  QRectF dragged_bounds_;
  std::array<TabDropSlot, TabDropSlots::capacity> drop_slots_{};
  std::size_t drop_slot_count_ = 0;
  std::optional<TabDragMove> drag_preview_;
  std::optional<std::uint64_t> dragged_;
  QPointF drag_pointer_;
  qreal drag_grab_offset_ = 0;
  QVariantMap counter_;
  std::optional<std::uint64_t> hovered_tab_;
};

}
