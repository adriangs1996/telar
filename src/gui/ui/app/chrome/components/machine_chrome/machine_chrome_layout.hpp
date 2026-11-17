#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_chrome_controller.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "ui/foundation/fonts/resident_fonts.hpp"
#include "ui/foundation/models/list_model.hpp"
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
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <string_view>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  class WindowFontCatalog;

  class MachineChromeLayout : public QQuickItem {
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(telar::gui::qt::MachineChromeController* controller READ controller WRITE setController NOTIFY controllerChanged)
    Q_PROPERTY(bool segment READ segment WRITE setSegment NOTIFY segmentChanged)
    Q_PROPERTY(bool inlineFacts READ inlineFacts WRITE setInlineFacts NOTIFY inlineFactsChanged)
    Q_PROPERTY(bool shown READ shown NOTIFY shownChanged)
    Q_PROPERTY(qreal preferredWidth READ preferredWidth NOTIFY layoutChanged)
    Q_PROPERTY(QAbstractItemModel* items READ items CONSTANT)
    Q_PROPERTY(QVariantMap style READ style NOTIFY layoutChanged)

  public:
    explicit MachineChromeLayout(QQuickItem* parent = nullptr);
    [[nodiscard]] MachineChromeController* controller() const noexcept;
    void setController(MachineChromeController* controller);
    [[nodiscard]] bool segment() const noexcept;
    void setSegment(bool segment);
    [[nodiscard]] bool inlineFacts() const noexcept;
    void setInlineFacts(bool enabled);
    [[nodiscard]] bool shown() const noexcept;
    [[nodiscard]] qreal preferredWidth() const noexcept;
    [[nodiscard]] QAbstractItemModel* items() noexcept;
    [[nodiscard]] QVariantMap style() const;
    Q_INVOKABLE void activate(const QString& identity);

  signals:
    void controllerChanged();
    void segmentChanged();
    void inlineFactsChanged();
    void shownChanged();
    void layoutChanged();

  protected:
    void updatePolish() override;
    void geometryChange(const QRectF& current, const QRectF& previous) override;
    void itemChange(ItemChange change, const ItemChangeData& data) override;

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

      bool operator==(const StackCard&) const = default;
    };

    struct Source {
      application::machines::MachineToken token;
      runtime::FixedText<application::machines::MachineLimits::label_bytes> label;
      runtime::FixedText<application::machines::MachineLimits::color_bytes> color;
      bool active = false;
      bool attention = false;
      bool live = false;
      application::machines::MachinePhase phase = application::machines::MachinePhase::connecting;
      std::optional<std::uint8_t> cpu_percent = std::nullopt;
      std::array<StackCard, stack_cards> cards{};
      std::size_t card_count = 0;
      // Every agent that works or waits there, past the cards the stack shows.
      std::size_t agent_count = 0;

      bool operator==(const Source& other) const noexcept {
        return agent_count == other.agent_count && token == other.token && label.view() == other.label.view() && color.view() == other.color.view() && active == other.active && attention == other.attention && live == other.live && phase == other.phase && cpu_percent == other.cpu_percent && card_count == other.card_count && cards == other.cards;
      }
    };

    void setMode(Mode mode);
    void observeSources();
    void invalidate();
    void bindWindow();
    void rebuild();
    [[nodiscard]] qreal segmentRecords(Rect area, QList<QVariantMap>& records);
    qreal listRecords(Rect area, QList<QVariantMap>& records);
    [[nodiscard]] QVariantMap listRecord(const Source& source, const application::machines::MachineChromeGeometry::ListRow& row) const;
    void collectCards(application::machines::Machines::Slot slot, Source& source) const;
    qreal factsRecords(Rect area, QList<QVariantMap>& records);
    [[nodiscard]] QVariantMap factRecord(const Source& source, const application::machines::MachineFacts::Geometry& geometry) const;
    [[nodiscard]] float measure(std::string_view text, bool emphasized) const;
    [[nodiscard]] QVariantMap controlRecord(const Source& source, Rect bounds, float advance) const;
    [[nodiscard]] QVariantMap geometryRecord(const application::machines::MachineChromeGeometry::Control& geometry) const;
    [[nodiscard]] QColor ink(std::string_view written) const;
    [[nodiscard]] QColor fill(CellColor value) const;

    QPointer<MachineChromeController> controller_;
    QPointer<WindowFontCatalog> catalog_;
    QMetaObject::Connection font_connection_;
    std::shared_ptr<ResidentFonts> fonts_;
    std::array<std::optional<Source>, application::machines::MachineLimits::window_slots> sources_;
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
