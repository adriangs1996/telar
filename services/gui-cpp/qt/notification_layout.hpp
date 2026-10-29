#pragma once

#include "application.hpp"
#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "font_collection.hpp"
#include "list_model.hpp"
#include "memory/fixed_text.hpp"
#include "presentation/notification_geometry.hpp"
#include "presentation/notification_stack.hpp"
#include "presentation/notification_text.hpp"
#include "resident_fonts.hpp"
#include <QAbstractItemModel>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

class WindowAnimationClock;
class WindowFontCatalog;

class NotificationLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(telar::gui::qt::Application *controller READ controller WRITE setController NOTIFY controllerChanged)
  Q_PROPERTY(QAbstractItemModel *cards READ cards CONSTANT)
  Q_PROPERTY(QRectF host READ host NOTIFY layoutChanged)
  Q_PROPERTY(QVariantMap style READ style NOTIFY layoutChanged)

public:
  explicit NotificationLayout(QQuickItem *parent = nullptr);
  ~NotificationLayout() override;
  NotificationLayout(const NotificationLayout &) = delete;
  NotificationLayout &operator=(const NotificationLayout &) = delete;
  NotificationLayout(NotificationLayout &&) = delete;
  NotificationLayout &operator=(NotificationLayout &&) = delete;
  [[nodiscard]] Application *controller() const noexcept;
  void setController(Application *controller);
  [[nodiscard]] QAbstractItemModel *cards() noexcept;
  [[nodiscard]] QRectF host() const noexcept;
  [[nodiscard]] QVariantMap style() const;
  [[nodiscard]] bool eligible() const noexcept;
  [[nodiscard]] std::optional<std::uint64_t> deadline(std::uint64_t now_ns) const;
  void sample(std::uint64_t now_ns);

signals:
  void controllerChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;

private:
  struct Content {
    NotificationId id{};
    runtime::FixedText<max_notification_message_bytes> message;
    NotificationText body;
    QVariantMap record;
    float width = 0;
    float height = 0;
    float action_advance = 0;
    float action_line_height = 0;
  };

  void invalidate();
  void scheduleLayout();
  void bindWindow();
  void rebuild();
  void refreshFonts();
  Content &content(const NotificationItem &item, float width);
  QVariantMap contentRecord(const NotificationItem &item, Content &content);
  [[nodiscard]] float measure(std::string_view text, std::uint16_t pixels, bool emphasized);

  QPointer<Application> controller_;
  QPointer<WindowAnimationClock> clock_;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection font_connection_;
  ListModel cards_;
  NotificationStack stack_;
  std::array<Content, NotificationCenter::capacity> contents_;
  std::shared_ptr<const FontCollection> collection_;
  std::shared_ptr<ResidentFonts> fonts_;
  ChromeMetrics chrome_;
  NotificationMetrics metrics_;
  QVariantMap style_;
  QRectF host_;
  qreal density_ = 1;
  std::uint64_t now_ns_ = 0;
  std::uint64_t machine_view_ = 0;
  std::optional<std::uint64_t> motion_end_ns_;
};

}
