export module telar.gui.ui.design.controls:cell_text_grid;

import std;
import telar.gui.qt;
import telar.gui.foundation.terminal;

export namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  struct CellTextGrid {
    FontGrid metrics;
    QString family;
    QString style;

    [[tbc::hot_path]] [[nodiscard]] inline QVariantMap record(qreal scale) const {
      return {
          {u"family"_s, family},
          {u"style"_s, style},
          {u"pixelHeight"_s, metrics.pixel_height / scale},
          {u"cellWidth"_s, metrics.width / scale},
          {u"cellHeight"_s, metrics.height / scale},
          {u"baseline"_s, static_cast<qreal>(metrics.baseline) / scale},
      };
    }

    [[tbc::hot_path]] [[nodiscard]] inline static CellTextGrid resolve(const QVariantMap& value, qreal scale) {
      CellTextGrid result;

      result.metrics.width = dimension(value, "cellWidth", scale);
      result.metrics.height = dimension(value, "cellHeight", scale);
      result.metrics.pixel_height = dimension(value, "pixelHeight", scale);
      result.metrics.baseline = static_cast<float>(value.value(u"baseline"_s).toDouble() * scale);
      if (!std::isfinite(result.metrics.baseline)) {
        throw std::invalid_argument{"InvalidCellTextBaseline"};
      }

      result.family = value.value(u"family"_s).toString();
      result.style = value.value(u"style"_s).toString();

      return result;
    }

  private:
    [[tbc::hot_path]] [[nodiscard]] inline static std::uint16_t dimension(const QVariantMap& value, const char* name, qreal scale) {
      const auto physical = std::round(static_cast<float>(value.value(QString::fromLatin1(name)).toDouble() * scale));
      if (!std::isfinite(physical) || physical < 1 || physical > std::numeric_limits<std::uint16_t>::max()) {
        throw std::invalid_argument{"InvalidCellTextGrid"};
      }

      return static_cast<std::uint16_t>(physical);
    }
  };

}
