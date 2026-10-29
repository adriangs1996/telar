#include "core/configuration.hpp"
#include "core/unicode_scalar.hpp"
#include "fonts/face.hpp"
#include "fonts/font_requests.hpp"
#include "fonts/font_query.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/shaped_run_view.hpp"
#include "frame_fixture.hpp"
#include "qt/chrome_fonts.hpp"
#include "qt/native_chrome_text.hpp"
#include "qt/native_cell_text.hpp"
#include "qt/font_source.hpp"
#include "qt/font_asset.hpp"
#include "qt/resident_fonts.hpp"
#include "qt/window_font_catalog.hpp"
#include "terminal/font_grid.hpp"
#include "ui/bundled_fonts.hpp"
#include <QByteArray>
#include <QColor>
#include <QDebug>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QPoint>
#include <QPointF>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QSize>
#include <QString>
#include <QVariantMap>
#include <QTemporaryDir>
#include <QtCore/qlogging.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qrgb.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr int wait_ms = 5000;
constexpr int window_width = 320;
constexpr int window_height = 80;
constexpr qreal label_left = 12;
constexpr qreal label_top = 10;
constexpr qreal label_width = 290;
constexpr qreal label_height = 40;
constexpr qreal font_size = 13;
constexpr std::int64_t fixed_unit = 64;
constexpr std::uint32_t channel_max = 255;
constexpr qreal cell_width = 9;
constexpr qreal cell_height = 20;
constexpr qreal cell_baseline = 15;

QVariantMap cellTextGrid() {
  return {{QStringLiteral("cellWidth"), cell_width}, {QStringLiteral("cellHeight"), cell_height}, {QStringLiteral("baseline"), cell_baseline}, {QStringLiteral("pixelHeight"), cell_baseline}, {QStringLiteral("family"), QStringLiteral("JetBrains Mono")}};
}

struct ReferencePaint {
  QPointF origin;
  qreal height = label_height;
  qreal pixel_size = font_size;
  qreal scale = 1;
  bool emphasized = false;
  bool red = false;
};

std::uint32_t over(std::uint32_t coverage, std::uint32_t background) noexcept {
  return coverage + (((background * (channel_max - coverage)) + (channel_max / 2)) / channel_max);
}

void stamp(QImage &expected, fonts::GlyphBitmapView bitmap, QPoint origin, bool red) {
  for (std::uint32_t row = 0; row < bitmap.height; ++row) {
    const auto coverage = bitmap.row(row);
    for (std::uint32_t column = 0; column < bitmap.width; ++column) {
      const auto x = origin.x() + static_cast<int>(column);
      const auto y = origin.y() + static_cast<int>(row);
      if (!expected.rect().contains(x, y)) {
        continue;
      }

      const auto value = static_cast<int>(over(coverage[column], static_cast<std::uint32_t>(qRed(expected.pixel(x, y)))));
      expected.setPixel(x, y, red ? qRgb(value, 0, 0) : qRgb(value, value, value));
    }
  }
}

QImage reference(QSize size, const QString &text, const ReferencePaint &paint) {
  const auto fonts = ChromeFonts::shared();
  auto &face = fonts->face(paint.emphasized);
  const auto height = static_cast<std::uint16_t>(std::round(static_cast<float>(paint.pixel_size * paint.scale)));
  const auto utf8 = text.toUtf8();
  const auto run = face.shape({utf8.constData(), static_cast<std::size_t>(utf8.size())}, height);
  const auto metrics = face.metrics(height);
  const auto y = static_cast<float>(paint.origin.y() * paint.scale);
  const auto box_height = static_cast<float>(paint.height * paint.scale);
  const auto baseline = static_cast<std::int64_t>(std::floor(y + ((box_height - static_cast<float>(metrics.line_height)) / 2)) + static_cast<float>(metrics.ascender));
  auto pen = static_cast<std::int64_t>(std::round(static_cast<float>(paint.origin.x() * paint.scale) * fixed_unit));
  QImage expected{size, QImage::Format_RGB32};
  expected.fill(Qt::black);
  for (std::size_t index = 0; index < run.size(); ++index) {
    const auto glyph = run.glyph(index);
    const auto bitmap = face.rasterize({.index = glyph.index, .pixel_height = height, .style = {}});
    const auto left = static_cast<std::int64_t>(FontMetrics::roundFixed(pen + glyph.x_offset)) + bitmap.left;
    const auto top = baseline - FontMetrics::roundFixed(glyph.y_offset) - bitmap.top;
    stamp(expected, bitmap, {static_cast<int>(left), static_cast<int>(top)}, paint.red);

    pen += glyph.x_advance;
  }

  return expected;
}

