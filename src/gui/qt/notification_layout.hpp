#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "application.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string_view>
#include <array>
#include <optional>
#include <span>
#include <stdexcept>
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "font_collection.hpp"
#include "list_model.hpp"
#include <concepts>
#include <charconv>
#include <cstring>
#include <system_error>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "resident_fonts.hpp"
#include <QAbstractItemModel>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QRectF>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <memory>

#pragma once

#include "core/memory.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.presentation.notification_stack;
import telar.gui.presentation.history_meta_geometry;

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
  // The body wraps the message stored beside it, so a content stays where it is.
  struct Content {
    Content() = default;
    ~Content() = default;
    Content(const Content &) = delete;
    Content &operator=(const Content &) = delete;
    Content(Content &&) = delete;
    Content &operator=(Content &&) = delete;

    void clear() {
      id = {};
      message.assign({});
      body = {};
      record.clear();
      width = 0;
      height = 0;
      action_advance = 0;
      action_line_height = 0;
    }

    NotificationId id{};
    runtime::FixedText<max_notification_message_bytes> message;
    tbc::view<NotificationText, tbc::lt::self> body;
    QVariantMap record;
    float width = 0;
    float height = 0;
    float action_advance = 0;
    float action_line_height = 0;
  };

  void retireRemovedFocus(int first, int last);
  void invalidate();
  void scheduleLayout();
  void bindWindow();
  void rebuild();
  void refreshFonts();
  Content &content(const NotificationItem &item, float width);
  struct ContentRecord {
    QVariantMap record;
    float action_advance = 0;
    float action_line_height = 0;
  };

  [[nodiscard]] ContentRecord contentRecord(const NotificationItem &item, const Content &content) const;
  // Measures through the window's catalog and the resident fonts, apart from the layout's state.
  [[nodiscard]] static float measure(WindowFontCatalog &catalog, ResidentFonts &fonts, std::string_view text, std::uint16_t pixels, bool emphasized);

  QPointer<Application> controller_;
  QPointer<WindowAnimationClock> clock_;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection font_connection_;
  ListModel cards_;
  NotificationStack stack_;
  tbc::view<std::array<Content, NotificationCenter::capacity>, tbc::lt::self> contents_;
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
