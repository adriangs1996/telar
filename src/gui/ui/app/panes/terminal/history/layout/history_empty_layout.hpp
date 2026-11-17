#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  class HistoryEmptyLayout : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariantMap input READ input WRITE setInput NOTIFY inputChanged)
    Q_PROPERTY(QVariantMap measurements READ measurements WRITE setMeasurements NOTIFY measurementsChanged)
    Q_PROPERTY(QString title READ title NOTIFY labelsChanged)
    Q_PROPERTY(QString subtitle READ subtitle NOTIFY labelsChanged)
    Q_PROPERTY(QString action READ action NOTIFY labelsChanged)
    Q_PROPERTY(bool emphasized READ emphasized NOTIFY labelsChanged)
    Q_PROPERTY(QVariantMap layout READ layout NOTIFY layoutChanged)

  public:
    explicit HistoryEmptyLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] QVariantMap input() const;
    void setInput(const QVariantMap& input);
    [[nodiscard]] QVariantMap measurements() const;
    void setMeasurements(const QVariantMap& measurements);
    [[nodiscard]] QString title() const;
    [[nodiscard]] QString subtitle() const;
    [[nodiscard]] QString action() const;
    [[nodiscard]] bool emphasized() const noexcept;
    [[nodiscard]] QVariantMap layout() const;

  signals:
    void inputChanged();
    void measurementsChanged();
    void labelsChanged();
    void layoutChanged();

  protected:
    void updatePolish() override;
    void componentComplete() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    void prepareLabels();

    QVariantMap input_;
    QVariantMap measurements_;
    application::history::HistoryEmpty content_;
    application::history::HistoryEmptyGeometry geometry_;
    qreal density_ = 1;
    qreal ratio_ = 1;
  };

}
