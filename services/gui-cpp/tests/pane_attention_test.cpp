#include "controlled_awake_clock.hpp"
#include "core/configuration.hpp"
#include "gui_wait.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/attention_fades.hpp"
#include "presentation/frame_pacer.hpp"
#include "presentation/pane_decoration_geometry.hpp"
#include "qt/native_pane_attention.hpp"
#include "qt/pane_attention_value.hpp"
#include "qt/window_animation_clock.hpp"
#include "shape_atlas.hpp"
#include <QColor>
#include <QCoreApplication>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSignalSpy>
#include <QSize>
#include <QString>
#include <QTimer>
#include <QUrl>
#include <QVariantMap>
#include <QtCore/qlogging.h>
#include <QtCore/qnumeric.h>
#include <QtCore/qobject.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstdint>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace {

using telar::gui::PaneAttentionKey;
using telar::gui::qt::NativePaneAttention;
using telar::gui::qt::paneAttentionKey;
using telar::gui::qt::paneAttentionValue;
using telar::gui::test::compareShapeImages;
using telar::gui::test::ControlledAwakeClock;
using telar::gui::test::shapeCompositingBudget;

constexpr int wait_ms = 5000;
constexpr int window_width = 160;
constexpr int window_height = 96;
constexpr std::uint64_t quarter_ns = 90'000'000;
constexpr std::uint64_t half_ns = quarter_ns * 2;
constexpr std::uint64_t duration_ns = quarter_ns * 4;
constexpr double quarter_alpha = 0.25;
constexpr double half_alpha = 0.5;
constexpr unsigned blocked_rgb = 0xE8C56A;
constexpr unsigned failed_rgb = 0xF27C7C;
constexpr unsigned background_rgb = 0x101010;
constexpr int cross_backend_error_per_layer = 1;

void configure(NativePaneAttention &item, PaneAttentionKey key = {.pane_id = 1, .attachment_generation = 1}) {
  item.setSize({window_width, window_height});
  item.setAttachment(paneAttentionValue(key));
  item.setColor(QColor::fromRgb(blocked_rgb));
  item.setActive(true);
}

bool frameAt(QQuickWindow &window, std::uint64_t now_ns) {
  ControlledAwakeClock::set(now_ns);
  const QSignalSpy frames{&window, &QQuickWindow::afterAnimating};
  window.update();

  return telar::gui::test::waitForGuiCondition([&frames] {
    return !frames.isEmpty();
  },
                                               wait_ms);
}

QJsonObject fixture() {
  QFile source{QStringLiteral(":/telar/test-pane-attention/cases.json")};
  if (!source.open(QFile::ReadOnly)) {
    qFatal("Could not open pane attention fixture");
  }

  return QJsonDocument::fromJson(source.readAll()).object();
}

std::vector<std::unique_ptr<NativePaneAttention>> createAtlas(const QQuickWindow &window, const QJsonObject &source) {
  std::vector<std::unique_ptr<NativePaneAttention>> items;
  const auto density = window.effectiveDevicePixelRatio();
  for (const auto &value : source.value(QStringLiteral("items")).toArray()) {
    const auto record = value.toObject();
    const auto bounds = record.value(QStringLiteral("rect")).toArray();
    auto item = std::make_unique<NativePaneAttention>(window.contentItem());
    configure(*item, {.pane_id = static_cast<std::uint64_t>(record.value(QStringLiteral("pane_id")).toInteger()), .attachment_generation = 1});
    item->setSize({bounds[2].toDouble() / density, bounds[3].toDouble() / density});
    item->setPosition({bounds[0].toDouble() / density, bounds[1].toDouble() / density});
    item->setRatio(record.value(QStringLiteral("ratio")).toDouble() / density);
    // This atlas records the original six-pixel shader shape, not the current chrome style.
    item->setRadius(6);
    item->setColor(QColor::fromRgb(record.value(QStringLiteral("rgb")).toInt()));
    items.push_back(std::move(item));
  }

  return items;
}

class PaneAttentionTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void init() {
    ControlledAwakeClock::set(0);
    QCOMPARE(telar::gui::platform::AwakeClock::nowNanoseconds(), 0);
  }

  Q_SLOT static void sharedFadePreservesIdentityAndParksItsClock() {
    QQuickWindow window;
    NativePaneAttention first{window.contentItem()};
    NativePaneAttention second{window.contentItem()};
    configure(first);
    configure(second);
    window.resize(window_width, window_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, 0));
    QCOMPARE(first.alpha(), 0);
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QVERIFY(timers.front()->isActive());

    QVERIFY(frameAt(window, quarter_ns));
    QCOMPARE(first.alpha(), quarter_alpha);
    QCOMPARE(second.alpha(), first.alpha());
    QVERIFY(frameAt(window, half_ns));
    QCOMPARE(first.alpha(), half_alpha);
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(first.alpha(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);

    NativePaneAttention replacement{window.contentItem()};
    configure(replacement);
    QVERIFY(frameAt(window, duration_ns));
    QTRY_COMPARE_WITH_TIMEOUT(replacement.alpha(), 1, wait_ms);
    first.setColor(QColor::fromRgb(failed_rgb));
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(first.alpha(), 1);
    QVERIFY(!timers.front()->isActive());

    first.setAttachment(paneAttentionValue({.pane_id = 1, .attachment_generation = 2}));
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(first.alpha(), 0);
    QCOMPARE(second.alpha(), 1);
    QVERIFY(frameAt(window, duration_ns + quarter_ns));
    QCOMPARE(first.alpha(), quarter_alpha);
    QCOMPARE(second.alpha(), 1);
  }

  Q_SLOT static void frameCapChangesCadenceWithoutRestartingFade() {
    QQuickWindow window;
    NativePaneAttention item{window.contentItem()};
    configure(item);
    auto &clock = telar::gui::qt::WindowAnimationClock::forWindow(window);
    const auto uncapped_interval = clock.frameInterval();
    window.resize(window_width, window_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, 0));
    QVERIFY(frameAt(window, quarter_ns));
    QCOMPARE(item.alpha(), quarter_alpha);

    clock.setMaximumFrameRate(telar::gui::Configuration::minimum_fps);
    QCOMPARE(clock.frameInterval(), telar::gui::FramePacer::maximum_interval_ns);
    QVERIFY(frameAt(window, quarter_ns));
    QCOMPARE(item.alpha(), quarter_alpha);
    QVERIFY(frameAt(window, half_ns));
    QCOMPARE(item.alpha(), half_alpha);

    clock.setMaximumFrameRate(std::nullopt);
    QCOMPARE(clock.frameInterval(), uncapped_interval);
    QVERIFY(frameAt(window, half_ns));
    QCOMPARE(item.alpha(), half_alpha);
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(item.alpha(), 1);
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void absentRingsArePrunedAndRestartOnReturn() {
    QQuickWindow window;
    NativePaneAttention item{window.contentItem()};
    configure(item);
    window.resize(window_width, window_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, 0));
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(item.alpha(), 1);

    item.setVisible(false);
    QVERIFY(frameAt(window, duration_ns));
    item.setVisible(true);
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(item.alpha(), 0);
    QVERIFY(frameAt(window, duration_ns + quarter_ns));
    QCOMPARE(item.alpha(), quarter_alpha);

    item.setActive(false);
    QVERIFY(frameAt(window, duration_ns + quarter_ns));
    item.setActive(true);
    QVERIFY(frameAt(window, duration_ns + quarter_ns));
    QCOMPARE(item.alpha(), 0);
  }

  Q_SLOT static void firstExposureStartsTheFadeAndHidingKeepsItsIdentity() {
    QQuickWindow window;
    NativePaneAttention item{window.contentItem()};
    configure(item);
    window.resize(window_width, window_height);
    QCoreApplication::sendPostedEvents();
    ControlledAwakeClock::set(duration_ns);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, duration_ns));
    QCOMPARE(item.alpha(), 0);
    QVERIFY(frameAt(window, duration_ns * 2));
    QCOMPARE(item.alpha(), 1);

    window.hide();
    QCoreApplication::sendPostedEvents();
    ControlledAwakeClock::set(duration_ns * 3);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, duration_ns * 3));
    QCOMPARE(item.alpha(), 1);
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr && !timer->isActive());
  }

  Q_SLOT static void movingToAnotherWindowStartsASeparateFade() {
    QQuickWindow first;
    QQuickWindow second;
    NativePaneAttention item{first.contentItem()};
    configure(item);
    first.resize(window_width, window_height);
    second.resize(window_width, window_height);
    first.show();
    QTRY_VERIFY_WITH_TIMEOUT(first.isExposed(), wait_ms);
    QVERIFY(frameAt(first, 0));
    QVERIFY(frameAt(first, duration_ns));
    QCOMPARE(item.alpha(), 1);

    first.hide();
    second.show();
    QTRY_VERIFY_WITH_TIMEOUT(second.isExposed(), wait_ms);
    item.setParentItem(second.contentItem());
    QVERIFY(frameAt(second, duration_ns));
    QCOMPARE(item.alpha(), 0);
    QVERIFY(frameAt(second, duration_ns + quarter_ns));
    QCOMPARE(item.alpha(), quarter_alpha);
    const auto *timer = first.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
  }

  Q_SLOT static void alphaCallbacksCanDestroyTheirWindow() {
    auto window = std::make_unique<QQuickWindow>();
    auto owned_item = std::make_unique<NativePaneAttention>(window->contentItem());
    const QPointer<NativePaneAttention> alive{owned_item.get()};
    configure(*owned_item);
    window->resize(window_width, window_height);
    window->show();
    QTRY_VERIFY_WITH_TIMEOUT(window->isExposed(), wait_ms);
    QVERIFY(frameAt(*window, 0));
    const auto *const item = owned_item.release();
    connect(item, &NativePaneAttention::alphaChanged, window.get(), [&window] {
      window.reset();
    });
    ControlledAwakeClock::set(quarter_ns);
    window->update();
    QTRY_VERIFY_WITH_TIMEOUT(alive.isNull(), wait_ms);
    QVERIFY(!window);
  }

  Q_SLOT static void attentionRadiusFollowsPaneSurfaces() {
    NativePaneAttention item;
    QCOMPARE(item.radius(), qreal{telar::gui::PaneDecorationGeometry::frame_radius});
    const QSignalSpy changes{&item, &NativePaneAttention::radiusChanged};
    item.setRadius(4);
    QCOMPARE(item.radius(), qreal{4});
    QCOMPARE(changes.size(), 1);
    item.setRadius(-1);
    item.setRadius(qQNaN());
    QCOMPARE(item.radius(), qreal{4});
    QCOMPARE(changes.size(), 1);
  }

  Q_SLOT static void attachmentIdentityKeepsAllIntegerBits() {
    constexpr PaneAttentionKey key{.pane_id = 0xFEDCBA9876543210, .attachment_generation = 0xABCDEF0123456789};
    const auto restored = paneAttentionKey(paneAttentionValue(key));
    QVERIFY(restored.has_value());
    QCOMPARE(restored.value_or(PaneAttentionKey{}), key);
    QVERIFY(!paneAttentionKey(QVariant::fromValue(1)).has_value());

    QQmlEngine engine;
    QQmlComponent component{&engine};
    component.setData(R"(
      import Telar.Gui
      NativePaneAttention {
        required property var record
        attachment: record.attentionKey
      }
    )",
                      QUrl{});
    const auto item = std::unique_ptr<QObject>{component.createWithInitialProperties({{QStringLiteral("record"), QVariantMap{{QStringLiteral("attentionKey"), paneAttentionValue(key)}}}})};
    QVERIFY2(item != nullptr, qPrintable(component.errorString()));
    const auto *ring = qobject_cast<NativePaneAttention *>(item.get());
    QVERIFY(ring != nullptr);
    QCOMPARE(paneAttentionKey(ring->attachment()).value_or(PaneAttentionKey{}), key);
  }

  Q_SLOT static void originalShaderAtlasAtFourFadePhases() {
    QQuickWindow window;
    auto source = fixture();
    const auto density = window.effectiveDevicePixelRatio();
    const QSize physical{source.value(QStringLiteral("width")).toInt(), source.value(QStringLiteral("height")).toInt()};
    window.resize(qRound(physical.width() / density), qRound(physical.height() / density));
    window.setMinimumSize(window.size());
    window.setMaximumSize(window.size());
    window.setColor(QColor::fromRgb(background_rgb));
    const auto items = createAtlas(window, source);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(frameAt(window, 0));
    const auto exact = window.rendererInterface()->graphicsApi() == QSGRendererInterface::Metal;
    qInfo() << "Graphics API:" << window.rendererInterface()->graphicsApi() << "effective density:" << density;
    const auto capture_dir = qEnvironmentVariable("TELAR_GUI_ATTENTION_CAPTURE_DIR");
    if (!capture_dir.isEmpty()) {
      QVERIFY(QDir{}.mkpath(capture_dir));
    }

    for (const auto &value : source.value(QStringLiteral("frames")).toArray()) {
      const auto phase = value.toObject();
      QVERIFY(frameAt(window, static_cast<std::uint64_t>(phase.value(QStringLiteral("now_ns")).toInteger())));
      for (const auto &item : items) {
        QCOMPARE(item->alpha(), phase.value(QStringLiteral("alpha")).toDouble());
      }

      const auto capture_name = phase.value(QStringLiteral("capture")).toString();
      const QImage expected{QStringLiteral(":/telar/test-pane-attention/") + capture_name};
      QVERIFY(!expected.isNull());
      source.insert(QStringLiteral("shapes"), phase.value(QStringLiteral("shapes")));
      const auto budget = shapeCompositingBudget(source, exact ? 0 : cross_backend_error_per_layer);
      auto image = window.grabWindow();
      image.setDevicePixelRatio(1);
      qInfo() << "Drawable pixels" << image.size() << "atlas pixels" << physical;
      QVERIFY(image.width() >= physical.width() && image.height() >= physical.height());
      if (!capture_dir.isEmpty()) {
        QVERIFY(image.save(QDir{capture_dir}.filePath(capture_name + QStringLiteral("-window.png"))));
      }

      image = image.copy(0, 0, physical.width(), physical.height());
      const auto error = compareShapeImages(image, {.pixels = expected, .budget = budget});
      qInfo() << capture_name << "exact Metal:" << exact << "different pixels:" << error.pixels << "maximum channel:" << error.maximum_channel << "outside budget:" << error.outside_budget;
      if (!capture_dir.isEmpty()) {
        QVERIFY(image.save(QDir{capture_dir}.filePath(capture_name)));
      }

      QCOMPARE(image.size(), physical);
      QCOMPARE(error.outside_budget, 0);
      if (exact) {
        QCOMPARE(error.pixels, 0);
      }
    }
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  PaneAttentionTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "pane_attention_test.moc"
