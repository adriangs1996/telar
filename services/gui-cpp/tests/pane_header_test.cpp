#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include <atomic>
#include <cstdint>
#include <limits>
#include <exception>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_config/graphics/limits.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <utility>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include "../terminal/screen.hpp"
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <charconv>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <tuple>
#include "qml_fixture.hpp"
#include "../qt/agent_status_value.hpp"
#include "../qt/bundled_fonts.hpp"
#include "../qt/native_agent_status.hpp"
#include "../qt/native_tab_activity.hpp"
#include "../qt/pane_header_layout.hpp"
#include "../qt/pane_projection.hpp"
#include "../qt/progress_value.hpp"
#include "../qt/projection.hpp"
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

#include "core/memory.hpp"
#include "qt/agent_status_value.hpp"
#include "qt/bundled_fonts.hpp"
#include "qt/native_agent_status.hpp"
#include "qt/native_tab_activity.hpp"
#include "qt/pane_header_layout.hpp"
#include "qt/pane_projection.hpp"
#include "qt/progress_value.hpp"
#include "qt/projection.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.graphics.texture_cache;
import telar.gui.presentation.application_mark;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int header_width = 460;
constexpr int header_height = 30;
constexpr int compact_header_width = 160;
constexpr int attention_header_width = 120;
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

QQuickItem *named(QQuickItem &root, const QString &name) {
  const auto items = visualItems(root, name);

  return items.size() == 1 ? items.front() : nullptr;
}

class PaneHeaderTest : public QObject {
  Q_OBJECT

  Q_SLOT static void initTestCase() {
    bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void chipUsesPaneWordsAndDoesNotPulse() {
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

  Q_SLOT static void projectionRejectsOtherPaneGenerationsAndUsesTheProgram() {
    SystemAllocator memory;
    GraphicsBudget budget;
    Pane pane{memory, 1, budget};
    pane.location = {.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
    pane.generation = 2;
    pane.attachment_generation = 3;
    pane.title = "Ignore OSC title";
    pane.cwd = "/ignore/cwd";
    std::array<Agent<SystemAllocator>, 1> agents{Agent{memory}};
    auto &agent = agents.front();
    agent.pane_id = pane.id;
    agent.location = pane.location;
    agent.pane_generation = 1;
    agent.status = AgentStatus::ready;
    const auto span = std::span<const Agent<SystemAllocator>>{agents};
    auto record = paneChromeRecord(pane, span, 2);
    QCOMPARE(record.value(QStringLiteral("program")).toString(), QStringLiteral("shell"));
    QVERIFY(record.value(QStringLiteral("agent")).toMap().isEmpty());
    pane.foreground = "nvim";
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

  Q_SLOT static void routineStatesStayQuietAndInactiveTitlesStayReadable() {
    QQmlEngine engine;
    const ChromeMetrics chrome;
    const auto colors = themeColors(Configuration{});
    const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}};
    auto record = headerRecord();
    auto item = createChrome(engine, QStringLiteral("PaneHeader"), {
                                                                       {QStringLiteral("record"), record},
                                                                       {QStringLiteral("colors"), colors},
                                                                       {QStringLiteral("typography"), typography},
                                                                   });
    auto *background = named(*item, QStringLiteral("paneStatusBackground"));
    const auto *program = named(*item, QStringLiteral("paneProgram"));
    QVERIFY(background != nullptr && program != nullptr);
    QCOMPARE(program->property("color").value<QColor>(), colors.value(QStringLiteral("text")).value<QColor>());
    const auto attention_alpha = background->property("color").value<QColor>().alphaF();
    record.insert(QStringLiteral("agent"), agentRecord(AgentStatus::ready));
    record.insert(QStringLiteral("needsAttention"), false);
    QVERIFY(item->setProperty("record", record));
    const auto quiet_alpha = background->property("color").value<QColor>().alphaF();
    QVERIFY(attention_alpha > quiet_alpha * 3);
    QVERIFY(quiet_alpha < 0.05);
  }

  Q_SLOT static void independentHeaderKeepsAttentionBeforeProgress() {
    QQmlEngine engine;
    QQuickWindow window;
    window.resize(header_width, header_height);
    const ChromeMetrics chrome;
    const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}};
    auto item = createChrome(engine, QStringLiteral("PaneHeader"), {
                                                                       {QStringLiteral("record"), headerRecord()},
                                                                       {QStringLiteral("colors"), themeColors(Configuration{})},
                                                                       {QStringLiteral("typography"), typography},
                                                                   });
    item->setParentItem(window.contentItem());
    item->setSize({header_width, header_height});
    const auto *layout = qobject_cast<PaneHeaderLayout *>(item.get());
    QVERIFY(layout != nullptr);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto *program = named(*item, QStringLiteral("paneProgram"));
    const auto *status = qobject_cast<NativeAgentStatus *>(named(*item, QStringLiteral("paneStatus")));
    QVERIFY(program != nullptr && status != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(layout->chipBounds().width() > 0 && layout->progressBounds().width() > 0 && !layout->compactProgress(), wait_ms);
    QCOMPARE(program->property("text").toString(), QStringLiteral("clang++"));
    QCOMPARE(status->statusText(), QStringLiteral("permission"));
    const auto *progress = qobject_cast<NativeTabActivity *>(named(*item, QStringLiteral("paneProgress")));
    QVERIFY(progress != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(progress->fraction() > 0 && !progress->compact(), wait_ms);
    item->setWidth(compact_header_width);
    QTRY_VERIFY_WITH_TIMEOUT(layout->compactProgress() && layout->chipBounds().width() > 0, wait_ms);
    item->setWidth(attention_header_width);
    QTRY_VERIFY_WITH_TIMEOUT(layout->progressBounds().isEmpty() && layout->chipBounds().width() > 0, wait_ms);
    item->setWidth(status->implicitWidth() + 2 * PaneHeaderGeometry::margin);
    QTRY_VERIFY_WITH_TIMEOUT(layout->indexBounds().isEmpty() && layout->progressBounds().isEmpty() && layout->chipBounds().width() > 0, wait_ms);
    auto record = headerRecord();
    record.insert(QStringLiteral("agent"), QVariantMap{});
    record.insert(QStringLiteral("needsAttention"), false);
    item->setProperty("record", record);
    QTRY_VERIFY_WITH_TIMEOUT(layout->chipBounds().isEmpty() && layout->progressBounds().width() > 0, wait_ms);
  }
};

}

QTEST_MAIN(PaneHeaderTest)
#include "pane_header_test.moc"
