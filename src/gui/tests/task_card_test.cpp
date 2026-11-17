#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "qml_fixture.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/chrome/activity/activity_projection.hpp"
#include "ui/app/chrome/activity/agent_projection.hpp"
#include "ui/app/chrome/sidebar_projection.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/models/list_model.hpp"
#include "ui/foundation/models/projection.hpp"
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
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

import telar.gui.tests.activity_fixture;
import telar.gui.tests.agent_fixture;
import telar.gui.application;
import telar.gui.foundation.system;
import telar.gui.features.activity;
import telar.gui.features.workbench;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::activity;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int window_width = 400;
  constexpr int window_height = 224;
  constexpr std::uint32_t diff_added = 12;

  QVariantMap properties(const QVariantMap& record) {
    const ChromeMetrics chrome;

    return {
        {QStringLiteral("record"), record},
        {QStringLiteral("geometry"), agentCardGeometryRecord({.chrome = chrome}, window_width)},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}}},
    };
  }

  QString text(QQuickItem& root, const QString& name) {
    return visualItems(root, name).front()->property("text").toString();
  }

  void show(QQuickWindow& window) {
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

    Q_SLOT static void taskCardShowsFactsPlanAndFinalAnswer() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
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
      task.commits_ahead = 1;
      task.command_state = CommandState::exited;
      task.command_label = "test";
      QQuickWindow window;
      QQmlEngine engine;
      auto record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true, .depth = 1});
      auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(record));

      card->setParentItem(window.contentItem());
      card->setSize({window_width, card->implicitHeight()});
      show(window);
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      QCOMPARE(text(*card, QStringLiteral("agentTitleLabel")), QStringLiteral("Fix the task"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsMachine")), QStringLiteral("host"));
      QCOMPARE(visualItems(*card, QStringLiteral("agentFactsBranchIcon")).front()->property("symbol").toString(), QStringLiteral("git-branch"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsBranchLabel")), QStringLiteral("fix"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsAdded")), QStringLiteral("+12"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsRemoved")), QStringLiteral("\u22123"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsFiles")), QStringLiteral("· 2"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsAhead")), QStringLiteral("\u21911"));
      QCOMPARE(text(*card, QStringLiteral("agentFactsCommand")), QStringLiteral("\u2713 test"));
      QCOMPARE(text(*card, QStringLiteral("agentSignal")), QStringLiteral("Compile the changes"));
      QCOMPARE(text(*card, QStringLiteral("agentPlanCount")), QStringLiteral("2/4"));
      QVERIFY(visualItems(*card, QStringLiteral("agentPlanBar")).front()->isVisible());
      const auto* bar = visualItems(*card, QStringLiteral("agentPlanBar")).front();

      QCOMPARE(visualItems(*card, QStringLiteral("agentPlanProgress")).front()->width(), bar->width() / 2);
      QVERIFY(visualItems(*card, QStringLiteral("activityTreeGuide")).front()->isVisible());
      const auto selection = card->metaObject()->method(card->metaObject()->indexOfSignal("selected(QString)"));
      const QSignalSpy selected{card.get(), selection};
      constexpr QPoint title_point{200, 34};

      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, title_point);
      QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, wait_ms);
      QCOMPARE(selected.front().front().toString(), QStringLiteral("2"));
      agent.status = AgentStatus::done;
      agent.final_message = "\n \t\n Final answer\t\nmore";
      record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true});
      QVERIFY(card->setProperty("record", record));
      QTRY_COMPARE_WITH_TIMEOUT(text(*card, QStringLiteral("agentSignal")), QStringLiteral("Final answer"), wait_ms);
      QVERIFY(!visualItems(*card, QStringLiteral("agentPlanBar")).front()->isVisible());
      QVERIFY(!visualItems(*card, QStringLiteral("agentPlanCount")).front()->isVisible());
      QVERIFY(!visualItems(*card, QStringLiteral("activityTreeGuide")).front()->isVisible());
      task.title.clear();
      record = taskRecord(agent, task, {.machine = {}, .branch = {}});
      // A task named after its branch does not repeat it.
      QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("worktree-fix"));
      QVERIFY(record.value(QStringLiteral("taskBranch")).toString().isEmpty());
      task.diff_files = 0;
      task.commits_ahead = 0;
      task.command_state = CommandState::none;
      agent.workspace_label = "project";
      QVERIFY(card->setProperty("record", taskRecord(agent, task, {.machine = {}, .branch = {}})));
      // With nothing to tell, the worktree's card names its project.
      QTRY_VERIFY_WITH_TIMEOUT(visualItems(*card, QStringLiteral("agentProjectLabel")).front()->isVisible(), wait_ms);
      QVERIFY(!visualItems(*card, QStringLiteral("agentFacts")).front()->isVisible());
      QCOMPARE(text(*card, QStringLiteral("agentProjectLabel")), QStringLiteral("project"));
      QVERIFY(!window.grabWindow().isNull());
    }

    Q_SLOT static void taskCardKeepsItsShapeWhileFocusAndStateChange() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
      Agent agent{memory};
      Worktree task{memory};

      agent.status = AgentStatus::working;
      agent.detail = "Reading the cards";
      task.branch = "worktree/fix";
      task.title = "Shape";
      QQuickWindow window;
      QQmlEngine engine;
      const auto settings = properties(taskRecord(agent, task, {.machine = {}, .branch = {}}));
      auto card = createChrome(engine, QStringLiteral("AgentCard"), settings);

      card->setParentItem(window.contentItem());
      show(window);
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto height = settings.value(QStringLiteral("geometry")).toMap().value(QStringLiteral("agentHeight")).toReal();
      const auto* attention = visualItems(*card, QStringLiteral("agentCardAttention")).front();

      QCOMPARE(card->implicitHeight(), height);
      QVERIFY(!attention->isVisible());
      QCOMPARE(text(*card, QStringLiteral("agentSignal")), QStringLiteral("Reading the cards"));
      agent.status = AgentStatus::blocked;
      agent.blocked_reason = AgentBlockedReason::question;
      agent.detail = "Keep the old snapshots?";
      QVERIFY(card->setProperty("record", taskRecord(agent, task, {.machine = {}, .branch = {}, .selected = true})));
      QTRY_VERIFY_WITH_TIMEOUT(attention->isVisible(), wait_ms);
      QCOMPARE(card->implicitHeight(), height);
      QCOMPARE(text(*card, QStringLiteral("agentSignal")), QStringLiteral("Keep the old snapshots?"));
      QVERIFY(!visualItems(*card, QStringLiteral("agentCardOutline")).front()->isVisible());
      agent.status = AgentStatus::working;
      QVERIFY(card->setProperty("record", taskRecord(agent, task, {.machine = {}, .branch = {}, .selected = true})));
      QTRY_VERIFY_WITH_TIMEOUT(!attention->isVisible(), wait_ms);
      QCOMPARE(card->implicitHeight(), height);
      QVERIFY(visualItems(*card, QStringLiteral("agentCardOutline")).front()->isVisible());
    }

    Q_SLOT static void taskFactsGiveWayWhileTheRowRunsShort() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
      Agent agent{memory};
      Worktree task{memory};

      agent.status = AgentStatus::working;
      agent.detail = "Running the build";
      task.branch = "worktree-arch/build";
      task.title = "Build architecture";
      task.diff_added = diff_added;
      task.diff_removed = 3;
      task.diff_files = 2;
      task.commits_ahead = 1;
      task.command_state = CommandState::exited;
      task.command_label = "test";
      QQuickWindow window;
      QQmlEngine engine;
      auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(taskRecord(agent, task, {.machine = "host", .branch = {}})));
      constexpr qreal wide = 1000;
      constexpr qreal narrow = 200;
      const auto shown = [&card](const QString& name) {
        return visualItems(*card, name).front()->isVisible();
      };

      card->setParentItem(window.contentItem());
      card->setSize({wide, card->implicitHeight()});
      show(window);
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      for (const auto* name : {"agentFactsMachine", "agentFactsBranch", "agentFactsDiff", "agentFactsFiles", "agentFactsAhead", "agentFactsCommand"}) {
        QVERIFY2(shown(QString::fromLatin1(name)), name);
      }

      card->setWidth(narrow);
      QTRY_VERIFY_WITH_TIMEOUT(!shown(QStringLiteral("agentFactsAhead")), wait_ms);
      QVERIFY(!shown(QStringLiteral("agentFactsBranch")));
      QVERIFY(!shown(QStringLiteral("agentFactsFiles")));
      QVERIFY(shown(QStringLiteral("agentFactsMachine")));
      QVERIFY(shown(QStringLiteral("agentFactsDiff")));
      const auto* context = visualItems(*card, QStringLiteral("agentContext")).front();
      const auto* signal = visualItems(*card, QStringLiteral("agentSignal")).front();

      QVERIFY(signal->mapToItem(card.get(), QPointF{signal->width(), 0}).x() <= context->mapToItem(card.get(), QPointF{}).x());
    }

    Q_SLOT static void trackedCommandsKeepTheirOutcomeAndNavigationIdentity() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
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

    Q_SLOT static void orderedActivityProjectsTasksAsAgentCards() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
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
      QVERIFY(agents.apply({.revision = 1, .entries = reports}, system::AwakeClock::nowNanoseconds()));
      using Order = ActivityOrder<telar::ConcurrentMemory>;
      const std::array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
      Order::Plan plan;

      Order::write(sources, 0, plan);
      ListModel model;
      QList<QVariantMap> records;

      for (const auto& entry : plan.view()) {
        const AgentRecordContext context{.machine = "host", .branch = {}, .coordinator = entry.coordinator, .starts_project = entry.first_in_project, .depth = entry.depth};

        if (entry.agent) {
          const auto& agent = agents.entries()[*entry.agent];

          records.append(entry.worktree ? taskRecord(agent, workspaces.worktrees()[*entry.worktree], context) : agentRecord(agent, context));
        } else if (entry.worktree) {
          records.append(commandRecord(workspaces.worktrees()[*entry.worktree], context));
        }
      }

      model.reconcile(records);
      auto settings = properties({});

      settings.remove(QStringLiteral("record"));
      settings.insert(QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&model)));
      QQuickWindow window;
      QQmlEngine engine;
      auto list = createChrome(engine, QStringLiteral("ActivityList"), settings);

      list->setParentItem(window.contentItem());
      list->setSize({window_width, window_height});
      show(window);
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("agentCard")).size(), 2, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*list, QStringLiteral("commandCard")).size(), 1, wait_ms);
      const auto geometry = settings.value(QStringLiteral("geometry")).toMap();
      const auto cards = visualItems(*list, QStringLiteral("agentCard"));
      const auto found = std::ranges::find_if(cards, [](const QQuickItem* card) {
        return card->property("record").toMap().value(QStringLiteral("task")).toBool();
      });

      QVERIFY(found != cards.end());
      auto* const task = *found;

      QCOMPARE(task->height(), geometry.value(QStringLiteral("agentHeight")).toReal());
      QCOMPARE(task->mapToItem(list.get(), QPointF{}).x(), geometry.value(QStringLiteral("taskIndent")).toReal());
      const auto* title = visualItems(*task, QStringLiteral("agentTitleLabel")).front();

      QVERIFY(title->width() < task->width());
      QVERIFY(agentRecord(agents.entries().front(), {.machine = {}, .branch = {}, .coordinator = true}).value(QStringLiteral("project")).toString().endsWith(QStringLiteral(" · coordinator")));
      QVERIFY(!window.grabWindow().isNull());
    }
  };

}

QTEST_MAIN(TaskCardTest)
#include "task_card_test.moc"
