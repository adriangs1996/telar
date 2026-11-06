#pragma once

#include "list_model.hpp"
#include "presentation/pane_motions.hpp"
#include <QAbstractItemModel>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <optional>

namespace telar::gui::qt {

class WindowAnimationClock;

class PaneMotionLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QAbstractItemModel *model READ model WRITE setModel NOTIFY modelChanged)
  Q_PROPERTY(QAbstractItemModel *items READ items CONSTANT)
  Q_PROPERTY(bool animationsEnabled READ motionEnabled WRITE setMotionEnabled NOTIFY motionEnabledChanged)

public:
  explicit PaneMotionLayout(QQuickItem *parent = nullptr);
  ~PaneMotionLayout() override;

  [[nodiscard]] QAbstractItemModel *model() const noexcept {
    return model_;
  }

  void setModel(QAbstractItemModel *model);

  [[nodiscard]] QAbstractItemModel *items() noexcept {
    return &items_;
  }

  [[nodiscard]] bool motionEnabled() const noexcept {
    return enabled_;
  }

  void setMotionEnabled(bool enabled);

signals:
  void modelChanged();
  void motionEnabledChanged();

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

  QPointer<QAbstractItemModel> model_;
  std::array<QMetaObject::Connection, 6> connections_;
  ListModel items_{this};
  PaneMotions motions_;
  QString context_;
  QPointer<WindowAnimationClock> clock_;
  QMetaObject::Connection frame_connection_;
  std::optional<std::uint64_t> next_sample_ns_;
  bool frame_requested_ = false;
  bool immediate_ = true;
  bool enabled_ = true;
};

}
