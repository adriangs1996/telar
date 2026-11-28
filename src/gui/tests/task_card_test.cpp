#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "qml_fixture.hpp"
#include "ui/app/chrome/activity/activity_projection.hpp"
#include "ui/app/chrome/activity/agent_projection.hpp"
#include "ui/app/chrome/sidebar_projection.hpp"
#include "ui/kit/fonts/bundled_fonts.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/models/projection.hpp"
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
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

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

    // What the cards read about where a pane works and what its shell ran: an agent's tab and
    // directory with its workspace's repository, and a process's command with how it ended and
    // the repository of its own directory.
    Q_SLOT static void recordsSayWhereAPaneWorksAndWhatItRan() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
      Agent agent{memory};

      agent.pane_id = 2;
      agent.pane_generation = 1;
      agent.status = AgentStatus::ready;
      agent.tab_label.assign("server");
      agent.cwd_label.assign("~/sandbox/telar");
      const auto resting = agentRecord(agent, {.machine = {}, .branch = "main", .dirty = true});

      QCOMPARE(resting.value(QStringLiteral("tab")).toString(), QStringLiteral("server"));
      QCOMPARE(resting.value(QStringLiteral("cwd")).toString(), QStringLiteral("~/sandbox/telar"));
      QCOMPARE(resting.value(QStringLiteral("branch")).toString(), QStringLiteral("main"));
      QVERIFY(resting.value(QStringLiteral("dirty")).toBool());
      agent.status = AgentStatus::working;
      QCOMPARE(agentRecord(agent, {.machine = {}, .branch = "main"}).value(QStringLiteral("branch")).toString(), QStringLiteral("main"));
      QVERIFY(!agentRecord(agent, {.machine = {}, .branch = {}, .dirty = true}).value(QStringLiteral("dirty")).toBool());

      // A shell that ran nothing, out of its workspace: no command and no repository.
      ListedPane pane;
      const AgentRecordContext workspace{.machine = {}, .branch = "main", .dirty = true};

      pane.pane_id = 3;
      pane.pane_generation = 1;
      pane.foreground.assign("zsh");
      pane.shell = true;
      auto record = processRecord(pane, "telar", workspace);

      QCOMPARE(record.value(QStringLiteral("commandState")).toString(), QStringLiteral("none"));
      QVERIFY(record.value(QStringLiteral("commandLine")).toString().isEmpty());
      QVERIFY(!record.value(QStringLiteral("exitCode")).isValid());
      QVERIFY(record.value(QStringLiteral("commandDuration")).toString().isEmpty());
      QVERIFY(record.value(QStringLiteral("cwd")).toString().isEmpty());
      QVERIFY(record.value(QStringLiteral("branch")).toString().isEmpty());
      QVERIFY(!record.value(QStringLiteral("dirty")).toBool());
      QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("zsh"));

      // Its last command failed, in a repository its shell read.
      pane.facts.command_state = PaneCommandState::finished;
      pane.facts.command.assign("just gui-case sidebar");
      pane.facts.exit_code = 1;
      pane.facts.duration_ms = 12'400;
      pane.facts.directory.assign("~/sandbox/telar");
      pane.facts.branch.assign("feature");
      record = processRecord(pane, "telar", workspace);
      QCOMPARE(record.value(QStringLiteral("commandState")).toString(), QStringLiteral("finished"));
      QCOMPARE(record.value(QStringLiteral("commandLine")).toString(), QStringLiteral("just gui-case sidebar"));
      QCOMPARE(record.value(QStringLiteral("exitCode")).toInt(), 1);
      QCOMPARE(record.value(QStringLiteral("commandDuration")).toString(), QStringLiteral("12s"));
      QCOMPARE(record.value(QStringLiteral("cwd")).toString(), QStringLiteral("~/sandbox/telar"));
      QCOMPARE(record.value(QStringLiteral("branch")).toString(), QStringLiteral("feature"));
      QVERIFY(!record.value(QStringLiteral("dirty")).toBool());
      QVERIFY(!record.value(QStringLiteral("commandTruncated")).toBool());

      // A prompt interrupted it: it ended without a status.
      pane.facts.exit_code.reset();
      pane.facts.duration_ms = 185'000;
      pane.facts.dirty = true;
      record = processRecord(pane, "telar", workspace);
      QVERIFY(!record.value(QStringLiteral("exitCode")).isValid());
      QCOMPARE(record.value(QStringLiteral("commandDuration")).toString(), QStringLiteral("3m"));
      QVERIFY(record.value(QStringLiteral("dirty")).toBool());

      // A command that runs has no status and no duration yet.
      pane.facts.command_state = PaneCommandState::running;
      pane.facts.command.assign("npm run dev");
      pane.facts.command_truncated = true;
      pane.facts.duration_ms = 0;
      record = processRecord(pane, "telar", workspace);
      QCOMPARE(record.value(QStringLiteral("commandState")).toString(), QStringLiteral("running"));
      QCOMPARE(record.value(QStringLiteral("commandLine")).toString(), QStringLiteral("npm run dev"));
      QVERIFY(record.value(QStringLiteral("commandTruncated")).toBool());
      QVERIFY(!record.value(QStringLiteral("exitCode")).isValid());
      QVERIFY(record.value(QStringLiteral("commandDuration")).toString().isEmpty());

      // A pane whose shell read no repository takes its workspace's, when it works there.
      pane.facts.branch.assign(std::string_view{});
      pane.facts.dirty = false;
      QVERIFY(processRecord(pane, "telar", workspace).value(QStringLiteral("branch")).toString().isEmpty());
      pane.facts.in_workspace = true;
      record = processRecord(pane, "telar", workspace);
      QCOMPARE(record.value(QStringLiteral("branch")).toString(), QStringLiteral("main"));
      QVERIFY(record.value(QStringLiteral("dirty")).toBool());
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
      agent.plan_step.assign("Compile the changes");
      task.branch.assign("worktree-fix");
      task.title.assign("Fix the task");
      task.diff_added = diff_added;
      task.diff_removed = 3;
      task.diff_files = 2;
      task.commits_ahead = 1;
      task.command_state = CommandState::exited;
      task.command_label.assign("test");
      QQuickWindow window;
      QQmlEngine engine;
      auto record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true});
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
      const auto selection = card->metaObject()->method(card->metaObject()->indexOfSignal("selected(QString)"));
      const QSignalSpy selected{card.get(), selection};
      constexpr QPoint title_point{200, 34};

      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, title_point);
      QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, wait_ms);
      QCOMPARE(selected.front().front().toString(), QStringLiteral("2"));
      agent.status = AgentStatus::done;
      agent.final_message.assign("\n \t\n Final answer\t\nmore");
      record = taskRecord(agent, task, {.machine = "host", .branch = {}, .selected = true});
      QVERIFY(card->setProperty("record", record));
      QTRY_COMPARE_WITH_TIMEOUT(text(*card, QStringLiteral("agentSignal")), QStringLiteral("Final answer"), wait_ms);
      QVERIFY(!visualItems(*card, QStringLiteral("agentPlanBar")).front()->isVisible());
      QVERIFY(!visualItems(*card, QStringLiteral("agentPlanCount")).front()->isVisible());
      task.title.clear();
      record = taskRecord(agent, task, {.machine = {}, .branch = {}});
      // A task named after its branch does not repeat it.
      QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("worktree-fix"));
      QVERIFY(record.value(QStringLiteral("taskBranch")).toString().isEmpty());
      task.diff_files = 0;
      task.commits_ahead = 0;
      task.command_state = CommandState::none;
      agent.workspace_label.assign("project");
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
      agent.detail.assign("Reading the cards");
      task.branch.assign("worktree/fix");
      task.title.assign("Shape");
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
      agent.detail.assign("Keep the old snapshots?");
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
      agent.detail.assign("Running the build");
      task.branch.assign("worktree-arch/build");
      task.title.assign("Build architecture");
      task.diff_added = diff_added;
      task.diff_removed = 3;
      task.diff_files = 2;
      task.commits_ahead = 1;
      task.command_state = CommandState::exited;
      task.command_label.assign("test");
      QQuickWindow window;
      QQmlEngine engine;
      auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(taskRecord(agent, task, {.machine = "host", .branch = {}})));
      constexpr qreal wide = 1000;
      // The facts have the third row to themselves, so they give way on a narrower card.
      constexpr qreal narrow = 130;
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

      // What happens keeps its own row, above where it happens.
      QVERIFY(signal->mapToItem(card.get(), QPointF{0, signal->height()}).y() <= context->mapToItem(card.get(), QPointF{}).y());
      QCOMPARE(signal->mapToItem(card.get(), QPointF{}).x(), context->mapToItem(card.get(), QPointF{}).x());
    }

    Q_SLOT static void trackedCommandsKeepTheirOutcomeAndNavigationIdentity() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::ConcurrentMemory& memory = adapter;
      Worktree task{memory};

      task.id = command_worktree_id;
      task.workspace = 2;
      task.branch.assign("worktree-fix");
      task.title.assign("Check the task");
      task.command_label.assign("test");
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
      const ds::Array projects{WorkspaceListEntry{.workspace = 1, .name = "project", .path = "/project"}};
      ds::Array tasks{worktreeEntry(), worktreeEntry()};

      tasks.atMut(tasks.size() - 1).worktree = command_worktree_id;
      tasks.atMut(tasks.size() - 1).workspace.reset();
      tasks.atMut(tasks.size() - 1).command_state = CommandState::running;
      QVERIFY(workspaces.apply({.revision = 1, .entries = projects, .worktrees = tasks}));
      ds::Array reports{agentSnapshotEntry(), agentSnapshotEntry()};

      reports.atMut(reports.size() - 1).pane_id = 2;
      reports.atMut(reports.size() - 1).work_tree = task_worktree_id;
      QVERIFY(agents.apply({.revision = 1, .entries = reports}, system::AwakeClock::nowNanoseconds()));
      using Order = ActivityOrder<telar::ConcurrentMemory>;
      const ds::Array sources{Order::Source{.agents = agents.entries(), .workspaces = workspaces}};
      Order::Plan plan;

      Order::write(sources, 0, plan);
      ListModel model;
      QList<QVariantMap> records;

      for (const auto& entry : plan.view()) {
        const AgentRecordContext context{.machine = "host", .branch = {}, .coordinator = entry.coordinator};

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
      // The inbox is flat: a task starts on the agents' edge.
      QCOMPARE(task->mapToItem(list.get(), QPointF{}).x(), 0.0);
      const auto* title = visualItems(*task, QStringLiteral("agentTitleLabel")).front();

      QVERIFY(title->width() < task->width());
      QVERIFY(agentRecord(agents.entries().front(), {.machine = {}, .branch = {}, .coordinator = true}).value(QStringLiteral("project")).toString().endsWith(QStringLiteral(" · coordinator")));
      QVERIFY(!window.grabWindow().isNull());
    }
  };

}

QTEST_MAIN(TaskCardTest)
#include "task_card_test.moc"
