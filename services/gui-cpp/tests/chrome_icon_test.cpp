#include "core/color.hpp"
#include "fonts/font_role.hpp"
#include "qml_fixture.hpp"
#include "qt/alpha_mask_material.hpp"
#include "qt/native_chrome_icon.hpp"
#include "qt/resident_fonts.hpp"
#include "qt/bundled_fonts.hpp"
#include <QColor>
#include <QDebug>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QPoint>
#include <QPointF>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QSignalSpy>
#include <QSize>
#include <QSizeF>
#include <QString>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qscopeguard.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <future>
#include <thread>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr QSize window_size{320, 80};
constexpr QPoint physical_origin{16, 10};
constexpr unsigned shade_background = 0x101010;
constexpr unsigned shade_subtext = 0xa0a0a0;
constexpr unsigned shade_overlay = 0x7e7e7e;
constexpr QSize folder_size{9, 15};
constexpr QSize status_size{11, 15};
constexpr qreal small_pixels = 11;
constexpr qreal title_pixels = 13;
constexpr int cross_backend_compositing_channel_tolerance = 1;

bool matchesReference(const QImage &actual, const QImage &expected, int channel_tolerance) {
  if (actual.size() != expected.size()) {
    return false;
  }

  for (int row = 0; row < actual.height(); ++row) {
    for (int column = 0; column < actual.width(); ++column) {
      const auto first = actual.pixelColor(column, row);
      const auto second = expected.pixelColor(column, row);
      const std::array differences{std::abs(first.red() - second.red()), std::abs(first.green() - second.green()), std::abs(first.blue() - second.blue()), std::abs(first.alpha() - second.alpha())};
      if (std::ranges::any_of(differences, [channel_tolerance](int difference) {
            return difference > channel_tolerance;
          })) {
        return false;
      }
    }
  }

  return true;
}

class AtlasTexture final : public QSGTexture {
public:
  [[nodiscard]] qint64 comparisonKey() const override {
    return 1;
  }

  [[nodiscard]] QSize textureSize() const override {
    return {1, 1};
  }

  [[nodiscard]] bool hasAlphaChannel() const override {
    return true;
  }

  [[nodiscard]] bool hasMipmaps() const override {
    return false;
  }
};

struct IconReference {
  QString glyph;
  QString filename;
  QSize size;
  qreal pixel_size = 0;
  QColor color;
};

class ChromeIconTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
  }

  Q_SLOT static void symbolsFallbackKeepsOriginalCoverage() {
    verifyReference({.glyph = QStringLiteral("\uf07b"), .filename = QStringLiteral("folder-small.png"), .size = folder_size, .pixel_size = small_pixels, .color = QColor{shade_subtext}});
  }

  Q_SLOT static void preferredSansKeepsOriginalCoverage() {
    verifyReference({.glyph = QStringLiteral("?"), .filename = QStringLiteral("unknown-status.png"), .size = status_size, .pixel_size = title_pixels, .color = QColor{shade_overlay}});
  }

  Q_SLOT static void fontFacesRemainSeparateAcrossThreads() {
    const auto source = ResidentFonts::resolveSource({}, {});
    const auto gui_fonts = ResidentFonts::shared(source);
    std::promise<bool> result;
    auto completed = result.get_future();
    const auto *gui_face = &gui_fonts->face(fonts::FontRole::regular);
    const std::jthread worker{[source, gui_face, &result] {
      const auto render_fonts = ResidentFonts::shared(source);
      result.set_value(&render_fonts->face(fonts::FontRole::regular) != gui_face);
    }};
    QVERIFY(completed.get());
  }

  Q_SLOT static void differentSamplersCannotBatchTogether() {
    AtlasTexture nearest;
    AtlasTexture linear;
    nearest.setFiltering(QSGTexture::Nearest);
    linear.setFiltering(QSGTexture::Linear);
    const AlphaMaskMaterial first{nearest, Color::rgb(shade_subtext)};
    const AlphaMaskMaterial second{linear, Color::rgb(shade_subtext)};
    QVERIFY(first.compare(&second) != 0);
    const AlphaMaskMaterial stable{nearest, Color::rgb(shade_subtext), AlphaMaskSampling::stable_nearest};
    QVERIFY(first.type() != stable.type());
    QVERIFY(first.compare(&stable) != 0);
  }

  Q_SLOT static void qmlIconNeedsNoApplicationController() {
    QQmlEngine engine;
    const auto icon = createChrome(engine, QStringLiteral("ChromeIcon"), {{QStringLiteral("glyph"), QStringLiteral("?")}, {QStringLiteral("pixelSize"), title_pixels}, {QStringLiteral("color"), QColor{shade_overlay}}});
    icon->setSize(status_size);
    QQuickWindow window;
    icon->setParentItem(window.contentItem());
    window.resize(window_size);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(icon->property("directRendering").toBool(), wait_ms);
  }

  static void verifyReference(const IconReference &expected) {
    const QImage golden{QStringLiteral(":/telar/test-icons/") + expected.filename};
    QVERIFY(!golden.isNull());
    QQuickWindow window;
    window.setColor(QColor{shade_background});
    window.resize(window_size);
    const auto scale = window.effectiveDevicePixelRatio();
    QQuickItem ancestor{window.contentItem()};
    NativeChromeIcon icon{&ancestor};
    icon.setPosition(QPointF{physical_origin} / scale);
    icon.setSize(QSizeF{expected.size} / scale);
    icon.setPixelSize(expected.pixel_size / scale);
    icon.setColor(expected.color);
    icon.setGlyph(expected.glyph);
    const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(icon.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
    const auto channel_tolerance = window.rendererInterface()->graphicsApi() == QSGRendererInterface::Metal ? 0 : cross_backend_compositing_channel_tolerance;
    QImage last_mismatch;
    const auto retain_mismatch = qScopeGuard([&] {
      if (QTest::currentTestFailed() && !last_mismatch.isNull()) {
        QTemporaryDir diagnostic;
        diagnostic.setAutoRemove(false);
        QVERIFY(last_mismatch.save(diagnostic.filePath(QStringLiteral("actual.png"))));
        QVERIFY(golden.save(diagnostic.filePath(QStringLiteral("expected.png"))));
        qInfo() << "Final icon pixel mismatch:" << diagnostic.path();
      }
    });
    const auto matches = [&](QPoint origin) {
      const auto image = window.grabWindow();
      const auto crop = image.copy(QRect{origin, expected.size});
      const auto same = !image.isNull() && matchesReference(crop, golden, channel_tolerance);
      if (!same) {
        last_mismatch = crop;
      }

      return same;
    };
    const auto actual = window.grabWindow().copy(QRect{physical_origin, expected.size}).convertToFormat(QImage::Format_RGB32);
    if (!matchesReference(actual, golden, channel_tolerance)) {
      QTemporaryDir diagnostic;
      diagnostic.setAutoRemove(false);
      QVERIFY(actual.save(diagnostic.filePath(QStringLiteral("actual.png"))));
      QVERIFY(golden.save(diagnostic.filePath(QStringLiteral("expected.png"))));
      qInfo() << "Icon pixel mismatch:" << diagnostic.path();
    }

    QVERIFY(matchesReference(actual, golden, channel_tolerance));

    ancestor.setX(1 / scale);
    const QPoint moved{physical_origin.x() + 1, physical_origin.y()};
    QTRY_VERIFY_WITH_TIMEOUT(matches(moved), wait_ms);
    ancestor.setX(0);
    QTRY_VERIFY_WITH_TIMEOUT(matches(physical_origin), wait_ms);

    icon.setPrimaryFamily(QStringLiteral("__telar_missing_icon_font__"));
    QTRY_VERIFY_WITH_TIMEOUT(!icon.available(), wait_ms);
    icon.setPrimaryFamily({});
    QTRY_VERIFY_WITH_TIMEOUT(icon.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(matches(physical_origin), wait_ms);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ChromeIconTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "chrome_icon_test.moc"
