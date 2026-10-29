#include "application/host_metrics.hpp"
#include "core/configuration.hpp"
#include "core/metrics.hpp"
#include "metrics_fixture.hpp"
#include "presentation/bar_metrics.hpp"
#include "presentation/mode_hints.hpp"
#include "qml_fixture.hpp"
#include "qt/metrics_projection.hpp"
#include "qt/mode_projection.hpp"
#include "qt/projection.hpp"
#include "ui/bundled_fonts.hpp"
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qvariant.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <cstdint>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int bar_width = 640;
constexpr int bar_height = 26;
constexpr std::uint8_t initial_cpu = 42;
constexpr std::uint16_t initial_memory = 128;
constexpr std::uint16_t updated_memory = 129;
constexpr std::uint8_t low_battery = 7;
constexpr std::uint8_t full_battery = 100;

QVariantMap barProperties(const HostMetrics &metrics) {
  return {
      {QStringLiteral("width"), bar_width},
      {QStringLiteral("height"), bar_height},
      {QStringLiteral("metrics"), metricsRecord(metrics)},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), ChromeMetrics{}.small}}},
  };
}

class StatusBarTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void missingMetricsStayHiddenWithoutAController() {
    QQmlEngine engine;
    const auto bar = createChrome(engine, QStringLiteral("StatusBar"), barProperties(HostMetrics{}));
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
    for (const auto *name : {"cpuMetric", "memoryMetric", "batteryMetric"}) {
      const auto *metric = bar->findChild<QQuickItem *>(QString::fromLatin1(name));
      QVERIFY(metric != nullptr);
      QVERIFY(!metric->isVisible());
    }
  }

  Q_SLOT static void metricsUseTheRuntimeValuesAndHideAnAbsentBattery() {
    QQmlEngine engine;
    HostMetrics metrics;
    QVERIFY(metrics.update(hostSample(1, initial_cpu, initial_memory, low_battery)));
    auto bar = createChrome(engine, QStringLiteral("StatusBar"), barProperties(metrics));
    const auto *cpu = bar->findChild<QQuickItem *>(QStringLiteral("cpuMetric"));
    const auto *memory = bar->findChild<QQuickItem *>(QStringLiteral("memoryMetric"));
    const auto *battery = bar->findChild<QQuickItem *>(QStringLiteral("batteryMetric"));
    QVERIFY(cpu != nullptr && memory != nullptr && battery != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(cpu->isVisible() && memory->isVisible() && battery->isVisible(), wait_ms);
    QCOMPARE(cpu->property("record").toMap().value(QStringLiteral("text")).toString(), QStringLiteral("42%"));
    QCOMPARE(memory->property("record").toMap().value(QStringLiteral("text")).toString(), QStringLiteral("12.8 GB"));
    QCOMPARE(battery->property("record").toMap().value(QStringLiteral("ink")).toString(), QStringLiteral("red"));
    QVERIFY(metrics.update(hostSample(2, 0, updated_memory)));
    QVERIFY(bar->setProperty("metrics", metricsRecord(metrics)));
    QVERIFY(!battery->isVisible());
    QVERIFY(cpu->isVisible() && memory->isVisible());
  }

  Q_SLOT static void modesReplaceMetricsAndDiagnosticsReserveSpace() {
    QQmlEngine engine;
    HostMetrics metrics;
    QVERIFY(metrics.update(hostSample(1, initial_cpu, initial_memory)));
    auto bar = createChrome(engine, QStringLiteral("StatusBar"), barProperties(metrics));
    const auto *cpu = bar->findChild<QQuickItem *>(QStringLiteral("cpuMetric"));
    QVERIFY(cpu != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(cpu->isVisible(), wait_ms);
    QVERIFY(bar->setProperty("mode", statusModeRecord(StatusMode::copy)));
    QVERIFY(!cpu->isVisible());
    QVERIFY(bar->setProperty("diagnostic", QStringLiteral("The configuration could not be loaded")));
    QVERIFY(bar->setProperty("mode", statusModeRecord(StatusMode::normal)));
    QTRY_VERIFY_WITH_TIMEOUT(cpu->isVisible(), wait_ms);
  }

  Q_SLOT static void liveMetricsAndResizesRenderWithoutQmlErrors() {
    QQuickWindow window;
    QQmlEngine engine;
    HostMetrics metrics;
    QVERIFY(metrics.update(hostSample(1, BarMetrics::cpu_danger, updated_memory, full_battery)));
    auto bar = createChrome(engine, QStringLiteral("StatusBar"), barProperties(metrics));
    bar->setParentItem(window.contentItem());
    window.resize(bar_width, bar_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(!window.grabWindow().isNull());
    constexpr int narrow_width = 90;
    bar->setWidth(narrow_width);
    const auto *memory = bar->findChild<QQuickItem *>(QStringLiteral("memoryMetric"));
    QVERIFY(memory != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!memory->isVisible(), wait_ms);
    bar->setWidth(bar_width);
    QTRY_VERIFY_WITH_TIMEOUT(memory->isVisible(), wait_ms);
    QVERIFY(metrics.update(hostSample(2, 0, initial_memory, 0)));
    QVERIFY(bar->setProperty("metrics", metricsRecord(metrics)));
    QVERIFY(!window.grabWindow().isNull());
  }
};

}

QTEST_MAIN(StatusBarTest)
#include "status_bar_test.moc"
