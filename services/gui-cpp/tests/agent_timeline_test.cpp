#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "agent_fixture.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdint>
#include "../core/memory.hpp"
#include <algorithm>
#include <limits>
#include "../core/terminal_size.hpp"
#include <atomic>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "../terminal/screen.hpp"
#include <string_view>
#include <stdexcept>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <charconv>
#include <cstring>
#include <system_error>
#include "qml_fixture.hpp"
#include "../qt/agent_projection.hpp"
#include "../qt/agent_status_value.hpp"
#include "../qt/list_model.hpp"
#include "../qt/native_agent_status.hpp"
#include "../qt/projection.hpp"
#include "../qt/sidebar_projection.hpp"
#include "../qt/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QDebug>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QList>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRect>
#include <QRectF>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QSignalSpy>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <memory>
#include <thread>

#include "core/memory.hpp"
#include "qt/agent_projection.hpp"
#include "qt/agent_status_value.hpp"
#include "qt/list_model.hpp"
#include "qt/native_agent_status.hpp"
#include "qt/projection.hpp"
#include "qt/sidebar_projection.hpp"
#include "qt/bundled_fonts.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.platform.profile_file;
import telar.gui.presentation.suggestion_labels;
import telar.gui.presentation.application_mark;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;
using telar::AgentStatus;

constexpr int wait_ms = 5000;
constexpr int window_width = 400;
constexpr int window_height = 64;
constexpr auto second = StatusAgeInterval::nanoseconds_per_second;

QVariantMap workingRecord() {
  SystemAllocator memory;
  Agent agent{memory};
  agent.pane_id = 1;
  agent.pane_generation = 1;
  agent.status = AgentStatus::working;

  return agentRecord(agent, {});
}

void show(QQuickWindow &window) {
  window.resize(window_width, window_height);
  window.setMinimumSize(window.size());
  window.setMaximumSize(window.size());
  window.show();
}

class AgentTimelineTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void opaqueIntervalSurvivesQmlWithoutNumericCoercion() {
    QQmlEngine engine;
    const ChromeMetrics chrome;
    auto record = workingRecord();
    constexpr StatusAgeInterval interval{.age_ns = 3 * second, .sampled_ns = 18'000'000'000'000'000'001ULL};
    record.insert(QStringLiteral("statusClock"), statusAgeValue(interval));
    const QVariantMap properties{
        {QStringLiteral("record"), record},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}, {QStringLiteral("body"), chrome.body}}},
        {QStringLiteral("geometry"), agentCardGeometryRecord({.chrome = chrome}, window_width)},
        {QStringLiteral("animate"), false},
    };
    auto card = createChrome(engine, QStringLiteral("AgentCard"), properties);
    const auto statuses = visualItems(*card, QStringLiteral("agentStatus"));
    QCOMPARE(statuses.size(), 1);
    const auto *item = statuses.front();
    const auto recovered = statusAgeInterval(item->property("record").toMap().value(QStringLiteral("statusClock")));
    QVERIFY(recovered.has_value());
    QVERIFY(recovered.value_or(StatusAgeInterval{}) == interval);
    QCOMPARE(item->property("statusText").toString(), QStringLiteral("Working 3s"));
  }

  Q_SLOT static void visibleStatusesShareOneTimerAndPauseTogether() {
    QQuickWindow window;
    NativeAgentStatus first{window.contentItem()};
    NativeAgentStatus second_status{window.contentItem()};
    first.setSize({window_width, window_height});
    second_status.setSize({window_width, window_height});
    auto record = workingRecord();
    const auto started = platform::AwakeClock::nowNanoseconds();
    record.insert(QStringLiteral("statusClock"), statusAgeValue({.age_ns = 0, .sampled_ns = started}));
    first.setRecord(record);
    second_status.setRecord(record);
    const QSignalSpy pulse{&first, &NativeAgentStatus::animatedAlphaChanged};
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(timers.front()->isActive(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!pulse.isEmpty(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(first.statusText() != QStringLiteral("Working 0s"), wait_ms);
    QCOMPARE(first.statusText(), second_status.statusText());
    first.setRunning(false);
    second_status.setRunning(false);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
    const auto pulse_count = pulse.count();
    constexpr int several_pulse_steps_ms = 400;
    QTest::qWait(several_pulse_steps_ms);
    QCOMPARE(pulse.count(), pulse_count);
    first.setRunning(true);
    QTRY_VERIFY_WITH_TIMEOUT(timers.front()->isActive(), wait_ms);
    window.hide();
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void readyLabelsCatchUpWithoutAStatusTransition() {
    QQuickWindow window;
    NativeAgentStatus status{window.contentItem()};
    status.setSize({window_width, window_height});
    auto record = workingRecord();
    record.insert(QStringLiteral("statusCode"), static_cast<int>(AgentStatus::ready));
    record.insert(QStringLiteral("working"), false);
    constexpr auto near_minute = (59 * second) + (second / 2);
    record.insert(QStringLiteral("statusClock"), statusAgeValue({.age_ns = near_minute, .sampled_ns = platform::AwakeClock::nowNanoseconds()}));
    status.setRecord(record);
    QCOMPARE(status.statusText(), QStringLiteral("now"));
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(status.statusText(), QStringLiteral("1m"), wait_ms);
    QCOMPARE(status.animatedAlpha(), 1);
    record.insert(QStringLiteral("enabled"), false);
    status.setRecord(record);
    QCOMPARE(status.statusText(), QStringLiteral("offline"));
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void onlyTheGlyphPulsesAndHiddenAncestorsParkTheClock() {
    QQuickWindow window;
    window.setColor(Qt::black);
    QQmlEngine engine;
    QQuickItem host{window.contentItem()};
    host.setSize({window_width, window_height});
    auto record = workingRecord();
    constexpr StatusAgeInterval frozen{.age_ns = 3 * second, .sampled_ns = 18'000'000'000'000'000'001ULL};
    record.insert(QStringLiteral("statusClock"), statusAgeValue(frozen));
    const ChromeMetrics chrome;
    const QVariantMap properties{
        {QStringLiteral("record"), record},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}, {QStringLiteral("body"), chrome.body}}},
        {QStringLiteral("geometry"), agentCardGeometryRecord({.chrome = chrome}, window_width)},
    };
    auto status = createChrome(engine, QStringLiteral("AgentStatus"), properties);
    status->setParentItem(&host);
    status->setSize({window_width, window_height});
    const auto *timeline = qobject_cast<NativeAgentStatus *>(status.get());
    QVERIFY(timeline != nullptr);
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto labels = visualItems(*status, QStringLiteral("agentStatusLabel"));
    qInfo() << "Agent timeline scene graph API:" << window.rendererInterface()->graphicsApi();
    const auto glyphs = visualItems(*status, QStringLiteral("agentStatusGlyph"));
    QCOMPARE(labels.size(), 1);
    QCOMPARE(glyphs.size(), 1);
    const auto density = window.effectiveDevicePixelRatio();
    const auto pixels = [density](const QQuickItem &item) {
      return QRectF{item.mapToScene({0, 0}) * density, item.size() * density}.toAlignedRect();
    };
    const auto text_bounds = pixels(*labels.front());
    const auto glyph_bounds = pixels(*glyphs.front());
    QVERIFY(!text_bounds.isEmpty() && !glyph_bounds.isEmpty());
    const auto first = window.grabWindow();
    const QSignalSpy text_updates{timeline, &NativeAgentStatus::statusTextChanged};
    QImage next;
    const auto capture_next_phase = [&] {
      next = window.grabWindow();

      return first.copy(glyph_bounds) != next.copy(glyph_bounds);
    };
    QTRY_VERIFY_WITH_TIMEOUT(capture_next_phase(), wait_ms);
    QCOMPARE(first.copy(text_bounds), next.copy(text_bounds));
    QVERIFY(first.copy(glyph_bounds) != next.copy(glyph_bounds));
    QCOMPARE(text_updates.count(), 0);
    const auto *timer = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation")).front();
    host.setVisible(false);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    host.setVisible(true);
    QTRY_VERIFY_WITH_TIMEOUT(timer->isActive(), wait_ms);
  }

  Q_SLOT static void reparentingAndSignalDestructionRetireSubscriptions() {
    QQuickWindow first_window;
    QQuickWindow second_window;
    auto status = std::make_unique<NativeAgentStatus>(first_window.contentItem());
    status->setSize({window_width, window_height});
    status->setRecord(workingRecord());
    show(first_window);
    show(second_window);
    QTRY_VERIFY_WITH_TIMEOUT(first_window.isExposed() && second_window.isExposed(), wait_ms);
    const auto *first_timer = first_window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation")).front();
    status->setParentItem(second_window.contentItem());
    QTRY_VERIFY_WITH_TIMEOUT(!first_timer->isActive(), wait_ms);
    const auto second_timers = second_window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(second_timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(second_timers.front()->isActive(), wait_ms);
    const QPointer<NativeAgentStatus> alive{status.get()};
    QObject::connect(status.get(), &NativeAgentStatus::statusTextChanged, &second_window, [&status] {
      status.reset();
    });
    auto record = workingRecord();
    record.insert(QStringLiteral("enabled"), false);
    status->setRecord(record);
    QVERIFY(alive.isNull());
    QTRY_VERIFY_WITH_TIMEOUT(!second_timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void activityModelPreservesElapsedAgeAcrossRevisions() {
    SystemAllocator memory;
    AgentReplica replica{memory};
    constexpr auto elapsed_before_mount = 3 * second;
    constexpr std::uint32_t reported_age = 58;
    QTRY_VERIFY_WITH_TIMEOUT(platform::AwakeClock::nowNanoseconds() >= elapsed_before_mount, wait_ms);
    std::array entries{agentSnapshotEntry(reported_age)};
    QVERIFY(replica.apply({.revision = 1, .entries = entries}, platform::AwakeClock::nowNanoseconds() - elapsed_before_mount));
    ListModel model;
    const auto publish = [&] {
      model.reconcile(QList<QVariantMap>{agentRecord(replica.entries().front(), {})});
    };
    publish();
    QQuickWindow window;
    QQmlEngine engine;
    const ChromeMetrics chrome;
    const QVariantMap properties{
        {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&model))},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}, {QStringLiteral("body"), chrome.body}}},
        {QStringLiteral("geometry"), agentCardGeometryRecord({.chrome = chrome}, window_width)},
    };
    auto list = createChrome(engine, QStringLiteral("ActivityList"), properties);
    list->setParentItem(window.contentItem());
    list->setSize({window_width, window_height});
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("agentStatus")).size(), 1, wait_ms);
    const auto *status = qobject_cast<NativeAgentStatus *>(visualItems(*list, QStringLiteral("agentStatus")).front());
    QVERIFY(status != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(status->statusText(), QStringLiteral("Working 1m"), wait_ms);
    QVERIFY(replica.apply({.revision = 2, .entries = entries}, platform::AwakeClock::nowNanoseconds()));
    const auto expected_interval = replica.entries().front().status_clock.interval();
    QStringList published_text;
    const QObject monitor;
    QObject::connect(status, &NativeAgentStatus::statusTextChanged, &monitor, [status, &published_text] {
      published_text.append(status->statusText());
    });
    publish();
    QTRY_VERIFY_WITH_TIMEOUT(statusAgeInterval(status->record().value(QStringLiteral("statusClock"))).value_or(StatusAgeInterval{}) == expected_interval, wait_ms);
    QCOMPARE(status->statusText(), QStringLiteral("Working 1m"));
    QVERIFY(!published_text.contains(QStringLiteral("Working 58s")));
    QVERIFY(!published_text.contains(QStringLiteral("Working 59s")));
    entries.front().status = AgentStatus::ready;
    entries.front().status_age_s = 0;
    QVERIFY(replica.apply({.revision = 3, .entries = entries}, platform::AwakeClock::nowNanoseconds()));
    publish();
    QTRY_COMPARE_WITH_TIMEOUT(status->statusText(), QStringLiteral("now"), wait_ms);
    QCOMPARE(status->animatedAlpha(), 1);
  }

  Q_SLOT static void frameSamplingKeepsWorkingGlyphsInPhase() {
    QQuickWindow window;
    NativeAgentStatus first{window.contentItem()};
    NativeAgentStatus second_status{window.contentItem()};
    first.setSize({window_width, window_height});
    second_status.setSize({window_width, window_height});
    first.setRecord(workingRecord());
    second_status.setRecord(workingRecord());
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QVERIFY(!window.grabWindow().isNull());
    const auto previous_alpha = first.animatedAlpha();
    constexpr unsigned maximum_steps = 6;
    const std::chrono::nanoseconds step{static_cast<std::int64_t>(AgentAnimation::pulse_interval_ns)};
    for (unsigned index = 0; index < maximum_steps && AgentAnimation::alpha(platform::AwakeClock::nowNanoseconds()) == previous_alpha; ++index) {
      std::this_thread::sleep_for(step);
    }

    auto changed = workingRecord();
    changed.insert(QStringLiteral("age"), 1);
    second_status.setRecord(changed);
    QVERIFY(first.animatedAlpha() != second_status.animatedAlpha());
    window.afterAnimating();
    QCOMPARE(first.animatedAlpha(), second_status.animatedAlpha());
  }
};

}

QTEST_MAIN(AgentTimelineTest)
#include "agent_timeline_test.moc"
