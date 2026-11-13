#pragma once

#include <QHash>
#include <QList>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QtQml/qqmlregistration.h>

#include <array>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

class WindowAnimationClock;

// Places the children of one mod element: a row, a column or a stack. Each child is an
// item with an `element` record; the layout reads its size, grow and pose from it and, for
// children with an `id` and a `transition`, eases between poses on the window clock.
class ElementLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(int direction READ direction WRITE setDirection NOTIFY layoutChanged)
  Q_PROPERTY(qreal gap READ gap WRITE setGap NOTIFY layoutChanged)
  Q_PROPERTY(QVariantList padding READ padding WRITE setPadding NOTIFY layoutChanged)
  Q_PROPERTY(int align READ align WRITE setAlign NOTIFY layoutChanged)
  Q_PROPERTY(int justify READ justify WRITE setJustify NOTIFY layoutChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY layoutChanged)

public:
  enum Direction : int {
    row,
    column,
    stack,
  };
  Q_ENUM(Direction)

  explicit ElementLayout(QQuickItem *parent = nullptr);
  ~ElementLayout() override;
  ElementLayout(const ElementLayout &) = delete;
  ElementLayout &operator=(const ElementLayout &) = delete;
  ElementLayout(ElementLayout &&) = delete;
  ElementLayout &operator=(ElementLayout &&) = delete;

  [[nodiscard]] int direction() const noexcept;
  void setDirection(int direction);
  [[nodiscard]] qreal gap() const noexcept;
  void setGap(qreal gap);
  [[nodiscard]] QVariantList padding() const;
  void setPadding(const QVariantList &padding);
  [[nodiscard]] int align() const noexcept;
  void setAlign(int align);
  [[nodiscard]] int justify() const noexcept;
  void setJustify(int justify);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);

  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
  void sample(std::uint64_t now_ns);

signals:
  void layoutChanged();

private slots:
  void relayout();

protected:
  void itemChange(ItemChange change, const ItemChangeData &value) override;
  void geometryChange(const QRectF &next, const QRectF &previous) override;
  void updatePolish() override;

private:
  struct Pose {
    qreal x = 0;
    qreal y = 0;
    qreal rotation = 0;
    qreal scale = 1;
    qreal opacity = 1;
  };

  struct Motion {
    Pose from;
    Pose to;
    Pose shown;
    std::uint64_t start_ns = 0;
    std::uint64_t duration_ns = 0;
    int easing = 0;
    bool seen = false;
  };

  void watch(QQuickItem *child);
  void bindClock();
  [[nodiscard]] Pose animate(const QString &key, const Pose &target, qreal transition_ms, int easing, std::uint64_t now_ns);

  int direction_ = row;
  qreal gap_ = 0;
  std::array<qreal, 4> padding_{};
  int align_ = 0;
  int justify_ = 0;
  qreal ratio_ = 1;
  QHash<QString, Motion> motions_;
  QPointer<WindowAnimationClock> clock_;
  std::optional<std::uint64_t> next_sample_ns_;
  bool frame_requested_ = false;
};

}