bool containsInk(const QImage &image) {
  for (int row = 0; row < image.height(); ++row) {
    for (int column = 0; column < image.width(); ++column) {
      if (qRed(image.pixel(column, row)) != 0) {
        return true;
      }
    }
  }

  return false;
}

QImage grabFrame(QQuickWindow &window) {
  auto frame = window.grabWindow();
  frame.setDevicePixelRatio(1);

  return frame.convertToFormat(QImage::Format_RGB32);
}

class ChromeTextTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void cellTextDiscoversTheContinuationGlyph() {
    QQuickWindow window;
    window.setColor(Qt::black);
    window.resize(window_width, window_height);
    NativeCellText label{window.contentItem()};
    label.setPosition({label_left, label_top});
    label.setSize({label_width, label_height});
    label.setGrid(cellTextGrid());
    label.setColor(Qt::white);
    label.setText(QStringLiteral("A↵B"));
    qreal initial_width = 0;
    connect(&label, &QQuickItem::implicitWidthChanged, &window, [&] {
      if (initial_width == 0) {
        initial_width = label.implicitWidth();
      }
    });
    const auto &catalog = WindowFontCatalog::forWindow(window);
    const auto original = catalog.collection();
    QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(catalog.collection()->count > 0, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
    QVERIFY(ResidentFonts::shared(catalog.collection())->source("↵", fonts::FontRole::primary).has_value());
    QVERIFY(test::waitForSynchronizedFrame(window, wait_ms));
    QVERIFY(label.available());
    QVERIFY(initial_width > 0);
    QCOMPARE(label.implicitWidth(), initial_width);
    const auto collection = catalog.collection();
    label.setText(QStringLiteral("B↵A"));
    QTRY_COMPARE_WITH_TIMEOUT(label.implicitWidth(), initial_width, wait_ms);
    QVERIFY(!catalog.busy());
    QCOMPARE(catalog.collection(), collection);
  }

  Q_SLOT static void cellTextPreservesItsPrimaryAcrossCatalogChanges() {
    const auto query = fonts::FontQuery::create("↵");
    if (!query) {
      QFAIL("The continuation marker must produce a font query");
    }

    const auto data = loadFallbackFontData(*query);
    if (!data) {
      QFAIL("The platform must resolve the continuation marker");
    }

    const FontAsset asset{*data};
    const fonts::Face discovered{asset.bytes(), asset.match()};
    FontConfiguration configuration;
    configuration.family.assign(discovered.family());
    configuration.style.assign(discovered.style());
    QQuickWindow window;
    window.setColor(Qt::black);
    window.resize(window_width, window_height);
    auto &catalog = WindowFontCatalog::forWindow(window);
    catalog.configure(configuration);
    QVERIFY(ResidentFonts::shared(catalog.collection())->source("↵", fonts::FontRole::primary).has_value());
    const auto primary = ResidentFonts::resolveSource(QStringLiteral("JetBrains Mono"), {});
    const auto original = catalog.collectionFor(primary);
    QCOMPARE(original->primary, primary);
    QCOMPARE(catalog.collectionFor(primary), original);
    QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
    NativeCellText label{window.contentItem()};
    label.setSize({label_width, label_height});
    label.setGrid(cellTextGrid());
    label.setColor(Qt::white);
    label.setText(QStringLiteral("A↵B"));
    qreal initial_width = 0;
    connect(&label, &QQuickItem::implicitWidthChanged, &window, [&] {
      if (initial_width == 0) {
        initial_width = label.implicitWidth();
      }
    });
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(catalog.collection()->count > 0, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
    const auto updated = catalog.collectionFor(primary);
    QVERIFY(updated != original);
    QCOMPARE(updated->primary, primary);
    QCOMPARE(catalog.collectionFor(primary), updated);
    QVERIFY(ResidentFonts::shared(updated)->source("↵", fonts::FontRole::primary).has_value());
    QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
    QVERIFY(test::waitForSynchronizedFrame(window, wait_ms));
    QVERIFY(label.available());
    QVERIFY(initial_width > 0);
    QCOMPARE(label.implicitWidth(), initial_width);
  }

  Q_SLOT static void cellTextNotificationsMayRetireTheItem() {
    std::unique_ptr<NativeCellText> label;
    const auto retire = [&label] {
      label.reset();
    };
    label = std::make_unique<NativeCellText>();
    connect(label.get(), &NativeCellText::textChanged, label.get(), retire);
    label->setText(QStringLiteral("retired"));
    QVERIFY(!label);
    label = std::make_unique<NativeCellText>();
    connect(label.get(), &NativeCellText::gridChanged, label.get(), retire);
    label->setGrid(cellTextGrid());
    QVERIFY(!label);
    label = std::make_unique<NativeCellText>();
    connect(label.get(), &NativeCellText::colorChanged, label.get(), retire);
    label->setColor(Qt::red);
    QVERIFY(!label);
    label = std::make_unique<NativeCellText>();
    connect(label.get(), &NativeCellText::boldChanged, label.get(), retire);
    label->setBold(true);
    QVERIFY(!label);
  }

  Q_SLOT static void cellTextLayoutObserversMayRetireTheItem() {
    QQuickWindow window;
    window.resize(window_width, window_height);
    std::unique_ptr<NativeCellText> label;
    const auto create = [&] {
      label = std::make_unique<NativeCellText>(window.contentItem());
      label->setGrid(cellTextGrid());
      label->setText(QStringLiteral("retired"));
      label->setColor(Qt::white);
    };
    const auto retire = [&label] {
      label.reset();
    };
    create();
    connect(label.get(), &QQuickItem::implicitWidthChanged, &window, retire);
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && !label, wait_ms);
    create();
    connect(label.get(), &NativeCellText::availabilityChanged, &window, retire);
    QTRY_VERIFY_WITH_TIMEOUT(!label, wait_ms);
  }

