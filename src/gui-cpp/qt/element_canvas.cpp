#include "element_canvas.hpp"

#include <QPainter>
#include <QPen>
#include <QRectF>
#include <QVariantMap>

#include <array>
#include <cmath>
#include <optional>

namespace telar::gui::qt {

namespace {

// Reads SVG path numbers: optional sign, digits, one dot, exponent; separators are spaces and commas.
class PathScanner {
public:
  explicit PathScanner(const QString &data)
      : data_(data) {}

  [[nodiscard]] bool done() {
    skip();

    return index_ >= data_.size();
  }

  [[nodiscard]] std::optional<QChar> command() {
    skip();
    if (index_ < data_.size() && data_[index_].isLetter()) {
      return data_[index_++];
    }

    return std::nullopt;
  }

  [[nodiscard]] bool numberNext() {
    skip();

    return index_ < data_.size() && (data_[index_].isDigit() || data_[index_] == u'-' || data_[index_] == u'+' || data_[index_] == u'.');
  }

  [[nodiscard]] std::optional<qreal> number() {
    skip();
    const auto start = index_;
    if (index_ < data_.size() && (data_[index_] == u'-' || data_[index_] == u'+')) {
      ++index_;
    }

    bool digits = false;
    bool dot = false;
    while (index_ < data_.size() && (data_[index_].isDigit() || (data_[index_] == u'.' && !dot))) {
      dot = dot || data_[index_] == u'.';
      digits = digits || data_[index_].isDigit();
      ++index_;
    }

    if (digits && index_ < data_.size() && (data_[index_] == u'e' || data_[index_] == u'E')) {
      ++index_;
      if (index_ < data_.size() && (data_[index_] == u'-' || data_[index_] == u'+')) {
        ++index_;
      }

      while (index_ < data_.size() && data_[index_].isDigit()) {
        ++index_;
      }
    }

    bool valid = false;
    const auto value = QStringView{data_}.sliced(start, index_ - start).toDouble(&valid);
    if (!digits || !valid || !std::isfinite(value)) {
      return std::nullopt;
    }

    return value;
  }

private:
  void skip() {
    while (index_ < data_.size() && (data_[index_].isSpace() || data_[index_] == u',')) {
      ++index_;
    }
  }

