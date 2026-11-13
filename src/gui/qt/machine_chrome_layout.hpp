#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "list_model.hpp"
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <span>
#include "resident_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QList>
#include <QMetaObject>
#include <QPointer>
#include <QQuickItem>
#include <QString>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>
#include <memory>

#pragma once


import telar.gui.core.metrics;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

class Application;
class WindowFontCatalog;

class MachineChromeLayout : public QQuickItem {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(telar::gui::qt::Application *controller READ controller WRITE setController NOTIFY controllerChanged)
  Q_PROPERTY(bool segment READ segment WRITE setSegment NOTIFY segmentChanged)
  Q_PROPERTY(bool inlineFacts READ inlineFacts WRITE setInlineFacts NOTIFY inlineFactsChanged)
  Q_PROPERTY(bool shown READ shown NOTIFY shownChanged)
  Q_PROPERTY(qreal preferredWidth READ preferredWidth NOTIFY layoutChanged)
  Q_PROPERTY(QAbstractItemModel *items READ items CONSTANT)
  Q_PROPERTY(QVariantMap style READ style NOTIFY layoutChanged)

public:
  explicit MachineChromeLayout(QQuickItem *parent = nullptr);
  [[nodiscard]] Application *controller() const noexcept;
  void setController(Application *controller);
  [[nodiscard]] bool segment() const noexcept;
  void setSegment(bool segment);
  [[nodiscard]] bool inlineFacts() const noexcept;
  void setInlineFacts(bool enabled);
  [[nodiscard]] bool shown() const noexcept;
  [[nodiscard]] qreal preferredWidth() const noexcept;
  [[nodiscard]] QAbstractItemModel *items() noexcept;
  [[nodiscard]] QVariantMap style() const;
  Q_INVOKABLE void activate(const QString &identity);

signals:
  void controllerChanged();
  void segmentChanged();
  void inlineFactsChanged();
  void shownChanged();
  void layoutChanged();

protected:
  void updatePolish() override;
  void geometryChange(const QRectF &current, const QRectF &previous) override;
  void itemChange(ItemChange change, const ItemChangeData &data) override;

private:
  enum class Mode : std::uint8_t {
    list,
    segment,
    facts,
  };

  // The tab strip shows at most three cards of a stack; a machine row does too.
  static constexpr std::size_t stack_cards = 3;

  // One agent that works or waits on a machine other than the active one.
  struct StackCard {
    std::uint8_t provider = 0;
    std::uint8_t status = 0;

    bool operator==(const StackCard &) const = default;
  };

  struct Source {
    MachineToken token;
    runtime::FixedText<MachineLimits::label_bytes> label;
    runtime::FixedText<MachineLimits::color_bytes> color;
    bool active = false;
    bool attention = false;
    bool live = false;
    MachinePhase phase = MachinePhase::connecting;
    std::optional<std::uint8_t> cpu_percent = std::nullopt;
    std::array<StackCard, stack_cards> cards{};
    std::size_t card_count = 0;

    bool operator==(const Source &other) const noexcept {
      return token == other.token && label.view() == other.label.view() && color.view() == other.color.view() && active == other.active && attention == other.attention && live == other.live && phase == other.phase && cpu_percent == other.cpu_percent && card_count == other.card_count && cards == other.cards;
    }
  };

  void setMode(Mode mode);
  void observeSources();
  void invalidate();
  void bindWindow();
  void rebuild();
  [[nodiscard]] qreal segmentRecords(Rect area, QList<QVariantMap> &records);
  qreal listRecords(Rect area, QList<QVariantMap> &records);
  [[nodiscard]] QVariantMap listRecord(const Source &source, const MachineChromeGeometry::ListRow &row) const;
  void collectCards(Machines::Slot slot, Source &source) const;
  qreal factsRecords(Rect area, QList<QVariantMap> &records);
  [[nodiscard]] QVariantMap factRecord(const Source &source, const MachineFacts::Geometry &geometry) const;
  [[nodiscard]] float measure(std::string_view text, bool emphasized) const;
  [[nodiscard]] QVariantMap controlRecord(const Source &source, Rect bounds, float advance) const;
  [[nodiscard]] QVariantMap geometryRecord(const MachineChromeGeometry::Control &geometry) const;
  [[nodiscard]] QColor ink(std::string_view written) const;
  [[nodiscard]] QColor fill(CellColor value) const;

  QPointer<Application> controller_;
  QPointer<WindowFontCatalog> catalog_;
  QMetaObject::Connection font_connection_;
  std::shared_ptr<ResidentFonts> fonts_;
  std::array<std::optional<Source>, MachineLimits::window_slots> sources_;
  ListModel items_{this};
  QVariantMap style_;
  ChromeMetrics chrome_;
  qreal density_ = 1;
  qreal preferred_width_ = 0;
  Mode mode_ = Mode::list;
  bool shown_ = false;
  bool attention_elsewhere_ = false;
};

}
