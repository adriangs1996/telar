#pragma once

#include "presentation/modal_motion.hpp"
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

class WindowAnimationClock;

class ModalRevealLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QString generation READ generation WRITE setGeneration NOTIFY generationChanged)
  Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
  Q_PROPERTY(qreal reveal READ reveal NOTIFY frameChanged)

public:
  explicit ModalRevealLayout(QQuickItem *parent = nullptr);
  ~ModalRevealLayout() override;
  ModalRevealLayout(const ModalRevealLayout &) = delete;
  ModalRevealLayout &operator=(const ModalRevealLayout &) = delete;
  ModalRevealLayout(ModalRevealLayout &&) = delete;
  ModalRevealLayout &operator=(ModalRevealLayout &&) = delete;
  [[nodiscard]] QString generation() const;
  void setGeneration(const QString &generation);
  [[nodiscard]] bool active() const noexcept;
  void setActive(bool active);
  [[nodiscard]] qreal reveal() const noexcept;

signals:
  void generationChanged();
  void activeChanged();
  void frameChanged();

protected:
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  friend class WindowAnimationClock;
  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
  void sample(std::uint64_t now_ns);
  void prepareFrame();
  void bindClock();
  void synchronize();

  QString generation_;
  std::optional<std::uint64_t> identity_;
  QPointer<WindowAnimationClock> clock_;
  QMetaObject::Connection frame_connection_;
  ModalMotion motion_;
  std::optional<std::uint64_t> next_sample_ns_;
  qreal reveal_ = 1;
  bool active_ = false;
  bool dirty_ = true;
  bool frame_requested_ = false;
};

}