  const QString &data_;
  qsizetype index_ = 0;
};

Qt::PenCapStyle capStyle(const QString &name) {
  if (name == QStringLiteral("round")) {
    return Qt::RoundCap;
  }

  return name == QStringLiteral("square") ? Qt::SquareCap : Qt::FlatCap;
}

Qt::PenJoinStyle joinStyle(const QString &name) {
  if (name == QStringLiteral("round")) {
    return Qt::RoundJoin;
  }

  return name == QStringLiteral("bevel") ? Qt::BevelJoin : Qt::MiterJoin;
}

}

ElementCanvas::ElementCanvas(QQuickItem *parent)
    : QQuickPaintedItem(parent) {
  setAntialiasing(true);
}

QVariantList ElementCanvas::operations() const {
  return operations_;
}

void ElementCanvas::setOperations(const QVariantList &operations) {
  if (operations == operations_) {
    return;
  }

  operations_ = operations;
  emit operationsChanged();
  update();
}

qreal ElementCanvas::ratio() const noexcept {
  return ratio_;
}

void ElementCanvas::setRatio(qreal ratio) {
  if (ratio != ratio_) {
    ratio_ = ratio;
    emit operationsChanged();
    update();
  }
}

bool ElementCanvas::appendSvgPath(QPainterPath &path, const QString &data) {
  PathScanner scanner{data};
  QPointF current = path.currentPosition();
  QChar active;
  while (!scanner.done()) {
    if (const auto command = scanner.command()) {
      active = *command;
    } else if (active.isNull() || !scanner.numberNext()) {
      return false;
    }

    const bool relative = active.isLower();
    const auto origin = relative ? current : QPointF{};
    const auto read = [&](qsizetype count, std::array<qreal, 6> &values) {
      for (qsizetype index = 0; index < count; ++index) {
        const auto value = scanner.number();
        if (!value) {
          return false;
        }

        values[static_cast<std::size_t>(index)] = *value;
      }

      return true;
    };
    std::array<qreal, 6> values{};
    switch (active.toUpper().unicode()) {
    case u'M':
      if (!read(2, values)) {
        return false;
      }

      current = origin + QPointF{values[0], values[1]};
      path.moveTo(current);
      // Later pairs after a move are lines, as in SVG.
      active = relative ? u'l' : u'L';
      break;
    case u'L':
      if (!read(2, values)) {
        return false;
      }

      current = origin + QPointF{values[0], values[1]};
      path.lineTo(current);
      break;
    case u'H':
      if (!read(1, values)) {
        return false;
      }

      current.setX((relative ? current.x() : 0) + values[0]);
      path.lineTo(current);
      break;
    case u'V':
      if (!read(1, values)) {
        return false;
      }

      current.setY((relative ? current.y() : 0) + values[0]);
      path.lineTo(current);
      break;
    case u'C':
      if (!read(6, values)) {
        return false;
      }

      path.cubicTo(origin + QPointF{values[0], values[1]}, origin + QPointF{values[2], values[3]}, origin + QPointF{values[4], values[5]});
      current = origin + QPointF{values[4], values[5]};
      break;
    case u'Q':
      if (!read(4, values)) {
        return false;
      }

      path.quadTo(origin + QPointF{values[0], values[1]}, origin + QPointF{values[2], values[3]});
      current = origin + QPointF{values[2], values[3]};
      break;
    case u'Z':
      path.closeSubpath();
      current = path.currentPosition();
      active = QChar{};
      break;
    default:
      return false;
    }
  }

  return true;
}

void ElementCanvas::paint(QPainter *painter) {
  painter->setRenderHint(QPainter::Antialiasing);
  painter->scale(ratio_, ratio_);
  QPainterPath path;
  qreal line_width = 1;
  auto cap = Qt::FlatCap;
  auto join = Qt::MiterJoin;
  for (const auto &entry : operations_) {
    const auto operation = entry.toMap();
    const auto values = operation.value(QStringLiteral("values")).toList();
    const auto value = [&](qsizetype index) {
      return index < values.size() ? values[index].toReal() : 0.0;
    };
    switch (operation.value(QStringLiteral("op")).toInt()) {
    case op_move:
      path.moveTo(value(0), value(1));
      break;
    case op_line:
      path.lineTo(value(0), value(1));
      break;
    case op_curve:
      path.cubicTo(value(0), value(1), value(2), value(3), value(4), value(5));
      break;
    case op_quad:
      path.quadTo(value(0), value(1), value(2), value(3));
      break;
    case op_arc: {
      // Degrees from twelve o'clock, clockwise, so a progress ring reads naturally.
      const QRectF bounds{value(0) - value(2), value(1) - value(2), 2 * value(2), 2 * value(2)};
      const auto start = 90 - value(3);
      const auto sweep = -(value(4) - value(3));
      if (path.elementCount() == 0) {
        path.arcMoveTo(bounds, start);
      }

      path.arcTo(bounds, start, sweep);
    } break;
    case op_rect:
      path.addRect(value(0), value(1), value(2), value(3));
      break;
    case op_round_rect:
      path.addRoundedRect(value(0), value(1), value(2), value(3), value(4), value(4));
      break;
    case op_circle:
      path.addEllipse(QPointF{value(0), value(1)}, value(2), value(2));
      break;
    case op_path:
      if (!appendSvgPath(path, operation.value(QStringLiteral("text")).toString())) {
        return;
      }
      break;
    case op_close:
      path.closeSubpath();
      break;
    case op_fill:
      painter->fillPath(path, operation.value(QStringLiteral("color")).value<QColor>());
      path = {};
      break;
    case op_stroke: {
      QPen pen{operation.value(QStringLiteral("color")).value<QColor>()};
      pen.setWidthF(values.isEmpty() ? line_width : value(0));
      pen.setCapStyle(cap);
      pen.setJoinStyle(join);
      painter->strokePath(path, pen);
      path = {};
    } break;
    case op_width:
      line_width = value(0);
      break;
    case op_cap:
      cap = capStyle(operation.value(QStringLiteral("text")).toString());
      break;
    case op_join:
      join = joinStyle(operation.value(QStringLiteral("text")).toString());
      break;
    case op_alpha:
      painter->setOpacity(value(0));
      break;
    case op_translate:
      painter->translate(value(0), value(1));
      break;
    case op_rotate:
      painter->rotate(value(0));
      break;
    case op_scale:
      painter->scale(value(0), values.size() > 1 ? value(1) : value(0));
      break;
    case op_save:
      painter->save();
      break;
    case op_restore:
      painter->restore();
      break;
    default:
      return;
    }
  }
}

}
