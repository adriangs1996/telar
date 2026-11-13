#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <optional>

#pragma once


import telar.gui.presentation.application_mark;

namespace telar::gui::qt {

class WindowAnimationClock;

class NativeAgentStatus : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap record READ record WRITE setRecord NOTIFY recordChanged REQUIRED)
  Q_PROPERTY(QString statusText READ statusText NOTIFY statusTextChanged)
  Q_PROPERTY(qreal animatedAlpha READ animatedAlpha NOTIFY animatedAlphaChanged)
  Q_PROPERTY(bool running READ running WRITE setRunning NOTIFY runningChanged)
  Q_PROPERTY(DisplayMode displayMode READ displayMode WRITE setDisplayMode NOTIFY displayModeChanged)

public:
  enum class DisplayMode : quint8 {
    card,
    compact,
    pane_chip,
  };
  Q_ENUM(DisplayMode)

  explicit NativeAgentStatus(QQuickItem *parent = nullptr);
  ~NativeAgentStatus() override;
  NativeAgentStatus(const NativeAgentStatus &) = delete;
  NativeAgentStatus &operator=(const NativeAgentStatus &) = delete;
  NativeAgentStatus(NativeAgentStatus &&) = delete;
  NativeAgentStatus &operator=(NativeAgentStatus &&) = delete;
  [[nodiscard]] QVariantMap record() const;
  void setRecord(const QVariantMap &record);
  [[nodiscard]] QString statusText() const;
  [[nodiscard]] qreal animatedAlpha() const noexcept;
  [[nodiscard]] bool running() const noexcept;
  void setRunning(bool running);
  [[nodiscard]] DisplayMode displayMode() const noexcept;
  void setDisplayMode(DisplayMode mode);

signals:
  void recordChanged();
  void statusTextChanged();
  void animatedAlphaChanged();
  void runningChanged();
  void displayModeChanged();

protected:
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
  QString status_text_;
  StatusAgeInterval interval_;
  AgentStatus status_ = AgentStatus::unknown;
  AgentBlockedReason reason_ = AgentBlockedReason::none;
  qreal animated_alpha_ = 1;
  bool connected_ = false;
  bool running_ = true;
  DisplayMode display_mode_ = DisplayMode::card;
  QPointer<WindowAnimationClock> clock_;
};

}
