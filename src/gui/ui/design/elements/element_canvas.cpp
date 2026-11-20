#include "element_canvas.hpp"
#include "telar_base/ds/values.hpp"

#include <QPainter>
#include <QPen>
#include <QRectF>
#include <QVariantMap>

#include <array>
#include <cmath>
#include <cstddef>
#include <functional>
#include <optional>
#include <utility>

namespace telar::gui::qt {

  namespace {

    // The most numbers one SVG path command reads: a cubic curve's two control points and end.
    constexpr std::size_t cubic_numbers = 6;

    // Reads SVG path numbers: optional sign, digits, one dot, exponent; separators are spaces and commas.
    class PathScanner {
    public:
      explicit PathScanner(const QString& data)
          : data_(data) {}

      [[nodiscard]] bool done() {
        skip();

        return index_ >= data_.size();
      }

      [[nodiscard]] ds::Option<QChar> command() {
        skip();
        if (index_ < data_.size() && data_[index_].isLetter()) {
          return data_[index_++];
        }

        return ds::none;
      }

      [[nodiscard]] bool numberNext() {
        skip();

        return index_ < data_.size() && (data_[index_].isDigit() || data_[index_] == u'-' || data_[index_] == u'+' || data_[index_] == u'.');
      }

      [[nodiscard]] ds::Option<qreal> number() {
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
          return ds::none;
        }

        return value;
      }

      [[nodiscard]] bool numbers(std::size_t count, ds::Array<qreal, cubic_numbers>& values) {
        for (std::size_t index = 0; index < count; ++index) {
          const auto value = number();
          if (!value) {
            return false;
          }

          values.atMut(index) = *value;
        }

        return true;
      }

    private:
      void skip() {
        while (index_ < data_.size() && (data_[index_].isSpace() || data_[index_] == u',')) {
          ++index_;
        }
      }

      const QString& data_;
      qsizetype index_ = 0;
    };

    Qt::PenCapStyle capStyle(const QString& name) {
      if (name == QStringLiteral("round")) {
        return Qt::RoundCap;
      }

      return name == QStringLiteral("square") ? Qt::SquareCap : Qt::FlatCap;
    }

    Qt::PenJoinStyle joinStyle(const QString& name) {
      if (name == QStringLiteral("round")) {
        return Qt::RoundJoin;
      }

      return name == QStringLiteral("bevel") ? Qt::BevelJoin : Qt::MiterJoin;
    }

    // The numbers an upper-case SVG path command reads; none for a command outside the subset.
    ds::Option<std::size_t> pathArity(char16_t command) {
      switch (command) {
      case u'M':
      case u'L':
        return 2;
      case u'H':
      case u'V':
        return 1;
      case u'C':
        return cubic_numbers;
      case u'Q':
        return 4;
      case u'Z':
        return 0;
      default:
        return ds::none;
      }
    }

    ds::Option<ElementCanvas::Operation> operationOf(const QVariantMap& operation) {
      const auto code = operation.value(QStringLiteral("op")).toInt();
      if (code < 0 || std::cmp_greater(code, std::to_underlying(ElementCanvas::Operation::restore))) {
        return ds::none;
      }

      return static_cast<ElementCanvas::Operation>(code);
    }

    // Values are the centre, the radius, then start and end in degrees from twelve o'clock,
    // clockwise, so a progress ring reads naturally.
    template <typename Value>
    void addArc(QPainterPath& path, const Value& value) {
      const QRectF bounds{value(0) - value(2), value(1) - value(2), 2 * value(2), 2 * value(2)};
      const auto start = 90 - value(3);
      const auto sweep = -(value(4) - value(3));

      if (path.elementCount() == 0) {
        path.arcMoveTo(bounds, start);
      }

      path.arcTo(bounds, start, sweep);
    }

