#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
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
#include <QSGNode>
#include <QSignalSpy>
#include <QSize>
#include <QString>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qrgb.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

import telar.gui.ui.design.controls;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.scene;
import telar.gui.tests.frame_fixture;
import telar.gui.tests.qt_case;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

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
    return {{u"cellWidth"_s, cell_width}, {u"cellHeight"_s, cell_height}, {u"baseline"_s, cell_baseline}, {u"pixelHeight"_s, cell_baseline}, {u"family"_s, u"JetBrains Mono"_s}};
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

  void stamp(QImage& expected, fonts::GlyphBitmapView bitmap, QPoint origin, bool red) {
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

  QImage reference(QSize size, const QString& text, const ReferencePaint& paint) {
    const auto fonts = ChromeFonts::shared();
    auto& face = fonts->face(paint.emphasized);
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

  bool containsInk(const QImage& image) {
    for (int row = 0; row < image.height(); ++row) {
      for (int column = 0; column < image.width(); ++column) {
        if (qRed(image.pixel(column, row)) != 0) {
          return true;
        }
      }
    }

    return false;
  }

  QImage grabFrame(QQuickWindow& window) {
    auto frame = window.grabWindow();

    frame.setDevicePixelRatio(1);

    return frame.convertToFormat(QImage::Format_RGB32);
  }

  class ObservedSceneNode final : public QSGNode {
  public:
    explicit ObservedSceneNode(unsigned& destroyed)
        : destroyed_(destroyed) {}

    ObservedSceneNode(const ObservedSceneNode&) = delete;
    ObservedSceneNode& operator=(const ObservedSceneNode&) = delete;
    ObservedSceneNode(ObservedSceneNode&&) = delete;
    ObservedSceneNode& operator=(ObservedSceneNode&&) = delete;

    ~ObservedSceneNode() override {
      ++destroyed_;
    }

  private:
    unsigned& destroyed_;
  };

  class AncestorItem final : public QQuickItem {
  public:
    [[nodiscard]] auto observerCounts() const {
      return telar::ds::Array{receivers("2xChanged()"), receivers("2yChanged()"), receivers("2widthChanged()"), receivers("2heightChanged()"), receivers("2rotationChanged()"), receivers("2scaleChanged()"), receivers("2transformOriginChanged(TransformOrigin)"), receivers("2parentChanged(QQuickItem*)")};
    }
  };

  class [[qt::object]] ChromeTextTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
  private:
    [[qt::slot]] static void initTestCase() {
      bundledFonts();
    }

    [[qt::slot]] static void ancestorConnectionsFollowTheCurrentChain() {
      AncestorItem first;
      AncestorItem second;
      auto middle = std::make_unique<AncestorItem>();
      AncestorItem nearest;

      middle->setParentItem(&first);
      nearest.setParentItem(middle.get());
      const auto absent = first.observerCounts();
      auto present = absent;

      for (auto& count : present.viewMut()) {
        ++count;
      }

      {
        NativeChromeText label{&nearest};

        QCOMPARE(first.observerCounts(), present);
        QCOMPARE(middle->observerCounts(), present);
        QCOMPARE(nearest.observerCounts(), present);
        QCOMPARE(second.observerCounts(), absent);

        middle->setParentItem(&second);
        QCOMPARE(first.observerCounts(), absent);
        QCOMPARE(second.observerCounts(), present);
        QCOMPARE(middle->observerCounts(), present);
        QCOMPARE(nearest.observerCounts(), present);

        nearest.setParentItem(&first);
        QCOMPARE(first.observerCounts(), present);
        QCOMPARE(second.observerCounts(), absent);
        QCOMPARE(middle->observerCounts(), absent);
        QCOMPARE(nearest.observerCounts(), present);

        nearest.setParentItem(middle.get());
        middle.reset();
        QVERIFY(nearest.parentItem() == nullptr);
        QCOMPARE(first.observerCounts(), absent);
        QCOMPARE(second.observerCounts(), absent);
        QCOMPARE(nearest.observerCounts(), present);

        label.setParentItem(&second);
        QCOMPARE(nearest.observerCounts(), absent);
        QCOMPARE(second.observerCounts(), present);
        label.setParentItem(nullptr);
        QCOMPARE(second.observerCounts(), absent);
        label.setParentItem(&nearest);
        QCOMPARE(nearest.observerCounts(), present);
      }

      QCOMPARE(first.observerCounts(), absent);
      QCOMPARE(second.observerCounts(), absent);
      QCOMPARE(nearest.observerCounts(), absent);
    }

    [[qt::slot]] static void reparentedAncestorsKeepChromePixelsExact() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      QQuickItem first{window.contentItem()};
      QQuickItem second{window.contentItem()};
      QQuickItem middle{&first};
      QQuickItem nearest{&middle};
      NativeChromeText label{&nearest};

      label.setPosition({label_left, label_top});
      label.setSize({label_width, label_height});
      label.setPixelSize(font_size);
      label.setColor(Qt::white);
      label.setText(u"AVATAR fi ffi"_s);
      label.setElide(Qt::ElideNone);
      const auto scale = window.effectiveDevicePixelRatio();
      constexpr qreal first_phase = 0.1;
      constexpr qreal second_phase = 0.9;
      constexpr qreal root_offset = 3;

      first.setX(first_phase / scale);
      second.setPosition({root_offset, root_offset});
      QVERIFY(test::showComponentWindow(window, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
      const auto matches = [&] {
        const auto actual = grabFrame(window);
        const ReferencePaint paint{.origin = label.mapToScene({0, 0}), .height = label.height(), .scale = scale};

        return !actual.isNull() && containsInk(actual) && actual == reference(actual.size(), label.text(), paint);
      };

      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      middle.setParentItem(&second);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      second.setX(root_offset + (second_phase / scale));
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      first.setY(root_offset);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      nearest.setParentItem(&first);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      first.setX(second_phase / scale);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      nearest.setParentItem(&middle);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
      middle.setParentItem(&first);
      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
    }

    [[qt::slot]] static void failedFontCollectionReleasesPreviousScene() {
      unsigned destroyed = 0;
      QQuickWindow window;
      QSGNode parent;
      auto previous = std::make_unique<ObservedSceneNode>(destroyed);
      auto child = std::make_unique<ObservedSceneNode>(destroyed);

      previous->appendChildNode(child.release());
      parent.appendChildNode(previous.release());
      const ChromeTextPaint paint;

      QVERIFY_THROWS_EXCEPTION(std::invalid_argument, static_cast<void>(paintChromeText(parent.firstChild(), window, paint, {})));
      constexpr unsigned expected_destroyed = 2;

      QCOMPARE(destroyed, expected_destroyed);
      QVERIFY(parent.firstChild() == nullptr);
    }

    [[qt::slot]] static void cellTextDiscoversTheContinuationGlyph() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      NativeCellText label{window.contentItem()};

      label.setPosition({label_left, label_top});
      label.setSize({label_width, label_height});
      label.setGrid(cellTextGrid());
      label.setColor(Qt::white);
      label.setText(u"A↵B"_s);
      qreal initial_width = 0;

      connect(&label, &QQuickItem::implicitWidthChanged, &window, [&] {
        if (initial_width == 0) {
          initial_width = label.implicitWidth();
        }
      });

      const auto& catalog = WindowFontCatalog::forWindow(window);
      const auto original = catalog.collection();

      QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
      QVERIFY(test::showComponentWindow(window, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(catalog.collection()->count > 0, wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
      QVERIFY(ResidentFonts::shared(catalog.collection())->source("↵", fonts::FontRole::primary).hasValue());
      QVERIFY(test::waitForSynchronizedFrame(window, wait_ms));
      QVERIFY(label.available());
      QVERIFY(initial_width > 0);
      QCOMPARE(label.implicitWidth(), initial_width);
      const auto collection = catalog.collection();

      label.setText(u"B↵A"_s);
      QTRY_COMPARE_WITH_TIMEOUT(label.implicitWidth(), initial_width, wait_ms);
      QVERIFY(!catalog.busy());
      QCOMPARE(catalog.collection(), collection);
    }

    [[qt::slot]] static void cellTextPreservesItsPrimaryAcrossCatalogChanges() {
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
      auto& catalog = WindowFontCatalog::forWindow(window);

      catalog.configure(configuration);
      QVERIFY(ResidentFonts::shared(catalog.collection())->source("↵", fonts::FontRole::primary).hasValue());
      const auto primary = ResidentFonts::resolveSource(u"JetBrains Mono"_s, {});
      const auto original = catalog.collectionFor(primary);

      QCOMPARE(original->primary, primary);
      QCOMPARE(catalog.collectionFor(primary), original);
      QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
      NativeCellText label{window.contentItem()};

      label.setSize({label_width, label_height});
      label.setGrid(cellTextGrid());
      label.setColor(Qt::white);
      label.setText(u"A↵B"_s);
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
      QVERIFY(ResidentFonts::shared(updated)->source("↵", fonts::FontRole::primary).hasValue());
      QVERIFY(!ResidentFonts::shared(original)->source("↵", fonts::FontRole::primary));
      QVERIFY(test::waitForSynchronizedFrame(window, wait_ms));
      QVERIFY(label.available());
      QVERIFY(initial_width > 0);
      QCOMPARE(label.implicitWidth(), initial_width);
    }

    [[qt::slot]] static void cellTextNotificationsMayRetireTheItem() {
      std::unique_ptr<NativeCellText> label;
      const auto retire = [&label] {
        label.reset();
      };

      label = std::make_unique<NativeCellText>();
      connect(label.get(), &NativeCellText::textChanged, label.get(), retire);
      label->setText(u"retired"_s);
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

    [[qt::slot]] static void cellTextLayoutObserversMayRetireTheItem() {
      QQuickWindow window;

      window.resize(window_width, window_height);
      std::unique_ptr<NativeCellText> label;
      const auto create = [&] {
        label = std::make_unique<NativeCellText>(window.contentItem());
        label->setGrid(cellTextGrid());
        label->setText(u"retired"_s);
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

    [[qt::slot]] static void centeredChromeUsesOriginalWholePixelInset() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      const auto scale = window.effectiveDevicePixelRatio();
      constexpr qreal physical_font_size = 27;
      constexpr qreal physical_free_space = 5;
      constexpr qreal original_inset = 2;
      const auto text = u"H"_s;

      QVERIFY(ChromeFonts::shared()->covers(text.toStdString(), false));
      NativeChromeText label{window.contentItem()};

      label.setPosition({label_left, label_top});
      label.setSize({label_width, label_height});
      label.setPixelSize(physical_font_size / scale);
      label.setColor(Qt::white);
      label.setText(text);
      label.setElide(Qt::ElideNone);
      label.setHorizontalAlignment(Qt::AlignHCenter);
      label.setWholePixelCentering(true);
      QVERIFY(test::showComponentWindow(window, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
      label.setWidth(label.implicitWidth() + (physical_free_space / scale));
      const ReferencePaint paint{.origin = label.mapToScene({original_inset / scale, 0}), .height = label.height(), .pixel_size = label.pixelSize(), .scale = scale};
      const auto matches = [&] {
        const auto actual = grabFrame(window);

        return !actual.isNull() && actual == reference(actual.size(), text, paint);
      };

      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
    }

    [[qt::slot]] static void centeredFormChromeKeepsOriginalFractionalInset() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      const auto scale = window.effectiveDevicePixelRatio();
      constexpr qreal physical_font_size = 27;
      constexpr qreal physical_free_space = 5;
      constexpr qreal original_inset = 2.5;
      const auto text = u"H"_s;

      QVERIFY(ChromeFonts::shared()->covers(text.toStdString(), false));
      NativeChromeText label{window.contentItem()};

      label.setPosition({label_left, label_top});
      label.setSize({label_width, label_height});
      label.setPixelSize(physical_font_size / scale);
      label.setColor(Qt::white);
      label.setText(text);
      label.setElide(Qt::ElideNone);
      label.setHorizontalAlignment(Qt::AlignHCenter);
      QVERIFY(test::showComponentWindow(window, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && label.available(), wait_ms);
      label.setWidth(label.implicitWidth() + (physical_free_space / scale));
      const ReferencePaint paint{.origin = label.mapToScene({original_inset / scale, 0}), .height = label.height(), .pixel_size = label.pixelSize(), .scale = scale};
      const auto matches = [&] {
        const auto actual = grabFrame(window);

        return !actual.isNull() && actual == reference(actual.size(), text, paint);
      };

      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);
    }

    [[qt::slot]] static void regularMasksAndPositionsMatchOriginalFace() {
      verifyMasks(false);
    }

    [[qt::slot]] static void emphasizedMasksAndPositionsMatchOriginalFace() {
      verifyMasks(true);
    }

    [[qt::slot]] static void mixedLabelsRetainPreferredInkDuringDiscovery() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      NativeChromeText label{window.contentItem()};

      label.setPosition({label_left, label_top});
      label.setSize({label_width, label_height});
      label.setPixelSize(font_size);
      label.setColor(Qt::white);
      label.setText(u"ABC \u2387 AV"_s);
      const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};

      QVERIFY(test::showComponentWindow(window, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
      const auto& catalog = WindowFontCatalog::forWindow(window);

      QTRY_VERIFY_WITH_TIMEOUT(!catalog.busy(), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
      const auto scale = window.effectiveDevicePixelRatio();
      const auto font_height = static_cast<std::uint16_t>(std::round(static_cast<float>(font_size * scale)));
      const auto prefix_width = ChromeFonts::shared()->face(false).shape("ABC ", font_height).advance();
      const QRect prefix{static_cast<int>(label_left * scale), static_cast<int>(label_top * scale), prefix_width, static_cast<int>(label_height * scale)};
      const ReferencePaint paint{.origin = label.mapToScene({0, 0}), .height = label.height(), .pixel_size = font_size, .scale = scale};
      const auto matches = [&] {
        const auto actual = grabFrame(window);

        return !actual.isNull() && actual.copy(prefix) == reference(actual.size(), u"ABC "_s, paint).copy(prefix);
      };

      QTRY_VERIFY_WITH_TIMEOUT(matches(), wait_ms);

      const auto collection = catalog.collection();
      const auto font_set = ResidentFonts::shared(collection);
      const auto expected = font_set->face(fonts::FontRole::regular).shape("ABC ", font_height).advance() + font_set->face(fonts::FontRole::primary).metrics(font_height).maximum_advance + font_set->face(fonts::FontRole::regular).shape(" AV", font_height).advance();

      QCOMPARE(label.implicitWidth(), expected / scale);
      qInfo() << "Discovered branch-font faces:" << collection->count;
      const auto changes = QSignalSpy{&catalog, &WindowFontCatalog::fontsChanged};
      const auto previous_frames = frames.count();

      label.setText(u"ABC \u2387 AV again"_s);
      QTRY_VERIFY_WITH_TIMEOUT(label.available(), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(frames.count() > previous_frames, wait_ms);
      QVERIFY(!catalog.busy());
      QCOMPARE(catalog.collection(), collection);
      QCOMPARE(changes.count(), 0);
    }

    [[qt::slot]] static void replacementFontSetRejectsInFlightDiscovery() {
      QQuickWindow window;
      auto& catalog = WindowFontCatalog::forWindow(window);
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

    [[qt::slot]] static void destroyingWindowJoinsItsDiscovery() {
      auto window = std::make_unique<QQuickWindow>();
      auto& catalog = WindowFontCatalog::forWindow(*window);
      const QPointer<WindowFontCatalog> lifetime{&catalog};

      catalog.request("\u2387", fonts::FontRole::regular);
      QVERIFY(catalog.busy());
      window.reset();
      QVERIFY(lifetime.isNull());
    }

    [[qt::slot]] static void discoveryCallbacksMayDestroyTheirWindow() {
      auto window = std::make_unique<QQuickWindow>();
      auto& catalog = WindowFontCatalog::forWindow(*window);
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

    [[qt::slot]] static void fittedLabelsKeepNativeMasksAndFullMeasurement() {
      QQuickWindow window;

      window.setColor(Qt::black);
      window.resize(window_width, window_height);
      const auto scale = window.effectiveDevicePixelRatio();
      constexpr qreal narrow_pixels = 50;
      constexpr qreal wider_pixels = 70;
      const auto original = u"Adrians-MacBook-Pro.local"_s;
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
      const auto matches = [&](const QString& text) {
        const auto actual = grabFrame(window);

        return !actual.isNull() && actual == reference(actual.size(), text, paint);
      };

      QTRY_VERIFY_WITH_TIMEOUT(matches(u"Adrian…"_s), wait_ms);

      label.setWidth(wider_pixels / scale);
      QTRY_VERIFY_WITH_TIMEOUT(matches(u"Adrians-M…"_s), wait_ms);
      QCOMPARE(label.implicitWidth(), full_width);

      label.setWidth(1 / scale);
      QTRY_VERIFY_WITH_TIMEOUT(matches(QString{}), wait_ms);
      QVERIFY(label.available());
      QCOMPARE(label.implicitWidth(), full_width);

      label.setWidth(label_width);
      QTRY_VERIFY_WITH_TIMEOUT(matches(original), wait_ms);
      label.setWidth(narrow_pixels / scale);
      QTRY_VERIFY_WITH_TIMEOUT(matches(u"Adrian…"_s), wait_ms);
      label.setElide(Qt::ElideNone);
      label.setWidth(label_width);
      QTRY_VERIFY_WITH_TIMEOUT(matches(original), wait_ms);
      QCOMPARE(label.text(), original);

      label.setWidth(narrow_pixels / scale);
      label.setEmphasized(true);
      label.setElide(Qt::ElideRight);
      paint.emphasized = true;
      QTRY_VERIFY_WITH_TIMEOUT(matches(u"Adria…"_s), wait_ms);
      label.setWidth(wider_pixels / scale);
      QTRY_VERIFY_WITH_TIMEOUT(matches(u"Adrians-…"_s), wait_ms);
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
      label.setText(u"AVATAR fi ffi · Crème"_s);
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
        const auto actual_path = diagnostic.filePath(u"actual.png"_s);
        const auto expected_path = diagnostic.filePath(u"expected.png"_s);

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

      label.setText(u"w0 £ ß XYZ"_s);
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

  using telar::gui::test::QtCase;

  const QtCase<ChromeTextTest, "ancestorConnectionsFollowTheCurrentChain"> case_ancestor_connections_follow_the_current_chain{"chrome_text.ancestor_connections_follow_the_current_chain"};
  const QtCase<ChromeTextTest, "reparentedAncestorsKeepChromePixelsExact"> case_reparented_ancestors_keep_chrome_pixels_exact{"chrome_text.reparented_ancestors_keep_chrome_pixels_exact"};
  const QtCase<ChromeTextTest, "failedFontCollectionReleasesPreviousScene"> case_failed_font_collection_releases_previous_scene{"chrome_text.failed_font_collection_releases_previous_scene"};
  const QtCase<ChromeTextTest, "cellTextDiscoversTheContinuationGlyph"> case_cell_text_discovers_the_continuation_glyph{"chrome_text.cell_text_discovers_the_continuation_glyph"};
  const QtCase<ChromeTextTest, "cellTextPreservesItsPrimaryAcrossCatalogChanges"> case_cell_text_preserves_its_primary_across_catalog_changes{"chrome_text.cell_text_preserves_its_primary_across_catalog_changes"};
  const QtCase<ChromeTextTest, "cellTextNotificationsMayRetireTheItem"> case_cell_text_notifications_may_retire_the_item{"chrome_text.cell_text_notifications_may_retire_the_item"};
  const QtCase<ChromeTextTest, "cellTextLayoutObserversMayRetireTheItem"> case_cell_text_layout_observers_may_retire_the_item{"chrome_text.cell_text_layout_observers_may_retire_the_item"};
  const QtCase<ChromeTextTest, "centeredChromeUsesOriginalWholePixelInset"> case_centered_chrome_uses_original_whole_pixel_inset{"chrome_text.centered_chrome_uses_original_whole_pixel_inset"};
  const QtCase<ChromeTextTest, "centeredFormChromeKeepsOriginalFractionalInset"> case_centered_form_chrome_keeps_original_fractional_inset{"chrome_text.centered_form_chrome_keeps_original_fractional_inset"};
  const QtCase<ChromeTextTest, "regularMasksAndPositionsMatchOriginalFace"> case_regular_masks_and_positions_match_original_face{"chrome_text.regular_masks_and_positions_match_original_face"};
  const QtCase<ChromeTextTest, "emphasizedMasksAndPositionsMatchOriginalFace"> case_emphasized_masks_and_positions_match_original_face{"chrome_text.emphasized_masks_and_positions_match_original_face"};
  const QtCase<ChromeTextTest, "mixedLabelsRetainPreferredInkDuringDiscovery"> case_mixed_labels_retain_preferred_ink_during_discovery{"chrome_text.mixed_labels_retain_preferred_ink_during_discovery"};
  const QtCase<ChromeTextTest, "replacementFontSetRejectsInFlightDiscovery"> case_replacement_font_set_rejects_in_flight_discovery{"chrome_text.replacement_font_set_rejects_in_flight_discovery"};
  const QtCase<ChromeTextTest, "destroyingWindowJoinsItsDiscovery"> case_destroying_window_joins_its_discovery{"chrome_text.destroying_window_joins_its_discovery"};
  const QtCase<ChromeTextTest, "discoveryCallbacksMayDestroyTheirWindow"> case_discovery_callbacks_may_destroy_their_window{"chrome_text.discovery_callbacks_may_destroy_their_window"};
  const QtCase<ChromeTextTest, "fittedLabelsKeepNativeMasksAndFullMeasurement"> case_fitted_labels_keep_native_masks_and_full_measurement{"chrome_text.fitted_labels_keep_native_masks_and_full_measurement"};

}

#ifndef TELAR_MOC_RUN
#include "chrome_text_test.moc"
#endif
