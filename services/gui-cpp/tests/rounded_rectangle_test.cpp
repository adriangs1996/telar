#include "qt/native_rounded_rectangle.hpp"
#include "shape_atlas.hpp"
#include "ui/bundled_fonts.hpp"
#include <QColor>
#include <QDebug>
#include <QFile>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QRectF>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QString>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qnumeric.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstddef>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

namespace {

using telar::gui::qt::NativeRoundedRectangle;

constexpr int wait_ms = 5000;
constexpr int fixture_width = 640;
constexpr int fixture_height = 480;
constexpr int cross_backend_error_per_layer = 1;
constexpr unsigned background_rgb = 0x101010;

QColor background() {
  return QColor::fromRgb(background_rgb);
}

QJsonObject fixture() {
  QFile source{QStringLiteral(":/telar/test-shapes/cases.json")};
  if (!source.open(QFile::ReadOnly)) {
    qFatal("Could not open rounded rectangle cases");
  }

  return QJsonDocument::fromJson(source.readAll()).object();
}

QColor color(const QJsonArray &channels) {
  return QColor::fromRgbF(static_cast<float>(channels[0].toDouble()), static_cast<float>(channels[1].toDouble()), static_cast<float>(channels[2].toDouble()), static_cast<float>(channels[3].toDouble()));
}

std::vector<std::unique_ptr<NativeRoundedRectangle>> createShapes(QQuickItem &parent, qreal density) {
  std::vector<std::unique_ptr<NativeRoundedRectangle>> shapes;
  const auto records = fixture().value(QStringLiteral("shapes")).toArray();
  shapes.reserve(static_cast<std::size_t>(records.size()));
  for (const auto &value : records) {
    const auto record = value.toObject();
    const auto rect = record.value(QStringLiteral("rect")).toArray();
    auto item = std::make_unique<NativeRoundedRectangle>(&parent);
    item->setPosition({rect[0].toDouble() / density, rect[1].toDouble() / density});
    item->setSize({rect[2].toDouble() / density, rect[3].toDouble() / density});
    item->setRadius(record.value(QStringLiteral("radius")).toDouble() / density);
    item->setBorderWidth(record.value(QStringLiteral("borderWidth")).toDouble() / density);
    item->setColor(color(record.value(QStringLiteral("fill")).toArray()));
    item->setBorderColor(color(record.value(QStringLiteral("border")).toArray()));
    item->setOpacity(record.value(QStringLiteral("opacity")).toDouble());
    shapes.push_back(std::move(item));
  }

  return shapes;
}

telar::gui::test::ShapeImageDifference difference(const QImage &actual, const QImage &expected) {
  return telar::gui::test::compareShapeImages(actual, {.pixels = expected, .budget = telar::gui::test::shapeCompositingBudget(fixture(), cross_backend_error_per_layer)});
}

class RoundedRectangleTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void originalShaderAtlas() {
    QQuickWindow window;
    const auto density = window.effectiveDevicePixelRatio();
    window.resize(qRound(fixture_width / density), qRound(fixture_height / density));
    window.setMinimumSize(window.size());
    window.setMaximumSize(window.size());
    window.setColor(background());
    const auto shapes = createShapes(*window.contentItem(), density);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    qInfo() << "Scene graph API:" << window.rendererInterface()->graphicsApi();
    const auto actual = window.grabWindow();
    const QImage expected{QStringLiteral(":/telar/test-shapes/rounded-rectangles.png")};
    QVERIFY(!actual.isNull() && !expected.isNull());
    QCOMPARE(actual.size(), expected.size());
    const auto comparison = difference(actual, expected);
    qInfo() << "Original shader atlas: different pixels" << comparison.pixels << "maximum channel" << comparison.maximum_channel;
    const auto capture = qEnvironmentVariable("TELAR_GUI_SHAPE_CAPTURE");
    if (!capture.isEmpty()) {
      QVERIFY(actual.save(capture));
    }

    QCOMPARE(comparison.outside_budget, 0);
    if (window.rendererInterface()->graphicsApi() == QSGRendererInterface::Metal) {
      QCOMPARE(comparison.pixels, 0);
    }
    QQuickItem clipping_parent{window.contentItem()};
    clipping_parent.setSize({fixture_width / (2 * density), fixture_height / density});
    clipping_parent.setClip(true);
    for (const auto &shape : shapes) {
      shape->setParentItem(&clipping_parent);
    }

    const auto clipped = window.grabWindow();
    auto clipped_reference = expected;
    constexpr int half_width = fixture_width / 2;
    for (int row = 0; row < fixture_height; ++row) {
      for (int column = half_width; column < fixture_width; ++column) {
        clipped_reference.setPixelColor(column, row, background());
      }
    }

    QCOMPARE(clipped.size(), clipped_reference.size());
    QCOMPARE(difference(clipped, clipped_reference).outside_budget, 0);
    for (const auto &shape : shapes) {
      shape->setParentItem(window.contentItem());
    }

    QCOMPARE(window.grabWindow(), actual);
  }

  Q_SLOT static void mutationsAndEmptyGeometry() {
    QQuickWindow window;
    window.resize(fixture_width, fixture_height);
    window.setColor(background());
    NativeRoundedRectangle shape{window.contentItem()};
    constexpr qreal side = 80;
    constexpr qreal radius = 12;
    shape.setPosition({side, side});
    shape.setSize({side, side});
    shape.setRadius(radius);
    shape.setBorderWidth(2);
    shape.setColor(Qt::green);
    shape.setBorderColor(Qt::white);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto original = window.grabWindow();
    shape.setColor(Qt::red);
    QVERIFY(window.grabWindow() != original);
    shape.setColor(Qt::green);
    shape.setRadius(std::numeric_limits<qreal>::quiet_NaN());
    shape.setBorderWidth(-1);
    QCOMPARE(shape.radius(), radius);
    QCOMPARE(shape.borderWidth(), qreal{2});
    QCOMPARE(window.grabWindow(), original);
    shape.setWidth(0);
    const auto empty = window.grabWindow();
    QImage background_image{empty.size(), empty.format()};
    background_image.setDevicePixelRatio(empty.devicePixelRatio());
    background_image.fill(background());
    QCOMPARE(empty, background_image);
    shape.setWidth(side);
    QCOMPARE(window.grabWindow(), original);
    shape.setColor(Qt::transparent);
    shape.setBorderColor(Qt::transparent);
    QCOMPARE(window.grabWindow(), background_image);
    shape.setColor(Qt::green);
    shape.setBorderColor(Qt::white);
    QCOMPARE(window.grabWindow(), original);
  }
};

}

QTEST_MAIN(RoundedRectangleTest)
#include "rounded_rectangle_test.moc"
