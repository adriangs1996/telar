#pragma once

#include "tbc/view.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/kit/scene/ancestor_geometry.hpp"
#include <QColor>
#include <QQuickItem>
#include <QSGNode>
#include <QString>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

namespace telar::gui::qt {

  class ProviderMark : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(qreal dimmedAlpha READ dimmedAlpha CONSTANT)
    Q_PROPERTY(int provider READ provider WRITE setProvider NOTIFY providerChanged)
    Q_PROPERTY(bool telarMark READ telarMark WRITE setTelarMark NOTIFY telarMarkChanged)
    Q_PROPERTY(QString symbol READ symbol WRITE setSymbol NOTIFY symbolChanged)
    Q_PROPERTY(bool monochrome READ monochrome WRITE setMonochrome NOTIFY monochromeChanged)
    Q_PROPERTY(int theme READ theme WRITE setTheme NOTIFY themeChanged)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
    Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)

  public:
    explicit ProviderMark(QQuickItem* parent = nullptr);
    ~ProviderMark() override;
    ProviderMark(const ProviderMark&) = delete;
    ProviderMark& operator=(const ProviderMark&) = delete;
    ProviderMark(ProviderMark&&) = delete;
    ProviderMark& operator=(ProviderMark&&) = delete;
    [[nodiscard]] static qreal dimmedAlpha() noexcept;
    [[nodiscard]] int provider() const noexcept;
    void setProvider(int provider);
    [[nodiscard]] bool telarMark() const noexcept;
    void setTelarMark(bool enabled);
    // A bundled line icon by name, tinted with `color`; it takes the place of the provider's mark.
    [[nodiscard]] QString symbol() const;
    void setSymbol(const QString& symbol);
    [[nodiscard]] bool monochrome() const noexcept;
    void setMonochrome(bool monochrome);
    [[nodiscard]] int theme() const noexcept;
    void setTheme(int theme);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);

  signals:
    void providerChanged();
    void telarMarkChanged();
    void symbolChanged();
    void monochromeChanged();
    void themeChanged();
    void colorChanged();
    void ratioChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    tbc::val_self<AncestorGeometry> ancestors_;
    AgentProvider provider_ = AgentProvider::unknown;
    bool telar_mark_ = false;
    QString symbol_;
    bool monochrome_ = false;
    int theme_ = -1;
    QColor color_;
    qreal ratio_ = 1;
    bool dirty_ = true;
  };

}
