#pragma once

#include "core/metrics.hpp"
#include "list_model.hpp"
#include "machines/limits.hpp"
#include "machines/machine_row.hpp"
#include "machines/machine_token.hpp"
#include "presentation/machine_chrome_geometry.hpp"
#include "presentation/machine_facts.hpp"
#include "resident_fonts.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
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
#include <memory>
#include <optional>
#include <string_view>

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
    switcher,
    segment,
    facts,
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

    bool operator==(const Source &other) const noexcept {
      return token == other.token && label.view() == other.label.view() && color.view() == other.color.view() && active == other.active && attention == other.attention && live == other.live && phase == other.phase && cpu_percent == other.cpu_percent;
    }
  };

  void setMode(Mode mode);
  void observeSources();
  void invalidate();
  void bindWindow();
  void rebuild();
  [[nodiscard]] qreal segmentRecords(Rect area, QList<QVariantMap> &records);
  qreal switcherRecords(Rect area, QList<QVariantMap> &records);
  qreal factsRecords(Rect area, QList<QVariantMap> &records);
  [[nodiscard]] QVariantMap factRecord(const Source &source, const MachineFacts::Geometry &geometry) const;
  [[nodiscard]] float measure(std::string_view text, bool emphasized);
  [[nodiscard]] QVariantMap controlRecord(const Source &source, Rect bounds, float advance) const;
  [[nodiscard]] QVariantMap foldRecord(Rect bounds, std::size_t count);
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
  Mode mode_ = Mode::switcher;
  bool shown_ = false;
  bool attention_elsewhere_ = false;
};

}
