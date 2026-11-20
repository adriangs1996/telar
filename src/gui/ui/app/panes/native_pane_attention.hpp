#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/view.hpp"
#include "ui/kit/scene/ancestor_geometry.hpp"
#include "ui/kit/scene/window_animation_clock.hpp"
#include <QColor>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QVariant>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class NativePaneAttention : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QVariant attachment READ attachment WRITE setAttachment NOTIFY attachmentChanged)
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(QColor color READ color WRITE setColor NOTIFY colorChanged)
    Q_PROPERTY(qreal ratio READ ratio WRITE setRatio NOTIFY ratioChanged)
    Q_PROPERTY(qreal radius READ radius WRITE setRadius NOTIFY radiusChanged)
    Q_PROPERTY(qreal alpha READ alpha NOTIFY alphaChanged)

  public:
    class WindowAnimationSet;

    explicit NativePaneAttention(QQuickItem* parent = nullptr);
    ~NativePaneAttention() override;
    NativePaneAttention(const NativePaneAttention&) = delete;
    NativePaneAttention& operator=(const NativePaneAttention&) = delete;
    NativePaneAttention(NativePaneAttention&&) = delete;
    NativePaneAttention& operator=(NativePaneAttention&&) = delete;

    [[nodiscard]] QVariant attachment() const;
    void setAttachment(const QVariant& attachment);
    [[nodiscard]] bool active() const noexcept;
    void setActive(bool active);
    [[nodiscard]] QColor color() const;
    void setColor(const QColor& color);
    [[nodiscard]] qreal ratio() const noexcept;
    void setRatio(qreal ratio);
    [[nodiscard]] qreal radius() const noexcept;
    void setRadius(qreal radius);
    [[nodiscard]] qreal alpha() const noexcept;

  signals:
    void attachmentChanged();
    void activeChanged();
    void colorChanged();
    void ratioChanged();
    void radiusChanged();
    void alphaChanged();

  protected:
    QSGNode* updatePaintNode(QSGNode* previous, UpdatePaintNodeData* data) override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

  private:
    friend class WindowAnimationItems<NativePaneAttention>;
    void bindClock();
    void synchronize();
    void setAlpha(float alpha);
    void sample(std::uint64_t now_ns, application::workbench::AttentionFades& fades);
    [[nodiscard]] bool eligible() const noexcept;
    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t now_ns) const noexcept;

    ds::Option<application::workbench::PaneAttentionKey> key_;
    QColor color_ = Qt::transparent;
    qreal ratio_ = 1;
    qreal radius_ = static_cast<qreal>(gui::application::workbench::PaneDecorationGeometry::frame_radius);
    float alpha_ = 0;
    bool active_ = false;
    bool notification_pending_ = false;
    ds::Option<std::uint64_t> deadline_ns_;
    QPointer<WindowAnimationClock> clock_;
    tbc::val_self<AncestorGeometry> ancestors_;
  };

  // The attention rings of one window share their fades and are sampled only while the
  // window is exposed.
  class NativePaneAttention::WindowAnimationSet {
  public:
    void attach(NativePaneAttention& item) {
      items_.attach(item);
    }

    void detach(NativePaneAttention& item) {
      items_.detach(item);
    }

    bool sample(std::uint64_t timestamp, bool window_exposed, const QPointer<WindowAnimationClock>& alive);

    [[nodiscard]] ds::Option<std::uint64_t> deadline(std::uint64_t timestamp) const {
      return items_.deadline(timestamp);
    }

  private:
    WindowAnimationItems<NativePaneAttention> items_;
    application::workbench::AttentionFades fades_;
  };

}
