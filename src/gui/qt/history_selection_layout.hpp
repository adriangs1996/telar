#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#pragma once


import telar.gui.presentation.display_metrics;

namespace telar::gui::qt {

class WindowAnimationClock;

class HistorySelectionLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(QVariantMap selection READ selection WRITE setSelection NOTIFY selectionChanged)
  Q_PROPERTY(qreal selectedOpen READ selectedOpen NOTIFY frameChanged)
  Q_PROPERTY(int leavingIndex READ leavingIndex NOTIFY frameChanged)
  Q_PROPERTY(QString leavingKey READ leavingKey NOTIFY frameChanged)
  Q_PROPERTY(qreal leavingOpen READ leavingOpen NOTIFY frameChanged)

public:
  explicit HistorySelectionLayout(QQuickItem *parent = nullptr);
  ~HistorySelectionLayout() override;
  HistorySelectionLayout(const HistorySelectionLayout &) = delete;
  HistorySelectionLayout &operator=(const HistorySelectionLayout &) = delete;
  HistorySelectionLayout(HistorySelectionLayout &&) = delete;
  HistorySelectionLayout &operator=(HistorySelectionLayout &&) = delete;
  [[nodiscard]] QVariantMap selection() const;
  void setSelection(const QVariantMap &selection);
  [[nodiscard]] qreal selectedOpen() const noexcept;
  [[nodiscard]] int leavingIndex() const noexcept;
  [[nodiscard]] QString leavingKey() const;
  [[nodiscard]] qreal leavingOpen() const noexcept;

signals:
  void selectionChanged();
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

  QVariantMap selection_;
  QPointer<WindowAnimationClock> clock_;
  QMetaObject::Connection frame_connection_;
  HistorySelectionMotion motion_;
  HistoryExpansion expansion_;
  QString leaving_key_;
  std::optional<std::uint64_t> generation_;
  std::optional<HistoryPosition> selected_;
  std::optional<std::uint64_t> next_sample_ns_;
  bool dirty_ = true;
  bool frame_requested_ = false;
};

}
