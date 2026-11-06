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
#include "telar_client/codecs/telar_value_codec.hpp"
#include <stdexcept>
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include <tuple>
#include "qml_fixture.hpp"
#include "../qt/agent_projection.hpp"
#include "../qt/list_model.hpp"
#include "../qt/projection.hpp"
#include "../qt/sidebar_projection.hpp"
#include "../qt/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QGuiApplication>
#include <QMetaMethod>
#include <QMetaObject>
#include <QObject>
#include <QPoint>
#include <QPointF>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QSignalSpy>
#include <QString>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>

#include "core/memory.hpp"
#include "qt/agent_projection.hpp"
#include "qt/list_model.hpp"
#include "qt/projection.hpp"
#include "qt/sidebar_projection.hpp"
#include "qt/bundled_fonts.hpp"


import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.presentation.activity_order;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;
using telar::AgentBlockedReason;
using telar::AgentProvider;
using telar::AgentStatus;
using telar::WorkspaceListEntry;
using telar::WorkspaceLocation;

constexpr int wait_ms = 5000;
constexpr float list_width = 263;
constexpr int viewport_height = 100;
constexpr std::uint64_t pane_id = 42;

QVariantMap typography() {
  const ChromeMetrics chrome;

  return {{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}, {QStringLiteral("title"), chrome.title}};
}

QVariantMap properties(const QVariantMap &record) {
  const ChromeMetrics chrome;
  const auto geometry = agentCardGeometryRecord({.chrome = chrome}, list_width);

  return {
      {QStringLiteral("record"), record},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), typography()},
      {QStringLiteral("geometry"), geometry},
  };
}

class AgentCardTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
  }

  Q_SLOT static void projectionKeepsOriginalLabelsAndBlockedReasons() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.pane_id = pane_id;
    agent.provider_name = "codex";
    agent.provider_kind = AgentProvider::codex;
    agent.workspace_label = "project";
    agent.status = AgentStatus::blocked;
    agent.blocked_reason = AgentBlockedReason::permission;
    agent.detail = "live event";
    AgentRecordContext context{.machine = "machine", .branch = "feature", .selected = true};
    auto record = agentRecord(agent, context);
    QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("Agent"));
    QCOMPARE(record.value(QStringLiteral("project")).toString(), QStringLiteral("machine · project"));
    QCOMPARE(record.value(QStringLiteral("status")).toString(), QStringLiteral("Approval"));
    QCOMPARE(record.value(QStringLiteral("statusGlyph")).toString(), QStringLiteral("\u26a0"));
    QCOMPARE(record.value(QStringLiteral("statusColor")).toString(), QStringLiteral("yellow"));
    QCOMPARE(record.value(QStringLiteral("detail")).toString(), QStringLiteral("feature"));
    QVERIFY(record.value(QStringLiteral("selected")).toBool());
    QCOMPARE(record.value(QStringLiteral("providerMark")).toInt(), static_cast<int>(AgentProvider::codex));

    agent.display_name = "Custom agent";
    agent.status = AgentStatus::working;
    record = agentRecord(agent, context);
    QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("Custom agent"));
    QCOMPARE(record.value(QStringLiteral("detail")).toString(), QStringLiteral("live event"));
    agent.title = "Session title";
    context.connected = false;
    record = agentRecord(agent, context);
    QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("Session title"));
    QCOMPARE(record.value(QStringLiteral("status")).toString(), QStringLiteral("offline"));
    QCOMPARE(record.value(QStringLiteral("statusGlyph")).toString(), QStringLiteral("?"));
    QVERIFY(!record.value(QStringLiteral("selected")).toBool());
    QVERIFY(!record.value(QStringLiteral("enabled")).toBool());
    QCOMPARE(record.value(QStringLiteral("detail")).toString(), QStringLiteral("live event"));
    agent.provider_kind = AgentProvider::unknown;
    record = agentRecord(agent, context);
    QCOMPARE(record.value(QStringLiteral("glyph")).toString(), QStringLiteral("?"));
    agent.icon = "!";
    record = agentRecord(agent, context);
    QCOMPARE(record.value(QStringLiteral("glyph")).toString(), QStringLiteral("!"));
  }

  Q_SLOT static void cardRowsAndSelectionNeedNoController() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.pane_id = pane_id;
    agent.title = "Session title";
    QQuickWindow window;
    QQmlEngine engine;
    const auto record = agentRecord(agent, {.machine = {}, .branch = {}, .selected = true});
    const auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(record));
    card->setParentItem(window.contentItem());
    window.resize(static_cast<int>(list_width), viewport_height);
    const auto title = visualItems(*card, QStringLiteral("agentTitleLabel"));
    const auto detail = visualItems(*card, QStringLiteral("agentDetailLabel"));
    const auto project = visualItems(*card, QStringLiteral("agentProjectLabel"));
    const auto background = visualItems(*card, QStringLiteral("agentCardBackground"));
    QCOMPARE(title.size(), 1);
    QCOMPARE(detail.size(), 1);
    QCOMPARE(project.size(), 1);
    QCOMPARE(background.size(), 1);
    constexpr qreal expected_height = 69;
    constexpr QPointF title_origin{10, 27};
    constexpr qreal detail_origin_y = 46;
    QCOMPARE(card->height(), expected_height);
    QCOMPARE(title.front()->position(), title_origin);
    QCOMPARE(title.front()->height(), qreal{17});
    QCOMPARE(detail.front()->parentItem()->y(), detail_origin_y);
    const auto colors = themeColors(Configuration{});
    auto selection_color = colors.value(QStringLiteral("text")).value<QColor>();
    selection_color.setAlphaF(telar::gui::ChromeStyle::selection_alpha);
    QCOMPARE(background.front()->property("color").value<QColor>(), selection_color);
    QCOMPARE(background.front()->property("radius").toReal(), qreal{telar::gui::ChromeStyle::surface_radius});
    const auto signal = card->metaObject()->method(card->metaObject()->indexOfSignal("selected(QString)"));
    QVERIFY(signal.isValid());
    const QSignalSpy selected{card.get(), signal};
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    constexpr QPoint card_center{128, 34};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, card_center);
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, wait_ms);
    QCOMPARE(selected.front().front().toString(), QStringLiteral("42"));
  }

  Q_SLOT static void offlineCardsRetireTheirHoveredBackground() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.pane_id = pane_id;
    QQuickWindow window;
    QQmlEngine engine;
    const auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(agentRecord(agent, {.machine = {}, .branch = {}})));
    card->setParentItem(window.contentItem());
    window.resize(static_cast<int>(list_width), viewport_height);
    const auto background = visualItems(*card, QStringLiteral("agentCardBackground"));
    QCOMPARE(background.size(), 1);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    constexpr QPoint card_center{128, 34};
    QTest::mouseMove(&window, card_center);
    QTRY_VERIFY_WITH_TIMEOUT(background.front()->isVisible(), wait_ms);
    QVERIFY(card->setProperty("record", agentRecord(agent, {.machine = {}, .branch = {}, .connected = false})));
    QTRY_VERIFY_WITH_TIMEOUT(!card->isEnabled(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!background.front()->isVisible(), wait_ms);
    QVERIFY(card->setProperty("heldHover", true));
    QVERIFY(!background.front()->isVisible());
  }

  Q_SLOT static void onlyEnabledCardsShowThePointingCursor() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.pane_id = pane_id;
    QQuickWindow window;
    QQmlEngine engine;
    const auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(agentRecord(agent, {.machine = {}, .branch = {}})));
    card->setParentItem(window.contentItem());
    window.resize(static_cast<int>(list_width), viewport_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    constexpr QPoint card_center{128, 34};
    QTest::mouseMove(&window, card_center);
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, wait_ms);

    QVERIFY(card->setProperty("record", agentRecord(agent, {.machine = {}, .branch = {}, .connected = false})));
    QTRY_VERIFY_WITH_TIMEOUT(!card->isEnabled(), wait_ms);
    constexpr QPoint moved_within_card{130, 34};
    QTest::mouseMove(&window, moved_within_card);
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::ArrowCursor, wait_ms);
  }

  Q_SLOT static void deliveredHoverIdentityOverridesGeometricHover() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.pane_id = pane_id;
    QQuickWindow window;
    QQmlEngine engine;
    const auto card = createChrome(engine, QStringLiteral("AgentCard"), properties(agentRecord(agent, {.machine = {}, .branch = {}})));
    card->setParentItem(window.contentItem());
    static_cast<void>(card->setProperty("semanticHover", true));
    window.resize(static_cast<int>(list_width), viewport_height);
    const auto background = visualItems(*card, QStringLiteral("agentCardBackground"));
    QCOMPARE(background.size(), 1);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    constexpr QPoint card_center{128, 34};
    QTest::mouseMove(&window, card_center);
    QTRY_VERIFY_WITH_TIMEOUT(!background.front()->isVisible(), wait_ms);
    QVERIFY(card->setProperty("heldHover", true));
    QTRY_VERIFY_WITH_TIMEOUT(background.front()->isVisible(), wait_ms);
    QVERIFY(card->setProperty("heldHover", false));
    QTRY_VERIFY_WITH_TIMEOUT(!background.front()->isVisible(), wait_ms);
  }

  Q_SLOT static void projectsKeepTheirOrderBeforeAgentAttention() {
    SystemAllocator memory;
    std::array agents{Agent{memory}, Agent{memory}, Agent{memory}, Agent{memory}};
    const WorkspaceLocation first{.kind = WorkspaceLocation::Kind::workspace, .id = 1};
    const WorkspaceLocation second{.kind = WorkspaceLocation::Kind::workspace, .id = 2};
    WorkspaceReplica workspaces{memory};
    const std::array projects{WorkspaceListEntry{.workspace = first.id, .name = "first", .path = "/first"}, WorkspaceListEntry{.workspace = second.id, .name = "second", .path = "/second"}};
    QVERIFY(workspaces.apply({.revision = 1, .entries = projects}));
    for (std::size_t index = 0; index < agents.size(); ++index) {
      agents[index].pane_id = index + 1;
      agents[index].location.workspace = first;
    }

    agents[1].status = AgentStatus::working;
    agents[2].status = AgentStatus::blocked;
    agents[2].location.workspace = second;
    agents[3].status = AgentStatus::blocked;
    const auto plan = AgentOrder::arrange(std::span<const Agent<SystemAllocator>>{agents}, workspaces);
    QCOMPARE(plan.count, agents.size());
    const std::array<std::size_t, 4> expected{3, 1, 0, 2};
    for (std::size_t index = 0; index < expected.size(); ++index) {
      QCOMPARE(plan.entries[index].agent, expected[index]);
      QCOMPARE(plan.entries[index].first_in_project, index == 0 || index == expected.size() - 1);
    }
  }

  Q_SLOT static void statusDropsDurationBeforeItsWordAndGlyph() {
    SystemAllocator memory;
    Agent agent{memory};
    agent.status = AgentStatus::working;
    constexpr std::uint32_t large_age = 1'000'000'000;
    agent.status_age_s = large_age;
    QQuickWindow window;
    QQmlEngine engine;
    const auto status = createChrome(engine, QStringLiteral("AgentStatus"), properties(agentRecord(agent, {})));
    status->setParentItem(window.contentItem());
    constexpr qreal complete_width = 200;
    constexpr qreal word_only_width = 70;
    constexpr qreal glyph_only_width = 10;
    constexpr qreal row_height = 15;
    status->setSize({complete_width, row_height});
    window.resize(static_cast<int>(list_width), viewport_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(status->property("label").toString(), QStringLiteral("Working 9999d"), wait_ms);
    status->setWidth(word_only_width);
    QTRY_COMPARE_WITH_TIMEOUT(status->property("label").toString(), QStringLiteral("Working"), wait_ms);
    status->setWidth(glyph_only_width);
    QTRY_COMPARE_WITH_TIMEOUT(status->property("label").toString(), QString{}, wait_ms);
    QCOMPARE(status->property("usedWidth").toReal(), glyph_only_width);
  }

  Q_SLOT static void activityCreatesOnlyVisibleCards() {
    SystemAllocator memory;
    Agent agent{memory};
    ListModel model;
    QList<QVariantMap> records;
    constexpr std::uint64_t agent_count = 64;
    for (std::uint64_t index = 0; index < agent_count; ++index) {
      agent.pane_id = index + 1;
      records.append(agentRecord(agent, {}));
    }

    model.reconcile(std::move(records));
    QQuickWindow window;
    QQmlEngine engine;
    auto settings = properties({});
    settings.remove(QStringLiteral("record"));
    settings.insert(QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&model)));
    const auto list = createChrome(engine, QStringLiteral("ActivityList"), settings);
    list->setParentItem(window.contentItem());
    list->setSize({list_width, viewport_height});
    window.resize(static_cast<int>(list_width), viewport_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!visualItems(*list, QStringLiteral("agentCard")).empty(), wait_ms);
    constexpr qsizetype maximum_visible_cards = 4;
    QVERIFY(visualItems(*list, QStringLiteral("agentCard")).size() <= maximum_visible_cards);
  }
};

}

QTEST_MAIN(AgentCardTest)
#include "agent_card_test.moc"
