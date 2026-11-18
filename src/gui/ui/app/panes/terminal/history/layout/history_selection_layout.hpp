#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class WindowAnimationClock;

  template <typename Item>
  class WindowAnimationItems;

  class HistorySelectionLayout : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantMap selection READ selection WRITE setSelection NOTIFY selectionChanged)
    Q_PROPERTY(qreal selectedOpen READ selectedOpen NOTIFY frameChanged)
    Q_PROPERTY(int leavingIndex READ leavingIndex NOTIFY frameChanged)
    Q_PROPERTY(QString leavingKey READ leavingKey NOTIFY frameChanged)
    Q_PROPERTY(qreal leavingOpen READ leavingOpen NOTIFY frameChanged)

  public:
    explicit HistorySelectionLayout(QQuickItem* parent = nullptr);
    ~HistorySelectionLayout() override;
    HistorySelectionLayout(const HistorySelectionLayout&) = delete;
    HistorySelectionLayout& operator=(const HistorySelectionLayout&) = delete;
    HistorySelectionLayout(HistorySelectionLayout&&) = delete;
    HistorySelectionLayout& operator=(HistorySelectionLayout&&) = delete;
    [[nodiscard]] QVariantMap selection() const;
    void setSelection(const QVariantMap& selection);
    [[nodiscard]] qreal selectedOpen() const noexcept;
    [[nodiscard]] int leavingIndex() const noexcept;
    [[nodiscard]] QString leavingKey() const;
    [[nodiscard]] qreal leavingOpen() const noexcept;

  signals:
    void selectionChanged();
    void frameChanged();

  protected:
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<HistorySelectionLayout>;
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;
    void sample(std::uint64_t now_ns);
    void prepareFrame();
    void bindClock();
    void synchronize();

    QVariantMap selection_;
    QPointer<WindowAnimationClock> clock_;
    QMetaObject::Connection frame_connection_;
    application::history::HistorySelectionMotion motion_;
    application::history::HistoryExpansion expansion_;
    QString leaving_key_;
    ds::Option<std::uint64_t> generation_;
    ds::Option<application::history::HistoryPosition> selected_;
    ds::Option<std::uint64_t> next_sample_ns_;
    bool dirty_ = true;
    bool frame_requested_ = false;
  };

}
