#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "ancestor_geometry.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <exception>
#include "telar_config/graphics/limits.hpp"
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include <tuple>
#include "telar_client/serializers/telar_cells.hpp"
#include <charconv>
#include <cstring>
#include <system_error>
#include <cmath>
#include <QColor>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QSGNode>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

#pragma once



import telar.gui.presentation.display_metrics;
import telar.gui.presentation.activity_order;

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
  tbc::view<AncestorGeometry, tbc::lt::self> ancestors_;
};

}
