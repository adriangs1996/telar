#pragma once

#include "ancestor_geometry.hpp"
#include "presentation/progress_motion.hpp"
#include "presentation/tab_activity.hpp"
#include <QColor>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

class WindowAnimationClock;

class NativeTabActivity : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap record READ record WRITE setRecord NOTIFY recordChanged REQUIRED)
  Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
  Q_PROPERTY(bool compact READ compact WRITE setCompact NOTIFY compactChanged)
  Q_PROPERTY(qreal fraction READ fraction NOTIFY animationChanged)
  Q_PROPERTY(qreal turns READ turns NOTIFY animationChanged)

public:
  explicit NativeTabActivity(QQuickItem *parent = nullptr);
  ~NativeTabActivity() override;
  NativeTabActivity(const NativeTabActivity &) = delete;
  NativeTabActivity &operator=(const NativeTabActivity &) = delete;
  NativeTabActivity(NativeTabActivity &&) = delete;
  NativeTabActivity &operator=(NativeTabActivity &&) = delete;
  [[nodiscard]] QVariantMap record() const;
  void setRecord(const QVariantMap &record);
  [[nodiscard]] QColor color() const;
  void setColor(const QColor &color);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] bool running() const noexcept;
  void setRunning(bool running);
  [[nodiscard]] bool compact() const noexcept;
  void setCompact(bool compact);
  [[nodiscard]] qreal fraction() const noexcept;
  [[nodiscard]] qreal turns() const noexcept;

signals:
  void recordChanged();
  void colorChanged();
  void ratioChanged();
  void runningChanged();
  void animationChanged();
  void compactChanged();

protected:
  QSGNode *updatePaintNode(QSGNode *previous, UpdatePaintNodeData *data) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;

private:
  friend class WindowAnimationClock;
  void bindClock();
  void synchronize();
  void sample(std::uint64_t now_ns);
  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

  QVariantMap record_;
  QColor color_ = Qt::white;
  qreal ratio_ = 1;
  TabActivity::Kind kind_ = TabActivity::Kind::none;
  ProgressSample progress_;
  ProgressMotion motion_;
  float fraction_ = 0;
  float turns_ = 0;
  bool running_ = true;
  bool compact_ = true;
  bool animation_notification_pending_ = false;
  QPointer<WindowAnimationClock> clock_;
  AncestorGeometry ancestors_;
};

}