    QColor colorOf(const QVariantMap& operation) {
      return operation.value(QStringLiteral("color")).value<QColor>();
    }

  }

  ElementCanvas::ElementCanvas(QQuickItem* parent)
      : QQuickPaintedItem(parent) {
    setAntialiasing(true);
  }

  QVariantList ElementCanvas::operations() const {
    return operations_;
  }

  void ElementCanvas::setOperations(const QVariantList& operations) {
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
    if (!std::equal_to<>{}(ratio, ratio_)) {
      ratio_ = ratio;
      emit operationsChanged();
      update();
    }
  }

  bool ElementCanvas::appendSvgPath(QPainterPath& path, const QString& data) {
    PathScanner scanner{data};
    QPointF current = path.currentPosition();
    QChar active;

    while (!scanner.done()) {
      if (const auto command = scanner.command()) {
        active = *command;
      } else if (active.isNull() || !scanner.numberNext()) {
        return false;
      }

      const auto upper = active.toUpper().unicode();
      const auto arity = pathArity(upper);
      ds::Array<qreal, cubic_numbers> values{};
      if (!arity || !scanner.numbers(*arity, values)) {
        return false;
      }

      const bool relative = active.isLower();
      const auto origin = relative ? current : QPointF{};
      const auto point = [&](std::size_t first) {
        return origin + QPointF{values[first], values[first + 1]};
      };

      switch (upper) {
      case u'M':
        current = point(0);
        path.moveTo(current);
        // Later pairs after a move are lines, as in SVG.
        active = relative ? u'l' : u'L';
        break;
      case u'L':
        current = point(0);
        path.lineTo(current);
        break;
      case u'H':
        current.setX((relative ? current.x() : 0) + values[0]);
        path.lineTo(current);
        break;
      case u'V':
        current.setY((relative ? current.y() : 0) + values[0]);
        path.lineTo(current);
        break;
      case u'C':
        path.cubicTo(point(0), point(2), point(4));
        current = point(4);
        break;
      case u'Q':
        path.quadTo(point(0), point(2));
        current = point(2);
        break;
      default:
        path.closeSubpath();
        current = path.currentPosition();
        active = QChar{};
        break;
      }
    }

    return true;
  }

  void ElementCanvas::paint(QPainter* painter) {
    painter->setRenderHint(QPainter::Antialiasing);
    painter->scale(ratio_, ratio_);
    QPainterPath path;
    qreal line_width = 1;
    auto cap = Qt::FlatCap;
    auto join = Qt::MiterJoin;

    for (const auto& entry : operations_) {
      const auto operation = entry.toMap();
      const auto kind = operationOf(operation);
      if (!kind) {
        return;
      }

      const auto values = operation.value(QStringLiteral("values")).toList();
      const auto value = [&](qsizetype index) {
        return index < values.size() ? values[index].toReal() : 0.0;
      };

      const auto point = [&](qsizetype first) {
        return QPointF{value(first), value(first + 1)};
      };

      switch (*kind) {
      case Operation::move:
        path.moveTo(point(0));
        break;
      case Operation::line:
        path.lineTo(point(0));
        break;
      case Operation::curve:
        path.cubicTo(point(0), point(2), point(4));
        break;
      case Operation::quad:
        path.quadTo(point(0), point(2));
        break;
      case Operation::arc:
        addArc(path, value);
        break;
      case Operation::rect:
        path.addRect(value(0), value(1), value(2), value(3));
        break;
      case Operation::round_rect:
        path.addRoundedRect(value(0), value(1), value(2), value(3), value(4), value(4));
        break;
      case Operation::circle:
        path.addEllipse(point(0), value(2), value(2));
        break;
      case Operation::path:
        if (!appendSvgPath(path, operation.value(QStringLiteral("text")).toString())) {
          return;
        }

        break;
      case Operation::close:
        path.closeSubpath();
        break;
      case Operation::fill:
        painter->fillPath(path, colorOf(operation));
        path = {};
        break;
      case Operation::stroke: {
        QPen pen{colorOf(operation)};

        pen.setWidthF(values.isEmpty() ? line_width : value(0));
        pen.setCapStyle(cap);
        pen.setJoinStyle(join);
        painter->strokePath(path, pen);
        path = {};
      } break;
      case Operation::width:
        line_width = value(0);
        break;
      case Operation::cap:
        cap = capStyle(operation.value(QStringLiteral("text")).toString());
        break;
      case Operation::join:
        join = joinStyle(operation.value(QStringLiteral("text")).toString());
        break;
      case Operation::alpha:
        painter->setOpacity(value(0));
        break;
      case Operation::translate:
        painter->translate(value(0), value(1));
        break;
      case Operation::rotate:
        painter->rotate(value(0));
        break;
      case Operation::scale:
        painter->scale(value(0), values.size() > 1 ? value(1) : value(0));
        break;
      case Operation::save:
        painter->save();
        break;
      case Operation::restore:
        painter->restore();
        break;
      }
    }
  }

}
