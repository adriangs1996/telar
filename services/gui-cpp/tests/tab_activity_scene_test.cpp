#include "core/configuration.hpp"
#include "core/metrics.hpp"
#include "input/tab_drag.hpp"
#include "input/tab_drop_slots.hpp"
#include "presentation/progress_geometry.hpp"
#include "presentation/progress_motion.hpp"
#include "presentation/tab_activity.hpp"
#include "qml_fixture.hpp"
#include "qt/list_model.hpp"
#include "qt/native_agent_status.hpp"
#include "qt/native_progress_ring.hpp"
#include "qt/native_tab_activity.hpp"
#include "qt/progress_value.hpp"
#include "qt/projection.hpp"
#include "qt/tab_strip_layout.hpp"
#include "shape_atlas.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "ui/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QDebug>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSignalSpy>
#include <QString>
#include <QTimer>
#include <QVariant>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnumeric.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr qreal strip_height = 42;
constexpr int window_width = 200;
constexpr int motion_strip_width = 600;
constexpr qreal agent_width = 100;
constexpr Byte quarter_percent = 25;

QVariantMap record(TabActivity::Kind kind, ProgressSample sample = {}) {
  const TabActivity activity{.kind = kind};

  return {
      {QStringLiteral("key"), QStringLiteral("tab:1")},
      {QStringLiteral("label"), QStringLiteral("Build engine")},
      {QStringLiteral("selected"), true},
      {QStringLiteral("activityKind"), static_cast<int>(kind)},
      {QStringLiteral("activityColor"), QStringLiteral("teal")},
      {QStringLiteral("statusWidth"), activity.width()},
      {QStringLiteral("progressSample"), progressValue(sample)},
  };
}

QVariantMap stripProperties(ListModel &model, int width) {
  const ChromeMetrics chrome;
  const QVariantMap typography{
      {QStringLiteral("body"), chrome.body},
      {QStringLiteral("small"), chrome.small},
  };

  return {
      {QStringLiteral("width"), width},
      {QStringLiteral("height"), strip_height},
      {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&model))},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), typography},
  };
}

void configure(NativeTabActivity &item, TabActivity::Kind kind) {
  item.setSize({TabActivity::spinner_side, strip_height});
  item.setRecord(record(kind));
}

QJsonObject atlasFixture() {
  QFile source{QStringLiteral(":/telar/test-tab-activity/cases.json")};
  if (!source.open(QFile::ReadOnly)) {
    qFatal("Could not read original progress fixture");
  }

  return QJsonDocument::fromJson(source.readAll()).object();
}

std::vector<std::unique_ptr<QQuickItem>> createAtlas(const QQuickWindow &window, const QJsonObject &fixture) {
  std::vector<std::unique_ptr<QQuickItem>> items;
  const auto density = window.effectiveDevicePixelRatio();
  for (const auto &value : fixture.value(QStringLiteral("items")).toArray()) {
    const auto source = value.toObject();
    const auto rect = source.value(QStringLiteral("rect")).toArray();
    const auto color = QColor::fromRgb(source.value(QStringLiteral("rgb")).toInt());
    const QSizeF size{rect[2].toDouble() / density, rect[3].toDouble() / density};
    if (source.value(QStringLiteral("kind")).toString() == QStringLiteral("ring")) {
      auto item = std::make_unique<NativeProgressRing>(window.contentItem());
      item->setSize(size);
      item->setPosition({rect[0].toDouble() / density, rect[1].toDouble() / density});
      item->setColor(color);
      item->setFraction(source.value(QStringLiteral("fraction")).toDouble());
      item->setTurns(source.value(QStringLiteral("turns")).toDouble());
      items.push_back(std::move(item));
    } else {
      auto item = std::make_unique<NativeTabActivity>(window.contentItem());
      item->setSize(size);
      item->setPosition({rect[0].toDouble() / density, rect[1].toDouble() / density});
      item->setRatio(source.value(QStringLiteral("ratio")).toDouble() / density);
      item->setColor(color);
      const auto percent = source.value(QStringLiteral("percent"));
      const ProgressSample sample{.pane_id = 1, .attachment = 1, .state = static_cast<PaneProgressState>(source.value(QStringLiteral("state")).toInt()), .percent = percent.isNull() ? std::nullopt : std::optional{static_cast<Byte>(percent.toInt())}};
      item->setRecord(record(TabActivity::Kind::progress, sample));
      items.push_back(std::move(item));
    }
  }

  return items;
}

class TabActivitySceneTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
  }

  Q_SLOT static void originalRingAndCapsuleAtlas() {
    QQuickWindow window;
    const auto fixture = atlasFixture();
    const auto density = window.effectiveDevicePixelRatio();
    const QSize physical{fixture.value(QStringLiteral("width")).toInt(), fixture.value(QStringLiteral("height")).toInt()};
    window.resize(qRound(physical.width() / density), qRound(physical.height() / density));
    window.setMinimumSize(window.size());
    window.setMaximumSize(window.size());
    constexpr unsigned background_rgb = 0x101010;
    window.setColor(QColor::fromRgb(background_rgb));
    const auto items = createAtlas(window, fixture);
    const QImage expected{QStringLiteral(":/telar/test-tab-activity/atlas.png")};
    QVERIFY(!expected.isNull());
    const QSignalSpy frames{&window, &QQuickWindow::frameSwapped};
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!frames.isEmpty(), wait_ms);
    const auto exact = window.rendererInterface()->graphicsApi() == QSGRendererInterface::Metal;
    const auto budget = shapeCompositingBudget(fixture, exact ? 0 : 1);
    qInfo() << "Exact Metal atlas comparison:" << exact;
    auto frame = window.grabWindow();
    frame.setDevicePixelRatio(1);
    const auto error = compareShapeImages(frame, {.pixels = expected, .budget = budget});
    qInfo() << "Original progress atlas differences:" << error.pixels << "maximum channel:" << error.maximum_channel << "outside budget:" << error.outside_budget;
    const auto capture = qEnvironmentVariable("TELAR_GUI_SHAPE_CAPTURE");
    if (!capture.isEmpty()) {
      QVERIFY(frame.save(capture));
    }

    QCOMPARE(frame.size(), physical);
    QCOMPARE(error.outside_budget, 0);
    if (exact) {
      QCOMPARE(error.pixels, 0);
    }
  }

  Q_SLOT static void sharedClockParksWhenEveryObserverIsHidden() {
    QQuickWindow window;
    NativeTabActivity first{window.contentItem()};
    NativeTabActivity second{window.contentItem()};
    NativeAgentStatus agent{window.contentItem()};
    agent.setSize({agent_width, strip_height});
    agent.setRecord({{QStringLiteral("statusCode"), static_cast<int>(AgentStatus::working)}, {QStringLiteral("enabled"), true}});
    configure(first, TabActivity::Kind::spinner);
    configure(second, TabActivity::Kind::spinner);
    const QSignalSpy changes{&first, &NativeTabActivity::animationChanged};
    window.resize(window_width, static_cast<int>(strip_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!changes.isEmpty(), wait_ms);
    QCOMPARE(first.turns(), second.turns());
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    first.setVisible(false);
    second.setVisible(false);
    agent.setVisible(false);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
    const auto before = changes.count();
    constexpr int parked_observation_ms = 300;
    QTest::qWait(parked_observation_ms);
    QCOMPARE(changes.count(), before);
    first.setVisible(true);
    QTRY_VERIFY_WITH_TIMEOUT(changes.count() > before, wait_ms);
  }

  Q_SLOT static void progressRetargetsAndSettlesWithoutIdlePolling() {
    QQuickWindow window;
    NativeTabActivity item{window.contentItem()};
    item.setSize({ProgressGeometry::compactWidth(), strip_height});
    ProgressSample sample{.pane_id = 1, .attachment = 1, .state = PaneProgressState::set, .percent = 0};
    item.setRecord(record(TabActivity::Kind::progress, sample));
    window.resize(window_width, static_cast<int>(strip_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QCOMPARE(item.fraction(), 0);
    sample.percent = ProgressSample::maximum_percent;
    item.setRecord(record(TabActivity::Kind::progress, sample));
    QCOMPARE(item.fraction(), 0);
    QTRY_COMPARE_WITH_TIMEOUT(item.fraction(), 1, wait_ms);
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    item.setVisible(false);
    sample.percent = quarter_percent;
    item.setRecord(record(TabActivity::Kind::progress, sample));
    item.setVisible(true);
    constexpr qreal restored_fraction = 0.25;
    QCOMPARE(item.fraction(), restored_fraction);
  }

  Q_SLOT static void clockCallbacksCanDestroyTheirWindow() {
    auto window = std::make_unique<QQuickWindow>();
    auto owned_item = std::make_unique<NativeTabActivity>(window->contentItem());
    auto *item = owned_item.get();
    const QPointer<NativeTabActivity> alive{item};
    configure(*item, TabActivity::Kind::spinner);
    window->resize(window_width, static_cast<int>(strip_height));
    window->show();
    QTRY_VERIFY_WITH_TIMEOUT(window->isExposed(), wait_ms);
    const auto *const transferred_item = owned_item.release();
    connect(transferred_item, &NativeTabActivity::animationChanged, window.get(), [&window] {
      window.reset();
    });
    QTRY_VERIFY_WITH_TIMEOUT(alive.isNull(), wait_ms);
    QVERIFY(!window);
  }

  Q_SLOT static void tabMotionSettlesAndParksTheSharedClock() {
    QQuickWindow window;
    ListModel model;
    auto first = record(TabActivity::Kind::none);
    auto second = first;
    first.insert(QStringLiteral("key"), QStringLiteral("1"));
    second.insert(QStringLiteral("key"), QStringLiteral("2"));
    model.reconcile({first, second});
    TabStripLayout layout{window.contentItem()};
    layout.setSize({motion_strip_width, strip_height});
    layout.setContext(1, WorkspaceLocation{});
    layout.setModel(&model);
    window.resize(motion_strip_width, static_cast<int>(strip_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(layout.items()->rowCount(), 2, wait_ms);
    const auto original = layout.items()->data(layout.items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("bounds")).toRectF();
    model.reconcile({second, first});
    QTRY_VERIFY_WITH_TIMEOUT(layout.transitioning(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!layout.transitioning(), wait_ms);
    const auto reordered = layout.items()->data(layout.items()->index(0, 0), ListModel::record_role).toMap();
    QCOMPARE(reordered.value(QStringLiteral("tab")).toMap().value(QStringLiteral("key")).toString(), QStringLiteral("2"));
    QCOMPARE(reordered.value(QStringLiteral("bounds")).toRectF(), original);
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
    const QSignalSpy changes{&layout, &TabStripLayout::layoutChanged};
    constexpr int parked_observation_ms = 300;
    QTest::qWait(parked_observation_ms);
    QCOMPARE(changes.count(), 0);
    model.reconcile({first, second});
    QTRY_VERIFY_WITH_TIMEOUT(layout.transitioning(), wait_ms);
    layout.setVisible(false);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
    layout.setVisible(true);
    QTRY_VERIFY_WITH_TIMEOUT(!layout.transitioning(), wait_ms);
  }

  Q_SLOT static void tabMotionObserverCanRetireDuringATransition() {
    QQuickWindow window;
    ListModel model;
    auto first = record(TabActivity::Kind::none);
    auto second = first;
    first.insert(QStringLiteral("key"), QStringLiteral("1"));
    second.insert(QStringLiteral("key"), QStringLiteral("2"));
    model.reconcile({first, second});
    auto layout = std::make_unique<TabStripLayout>(window.contentItem());
    layout->setSize({motion_strip_width, strip_height});
    layout->setContext(1, WorkspaceLocation{});
    layout->setModel(&model);
    window.resize(motion_strip_width, static_cast<int>(strip_height));
    window.show();
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, wait_ms);
    model.reconcile({second, first});
    QTRY_VERIFY_WITH_TIMEOUT(layout->transitioning(), wait_ms);
    const QPointer<TabStripLayout> alive{layout.get()};
    layout.reset();
    QVERIFY(alive.isNull());
    const auto timers = window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QCOMPARE(timers.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(!timers.front()->isActive(), wait_ms);
  }

  Q_SLOT static void machineContextReplacementRetiresCollidingTabVisuals() {
    QQuickWindow window;
    ListModel model;
    auto first = record(TabActivity::Kind::none);
    auto second = first;
    first.insert(QStringLiteral("key"), QStringLiteral("1"));
    second.insert(QStringLiteral("key"), QStringLiteral("2"));
    model.reconcile({first, second});
    TabStripLayout layout{window.contentItem()};
    layout.setSize({motion_strip_width, strip_height});
    const WorkspaceLocation workspace;
    layout.setContext(1, workspace);
    layout.setModel(&model);
    window.resize(motion_strip_width, static_cast<int>(strip_height));
    window.show();
    QTRY_COMPARE_WITH_TIMEOUT(layout.items()->rowCount(), 2, wait_ms);
    const TabDragMove move{.location = {.workspace = workspace, .tab_id = 1}, .direction = TabMoveDirection::next, .relative_to = 2};
    layout.setDrag(move, 1, {static_cast<qreal>(motion_strip_width) / 2, strip_height / 2}, 0);
    layout.setPointerHover(1);
    QTRY_VERIFY_WITH_TIMEOUT(!layout.draggedBounds().isEmpty(), wait_ms);
    QVERIFY(!layout.dropMarker().isEmpty());
    layout.setContext(2, workspace);
    QCOMPARE(layout.draggedBounds(), QRectF{});
    QCOMPARE(layout.dropMarker(), QRectF{});
    QCOMPARE(layout.hoveredTab(), QString{});
    QTRY_VERIFY_WITH_TIMEOUT(!layout.transitioning(), wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(layout.items()->data(layout.items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("tab")).toMap().value(QStringLiteral("key")).toString(), QStringLiteral("1"), wait_ms);
    auto replacement = workspace;
    ++replacement.id;
    const QSignalSpy changes{&layout, &TabStripLayout::layoutChanged};
    layout.setContext(2, replacement);
    layout.setDrag(move, std::nullopt, {}, 0);
    QTRY_VERIFY_WITH_TIMEOUT(!changes.isEmpty(), wait_ms);
    QCOMPARE(layout.dropMarker(), QRectF{});
    QCOMPARE(layout.items()->data(layout.items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("tab")).toMap().value(QStringLiteral("key")).toString(), QStringLiteral("1"));
  }

  Q_SLOT static void stripReservesStatusAndPropagatesHiddenAttention() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel model;
    constexpr std::size_t tab_count = 64;
    constexpr std::size_t active_index = tab_count / 2;
    constexpr int strip_width = 120;
    QList<QVariantMap> records;
    for (std::size_t index = 0; index < tab_count; ++index) {
      auto row = record(index == active_index ? TabActivity::Kind::spinner : TabActivity::Kind::none);
      row.insert(QStringLiteral("key"), QString::number(index + 1));
      row.insert(QStringLiteral("selected"), index == active_index);
      records.append(row);
    }

    records.front().insert(QStringLiteral("attentionColor"), QStringLiteral("red"));
    records.back().insert(QStringLiteral("attentionColor"), QStringLiteral("yellow"));
    model.reconcile(records);
    const auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), stripProperties(model, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(strip_height));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->counter().value(QStringLiteral("attentionColor")).toString(), QStringLiteral("yellow"), wait_ms);
    const auto positioned = layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap();
    QCOMPARE(positioned.value(QStringLiteral("status")).toRectF().width(), TabActivity::spinner_side);
    const auto activity_items = visualItems(*strip, QStringLiteral("tabActivity"));
    QCOMPARE(activity_items.size(), 1);
    QCOMPARE(activity_items.front()->width(), TabActivity::spinner_side);
    std::array<TabDropSlot, TabDropSlots::capacity> targets{};
    const auto target_count = layout->dropSlots(targets);
    QCOMPARE(target_count, std::size_t{2});
    QCOMPARE(targets[target_count - 1].id, layout->counter().value(QStringLiteral("key")).toString().toULongLong());
    const auto counter_bounds = layout->counter().value(QStringLiteral("bounds")).toRectF();
    QCOMPARE(targets[target_count - 1].bounds.width, static_cast<float>(counter_bounds.width() * window.effectiveDevicePixelRatio()));
    records.back().insert(QStringLiteral("attentionColor"), QString{});
    model.reconcile(records);
    QTRY_COMPARE_WITH_TIMEOUT(layout->counter().value(QStringLiteral("attentionColor")).toString(), QStringLiteral("red"), wait_ms);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  TabActivitySceneTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "tab_activity_scene_test.moc"
