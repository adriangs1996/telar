#include <QColor>
#include <QDebug>
#include <QFile>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMatrix4x4>
#include <QMetaProperty>
#include <QObject>
#include <QPointF>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QRectF>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QSize>
#include <QSizeF>
#include <QString>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qnumeric.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qsignalspy.h>
#include <QtTest/qtestcase.h>
#include <cmath>
#include <cstddef>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

import telar.gui.ui.design.controls;
import telar.gui.ui.kit.fonts;
import telar.gui.tests.qt_case;
import telar.gui.tests.shape_atlas;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

  using telar::gui::qt::NativeRoundedRectangle;

  class HomogeneousTransform final : public QQuickTransform {
  public:
    void applyTo(QMatrix4x4* matrix) const override {
      QMatrix4x4 transform;

      transform(3, 3) = 2;
      *matrix *= transform;
    }
  };

  constexpr int wait_ms = 5000;
  constexpr int fixture_width = 640;
  constexpr int fixture_height = 480;
  constexpr int cross_backend_error_per_layer = 1;
  constexpr unsigned background_rgb = 0x101010;

  QColor background() {
    return QColor::fromRgb(background_rgb);
  }

  QJsonObject fixture() {
    QFile source{u":/telar/test-shapes/cases.json"_s};
    if (!source.open(QFile::ReadOnly)) {
      qFatal("Could not open rounded rectangle cases");
    }

    return QJsonDocument::fromJson(source.readAll()).object();
  }

  QColor color(const QJsonArray& channels) {
    return QColor::fromRgbF(static_cast<float>(channels[0].toDouble()), static_cast<float>(channels[1].toDouble()), static_cast<float>(channels[2].toDouble()), static_cast<float>(channels[3].toDouble()));
  }

  std::vector<std::unique_ptr<NativeRoundedRectangle>> createShapes(QQuickItem& parent, qreal density) {
    std::vector<std::unique_ptr<NativeRoundedRectangle>> shapes;
    const auto records = fixture().value(u"shapes"_s).toArray();

    shapes.reserve(static_cast<std::size_t>(records.size()));
    for (const auto& value : records) {
      const auto record = value.toObject();
      const auto rect = record.value(u"rect"_s).toArray();
      auto item = std::make_unique<NativeRoundedRectangle>(&parent);

      item->setPosition({rect[0].toDouble() / density, rect[1].toDouble() / density});
      item->setSize({rect[2].toDouble() / density, rect[3].toDouble() / density});
      item->setRadius(record.value(u"radius"_s).toDouble() / density);
      item->setBorderWidth(record.value(u"borderWidth"_s).toDouble() / density);
      item->setColor(color(record.value(u"fill"_s).toArray()));
      item->setBorderColor(color(record.value(u"border"_s).toArray()));
      item->setOpacity(record.value(u"opacity"_s).toDouble());
      shapes.push_back(std::move(item));
    }

    return shapes;
  }

  telar::gui::test::ShapeImageDifference difference(const QImage& actual, const QImage& expected) {
    return telar::gui::test::compareShapeImages(actual, {.pixels = expected, .budget = telar::gui::test::shapeCompositingBudget(fixture(), cross_backend_error_per_layer)});
  }

  class [[qt::object]] RoundedRectangleTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
  private:
    [[qt::slot]] static void initTestCase() {
      telar::gui::qt::bundledFonts();
      QGuiApplication::setFont(QFont{u"IBM Plex Sans"_s});
    }

    [[qt::slot]] static void init() {
      QTest::failOnWarning(QRegularExpression{u".*"_s});
    }

    [[qt::slot]] static void originalShaderAtlas() {
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
      const QImage expected{u":/telar/test-shapes/rounded-rectangles.png"_s};

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
      for (const auto& shape : shapes) {
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
      for (const auto& shape : shapes) {
        shape->setParentItem(window.contentItem());
      }

      QCOMPARE(window.grabWindow(), actual);
    }

    [[qt::slot]] static void backgroundReplacementKeepsFinalAlphaAndOpaqueInk() {
      // A white base, a surface over it that replaces the background, and blue ink on the surface.
      constexpr QSize window_size{240, 180};
      constexpr QRectF surface_rect{20, 20, 160, 120};
      constexpr QRectF ink_rect{80, 60, 20, 20};
      constexpr float surface_red = 0.2F;
      constexpr float surface_green = 0.4F;
      constexpr float surface_blue = 0.6F;
      constexpr qreal surface_radius = 16;
      constexpr float backdrop_gray = 0.1F;
      constexpr float backdrop_alpha = 0.8F;
      QQuickWindow window;

      window.resize(window_size);
      window.setColor(Qt::transparent);
      NativeRoundedRectangle base{window.contentItem()};

      base.setSize(QSizeF{window_size});
      base.setColor(Qt::white);
      NativeRoundedRectangle surface{window.contentItem()};

      surface.setPosition(surface_rect.topLeft());
      surface.setSize(surface_rect.size());
      surface.setReplaceBackground(true);
      NativeRoundedRectangle ink{window.contentItem()};

      ink.setPosition(ink_rect.topLeft());
      ink.setSize(ink_rect.size());
      ink.setColor(Qt::blue);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto density = window.effectiveDevicePixelRatio();

      for (const auto opacity : {0.0F, 0.25F, 0.75F, 1.0F, 0.25F}) {
        surface.setColor(QColor::fromRgbF(surface_red, surface_green, surface_blue, opacity));
        const auto frame = window.grabWindow();

        QVERIFY(!frame.isNull());
        const auto pixel = frame.pixelColor(qRound(40 * density), qRound(40 * density));

        QVERIFY(std::abs(pixel.alphaF() - opacity) <= 1.0 / 255);
        QCOMPARE(frame.pixelColor(qRound(90 * density), qRound(70 * density)), QColor{Qt::blue});
        QCOMPARE(frame.pixelColor(qRound(5 * density), qRound(5 * density)), QColor{Qt::white});
      }

      surface.setRadius(surface_radius);
      surface.setBackdropColor(QColor::fromRgbF(backdrop_gray, backdrop_gray, backdrop_gray, backdrop_alpha));
      const auto rounded = window.grabWindow();

      QVERIFY(std::abs(rounded.pixelColor(qRound(20 * density), qRound(20 * density)).alphaF() - backdrop_alpha) <= 1.0 / 255);
      surface.setReplaceBackground(false);
      const auto blended = window.grabWindow();

      QCOMPARE(blended.pixelColor(qRound(40 * density), qRound(40 * density)).alpha(), 255);
    }

    [[qt::slot]] static void projectiveParentUsesHomogeneousOrigin() {
      QQuickWindow window;

      window.resize(fixture_width, fixture_height);
      window.setColor(background());
      QQuickItem group{window.contentItem()};
      HomogeneousTransform transform;

      transform.appendToItem(&group);
      NativeRoundedRectangle shape{&group};
      constexpr qreal side = 80;

      shape.setPosition({2 * side, 2 * side});
      shape.setSize({side, side});
      shape.setColor(Qt::green);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto actual = window.grabWindow();

      QVERIFY(!actual.isNull());
      const auto density = window.effectiveDevicePixelRatio();
      const auto center = shape.mapToScene({side / 2, side / 2}) * density;
      const auto outside = shape.mapToScene({2 * side, side / 2}) * density;

      QCOMPARE(actual.pixelColor(qRound(center.x()), qRound(center.y())), QColor{Qt::green});
      QCOMPARE(actual.pixelColor(qRound(outside.x()), qRound(outside.y())), background());
    }

    [[qt::slot]] static void mutationsAndEmptyGeometry() {
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
      constexpr qreal border_alpha = 0.09;

      shape.setBorderAlpha(border_alpha);
      const auto translucent = window.grabWindow();

      QVERIFY(translucent != original);
      for (const auto invalid : {std::numeric_limits<qreal>::quiet_NaN(), std::numeric_limits<qreal>::infinity(), std::numeric_limits<qreal>::max(), qreal{-1}}) {
        shape.setBorderAlpha(invalid);
        QCOMPARE(shape.borderAlpha(), qreal{static_cast<float>(border_alpha)});
        QCOMPARE(window.grabWindow(), translucent);
      }

      shape.setBorderAlpha(1);
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

    [[qt::slot]] static void geometricClipAndReset() {
      constexpr int left = 16;
      constexpr int top = 16;
      constexpr int shape_width = 6;
      constexpr int shape_height = 20;
      constexpr int clip_left = shape_width / 2;
      QQuickWindow window;
      const auto density = window.effectiveDevicePixelRatio();

      window.resize(qRound(fixture_width / density), qRound(fixture_height / density));
      window.setMinimumSize(window.size());
      window.setMaximumSize(window.size());
      window.setColor(background());
      NativeRoundedRectangle shape{window.contentItem()};

      shape.setPosition({left / density, top / density});
      shape.setSize({shape_width / density, shape_height / density});
      shape.setRadius(clip_left / density);
      shape.setColor(Qt::white);
      const auto changed = std::make_unique<QSignalSpy>(&shape, &NativeRoundedRectangle::paintClipChanged);
      const auto property = shape.metaObject()->property(shape.metaObject()->indexOfProperty("paintClip"));

      QVERIFY(property.isResettable());
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto original = window.grabWindow();

      QVERIFY(!original.isNull());
      const QRectF clip{clip_left / density, 0, clip_left / density, shape_height / density};

      shape.setPaintClip(clip);
      QCOMPARE(shape.paintClip(), clip);
      QCOMPARE(changed->count(), 1);
      const auto clipped = window.grabWindow();

      QVERIFY(clipped != original);
      QCOMPARE(clipped.pixelColor(left, top + (shape_height / 2)), background());
      QCOMPARE(clipped.pixelColor(left + clip_left, top), background());
      QCOMPARE(clipped.pixelColor(left + clip_left + (clip_left / 2), top + (shape_height / 2)), QColor{Qt::white});
      shape.setPaintClip(clip);
      QCOMPARE(changed->count(), 1);
      QVERIFY(property.reset(&shape));
      QCOMPARE(changed->count(), 2);
      QCOMPARE(window.grabWindow(), original);

      shape.setPaintClip({});
      QCOMPARE(changed->count(), 3);
      const auto empty = window.grabWindow();
      QImage background_image{empty.size(), empty.format()};

      background_image.setDevicePixelRatio(empty.devicePixelRatio());
      background_image.fill(background());
      QCOMPARE(empty, background_image);
      QVERIFY(property.reset(&shape));
      QCOMPARE(changed->count(), 4);
      QCOMPARE(window.grabWindow(), original);

      for (const auto invalid : {std::numeric_limits<qreal>::quiet_NaN(), std::numeric_limits<qreal>::infinity(), qreal{-1}}) {
        shape.setPaintClip({0, 0, invalid, shape_height / density});
        QCOMPARE(changed->count(), 4);
        QCOMPARE(window.grabWindow(), original);
      }

      shape.setPaintClip({std::numeric_limits<qreal>::max(), 0, 1, 1});
      QCOMPARE(changed->count(), 5);
      QCOMPARE(window.grabWindow(), background_image);
      QVERIFY(property.reset(&shape));
      QCOMPARE(changed->count(), 6);
      QCOMPARE(window.grabWindow(), original);
      shape.resetPaintClip();
      QCOMPARE(changed->count(), 6);
    }
  };

  using telar::gui::test::QtCase;

  const QtCase<RoundedRectangleTest, "originalShaderAtlas"> case_original_shader_atlas{"rounded_rectangle.original_shader_atlas"};
  const QtCase<RoundedRectangleTest, "backgroundReplacementKeepsFinalAlphaAndOpaqueInk"> case_background_replacement_keeps_final_alpha_and_opaque_ink{"rounded_rectangle.background_replacement_keeps_final_alpha_and_opaque_ink"};
  const QtCase<RoundedRectangleTest, "projectiveParentUsesHomogeneousOrigin"> case_projective_parent_uses_homogeneous_origin{"rounded_rectangle.projective_parent_uses_homogeneous_origin"};
  const QtCase<RoundedRectangleTest, "mutationsAndEmptyGeometry"> case_mutations_and_empty_geometry{"rounded_rectangle.mutations_and_empty_geometry"};
  const QtCase<RoundedRectangleTest, "geometricClipAndReset"> case_geometric_clip_and_reset{"rounded_rectangle.geometric_clip_and_reset"};

}

#ifndef TELAR_MOC_RUN
#include "rounded_rectangle_test.moc"
#endif
