#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


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
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <tuple>
#include <compare>
#include "qml_fixture.hpp"
#include "../qt/activity_projection.hpp"
#include "../qt/agent_projection.hpp"
#include "../qt/agent_status_value.hpp"
#include "../qt/list_model.hpp"
#include "../qt/native_agent_status.hpp"
#include "../qt/projection.hpp"
#include "../qt/sidebar_projection.hpp"
#include "../qt/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QDebug>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QMetaMethod>
#include <QObject>
#include <QPoint>
#include <QPointF>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QSignalSpy>
#include <QString>
#include <QTimer>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>

#include "core/memory.hpp"
#include "qt/activity_projection.hpp"
#include "qt/agent_projection.hpp"
#include "qt/agent_status_value.hpp"
#include "qt/list_model.hpp"
#include "qt/native_agent_status.hpp"
#include "qt/projection.hpp"
#include "qt/sidebar_projection.hpp"
#include "qt/bundled_fonts.hpp"

import telar.gui.tests.activity_fixture;
import telar.gui.tests.agent_fixture;
import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.platform.profile_file;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int window_width = 400;
constexpr int window_height = 224;
constexpr auto second = StatusAgeInterval::nanoseconds_per_second;
constexpr std::uint32_t diff_added = 12;
constexpr std::uint64_t almost_a_minute = (59 * second) + (second / 2);

QVariantMap properties(const QVariantMap &record) {
  const ChromeMetrics chrome;

  return {
      {QStringLiteral("record"), record},
      {QStringLiteral("geometry"), agentCardGeometryRecord({.chrome = chrome}, window_width)},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}}},
  };
}

void show(QQuickWindow &window) {
  window.resize(window_width, window_height);
  window.setMinimumSize(window.size());
  window.setMaximumSize(window.size());
  window.show();
}

class TaskCardTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void fullTaskShowsFactsPlanAndFinalAnswer() {
    SystemAllocator memory;
    Agent agent{memory};
    Worktree task{memory};
    agent.pane_id = 2;
    agent.pane_generation = 1;
    agent.status = AgentStatus::working;
    agent.plan_done = 2;
    agent.plan_total = 4;
    agent.plan_step = "Compile the changes";
    task.branch = "worktree-fix";
    task.title = "Fix the task";
    task.diff_added = diff_added;
    task.diff_removed = 3;
    task.diff_files = 2;
    task.command_state = CommandState::exited;
    task.command_label = "test";
    QQuickWindow window;
    QQmlEngine engine;
    auto record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true, .depth = 1}, false);
    auto card = createChrome(engine, QStringLiteral("TaskCard"), properties(record));
    card->setParentItem(window.contentItem());
    card->setSize({window_width, card->implicitHeight()});
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*card, QStringLiteral("taskTitle")).size(), 1, wait_ms);
    QCOMPARE(visualItems(*card, QStringLiteral("taskFacts")).front()->property("text").toString(), QStringLiteral("host · \u2387 fix  +12 \u22123 · 2  \u2713 test"));
    QCOMPARE(visualItems(*card, QStringLiteral("taskTitle")).front()->property("text").toString(), QStringLiteral("Fix the task"));
    QVERIFY(visualItems(*card, QStringLiteral("taskTitle")).front()->property("emphasized").toBool());
    QCOMPARE(visualItems(*card, QStringLiteral("taskActivity")).front()->property("text").toString(), QStringLiteral("Compile the changes"));
    QCOMPARE(visualItems(*card, QStringLiteral("taskPlanCell")).size(), agent.plan_total);
    QCOMPARE(visualItems(*card, QStringLiteral("taskPlanCount")).front()->property("text").toString(), QStringLiteral("2/4"));
    QVERIFY(visualItems(*card, QStringLiteral("activityTreeGuide")).front()->isVisible());
    const auto plan_image = window.grabWindow();
    QVERIFY(!plan_image.isNull());
    const auto scale = static_cast<qreal>(plan_image.width()) / window.width();
    for (const auto *cell : visualItems(*card, QStringLiteral("taskPlanCell"))) {
      const auto center = cell->mapToScene(QPointF{cell->width() / 2, cell->height() / 2});
      const auto pixel = QPointF{center.x() * scale, center.y() * scale}.toPoint();
      QCOMPARE(plan_image.pixelColor(pixel), cell->property("color").value<QColor>());
    }
    const auto selection = card->metaObject()->method(card->metaObject()->indexOfSignal("selected(QString)"));
    const QSignalSpy selected{card.get(), selection};
    constexpr QPoint title_point{200, 34};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, title_point);
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, wait_ms);
    QCOMPARE(selected.front().front().toString(), QStringLiteral("2"));
    agent.status = AgentStatus::done;
    agent.final_message = "\n \t\n Final answer\t\nmore";
    record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true}, false);
    QVERIFY(card->setProperty("record", record));
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*card, QStringLiteral("taskActivity")).front()->property("text").toString(), QStringLiteral("Final answer"), wait_ms);
    QVERIFY(!visualItems(*card, QStringLiteral("taskPlan")).front()->isVisible());
    QVERIFY(!visualItems(*card, QStringLiteral("activityTreeGuide")).front()->isVisible());
    const auto image = window.grabWindow();
    QVERIFY(!image.isNull());
    qInfo() << "Task card scene graph API:" << static_cast<int>(window.rendererInterface()->graphicsApi());
  }

  Q_SLOT static void compactClockChangesModeAndCatchesUp() {
    SystemAllocator memory;
    Agent agent{memory};
    Worktree task{memory};
    agent.status = AgentStatus::unknown;
    task.branch = "worktree/fix";
    task.title = "Compact task";
    auto record = taskRecord(agent, task, {.machine = "host", .branch = {}}, true);
    record.insert(QStringLiteral("statusClock"), statusAgeValue({.age_ns = almost_a_minute, .sampled_ns = platform::AwakeClock::nowNanoseconds()}));
    QQuickWindow window;
    QQmlEngine engine;
    auto card = createChrome(engine, QStringLiteral("TaskCard"), properties(record));
    card->setParentItem(window.contentItem());
    card->setSize({window_width, card->implicitHeight()});
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*card, QStringLiteral("taskCompactTitle")).size(), 1, wait_ms);
    const auto old_clock = QPointer{qobject_cast<NativeAgentStatus *>(visualItems(*card, QStringLiteral("agentStatus")).front())};
    QVERIFY(old_clock);
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(timers.front()->isActive(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*card, QStringLiteral("taskCompactStatus")).front()->property("text").toString(), QStringLiteral("host · 1m"), wait_ms);
    record.insert(QStringLiteral("compact"), false);
    QVERIFY(card->setProperty("record", record));
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*card, QStringLiteral("taskTitle")).size(), 1, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(old_clock.isNull(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void trackedCommandsKeepTheirOutcomeAndNavigationIdentity() {
    SystemAllocator memory;
    Worktree task{memory};
    task.id = command_worktree_id;
    task.workspace = 2;
    task.branch = "worktree-fix";
    task.title = "Check the task";
    task.command_label = "test";
    task.command_state = CommandState::exited;
    task.command_exit = 1;
    const auto record = commandRecord(task, {.machine = "host", .branch = {}});
    QCOMPARE(record.value(QStringLiteral("key")).toString(), QStringLiteral("command:11"));
    QCOMPARE(record.value(QStringLiteral("facts")).toString(), QStringLiteral("host · fix · failed"));
    QQuickWindow window;
    QQmlEngine engine;
    auto card = createChrome(engine, QStringLiteral("CommandCard"), properties(record));
    card->setParentItem(window.contentItem());
    card->setSize({window_width, card->implicitHeight()});
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QCOMPARE(visualItems(*card, QStringLiteral("commandLabel")).front()->property("text").toString(), QStringLiteral("test"));
    QCOMPARE(visualItems(*card, QStringLiteral("commandTitle")).front()->property("text").toString(), QStringLiteral("Check the task"));
    QVERIFY(!visualItems(*card, QStringLiteral("commandTitle")).front()->property("emphasized").toBool());
    const auto selection = card->metaObject()->method(card->metaObject()->indexOfSignal("selected(QString)"));
    const QSignalSpy selected{card.get(), selection};
    constexpr QPoint title_point{200, 34};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, title_point);
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, wait_ms);
    QCOMPARE(selected.front().front().toString(), record.value(QStringLiteral("key")).toString());
    const auto offline = commandRecord(task, {.machine = "host", .branch = {}, .connected = false});
    QVERIFY(card->setProperty("record", offline));
    QVERIFY(!card->isEnabled());
    QCOMPARE(visualItems(*card, QStringLiteral("commandFacts")).front()->property("text").toString(), QStringLiteral("host · fix · offline · last known"));
  }

  Q_SLOT static void orderedActivityProjectsVariableCardsIntoTheList() {
    SystemAllocator memory;
    WorkspaceReplica workspaces{memory};
    AgentReplica agents{memory};
    const std::array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
    std::array tasks{worktreeEntry(), worktreeEntry()};
    tasks.back().worktree = command_worktree_id;
    tasks.back().workspace.reset();
    tasks.back().command_state = CommandState::running;
    QVERIFY(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}));
    std::array reports{agentSnapshotEntry(), agentSnapshotEntry()};
    reports.back().pane_id = 2;
    reports.back().work_tree = task_worktree_id;
    QVERIFY(agents.apply({.revision = 1, .entries = reports}, platform::AwakeClock::nowNanoseconds()));
    using Order = ActivityOrder<SystemAllocator>;
    const std::array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
    Order::Plan plan;
    Order::write(sources, 0, plan);
    ListModel model;
    QList<QVariantMap> records;
    for (const auto &entry : plan.view()) {
      const AgentRecordContext context{.machine = "host", .branch = {}, .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};
      if (entry.agent) {
        const auto &agent = agents.entries()[*entry.agent];
        records.append(entry.worktree ? taskRecord(agent, workspaces.worktrees()[*entry.worktree], context, entry.card == ActivityCard::task_compact) : agentRecord(agent, context));
      } else if (entry.worktree) {
        records.append(commandRecord(workspaces.worktrees()[*entry.worktree], context));
      }
    }

    model.reconcile(records);
    auto settings = properties({});
    settings.remove(QStringLiteral("record"));
    settings.insert(QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&model)));
    QQuickWindow window;
    QQmlEngine engine;
    auto list = createChrome(engine, QStringLiteral("ActivityList"), settings);
    list->setParentItem(window.contentItem());
    list->setSize({window_width, window_height});
    show(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("agentCard")).size(), 1, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("taskCard")).size(), 1, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("commandCard")).size(), 1, wait_ms);
    const auto geometry = settings.value(QStringLiteral("geometry")).toMap();
    auto *const task = visualItems(*list, QStringLiteral("taskCard")).front();
    QCOMPARE(task->height(), geometry.value(QStringLiteral("compactHeight")).toReal());
    QCOMPARE(task->mapToItem(list.get(), QPointF{}).x(), geometry.value(QStringLiteral("taskIndent")).toReal());
    const auto *title = visualItems(*task, QStringLiteral("taskCompactTitle")).front();
    QVERIFY(title->width() < task->width());
    QVERIFY(agentRecord(agents.entries().front(), {.machine = {}, .branch = {}, .coordinator = true}).value(QStringLiteral("project")).toString().endsWith(QStringLiteral(" · coordinator")));
    QVERIFY(!window.grabWindow().isNull());
  }
};

}

QTEST_MAIN(TaskCardTest)
#include "task_card_test.moc"
