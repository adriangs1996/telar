#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QObject>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QString>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <span>

import telar.gui.application;
import telar.gui.features.terminal.graphics;
import telar.gui.features.activity;
import telar.gui.features.workbench;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.gui.ui.app.panes.header;
import telar.gui.ui.app.panes;
import telar.gui.ui.design.controls;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.tests.qml_fixture;
import telar.gui.foundation.core;
import telar.gui.foundation.model;
import telar.gui.qt;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::activity;
  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int header_width = 460;
  constexpr int header_height = 30;
  constexpr int compact_header_width = 120;
  constexpr std::uint32_t working_seconds = 24 * 60 * 60;

  QVariantMap agentRecord(AgentStatus status) {
    return {
        {QStringLiteral("statusCode"), static_cast<int>(status)},
        {QStringLiteral("blockedReason"), static_cast<int>(AgentBlockedReason::permission)},
        {QStringLiteral("statusColor"), QStringLiteral("yellow")},
        {QStringLiteral("statusClock"), statusAgeValue({.age_ns = working_seconds * StatusAgeInterval::nanoseconds_per_second, .sampled_ns = std::numeric_limits<std::uint64_t>::max()})},
    };
  }

  QVariantMap headerRecord() {
    return {
        {QStringLiteral("index"), QStringLiteral("2")},
        {QStringLiteral("program"), QStringLiteral("clang++")},
        {QStringLiteral("agent"), agentRecord(AgentStatus::blocked)},
        {QStringLiteral("needsAttention"), true},
        {QStringLiteral("activityKind"), static_cast<int>(TabActivity::Kind::progress)},
        {QStringLiteral("activityColor"), QStringLiteral("teal")},
        {QStringLiteral("progressText"), QStringLiteral("Working")},
        {QStringLiteral("progressSample"), progressValue({.pane_id = 1, .attachment = 1, .state = PaneProgressState::indeterminate})},
    };
  }

  QQuickItem* named(QQuickItem& root, const QString& name) {
    const auto items = visualItems(root, name);

    return items.size() == 1 ? items.front() : nullptr;
  }

  class [[qt::object]] PaneHeaderTest : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
    [[qt::slot]] static void initTestCase() {
      bundledFonts();
      QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
    }

    [[qt::slot]] static void init() {
      QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
    }

    [[qt::slot]] static void chipUsesPaneWordsAndDoesNotPulse() {
      NativeAgentStatus status;

      status.setDisplayMode(NativeAgentStatus::DisplayMode::pane_chip);
      status.setRecord(agentRecord(AgentStatus::working));
      QCOMPARE(status.statusText(), QStringLiteral("working 24h"));
      QCOMPARE(status.animatedAlpha(), 1);
      status.setRecord(agentRecord(AgentStatus::blocked));
      QCOMPARE(status.statusText(), QStringLiteral("permission"));
      status.setRecord(agentRecord(AgentStatus::ready));
      QCOMPARE(status.statusText(), QStringLiteral("ready"));
      status.setRecord(agentRecord(AgentStatus::unknown));
      QVERIFY(status.statusText().isEmpty());
    }

    [[qt::slot]] static void projectionRejectsOtherPaneGenerationsAndUsesTheProgram() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::Memory& memory = adapter;
      GraphicsBudget budget;
      application::Pane pane{memory, 1, budget};

      pane.location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
      pane.generation = 2;
      pane.attachment_generation = 3;
      pane.title.assign("Ignore OSC title");
      pane.cwd.assign("/ignore/cwd");
      ds::Array<Agent<Memory>, 1> agents{Agent{memory}};
      auto& agent = agents.atMut(0);

      agent.pane_id = pane.id;
      agent.location = pane.location;
      agent.pane_generation = 1;
      agent.status = AgentStatus::ready;
      const auto span = std::span<const Agent<Memory>>{agents};
      auto record = paneChromeRecord(pane, span, 2);

      QCOMPARE(record.value(QStringLiteral("program")).toString(), QStringLiteral("shell"));
      QVERIFY(record.value(QStringLiteral("agent")).toMap().isEmpty());
      pane.foreground.assign("nvim");
      agent.pane_generation = pane.generation;
      record = paneChromeRecord(pane, span, 2);
      QCOMPARE(record.value(QStringLiteral("program")).toString(), QStringLiteral("nvim"));
      QCOMPARE(record.value(QStringLiteral("index")).toString(), QStringLiteral("2"));
      QCOMPARE(record.value(QStringLiteral("agent")).toMap().value(QStringLiteral("statusColor")).toString(), QStringLiteral("green"));
      ++pane.attachment_generation;
      QVERIFY(!paneChromeRecord(pane, span, 2).value(QStringLiteral("agent")).toMap().isEmpty());
      agent.location.tab_id = 2;
      QVERIFY(paneChromeRecord(pane, span, 2).value(QStringLiteral("agent")).toMap().isEmpty());
    }

    [[qt::slot]] static void projectionAddsSafeSessionTitleOrDirectoryContext() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::Memory& memory = adapter;
      GraphicsBudget budget;
      application::Pane pane{memory, 1, budget};

      pane.location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
      pane.generation = 2;
      pane.foreground.assign("zsh");
      pane.cwd.assign("/projects/telar");
      pane.title.assign("Test\n\tresults");
      QCOMPARE(paneChromeRecord(pane, std::span<const Agent<Memory>>{}, 1).value(QStringLiteral("context")).toString(), QStringLiteral("/projects/telar"));
      pane.title.clear();
      ds::Array<Agent<Memory>, 1> agents{Agent{memory}};
      auto& agent = agents.atMut(0);

      agent.pane_id = pane.id;
      agent.pane_generation = pane.generation;
      agent.location = pane.location;
      agent.title_state = AgentTitleState::ready;
      agent.title.assign("Fix session restore");
      auto record = paneChromeRecord(pane, std::span<const Agent<Memory>>{agents}, 1);

      QCOMPARE(record.value(QStringLiteral("context")).toString(), QStringLiteral("Fix session restore"));
      // A session title is the pane's own; only a directory is what its tab already shows.
      QVERIFY(!record.value(QStringLiteral("contextIsDirectory")).toBool());
      QCOMPARE(record.value(QStringLiteral("program")).toString(), QStringLiteral("zsh"));
      ++agent.pane_generation;
      record = paneChromeRecord(pane, std::span<const Agent<Memory>>{agents}, 1);
      QCOMPARE(record.value(QStringLiteral("context")).toString(), QStringLiteral("/projects/telar"));
      QVERIFY(record.value(QStringLiteral("contextIsDirectory")).toBool());
    }

    [[qt::slot]] static void aTabsOnlyPaneDoesNotRepeatTheDirectoryItsTabShows() {
      QQmlEngine engine;
      QQuickWindow window;

      window.resize(header_width, header_height);
      const ChromeMetrics chrome;
      const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}};
      auto record = headerRecord();

      record.insert(QStringLiteral("context"), QStringLiteral("~/projects/telar"));
      record.insert(QStringLiteral("contextIsDirectory"), true);
      record.insert(QStringLiteral("git"), QStringLiteral("⎇ main"));
      record.insert(QStringLiteral("aloneInTab"), false);
      auto item = createChrome(engine, QStringLiteral("PaneHeader"), {{QStringLiteral("record"), record}, {QStringLiteral("colors"), themeColors(Configuration{})}, {QStringLiteral("typography"), typography}});

      item->setParentItem(window.contentItem());
      item->setSize({header_width, header_height});
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto* context = named(*item, QStringLiteral("paneContext"));

      QVERIFY(context != nullptr);
      // Beside other panes the header says where this one works.
      QTRY_VERIFY_WITH_TIMEOUT(context->property("text").toString().contains(QStringLiteral("~/projects/telar")), wait_ms);
      QVERIFY(context->property("text").toString().contains(QStringLiteral("main")));
      // Alone in its tab it keeps the branch and leaves the directory to the tab.
      record.insert(QStringLiteral("aloneInTab"), true);
      QVERIFY(item->setProperty("record", record));
      QTRY_COMPARE_WITH_TIMEOUT(context->property("text").toString(), QStringLiteral("⎇ main"), wait_ms);
      // A session title is not the tab's directory: it stays.
      record.insert(QStringLiteral("context"), QStringLiteral("Fix session restore"));
      record.insert(QStringLiteral("contextIsDirectory"), false);
      QVERIFY(item->setProperty("record", record));
      QTRY_VERIFY_WITH_TIMEOUT(context->property("text").toString().startsWith(QStringLiteral("Fix session restore")), wait_ms);
    }

    [[qt::slot]] static void routineStatesStayQuietAndInactiveTitlesStayReadable() {
      QQmlEngine engine;
      const ChromeMetrics chrome;
      const auto colors = themeColors(Configuration{});
      const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}};
      auto record = headerRecord();
      auto item = createChrome(engine, QStringLiteral("PaneHeader"), {
                                                                         {QStringLiteral("record"), record},
                                                                         {QStringLiteral("colors"), colors},
                                                                         {QStringLiteral("typography"), typography},
                                                                     });

      const auto* state = named(*item, QStringLiteral("applicationStatus"));
      const auto* program = named(*item, QStringLiteral("paneProgram"));

      QVERIFY(state != nullptr && program != nullptr);
      QCOMPARE(program->property("color").value<QColor>(), colors.value(QStringLiteral("text")).value<QColor>());
      const auto attention_color = state->property("color").value<QColor>();

      record.insert(QStringLiteral("agent"), agentRecord(AgentStatus::ready));
      record.insert(QStringLiteral("needsAttention"), false);
      QVERIFY(item->setProperty("record", record));
      const auto quiet_color = state->property("color").value<QColor>();

      QCOMPARE(attention_color, colors.value(QStringLiteral("yellow")).value<QColor>());
      QCOMPARE(quiet_color, attention_color);
    }

    [[qt::slot]] static void compactHeaderKeepsTheProgramInsteadOfAnAmbiguousEllipsis() {
      QQmlEngine engine;
      QQuickWindow window;

      constexpr int title_size = 15;

      window.resize(compact_header_width, header_height);
      const ChromeMetrics chrome;
      auto record = headerRecord();

      record.insert(QStringLiteral("program"), QStringLiteral("Pi"));
      record.insert(QStringLiteral("context"), QStringLiteral("A long session title that cannot fit in this header"));
      record.insert(QStringLiteral("agent"), agentRecord(AgentStatus::ready));
      record.insert(QStringLiteral("needsAttention"), false);
      record.insert(QStringLiteral("progressText"), QString{});
      record.remove(QStringLiteral("progressSample"));
      record.insert(QStringLiteral("activityKind"), static_cast<int>(TabActivity::Kind::none));
      auto item = createChrome(engine, QStringLiteral("PaneHeader"), {{QStringLiteral("record"), record}, {QStringLiteral("colors"), themeColors(Configuration{})}, {QStringLiteral("typography"), QVariantMap{{QStringLiteral("title"), title_size}, {QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}}}});

      item->setParentItem(window.contentItem());
      item->setSize({compact_header_width, header_height});
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto* program = named(*item, QStringLiteral("paneProgram"));

      QVERIFY(program != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(program->property("text").toString(), QStringLiteral("Pi"), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(program->width() >= program->implicitWidth(), wait_ms);
    }

    [[qt::slot]] static void independentHeaderMarksTheStateOnTheTileAndKeepsProgress() {
      QQmlEngine engine;
      QQuickWindow window;

      window.resize(header_width, header_height);
      const ChromeMetrics chrome;
      const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}};
      auto item = createChrome(engine, QStringLiteral("PaneHeader"), {
                                                                         {QStringLiteral("record"), headerRecord()},
                                                                         {QStringLiteral("colors"), themeColors(Configuration{})},
                                                                         {QStringLiteral("typography"), typography},
                                                                     });

      item->setParentItem(window.contentItem());
      item->setSize({header_width, header_height});
      const auto* layout = qobject_cast<PaneHeaderLayout*>(item.get());

      QVERIFY(layout != nullptr);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      const auto* program = named(*item, QStringLiteral("paneProgram"));
      const auto* state = named(*item, QStringLiteral("applicationStatus"));

      QVERIFY(program != nullptr && state != nullptr && state->isVisible());
      // The default header places no worded chip, so the title and the progress share the band.
      QVERIFY(visualItems(*item, QStringLiteral("paneStatus")).isEmpty());
      QTRY_VERIFY_WITH_TIMEOUT(layout->chipBounds().isEmpty() && layout->progressBounds().width() > 0 && !layout->compactProgress(), wait_ms);
      QCOMPARE(program->property("text").toString(), QStringLiteral("clang++"));
      const auto* progress = qobject_cast<NativeTabActivity*>(named(*item, QStringLiteral("paneProgress")));

      QVERIFY(progress != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(progress->fraction() > 0 && !progress->compact(), wait_ms);
      item->setWidth(compact_header_width);
      QTRY_VERIFY_WITH_TIMEOUT(layout->compactProgress() && layout->progressBounds().width() > 0, wait_ms);
      QCOMPARE(program->property("text").toString(), QStringLiteral("clang++"));
      auto record = headerRecord();

      record.insert(QStringLiteral("agent"), QVariantMap{});
      record.insert(QStringLiteral("needsAttention"), false);
      item->setProperty("record", record);
      QTRY_VERIFY_WITH_TIMEOUT(!state->isVisible() && layout->progressBounds().width() > 0, wait_ms);
    }
  };

}

QTEST_MAIN(PaneHeaderTest)
#ifndef TELAR_MOC_RUN
#include "pane_header_test.moc"
#endif