  Q_SLOT static void regularMasksAndPositionsMatchOriginalFace() {
    verifyMasks(false);
  }

  Q_SLOT static void emphasizedMasksAndPositionsMatchOriginalFace() {
    verifyMasks(true);
  }

  Q_SLOT static void mixedLabelsRetainPreferredInkDuringDiscovery() {
    QQuickWindow window;
    window.setColor(Qt::black);
    window.resize(window_width, window_height);
    NativeChromeText label{window.contentItem()};
    label.setPosition({label_left, label_top});
    label.setSize({label_width, label_height});
    label.setPixelSize(font_size);
    label.setColor(Qt::white);
    label.setText(QStringLiteral("ABC \u2387 AV"));
    const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
    const auto &catalog = WindowFontCatalog::forWindow(window);
    QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
    const auto scale = window.effectiveDevicePixelRatio();
    const auto font_height = static_cast<std::uint16_t>(std::round(static_cast<float>(font_size * scale)));
    const auto prefix_width = ChromeFonts::shared()->face(false).shape("ABC ", font_height).advance();
    const QRect prefix{static_cast<int>(label_left * scale), static_cast<int>(label_top * scale), prefix_width, static_cast<int>(label_height * scale)};
    const ReferencePaint paint{.origin = label.mapToScene({0, 0}), .height = label.height(), .pixel_size = font_size, .scale = scale};
    const auto matches = [&] {
      const auto actual = grabFrame(window);

      return !actual.isNull() && actual.copy(prefix) == reference(actual.size(), QStringLiteral("ABC "), paint).copy(prefix);
    };
    QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);

