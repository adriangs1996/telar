#pragma once

#include "presentation/loading_cue.hpp"
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

namespace telar::gui::qt {

class WindowAnimationClock;

class HistoryLoadingLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(bool waiting READ waiting WRITE setWaiting NOTIFY waitingChanged)
  Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
  Q_PROPERTY(bool cueVisible READ cueVisible NOTIFY frameChanged)
  Q_PROPERTY(qreal rowsOpacity READ rowsOpacity NOTIFY frameChanged)
  Q_PROPERTY(QRectF line READ line NOTIFY frameChanged)

public:
  explicit HistoryLoadingLayout(QQuickItem *parent = nullptr);
  ~HistoryLoadingLayout() override;
  HistoryLoadingLayout(const HistoryLoadingLayout &) = delete;
  HistoryLoadingLayout &operator=(const HistoryLoadingLayout &) = delete;
  HistoryLoadingLayout(HistoryLoadingLayout &&) = delete;
  HistoryLoadingLayout &operator=(HistoryLoadingLayout &&) = delete;
  [[nodiscard]] bool waiting() const noexcept;
  void setWaiting(bool waiting);
  [[nodiscard]] qreal ratio() const noexcept;
  void setRatio(qreal ratio);
  [[nodiscard]] bool cueVisible() const noexcept;
  [[nodiscard]] qreal rowsOpacity() const noexcept;
  [[nodiscard]] QRectF line() const noexcept;

signals:
  void waitingChanged();
  void ratioChanged();
  void frameChanged();

protected:
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;

private:
  friend class WindowAnimationClock;
  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
  void sample(std::uint64_t now_ns);
  void synchronize();
  void bindClock();

  QPointer<WindowAnimationClock> clock_;
  LoadingCue cue_;
  QRectF line_;
  qreal ratio_ = 1;
  bool waiting_ = false;
  bool cue_visible_ = false;
};

}
