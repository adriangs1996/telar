export module telar.gui.tests.shape_atlas;

import std;
import telar.gui.qt;
import telar.base.ds;

export namespace telar::gui::test {

  struct ShapeImageDifference {
    int pixels = 0;
    int maximum_channel = 0;
    int outside_budget = 0;
  };

  struct ShapeImageReference {
    const QImage& pixels;
    const QImage& budget;
  };

  inline QImage shapeCompositingBudget(const QJsonObject& fixture, int error_per_layer) {
    using Qt::StringLiterals::operator""_s;
    QImage budget{fixture.value(u"width"_s).toInt(), fixture.value(u"height"_s).toInt(), QImage::Format_Grayscale8};

    budget.fill(0);
    for (const auto& value : fixture.value(u"shapes"_s).toArray()) {
      const auto rect = value.toObject().value(u"rect"_s).toArray();
      const auto bounds = QRectF{rect[0].toDouble(), rect[1].toDouble(), rect[2].toDouble(), rect[3].toDouble()}.toAlignedRect().intersected(budget.rect());

      for (int row = bounds.top(); row <= bounds.bottom(); ++row) {
        for (int column = bounds.left(); column <= bounds.right(); ++column) {
          constexpr int channel_max = 255;
          const auto allowance = std::min(channel_max, budget.pixelColor(column, row).red() + error_per_layer);

          budget.setPixelColor(column, row, QColor::fromRgb(allowance, allowance, allowance));
        }
      }
    }

    return budget;
  }

  inline ShapeImageDifference compareShapeImages(const QImage& actual, ShapeImageReference reference) {
    ShapeImageDifference result;
    const auto first = actual.convertToFormat(QImage::Format_ARGB32);
    const auto second = reference.pixels.convertToFormat(QImage::Format_ARGB32);
    if (first.size() != second.size() || first.size() != reference.budget.size()) {
      result.outside_budget = 1;
      return result;
    }

    for (int row = 0; row < first.height(); ++row) {
      for (int column = 0; column < first.width(); ++column) {
        const auto a = first.pixel(column, row);
        const auto b = second.pixel(column, row);
        const ds::Array channels{std::abs(qRed(a) - qRed(b)), std::abs(qGreen(a) - qGreen(b)), std::abs(qBlue(a) - qBlue(b)), std::abs(qAlpha(a) - qAlpha(b))};
        const auto maximum = std::ranges::max(channels);

        result.pixels += maximum != 0 ? 1 : 0;
        result.maximum_channel = std::max(result.maximum_channel, maximum);
        result.outside_budget += maximum > reference.budget.pixelColor(column, row).red() ? 1 : 0;
      }
    }

    return result;
  }

}