    const auto collection = catalog.collection();
    const auto font_set = ResidentFonts::shared(collection);
    const auto expected = font_set->face(fonts::FontRole::regular).shape("ABC ", font_height).advance() + font_set->face(fonts::FontRole::primary).metrics(font_height).maximum_advance + font_set->face(fonts::FontRole::regular).shape(" AV", font_height).advance();
    QCOMPARE(label.implicitWidth(), expected / scale);
    qInfo() << "Discovered branch-font faces:" << collection->count;
    const auto changes = QSignalSpy{&catalog, &WindowFontCatalog::fontsChanged};
    const auto previous_frames = frames.count();
    label.setText(QStringLiteral("ABC \u2387 AV again"));
    QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(frames.count() > previous_frames, wait_ms);
    QVERIFY(!catalog.busy());
    QCOMPARE(catalog.collection(), collection);
    QCOMPARE(changes.count(), 0);
  }

  Q_SLOT static void replacementFontSetRejectsInFlightDiscovery() {
    QQuickWindow window;
    auto &catalog = WindowFontCatalog::forWindow(window);
    const auto previous = catalog.collection();
    catalog.request("\u2387", fonts::FontRole::regular);
    QVERIFY(catalog.busy());
    FontConfiguration replacement;
    replacement.family.assign("JetBrains Mono");
    const QSignalSpy changes{&catalog, &WindowFontCatalog::fontsChanged};
    catalog.configure(replacement);
    QVERIFY(catalog.collection() != previous);
    const auto current = catalog.collection();
    QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
    QCOMPARE(catalog.collection(), current);
    QCOMPARE(catalog.collection()->count, std::size_t{0});
    QCOMPARE(changes.count(), 1);
    catalog.request("\u2387", fonts::FontRole::regular);
    QVERIFY(catalog.busy());
    QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
    qInfo() << "Replacement set discovered branch-font faces:" << catalog.collection()->count;
  }

  Q_SLOT static void destroyingWindowJoinsItsDiscovery() {
    auto window = std::make_unique<QQuickWindow>();
    auto &catalog = WindowFontCatalog::forWindow(*window);
    const QPointer<WindowFontCatalog> lifetime{&catalog};
    catalog.request("\u2387", fonts::FontRole::regular);
    QVERIFY(catalog.busy());
    window.reset();
    QVERIFY(lifetime.isNull());
  }

  Q_SLOT static void discoveryCallbacksMayDestroyTheirWindow() {
    auto window = std::make_unique<QQuickWindow>();
    auto &catalog = WindowFontCatalog::forWindow(*window);
    const QPointer<WindowFontCatalog> lifetime{&catalog};
    std::string missing;
    constexpr std::uint32_t first_noncharacter = 0xfdd0;
    for (std::size_t index = 0; index <= fonts::FontRequests::pending_capacity; ++index) {
      missing.append(Utf8Scalar::encode(first_noncharacter + static_cast<std::uint32_t>(index)).view());
    }

    connect(&catalog, &WindowFontCatalog::fontsChanged, &catalog, [&window] {
      window.reset();
    });
    catalog.request(missing, fonts::FontRole::regular);
    QTRY_VERIFY_WITH_TIMEOUT(lifetime.isNull(), wait_ms);
  }

  Q_SLOT static void fittedLabelsKeepNativeMasksAndFullMeasurement() {
    QQuickWindow window;
    window.setColor(Qt::black);
    window.resize(window_width, window_height);
    const auto scale = window.effectiveDevicePixelRatio();
    constexpr qreal narrow_pixels = 50;
    constexpr qreal wider_pixels = 70;
    const auto original = QStringLiteral("Adrians-MacBook-Pro.local");
    NativeChromeText label{window.contentItem()};
    label.setPosition({label_left, label_top});
    label.setSize({narrow_pixels / scale, label_height});
    label.setPixelSize(font_size / scale);
    label.setColor(Qt::white);
    label.setText(original);
    const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
    const auto full_width = label.implicitWidth();
    QVERIFY(full_width > wider_pixels / scale);
    ReferencePaint paint{.origin = label.mapToScene({0, 0}), .height = label.height(), .pixel_size = label.pixelSize(), .scale = scale};
    const auto matches = [&](const QString &text) {
      const auto actual = grabFrame(window);

      return !actual.isNull() && actual == reference(actual.size(), text, paint);
    };
    QTRY_VERIFY_WITH_TIMEOUT(matches(QStringLiteral("Adrian…")), wait_ms);

    label.setWidth(wider_pixels / scale);
    QTRY_VERIFY_WITH_TIMEOUT(matches(QStringLiteral("Adrians-M…")), wait_ms);
    QCOMPARE(label.implicitWidth(), full_width);

    label.setWidth(1 / scale);
    QTRY_VERIFY_WITH_TIMEOUT(matches(QString{}), wait_ms);
    QVERIFY(label.available());
    QCOMPARE(label.implicitWidth(), full_width);

    label.setWidth(label_width);
    QTRY_VERIFY_WITH_TIMEOUT(matches(original), wait_ms);
    label.setWidth(narrow_pixels / scale);
    QTRY_VERIFY_WITH_TIMEOUT(matches(QStringLiteral("Adrian…")), wait_ms);
    label.setElide(Qt::ElideNone);
    label.setWidth(label_width);
    QTRY_VERIFY_WITH_TIMEOUT(matches(original), wait_ms);
    QCOMPARE(label.text(), original);

    label.setWidth(narrow_pixels / scale);
    label.setEmphasized(true);
    label.setElide(Qt::ElideRight);
    paint.emphasized = true;
    QTRY_VERIFY_WITH_TIMEOUT(matches(QStringLiteral("Adria…")), wait_ms);
    label.setWidth(wider_pixels / scale);
    QTRY_VERIFY_WITH_TIMEOUT(matches(QStringLiteral("Adrians-…")), wait_ms);
  }

  static void verifyMasks(bool emphasized) {
    QQuickWindow window;
    window.setColor(Qt::black);
    window.resize(window_width, window_height);
    QQuickItem ancestor{window.contentItem()};
    NativeChromeText label{&ancestor};
    label.setPosition({label_left, label_top});
    label.setSize({label_width, label_height});
    label.setPixelSize(font_size);
    label.setColor(Qt::white);
    label.setEmphasized(emphasized);
    label.setElide(Qt::ElideNone);
    label.setText(QStringLiteral("AVATAR fi ffi · Crème"));
    label.setClip(true);
    const auto scale = window.effectiveDevicePixelRatio();
    constexpr qreal first_phase = 0.1;
    constexpr qreal second_phase = 0.9;
    ancestor.setX(first_phase / scale);
    const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};
    QVERIFY(test::showComponentWindow(window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
    QImage frame;
    const auto grab = [&] {
      frame = grabFrame(window);

      return containsInk(frame);
    };
    QTRY_VERIFY_WITH_TIMEOUT(grab(), wait_ms);
    const auto expected = reference(frame.size(), label.text(), {.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale, .emphasized = emphasized, .red = false});
    if (frame != expected) {
      QTemporaryDir diagnostic;
      diagnostic.setAutoRemove(false);
      const auto actual_path = diagnostic.filePath(QStringLiteral("actual.png"));
      const auto expected_path = diagnostic.filePath(QStringLiteral("expected.png"));
      QVERIFY(frame.save(actual_path));
      QVERIFY(expected.save(expected_path));
      qInfo() << "Chrome text pixel mismatch:" << diagnostic.path();
    }

    QCOMPARE(frame, expected);

    ancestor.setX(second_phase / scale);
    const auto shifted = reference(frame.size(), label.text(), {.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale, .emphasized = emphasized, .red = false});
    QTRY_COMPARE_WITH_TIMEOUT(grabFrame(window), shifted, wait_ms);

    label.setColor(Qt::red);
    const auto recolored = reference(frame.size(), label.text(), {.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale, .emphasized = emphasized, .red = true});
    QTRY_COMPARE_WITH_TIMEOUT(grabFrame(window), recolored, wait_ms);

    label.setColor(Qt::white);
    QTRY_COMPARE_WITH_TIMEOUT(grabFrame(window), shifted, wait_ms);

    label.setText(QStringLiteral("w0 £ ß XYZ"));
    QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
    const auto replaced = reference(frame.size(), label.text(), {.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale, .emphasized = emphasized, .red = false});
    QTRY_COMPARE_WITH_TIMEOUT(grabFrame(window), replaced, wait_ms);

    constexpr QSize alternate_window{333, 83};
    const auto previous_pixels = grabFrame(window).size();
    window.resize(alternate_window);
    QTRY_COMPARE_WITH_TIMEOUT(window.size(), alternate_window, wait_ms);
    const auto resized_matches = [&] {
      const auto actual = grabFrame(window);

      return !actual.isNull() && actual.size() != previous_pixels && containsInk(actual) && actual == reference(actual.size(), label.text(), {.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale, .emphasized = emphasized, .red = false});
    };
    QTRY_VERIFY_WITH_TIMEOUT(resized_matches(), wait_ms);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ui::bundledFonts();
  ChromeTextTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "chrome_text_test.moc"
