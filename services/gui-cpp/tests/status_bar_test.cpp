#include "application/host_metrics.hpp"
#include "core/configuration.hpp"
#include "core/metrics.hpp"
#include "metrics_fixture.hpp"
#include "presentation/bar_metrics.hpp"
#include "presentation/mode_hints.hpp"
#include "qml_fixture.hpp"
#include "qt/component_projection.hpp"
#include "qt/metrics_projection.hpp"
#include "qt/mode_projection.hpp"
#include "qt/projection.hpp"
#include "qt/bundled_fonts.hpp"
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
#include <array>
#include <cstdint>
#include <optional>
#include <string_view>

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

using BarContent = components::Content<components::Capacity{.nodes = 8, .text = 256, .samples = 64, .actions = 0}>;

void appendNode(BarContent &content, components::Node node, std::string_view text = {}, std::string_view detail = {}) {
  components::Input input{};
  input.node = node;
  input.text = text;
  input.detail = detail;
  content.append(input);
}

QVariantMap treeProperties(const BarContent &content) {
  const auto nodes = componentRecords(content, Configuration{}.theme, {}, [](BindingAction) -> std::optional<NamedActionDescription> { return std::nullopt; });
  return {
      {QStringLiteral("width"), 1000},
      {QStringLiteral("height"), bar_height},
      {QStringLiteral("controller"), QVariant::fromValue(static_cast<QObject *>(nullptr))},
      {QStringLiteral("surface"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("static")}, {QStringLiteral("identity"), QStringLiteral("fixture")}, {QStringLiteral("generation"), QStringLiteral("1")}, {QStringLiteral("source"), 0}, {QStringLiteral("nodes"), nodes}}},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), ChromeMetrics{}.small}, {QStringLiteral("body"), ChromeMetrics{}.body}}},
  };
}

class StatusBarTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
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

  Q_SLOT static void diagnosticShowsThePointingCursor() {
    QQuickWindow window;
    QQmlEngine engine;
    HostMetrics metrics;
    QVERIFY(metrics.update(hostSample(1, initial_cpu, initial_memory)));
    auto bar = createChrome(engine, QStringLiteral("StatusBar"), barProperties(metrics));
    bar->setParentItem(window.contentItem());
    window.resize(bar_width, bar_height);
    QVERIFY(bar->setProperty("diagnostic", QStringLiteral("The configuration could not be loaded")));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto findArea = [&]() -> QQuickItem * {
      for (auto *item : visualItems(*bar, QString{})) {
        if (item->inherits("QQuickMouseArea") && item->isVisible() && item->width() > 0) {
          return item;
        }
      }

      return nullptr;
    };
    QTRY_VERIFY_WITH_TIMEOUT(findArea() != nullptr, wait_ms);
    const auto *area = findArea();
    QTest::mouseMove(&window, area->mapRectToScene(area->boundingRect()).center().toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, wait_ms);
  }

  Q_SLOT static void inlineMetersReserveTheirTextAndTrack_data() {
    QTest::addColumn<bool>("compact");
    QTest::addColumn<bool>("labelled");
    QTest::addColumn<QString>("detail");
    QTest::addColumn<qreal>("ratio");
    QTest::newRow("full") << false << true << QString{} << qreal{1};
    QTest::newRow("compact") << true << true << QString{} << qreal{1};
    QTest::newRow("unlabelled") << false << false << QString{} << qreal{1};
    QTest::newRow("unlabelled-compact") << true << false << QString{} << qreal{1};
    QTest::newRow("custom-value") << false << true << QStringLiteral("20 / 100") << qreal{1};
    QTest::newRow("scaled") << false << true << QString{} << qreal{1.5};
  }

  Q_SLOT static void inlineMetersReserveTheirTextAndTrack() {
    QFETCH(bool, compact);
    QFETCH(bool, labelled);
    QFETCH(QString, detail);
    QFETCH(qreal, ratio);
    QQuickWindow window;
    QQmlEngine engine;
    BarContent content;
    const auto detail_bytes = detail.toUtf8();
    const std::string_view value_text{detail_bytes.constData(), static_cast<std::size_t>(detail_bytes.size())};
    appendNode(content, {.kind = components::Kind::group});
    appendNode(content, {.kind = components::Kind::meter, .parent = 0, .value = components::Node::full_scale}, labelled ? "5h" : "", value_text);
    appendNode(content, {.kind = components::Kind::meter, .parent = 0}, labelled ? "7d" : "", value_text);
    auto properties = treeProperties(content);
    properties.insert(QStringLiteral("ratio"), ratio);
    if (compact) {
      properties.insert(QStringLiteral("fittedLevels"), QVariantMap{{QStringLiteral("1"), 1}, {QStringLiteral("2"), 1}});
    }
    auto tree = createChrome(engine, QStringLiteral("ComponentTree"), properties);
    tree->setParentItem(window.contentItem());
    window.resize(1000, bar_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*tree, QStringLiteral("componentMeterTrack")).size(), 2, wait_ms);
    QVERIFY(!window.grabWindow().isNull());
    for (const auto *track : visualItems(*tree, QStringLiteral("componentMeterTrack"))) {
      const auto *meter = track->parentItem();
      const auto *label = meter->findChild<QQuickItem *>(QStringLiteral("componentMeterLabel"));
      const auto *value = meter->findChild<QQuickItem *>(QStringLiteral("componentMeterValue"));
      QVERIFY(label != nullptr && value != nullptr);
      QVERIFY(value->isVisible());
      QTRY_VERIFY_WITH_TIMEOUT(value->implicitWidth() > 0, wait_ms);
      QCOMPARE(label->property("text").toString().contains(QLatin1Char{'%'}), false);
      const auto expected_value = detail.isEmpty() ? (label->property("text").toString() == QStringLiteral("7d") ? QStringLiteral("0%") : QStringLiteral("100%")) : detail;
      if (labelled || !detail.isEmpty()) {
        QCOMPARE(value->property("text").toString(), expected_value);
      }
      QVERIFY(label->property("emphasized").toBool());
      QCOMPARE(label->property("color").value<QColor>(), themeColors(Configuration{}).value(QStringLiteral("subtext0")).value<QColor>());
      constexpr qreal track_width = 24;
      constexpr qreal track_height = 3;
      constexpr qreal part_gap = 5;
      const auto label_gap = labelled ? part_gap * ratio : 0;
      QCOMPARE(track->isVisible(), !compact);
      QCOMPARE(track->width(), compact ? qreal{0} : track_width * ratio);
      QCOMPARE(track->height(), track_height * ratio);
      QTRY_COMPARE_WITH_TIMEOUT(track->x(), label->width() + label_gap, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(value->x(), label->width() + label_gap + (compact ? 0 : (track_width + part_gap) * ratio), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(meter->width(), value->x() + value->width(), wait_ms);
      QVERIFY(meter->boundingRect().contains(value->mapRectToItem(meter, value->boundingRect())));
      if (!compact) {
        QVERIFY(meter->boundingRect().contains(track->mapRectToItem(meter, track->boundingRect())));
      }
    }
  }

  Q_SLOT static void sparklinesOnlyShowTheLatestNineSamples() {
    QQuickWindow window;
    QQmlEngine engine;
    BarContent content;
    std::array<std::uint8_t, 60> samples{};
    samples.back() = 100;
    components::Input input{};
    input.node.kind = components::Kind::sparkline;
    input.samples = samples;
    content.append(input);
    const auto tree = createChrome(engine, QStringLiteral("ComponentTree"), treeProperties(content));
    tree->setParentItem(window.contentItem());
    window.resize(1000, bar_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(tree->implicitWidth(), qreal{26}, wait_ms);
    const auto columns = visualItems(*tree, QStringLiteral("componentSparklineSample"));
    QCOMPARE(columns.size(), 9);
    int full_samples = 0;
    for (const auto *column : columns) {
      full_samples += column->property("modelData").toInt() == 100;
    }
    QCOMPARE(full_samples, 1);
  }

  Q_SLOT static void groupsHaveAutomaticSeparators() {
    QQuickWindow window;
    QQmlEngine engine;
    BarContent content;
    appendNode(content, {.kind = components::Kind::group});
    appendNode(content, {.kind = components::Kind::label, .parent = 0}, "Clock");
    appendNode(content, {.kind = components::Kind::group});
    appendNode(content, {.kind = components::Kind::label, .parent = 2}, "GPU");
    const auto tree = createChrome(engine, QStringLiteral("ComponentTree"), treeProperties(content));
    tree->setParentItem(window.contentItem());
    window.resize(1000, bar_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto separators = [&] {
      auto items = visualItems(*tree, QStringLiteral("componentGroupSeparator"));
      items.removeIf([](const QQuickItem *item) { return !item->isVisible(); });
      return items;
    };
    QTRY_COMPARE_WITH_TIMEOUT(separators().size(), 1, wait_ms);
    const QVariantMap levels{{QStringLiteral("0"), 2}, {QStringLiteral("1"), 2}};
    QVERIFY(tree->setProperty("fittedLevels", levels));
    QTRY_COMPARE_WITH_TIMEOUT(separators().size(), 0, wait_ms);
    QVERIFY(tree->setProperty("horizontal", false));
    QTRY_COMPARE_WITH_TIMEOUT(separators().size(), 0, wait_ms);
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
