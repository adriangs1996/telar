#include "core/memory.hpp"
#include "frame_fixture.hpp"
#include "history/entry.hpp"
#include "presentation/history_labels.hpp"
#include "presentation/history_loading.hpp"
#include "presentation/loading_cue.hpp"
#include "qml_fixture.hpp"
#include "qt/projection.hpp"
#include "qt/scroll_event.hpp"
#include "qt/history_loading_layout.hpp"
#include "qt/history_selection_layout.hpp"
#include "qt/history_empty_layout.hpp"
#include "qt/history_footer_layout.hpp"
#include "qt/history_filters_layout.hpp"
#include "input/history_hover.hpp"
#include "presentation/history_footer.hpp"
#include "input/wheel_accumulator.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/bundled_fonts.hpp"
#include <QColor>
#include <QList>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QPointF>
#include <QPointingDevice>
#include <QInputDevice>
#include <QWheelEvent>
#include <QFont>
#include <QGuiApplication>
#include <QObject>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QRegularExpression>
#include <QSignalSpy>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <QWindow>
#include <QTimer>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qchar.h>
#include <QtCore/qobject.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qpoint.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtGui/qtestsupport_gui.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstddef>
#include <limits>
#include <memory>
#include <span>
#include <variant>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int wide_width = 1200;
constexpr int narrow_width = 320;
constexpr int header_height = 46;
constexpr int search_height = 52;
constexpr int body_pixels = 13;
constexpr int small_pixels = 11;
constexpr int row_height = 34;
constexpr int cell_width = 8;
constexpr int cell_height = 20;
constexpr int terminal_pixels = 15;
constexpr int terminal_baseline = 14;
constexpr int fact_limited_width = 260;
constexpr int footer_height = 36;

QVariantMap historyFooterState() {
  constexpr int page_count = 12;
  constexpr int page_offset = 256;

  return {
      {QStringLiteral("phase"), QStringLiteral("ready")},
      {QStringLiteral("count"), page_count},
      {QStringLiteral("selection"), 0},
      {QStringLiteral("offset"), page_offset},
      {QStringLiteral("hasMore"), true},
      {QStringLiteral("matchFuzzy"), true},
      {QStringLiteral("query"), QStringLiteral("git")},
      {QStringLiteral("macStyle"), true},
      {QStringLiteral("enterRuns"), false},
      {QStringLiteral("inspecting"), false},
      {QStringLiteral("error"), QString{}},
  };
}

QQuickItem *hintForAction(QQuickItem &root, const QString &action) {
  for (auto *hint : visualItems(root, QStringLiteral("historyHint"))) {
    if (hint->isVisible() && hint->property("label").toMap().value(QStringLiteral("action")).toString() == action) {
      return hint;
    }
  }

  return nullptr;
}

QVariantMap historyTypography() {
  return {
      {QStringLiteral("primaryFamily"), QStringLiteral("JetBrains Mono")},
      {QStringLiteral("primaryStyle"), QString{}},
      {QStringLiteral("body"), body_pixels},
      {QStringLiteral("small"), small_pixels},
      {
          QStringLiteral("grid"),
          QVariantMap{
              {QStringLiteral("family"), QStringLiteral("JetBrains Mono")},
              {QStringLiteral("style"), QString{}},
              {QStringLiteral("cellWidth"), cell_width},
              {QStringLiteral("cellHeight"), cell_height},
              {QStringLiteral("pixelHeight"), terminal_pixels},
              {QStringLiteral("baseline"), terminal_baseline},
          },
      },
  };
}

QVariantMap historyState() {
  return {
      {QStringLiteral("effectiveScope"), QStringLiteral("global")},
      {QStringLiteral("author"), QStringLiteral("human")},
      {QStringLiteral("failedOnly"), false},
  };
}

QQuickItem *chipFor(QQuickItem &filters, const QString &value) {
  for (auto *item : visualItems(filters, QStringLiteral("historyFilterChip"))) {
    if (item->property("modelData").toMap().value(QStringLiteral("value")).toString() == value) {
      return item;
    }
  }

  return nullptr;
}

void followWindowSize(QQuickItem &item, QQuickWindow &window) {
  QObject::connect(&window, &QWindow::widthChanged, &item, &QQuickItem::setWidth);
  QObject::connect(&window, &QWindow::heightChanged, &item, &QQuickItem::setHeight);
  item.setSize(window.size());
}

QVariantMap inspectionDetails() {
  QVariantList facts;
  for (const auto *label : {"When", "Took", "Exit", "Where", "Pane", "By"}) {
    const auto label_text = QString::fromLatin1(label);
    facts.append(QVariantMap{
        {QStringLiteral("label"), label_text},
        {QStringLiteral("text"), QStringLiteral("fixture fact")},
        {QStringLiteral("color"), QStringLiteral("text")},
        {QStringLiteral("mono"), label_text == QStringLiteral("Where")},
    });
  }

  return {{QStringLiteral("identity"), QStringLiteral("77")}, {QStringLiteral("facts"), facts}, {QStringLiteral("heading"), QStringLiteral("Captured output")}};
}

QQuickItem *inspectionAction(QQuickItem &root, const QString &action) {
  for (auto *button : visualItems(root, QStringLiteral("historyInspectionAction"))) {
    if (button->isVisible() && button->property("action").toMap().value(QStringLiteral("action")).toString() == action) {
      return button;
    }
  }

  return nullptr;
}

struct InspectionFixture {
  static constexpr int height = 360;
  static constexpr int output_lines = 80;

  InspectionFixture() {
    state.insert(QStringLiteral("revision"), QStringLiteral("77"));
    state.insert(QStringLiteral("paneOpen"), false);
    item = createChrome(engine, QStringLiteral("HistoryInspector"), {
                                                                        {QStringLiteral("details"), inspectionDetails()},
                                                                        {QStringLiteral("browserState"), state},
                                                                        {QStringLiteral("colors"), themeColors({})},
                                                                        {QStringLiteral("typography"), historyTypography()},
                                                                        {QStringLiteral("command"), QStringLiteral("echo inspection fixture")},
                                                                        {QStringLiteral("output"), QStringLiteral("captured output\n").repeated(output_lines)},
                                                                        {QStringLiteral("width"), wide_width},
                                                                        {QStringLiteral("height"), height},
                                                                    });
    item->setParentItem(window.contentItem());
    window.resize(wide_width, height);
    followWindowSize(*item, window);
  }

  QQuickWindow window;
  QQmlEngine engine;
  QVariantMap state = historyFooterState();
  std::unique_ptr<QQuickItem> item;
};

class HistoryControlsTest final : public QObject {
  Q_OBJECT

  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
    QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
  }

  Q_SLOT static void init() {
    QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
  }

  Q_SLOT static void emptyStatesWorkWithoutAnApplicationController() {
    QQuickWindow window;
    QQmlEngine engine;
    constexpr int empty_height = 360;
    auto item = createChrome(engine, QStringLiteral("HistoryEmpty"), {{QStringLiteral("state"), QVariantMap{}}, {QStringLiteral("colors"), themeColors({})}, {QStringLiteral("typography"), historyTypography()}, {QStringLiteral("workspace"), QStringLiteral("thread 🧵")}, {QStringLiteral("width"), wide_width}, {QStringLiteral("height"), empty_height}});
    item->setParentItem(window.contentItem());
    window.resize(wide_width, empty_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    followWindowSize(*item, window);
    struct Case {
      QString phase = QStringLiteral("ready");
      QString scope = QStringLiteral("global");
      QString author = QStringLiteral("all");
      QString title;
      QString action = QStringLiteral("none");
      bool has_page = true;
    };
    const std::array cases{
        Case{.phase = QStringLiteral("loading"), .title = QStringLiteral("Searching your command history…"), .has_page = false},
        Case{.phase = QStringLiteral("failed"), .title = QStringLiteral("Could not load the command history")},
        Case{.title = QStringLiteral("No commands yet"), .action = QStringLiteral("import")},
        Case{.author = QStringLiteral("human"), .title = QStringLiteral("No matching commands")},
        Case{.scope = QStringLiteral("workspace"), .title = QStringLiteral("No matches in workspace thread 🧵"), .action = QStringLiteral("everywhere")},
        Case{.scope = QStringLiteral("cwd"), .title = QStringLiteral("No matches in this directory"), .action = QStringLiteral("everywhere")},
        Case{.scope = QStringLiteral("pane"), .title = QStringLiteral("No matches in this pane"), .action = QStringLiteral("everywhere")},
        Case{.phase = QStringLiteral("loading"), .title = QStringLiteral("No commands yet"), .action = QStringLiteral("import")},
    };
    for (const auto &sample : cases) {
      const QVariantMap state{{QStringLiteral("phase"), sample.phase}, {QStringLiteral("effectiveScope"), sample.scope}, {QStringLiteral("author"), sample.author}, {QStringLiteral("hasPage"), sample.has_page}};
      item->setProperty("state", state);
      QTRY_COMPARE_WITH_TIMEOUT(item->property("title").toString(), sample.title, wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(item->property("action").toString(), sample.action, wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(item->property("layout").toMap().value(QStringLiteral("title")).toRectF().width() > 0, wait_ms);
    }

    auto state = item->property("state").toMap();
    state.insert(QStringLiteral("phase"), QStringLiteral("ready"));
    state.insert(QStringLiteral("effectiveScope"), QStringLiteral("workspace"));
    item->setProperty("state", state);
    constexpr int oversized_workspace = 100;
    item->setProperty("workspace", QString(oversized_workspace, QLatin1Char('x')));
    QTRY_COMPARE_WITH_TIMEOUT(item->property("title").toString(), QStringLiteral("No matches in this workspace"), wait_ms);
  }

  Q_SLOT static void emptyRecoveryRetiresHiddenPresses() {
    QQuickWindow window;
    QQmlEngine engine;
    constexpr int empty_height = 360;
    QVariantMap state{{QStringLiteral("phase"), QStringLiteral("ready")}, {QStringLiteral("effectiveScope"), QStringLiteral("workspace")}, {QStringLiteral("query"), QStringLiteral("missing")}};
    auto item = createChrome(engine, QStringLiteral("HistoryEmpty"), {{QStringLiteral("state"), state}, {QStringLiteral("colors"), themeColors({})}, {QStringLiteral("typography"), historyTypography()}, {QStringLiteral("workspace"), QStringLiteral("project")}, {QStringLiteral("width"), wide_width}, {QStringLiteral("height"), empty_height}});
    item->setParentItem(window.contentItem());
    window.resize(wide_width, empty_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    followWindowSize(*item, window);
    const auto *button = item->findChild<QQuickItem *>(QStringLiteral("historySearchEverywhere"));
    QVERIFY(button != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(button->isVisible() && button->width() > 0, wait_ms);
    const QSignalSpy recovered{item.get(), SIGNAL(searchEverywhere())};
    const auto center = button->mapToScene({button->width() / 2, button->height() / 2}).toPoint();
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    state.insert(QStringLiteral("phase"), QStringLiteral("failed"));
    item->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(!button->isVisible(), wait_ms);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(recovered.size(), 0);
    state.insert(QStringLiteral("phase"), QStringLiteral("ready"));
    item->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(button->isVisible(), wait_ms);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(recovered.size(), 1);
  }

  Q_SLOT static void replacementLoadingWaitsAndStops() {
    QQuickWindow window;
    QQmlEngine engine;
    auto item = createChrome(engine, QStringLiteral("HistorySearchBar"), {{QStringLiteral("colors"), themeColors({})}, {QStringLiteral("typography"), historyTypography()}, {QStringLiteral("width"), wide_width}, {QStringLiteral("height"), search_height}});
    item->setParentItem(window.contentItem());
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    followWindowSize(*item, window);
    const auto *loading = item->findChild<HistoryLoadingLayout *>(QStringLiteral("historyLoading"));
    QVERIFY(loading != nullptr);
    QElapsedTimer elapsed;
    elapsed.start();
    item->setProperty("replacing", true);
    QVERIFY(!loading->cueVisible());
    QCOMPARE(loading->rowsOpacity(), qreal{1});
    QTRY_VERIFY_WITH_TIMEOUT(loading->cueVisible(), wait_ms);
    constexpr std::uint64_t nanoseconds_per_millisecond = 1'000'000;
    QVERIFY(elapsed.elapsed() >= static_cast<qint64>(LoadingCue::delay_ns / nanoseconds_per_millisecond));
    QCOMPARE(loading->rowsOpacity(), static_cast<qreal>(HistoryLoading::row_opacity));
    const auto initial = loading->line();
    QTRY_VERIFY_WITH_TIMEOUT(loading->line().x() != initial.x(), wait_ms);
    item->setProperty("replacing", false);
    QTRY_VERIFY_WITH_TIMEOUT(!loading->cueVisible(), wait_ms);
    QCOMPARE(loading->rowsOpacity(), qreal{1});
    QVERIFY(loading->line().isEmpty());
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
  }

  Q_SLOT static void selectionMotionStartsOnAFrameAndParksItsClock() {
    QQuickWindow window;
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    HistorySelectionLayout motion(window.contentItem());
    const auto selection = [](int index, const QString &identity) {
      return QVariantMap{
          {QStringLiteral("active"), true},
          {QStringLiteral("generation"), QStringLiteral("41")},
          {QStringLiteral("index"), index},
          {QStringLiteral("id"), identity},
      };
    };
    motion.setSelection(selection(0, QStringLiteral("9007199254740993")));
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    QCOMPARE(motion.selectedOpen(), qreal{1});
    QCOMPARE(motion.leavingIndex(), -1);
    QList<qreal> samples;
    QObject::connect(&motion, &HistorySelectionLayout::frameChanged, &window, [&] { samples.append(motion.selectedOpen()); });
    motion.setSelection(selection(1, QStringLiteral("9007199254740995")));
    QCOMPARE(motion.selectedOpen(), qreal{1});
    QTRY_VERIFY_WITH_TIMEOUT(!samples.isEmpty(), wait_ms);
    QCOMPARE(samples.front(), qreal{0});
    QCOMPARE(motion.leavingIndex(), 0);
    QCOMPARE(motion.leavingKey(), QStringLiteral("9007199254740993"));
    QTRY_COMPARE_WITH_TIMEOUT(motion.selectedOpen(), qreal{1}, wait_ms);
    QCOMPARE(motion.leavingIndex(), -1);
    QVERIFY(std::ranges::any_of(samples, [](qreal open) { return open > 0 && open < 1; }));
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    QCOMPARE(window.findChildren<QTimer *>(QStringLiteral("agentStatusAnimation")).size(), 1);
    motion.setSelection(selection(2, QStringLiteral("9007199254740997")));
    QTRY_VERIFY_WITH_TIMEOUT(motion.selectedOpen() < 1, wait_ms);
    motion.setVisible(false);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    motion.setVisible(true);
    QTRY_COMPARE_WITH_TIMEOUT(motion.selectedOpen(), qreal{1}, wait_ms);
    QCOMPARE(motion.leavingIndex(), -1);
  }

  Q_SLOT static void selectionClockRetiresDestroyedItems() {
    QQuickWindow window;
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    auto motion = std::make_unique<HistorySelectionLayout>(window.contentItem());
    motion->setSelection({{QStringLiteral("active"), true}, {QStringLiteral("generation"), QStringLiteral("1")}, {QStringLiteral("id"), QStringLiteral("1")}, {QStringLiteral("index"), 0}});
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    motion->setSelection({{QStringLiteral("active"), true}, {QStringLiteral("generation"), QStringLiteral("1")}, {QStringLiteral("id"), QStringLiteral("2")}, {QStringLiteral("index"), 1}});
    QTRY_VERIFY_WITH_TIMEOUT(motion->selectedOpen() < 1, wait_ms);
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    motion.reset();
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
  }

  Q_SLOT static void loadingClockRetiresDestroyedItems() {
    QQuickWindow window;
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    auto loading = std::make_unique<HistoryLoadingLayout>(window.contentItem());
    loading->setSize(window.size());
    loading->setWaiting(true);
    QTRY_VERIFY_WITH_TIMEOUT(loading->cueVisible(), wait_ms);
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    loading.reset();
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
  }

  Q_SLOT static void emptyGeometryRejectsNonfiniteTypography() {
    QQuickWindow window;
    HistoryEmptyLayout item{window.contentItem()};
    item.setSize({wide_width, search_height});
    item.setInput({{QStringLiteral("bodyPixels"), std::numeric_limits<double>::quiet_NaN()}, {QStringLiteral("smallPixels"), std::numeric_limits<double>::infinity()}});
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QTRY_COMPARE_WITH_TIMEOUT(item.layout().value(QStringLiteral("title")).toRectF().height(), qreal{0}, wait_ms);
    QCOMPARE(item.layout().value(QStringLiteral("subtitle")).toRectF().height(), qreal{0});
  }

  Q_SLOT static void stateObserversCanRetireTheComponent() {
    auto empty = std::make_unique<HistoryEmptyLayout>();
    QObject::connect(empty.get(), &HistoryEmptyLayout::inputChanged, [&empty] { empty.reset(); });
    empty->setInput({{QStringLiteral("ratio"), 1}});
    QVERIFY(empty == nullptr);

    auto waiting = std::make_unique<HistoryLoadingLayout>();
    QObject::connect(waiting.get(), &HistoryLoadingLayout::waitingChanged, [&waiting] { waiting.reset(); });
    waiting->setWaiting(true);
    QVERIFY(waiting == nullptr);

    auto ratio = std::make_unique<HistoryLoadingLayout>();
    QObject::connect(ratio.get(), &HistoryLoadingLayout::ratioChanged, [&ratio] { ratio.reset(); });
    constexpr qreal doubled_ratio = 2;
    ratio->setRatio(doubled_ratio);
    QVERIFY(ratio == nullptr);
  }

  Q_SLOT static void filterHoverTargetsTrackPresentedGeometryAndStableActions() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyState();
    auto filters = createChrome(engine, QStringLiteral("HistoryFilters"), {
        {QStringLiteral("state"), state},
        {QStringLiteral("colors"), themeColors({})},
        {QStringLiteral("pixelSize"), small_pixels},
        {QStringLiteral("grid"), historyTypography().value(QStringLiteral("grid"))},
        {QStringLiteral("width"), wide_width},
        {QStringLiteral("height"), header_height},
    });
    filters->setParentItem(window.contentItem());
    window.resize(wide_width, header_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    const auto *layout = qobject_cast<HistoryFiltersLayout *>(filters.get());
    QVERIFY(layout != nullptr);
    std::array<HistoryHoverTarget, HistoryFiltersLayout::target_count> targets;
    constexpr auto generation = std::numeric_limits<std::uint64_t>::max();
    QTRY_COMPARE_WITH_TIMEOUT(layout->hoverTargets(generation, targets), targets.size(), wait_ms);
    const auto identity = targets[1].identity;
    const auto *action = std::get_if<HistoryFilterAction>(&identity.action);
    QVERIFY(action != nullptr);
    QCOMPARE(*action, HistoryFilterAction::workspace);
    QCOMPARE(identity.generation, generation);
    const auto *workspace = chipFor(*filters, QStringLiteral("workspace"));
    QVERIFY(workspace != nullptr);
    const auto verify_bounds = [&] {
      const auto bounds = workspace->mapRectToScene(workspace->boundingRect());
      const auto scale = window.effectiveDevicePixelRatio();
      QCOMPARE(targets[1].bounds.x, static_cast<float>(bounds.x() * scale));
      QCOMPARE(targets[1].bounds.y, static_cast<float>(bounds.y() * scale));
      QCOMPARE(targets[1].bounds.width, static_cast<float>(bounds.width() * scale));
      QCOMPARE(targets[1].bounds.height, static_cast<float>(bounds.height() * scale));
    };
    verify_bounds();
    const auto previous_width = targets[1].bounds.width;
    const auto failed_identity = targets[4].identity;
    state.insert(QStringLiteral("effectiveScope"), QStringLiteral("workspace"));
    state.insert(QStringLiteral("scopeValue"), QStringLiteral("workspace detail"));
    state.insert(QStringLiteral("author"), QStringLiteral("agent"));
    state.insert(QStringLiteral("failedOnly"), true);
    filters->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT((layout->hoverTargets(generation, targets) == targets.size() && targets[1].bounds.width > previous_width), wait_ms);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    QCOMPARE(targets[1].identity, identity);
    QCOMPARE(targets[4].identity, failed_identity);
    verify_bounds();
    filters->setEnabled(false);
    QCOMPARE(layout->hoverTargets(generation, targets), targets.size());
    QCOMPARE(layout->hoverTargets(generation, std::span{targets}.first(1)), std::size_t{1});
    QCOMPARE(layout->hoverTargets(generation, {}), std::size_t{0});
    filters->setWidth(narrow_width);
    constexpr std::size_t scope_count = 4;
    QTRY_COMPARE_WITH_TIMEOUT(layout->hoverTargets(generation, targets), scope_count, wait_ms);
    filters->setVisible(false);
    QCOMPARE(layout->hoverTargets(generation, targets), std::size_t{0});
  }

  Q_SLOT static void filtersWorkWithoutAnApplicationController() {
    QQuickWindow window;
    QQmlEngine engine;
    auto filters = createChrome(engine, QStringLiteral("HistoryFilters"), {
                                                                              {QStringLiteral("state"), historyState()},
                                                                              {QStringLiteral("colors"), themeColors({})},
                                                                              {QStringLiteral("pixelSize"), small_pixels},
                                                                              {QStringLiteral("grid"), historyTypography().value(QStringLiteral("grid"))},
                                                                              {QStringLiteral("width"), wide_width},
                                                                              {QStringLiteral("height"), header_height},
                                                                          });
    filters->setParentItem(window.contentItem());
    window.resize(wide_width, header_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    followWindowSize(*filters, window);
    const auto *workspace = chipFor(*filters, QStringLiteral("workspace"));
    const auto *agent = chipFor(*filters, QStringLiteral("agent"));
    const auto *all = chipFor(*filters, QStringLiteral("global"));
    QVERIFY(workspace != nullptr && agent != nullptr && all != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(workspace->width() > 0 && agent->isVisible(), wait_ms);
    const QSignalSpy scopes{filters.get(), SIGNAL(scopeSelected(QString))};
    const QSignalSpy authors{filters.get(), SIGNAL(authorSelected(QString))};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, workspace->mapToScene(QPointF{workspace->width() / 2, workspace->height() / 2}).toPoint());
    QCOMPARE(scopes.size(), 1);
    QCOMPARE(scopes.front().front().toString(), QStringLiteral("workspace"));
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, agent->mapToScene(QPointF{agent->width() / 2, agent->height() / 2}).toPoint());
    QCOMPARE(authors.size(), 1);
    QCOMPARE(authors.front().front().toString(), QStringLiteral("agent"));
    QVERIFY(all->property("selected").toBool());
    auto state = historyState();
    state.insert(QStringLiteral("effectiveScope"), QStringLiteral("workspace"));
    filters->setProperty("state", state);
    QVERIFY(workspace->property("selected").toBool());
    QVERIFY(!all->property("selected").toBool());
    window.resize(narrow_width, header_height);
    QTRY_COMPARE_WITH_TIMEOUT(filters->width(), qreal{narrow_width}, wait_ms);
    const auto *author_group = filters->findChild<QQuickItem *>(QStringLiteral("historyAuthor"));
    QVERIFY(author_group != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!author_group->isVisible(), wait_ms);
  }

  Q_SLOT static void filtersShowTheSelectedScopeValueAndKeyHints() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyState();
    state.insert(QStringLiteral("effectiveScope"), QStringLiteral("workspace"));
    state.insert(QStringLiteral("scopeValue"), QStringLiteral("project"));
    state.insert(QStringLiteral("macStyle"), true);
    auto filters = createChrome(engine, QStringLiteral("HistoryFilters"), {
                                                                              {QStringLiteral("state"), state},
                                                                              {QStringLiteral("colors"), themeColors({})},
                                                                              {QStringLiteral("pixelSize"), small_pixels},
                                                                              {QStringLiteral("grid"), historyTypography().value(QStringLiteral("grid"))},
                                                                              {QStringLiteral("width"), wide_width},
                                                                              {QStringLiteral("height"), header_height},
                                                                          });
    filters->setParentItem(window.contentItem());
    window.resize(wide_width, header_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    const auto values = visualItems(*filters, QStringLiteral("historyScopeValue"));
    QVERIFY(!values.isEmpty());
    const auto selected = std::ranges::find_if(values, [](const auto *value) {
      return value->isVisible() && value->property("text").toString() == QStringLiteral("project");
    });
    QVERIFY(selected != values.end());
    const auto keys = visualItems(*filters, QStringLiteral("historyFilterKey"));
    constexpr qsizetype key_count = 3;
    QCOMPARE(keys.size(), key_count);
    for (const auto *key : keys) {
      QVERIFY(key->isVisible());
    }

    const auto *workspace = chipFor(*filters, QStringLiteral("workspace"));
    QVERIFY(workspace != nullptr);
    state.insert(QStringLiteral("effectiveScope"), QStringLiteral("cwd"));
    state.insert(QStringLiteral("scopeValue"), QStringLiteral("/work/project"));
    state.insert(QStringLiteral("macStyle"), false);
    filters->setProperty("state", state);
    QCOMPARE(chipFor(*filters, QStringLiteral("workspace")), workspace);
    QVERIFY(!workspace->property("selected").toBool());
    const auto changed_values = visualItems(*filters, QStringLiteral("historyScopeValue"));
    qsizetype visible_values = 0;
    for (const auto *value : changed_values) {
      if (value->isVisible()) {
        ++visible_values;
        QCOMPARE(value->property("text").toString(), QStringLiteral("/work/project"));
      }
    }
    QCOMPARE(visible_values, qsizetype{1});
    QStringList key_labels;
    for (const auto *key : keys) {
      key_labels.append(key->property("text").toString());
    }
    QVERIFY(key_labels.contains(QStringLiteral("Tab")));
    QVERIFY(key_labels.contains(QStringLiteral("Shift+Tab")));
    QVERIFY(key_labels.contains(QStringLiteral("!")));
  }

  Q_SLOT static void filtersHideKeyHintsBeforeTheRightControls() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyState();
    state.insert(QStringLiteral("macStyle"), true);
    auto filters = createChrome(engine, QStringLiteral("HistoryFilters"), {
                                                                              {QStringLiteral("state"), state},
                                                                              {QStringLiteral("colors"), themeColors({})},
                                                                              {QStringLiteral("pixelSize"), small_pixels},
                                                                              {QStringLiteral("grid"), historyTypography().value(QStringLiteral("grid"))},
                                                                              {QStringLiteral("width"), wide_width},
                                                                              {QStringLiteral("height"), header_height},
                                                                          });
    filters->setParentItem(window.contentItem());
    window.resize(wide_width, header_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    followWindowSize(*filters, window);
    const auto layout = [&filters] {
      return filters->property("layout").toMap();
    };
    QTRY_VERIFY_WITH_TIMEOUT(layout().value(QStringLiteral("showKeys")).toBool(), wait_ms);
    constexpr int controls_only_width = 500;
    window.resize(controls_only_width, header_height);
    QTRY_VERIFY_WITH_TIMEOUT(!layout().value(QStringLiteral("showKeys")).toBool(), wait_ms);
    QVERIFY(layout().value(QStringLiteral("showRight")).toBool());
    const auto *failed = filters->findChild<QQuickItem *>(QStringLiteral("historyFailedOnly"));
    QVERIFY(failed != nullptr && failed->isVisible());
    const QSignalSpy toggled{filters.get(), SIGNAL(failedToggled())};
    const auto point = failed->mapToScene(QPointF{failed->width() / 2, failed->height() / 2}).toPoint();
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, point);
    window.resize(narrow_width, header_height);
    QTRY_VERIFY_WITH_TIMEOUT(!layout().value(QStringLiteral("showRight")).toBool(), wait_ms);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, QPoint{narrow_width / 2, header_height / 2});
    QCOMPARE(toggled.size(), 0);
    const auto *scope_group = filters->findChild<QQuickItem *>(QStringLiteral("historyScope"));
    QVERIFY(scope_group != nullptr && scope_group->isVisible());
    window.resize(wide_width, header_height);
    QTRY_VERIFY_WITH_TIMEOUT(layout().value(QStringLiteral("showKeys")).toBool(), wait_ms);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, failed->mapToScene(QPointF{failed->width() / 2, failed->height() / 2}).toPoint());
    QCOMPARE(toggled.size(), 1);
  }

  Q_SLOT static void searchControlsKeepTheInputBetweenTheIconAndCloseAction() {
    QQuickWindow window;
    QQmlEngine engine;
    auto search = createChrome(engine, QStringLiteral("HistorySearchBar"), {
                                                                               {QStringLiteral("colors"), themeColors({})},
                                                                               {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), body_pixels}, {QStringLiteral("small"), small_pixels}, {QStringLiteral("primaryFamily"), QStringLiteral("JetBrains Mono")}, {QStringLiteral("primaryStyle"), QString{}}}},
                                                                               {QStringLiteral("width"), wide_width},
                                                                               {QStringLiteral("height"), search_height},
                                                                           });
    search->setParentItem(window.contentItem());
    window.resize(wide_width, search_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    followWindowSize(*search, window);
    const auto *field = search->findChild<QQuickItem *>(QStringLiteral("historySearchHost"));
    const auto *close = search->findChild<QQuickItem *>(QStringLiteral("historyClose"));
    QVERIFY(field != nullptr && close != nullptr);
    constexpr qreal expected_field_left = 44;
    constexpr qreal expected_gap = 10;
    QCOMPARE(field->x(), expected_field_left);
    QCOMPARE(field->x() + field->width(), close->x() - expected_gap);
    QCOMPARE(field->height(), static_cast<qreal>(search_height));
    const QSignalSpy cancelled{search.get(), SIGNAL(cancelled())};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, close->mapToScene(QPointF{close->width() / 2, close->height() / 2}).toPoint());
    QCOMPARE(cancelled.size(), 1);
    window.resize(narrow_width, search_height);
    QTRY_COMPARE_WITH_TIMEOUT(search->width(), qreal{narrow_width}, wait_ms);
    QVERIFY(field->width() > 0);
    QCOMPARE(field->x() + field->width(), close->x() - expected_gap);
  }

  Q_SLOT static void rowsFitFactsAndSelectWithoutAnApplicationController() {
    SystemAllocator memory;
    HistoryRow<SystemAllocator> entry{memory};
    entry.command = "make test\nnext command";
    entry.cwd = "/work/project";
    entry.provider = "custom-agent";
    entry.author = telar::HistoryAuthor::agent;
    entry.exit_code = 1;
    constexpr std::int64_t two_days_ms = 2 * HistoryLabels::seconds_per_day * HistoryLabels::milliseconds_per_second;
    auto record = historyRecord(entry, {.now_ms = two_days_ms});
    QCOMPARE(record.value(QStringLiteral("providerLetter")).toString(), QStringLiteral("C"));
    const auto colors = themeColors({});
    QQuickWindow window;
    QQmlEngine engine;
    auto row = createChrome(engine, QStringLiteral("HistoryRow"), {
                                                                      {QStringLiteral("record"), record},
                                                                      {QStringLiteral("colors"), colors},
                                                                      {QStringLiteral("typography"), historyTypography()},
                                                                      {QStringLiteral("rowHeight"), row_height},
                                                                      {QStringLiteral("width"), wide_width},
                                                                      {QStringLiteral("height"), row_height},
                                                                  });
    row->setParentItem(window.contentItem());
    window.resize(wide_width, row_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    followWindowSize(*row, window);
    const auto *command = visualItems(*row, QStringLiteral("historyRowCommand")).value(0);
    const auto *directory = row->findChild<QQuickItem *>(QStringLiteral("historyDirectory"));
    const auto *timestamp = row->findChild<QQuickItem *>(QStringLiteral("historyTimestamp"));
    const auto *status = row->findChild<QQuickItem *>(QStringLiteral("historyStatus"));
    const auto *continuation = visualItems(*row, QStringLiteral("historyContinuation")).value(0);
    QVERIFY(command != nullptr && directory != nullptr && timestamp != nullptr && status != nullptr && continuation != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(command->width() > 0 && directory->isVisible() && timestamp->isVisible(), wait_ms);
    QCOMPARE(command->property("text").toString(), QStringLiteral("make test"));
    QCOMPARE(command->property("color").value<QColor>(), colors.value(QStringLiteral("text")).value<QColor>());
    QCOMPARE(status->property("color").value<QColor>(), colors.value(QStringLiteral("red")).value<QColor>());
    QCOMPARE(continuation->property("text").toString(), QStringLiteral("↵"));
    QVERIFY(continuation->isVisible());
    const QSignalSpy activated{row.get(), SIGNAL(activated(QString))};
    const auto position = command->mapToScene(QPointF{command->width() / 2, command->height() / 2}).toPoint();
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, position);
    QCOMPARE(activated.size(), 1);
    row->setProperty("grouped", false);
    QCOMPARE(timestamp->property("text").toString(), record.value(QStringLiteral("date")).toString());
    window.resize(fact_limited_width, row_height);
    QTRY_COMPARE_WITH_TIMEOUT(row->width(), qreal{fact_limited_width}, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(!directory->isVisible() && !timestamp->isVisible(), wait_ms);
    const auto *provider = row->findChild<QQuickItem *>(QStringLiteral("historyProvider"));
    QVERIFY(provider != nullptr && provider->isVisible());
    record.insert(QStringLiteral("command"), QString(wide_width, QLatin1Char{'x'}));
    row->setProperty("record", record);
    QTRY_COMPARE_WITH_TIMEOUT(continuation->property("text").toString(), QStringLiteral("…"), wait_ms);
    QVERIFY(continuation->x() + continuation->width() <= row->width());
  }

  Q_SLOT static void rowsRetireGesturesWhenTheContentRevisionChanges() {
    SystemAllocator memory;
    HistoryRow<SystemAllocator> entry{memory};
    entry.command = "first command";
    auto record = historyRecord(entry, {});
    QQuickWindow window;
    QQmlEngine engine;
    auto row = createChrome(engine, QStringLiteral("HistoryRow"), {
                                                                      {QStringLiteral("record"), record},
                                                                      {QStringLiteral("colors"), themeColors({})},
                                                                      {QStringLiteral("typography"), historyTypography()},
                                                                      {QStringLiteral("revision"), QStringLiteral("9007199254740993")},
                                                                      {QStringLiteral("rowHeight"), row_height},
                                                                      {QStringLiteral("width"), wide_width},
                                                                      {QStringLiteral("height"), row_height},
                                                                  });
    row->setParentItem(window.contentItem());
    window.resize(wide_width, row_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    const auto center = QPoint{wide_width / 2, row_height / 2};
    const QSignalSpy activated{row.get(), SIGNAL(activated(QString))};
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    record.insert(QStringLiteral("command"), QStringLiteral("replacement command"));
    row->setProperty("record", record);
    row->setProperty("revision", QStringLiteral("9007199254740994"));
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 0);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 1);
    QCOMPARE(activated.back().front().toString(), QStringLiteral("9007199254740994"));
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    row->setProperty("interactive", false);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 1);
  }

  Q_SLOT static void selectedCardsShowEveryExplicitCommandLine() {
    SystemAllocator memory;
    HistoryRow<SystemAllocator> entry{memory};
    entry.command = "first command\nsecond command\nthird command";
    const auto record = historyRecord(entry, {});
    constexpr int card_height = 300;
    QQuickWindow window;
    QQmlEngine engine;
    auto row = createChrome(engine, QStringLiteral("HistoryRow"), {
                                                                      {QStringLiteral("record"), record},
                                                                      {QStringLiteral("colors"), themeColors({})},
                                                                      {QStringLiteral("typography"), historyTypography()},
                                                                      {QStringLiteral("rowHeight"), row_height},
                                                                      {QStringLiteral("expanded"), true},
                                                                      {QStringLiteral("selected"), true},
                                                                      {QStringLiteral("width"), wide_width},
                                                                      {QStringLiteral("height"), card_height},
                                                                  });
    row->setParentItem(window.contentItem());
    window.resize(wide_width, card_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    followWindowSize(*row, window);
    const auto command_lines = [&] {
      auto labels = visualItems(*row, QStringLiteral("historyRowCommand"));
      labels.removeIf([](const auto *item) {
        return !item->isVisible();
      });

      return labels;
    };
    constexpr qsizetype expected_lines = 3;
    QTRY_COMPARE_WITH_TIMEOUT(command_lines().size(), expected_lines, wait_ms);
    QStringList shown;
    for (const auto *line : command_lines()) {
      shown.append(line->property("text").toString());
    }

    QVERIFY(shown.contains(QStringLiteral("first command")));
    QVERIFY(shown.contains(QStringLiteral("second command")));
    QVERIFY(shown.contains(QStringLiteral("third command")));
    constexpr qreal minimum_card_height = row_height + (expected_lines * cell_height);
    QVERIFY(row->implicitHeight() > minimum_card_height);
    QVERIFY(row->implicitHeight() < card_height);
    row->setProperty("query", QStringLiteral("cS"));
    constexpr qsizetype expected_matches = 2;
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*row, QStringLiteral("historyMatch")).size(), expected_matches, wait_ms);
    const auto matches = visualItems(*row, QStringLiteral("historyMatch"));
    QVERIFY(matches.front()->y() != matches.back()->y());
    constexpr int short_viewport = 100;
    row->setProperty("viewportHeight", short_viewport);
    QTRY_COMPARE_WITH_TIMEOUT(command_lines().size(), qsizetype{1}, wait_ms);
    QCOMPARE(row->property("layout").toMap().value(QStringLiteral("more")).toInt(), 2);
    const auto *details = row->findChild<QQuickItem *>(QStringLiteral("historyRowDetails"));
    QVERIFY(details != nullptr);
    QVERIFY(details->property("text").toString().contains(QStringLiteral("+2 more lines")));
  }

  Q_SLOT static void runningCardsNameTheirOutcome() {
    SystemAllocator memory;
    HistoryRow<SystemAllocator> entry{memory};
    entry.command = "sleep 10";
    entry.status = telar::HistoryStatus::running;
    const auto record = historyRecord(entry, {});
    QQuickWindow window;
    QQmlEngine engine;
    constexpr int card_height = 100;
    auto row = createChrome(engine, QStringLiteral("HistoryRow"), {
                                                                      {QStringLiteral("record"), record},
                                                                      {QStringLiteral("colors"), themeColors({})},
                                                                      {QStringLiteral("typography"), historyTypography()},
                                                                      {QStringLiteral("rowHeight"), row_height},
                                                                      {QStringLiteral("expanded"), true},
                                                                      {QStringLiteral("selected"), true},
                                                                      {QStringLiteral("width"), wide_width},
                                                                      {QStringLiteral("height"), card_height},
                                                                  });
    row->setParentItem(window.contentItem());
    window.resize(wide_width, card_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    const auto *details = row->findChild<QQuickItem *>(QStringLiteral("historyRowDetails"));
    QVERIFY(details != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(details->property("text").toString().contains(QStringLiteral("running")), wait_ms);
  }

  Q_SLOT static void metadataActionsWorkWithoutAnApplicationController() {
    constexpr int metadata_height = 28;
    const QVariantMap record{
        {QStringLiteral("status"), static_cast<int>(telar::HistoryStatus::completed)},
        {QStringLiteral("duration"), QStringLiteral("1.2s")},
        {QStringLiteral("timestamp"), -1},
    };
    QQuickWindow window;
    QQmlEngine engine;
    auto metadata = createChrome(engine, QStringLiteral("HistoryMeta"), {
                                                                            {QStringLiteral("record"), record},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("paneOpen"), true},
                                                                            {QStringLiteral("macStyle"), true},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), metadata_height},
                                                                        });
    metadata->setParentItem(window.contentItem());
    window.resize(wide_width, metadata_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    const auto action_count = [&] {
      return metadata->property("layout").toMap().value(QStringLiteral("actionCount")).toInt();
    };
    constexpr int all_actions = 3;
    constexpr int pane_closed_actions = 2;
    QTRY_COMPARE_WITH_TIMEOUT(action_count(), all_actions, wait_ms);
    const QSignalSpy activated{metadata.get(), SIGNAL(actionTriggered(QString))};
    auto hints = visualItems(*metadata, QStringLiteral("historyHint"));
    std::ranges::sort(hints, [](const auto *left, const auto *right) {
      return left->x() < right->x();
    });
    QCOMPARE(hints.size(), all_actions);
    const QStringList expected_actions{QStringLiteral("copy"), QStringLiteral("erase"), QStringLiteral("visit")};
    const QStringList expected_keys{QStringLiteral("⌘C"), QStringLiteral("⌘⌫"), QStringLiteral("⌥↩")};
    for (qsizetype index = 0; index < hints.size(); ++index) {
      const auto *hint = hints[index];
      QCOMPARE(hint->property("label").toMap().value(QStringLiteral("key")).toString(), expected_keys[index]);
      const auto center = hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint();
      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
      QCOMPARE(activated.size(), index + 1);
      QCOMPARE(activated.back().front().toString(), expected_actions[index]);
    }

    metadata->setProperty("interactive", false);
    const auto *first = hints.front();
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, first->mapToScene(QPointF{first->width() / 2, first->height() / 2}).toPoint());
    QCOMPARE(activated.size(), all_actions);
    metadata->setProperty("paneOpen", false);
    QTRY_COMPARE_WITH_TIMEOUT(action_count(), pane_closed_actions, wait_ms);
    constexpr int actionless_width = 160;
    metadata->setWidth(actionless_width);
    QTRY_COMPARE_WITH_TIMEOUT(action_count(), 0, wait_ms);
    metadata->setProperty("selected", false);
    QTRY_COMPARE_WITH_TIMEOUT(action_count(), 0, wait_ms);
  }

  Q_SLOT static void metadataRefreshesWhenTheSelectedCommandChanges() {
    SystemAllocator memory;
    HistoryRow<SystemAllocator> entry{memory};
    entry.command = "failed command";
    entry.cwd = "/work/project";
    entry.provider = "custom-agent";
    entry.author = telar::HistoryAuthor::agent;
    entry.exit_code = 1;
    constexpr int metadata_height = 28;
    QQuickWindow window;
    QQmlEngine engine;
    auto metadata = createChrome(engine, QStringLiteral("HistoryMeta"), {
                                                                            {QStringLiteral("record"), historyRecord(entry, {})},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("selected"), false},
                                                                            {QStringLiteral("more"), 1},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), metadata_height},
                                                                        });
    metadata->setParentItem(window.contentItem());
    window.resize(wide_width, metadata_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    QTRY_VERIFY_WITH_TIMEOUT(metadata->property("text").toString().contains(QStringLiteral("custom-agent")), wait_ms);
    entry.cwd.clear();
    entry.author = telar::HistoryAuthor::human;
    entry.status = telar::HistoryStatus::running;
    entry.started_at_ms = -1;
    metadata->setProperty("more", 0);
    metadata->setProperty("record", historyRecord(entry, {}));
    QTRY_COMPARE_WITH_TIMEOUT(metadata->property("text").toString(), QStringLiteral("running"), wait_ms);
    const auto labels = metadata->property("facts").toList();
    QCOMPARE(labels.size(), 1);
    QCOMPARE(labels.front().toMap().value(QStringLiteral("color")).toString(), QStringLiteral("teal"));
    metadata->setProperty("commandLoaded", false);
    QTRY_VERIFY_WITH_TIMEOUT(metadata->property("text").toString().startsWith(QStringLiteral("loading the complete command…")), wait_ms);
    entry.command_truncated = true;
    metadata->setProperty("record", historyRecord(entry, {}));
    QTRY_VERIFY_WITH_TIMEOUT(metadata->property("text").toString().startsWith(QStringLiteral("capture cut short, cannot paste")), wait_ms);
    QCOMPARE(metadata->property("facts").toList().front().toMap().value(QStringLiteral("color")).toString(), QStringLiteral("yellow"));
  }

  Q_SLOT static void footerHoverTargetsPreserveChoicePrecisionAndRenderedBounds() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    constexpr auto revision = std::numeric_limits<std::uint64_t>::max();
    constexpr std::uint64_t generation = 41;
    state.insert(QStringLiteral("revision"), QString::number(revision));
    state.insert(QStringLiteral("selection"), 2);
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
        {QStringLiteral("state"), state},
        {QStringLiteral("colors"), themeColors({})},
        {QStringLiteral("pixelSize"), small_pixels},
        {QStringLiteral("width"), wide_width},
        {QStringLiteral("height"), footer_height},
    });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    const auto *layout = qobject_cast<HistoryFooterLayout *>(footer.get());
    QVERIFY(layout != nullptr);
    std::array<HistoryHoverTarget, HistoryFooter::capacity> targets;
    constexpr std::size_t browse_count = 3;
    QTRY_COMPARE_WITH_TIMEOUT(layout->hoverTargets(generation, targets), browse_count, wait_ms);
    const auto *submit = std::get_if<HistoryFooterIdentity>(&targets.front().identity.action);
    QVERIFY(submit != nullptr);
    QCOMPARE(submit->action, HistoryFooterAction::submit);
    QCOMPARE(submit->choice.revision, revision);
    QCOMPARE(submit->choice.index, std::size_t{2});
    QCOMPARE(targets.front().identity.generation, generation);
    const auto *hint = hintForAction(*footer, QStringLiteral("submit"));
    QVERIFY(hint != nullptr);
    const auto bounds = hint->mapRectToScene(hint->boundingRect());
    const auto scale = window.effectiveDevicePixelRatio();
    QCOMPARE(targets.front().bounds.x, static_cast<float>(bounds.x() * scale));
    QCOMPARE(targets.front().bounds.y, static_cast<float>(bounds.y() * scale));
    QCOMPARE(targets.front().bounds.width, static_cast<float>(bounds.width() * scale));
    QCOMPARE(targets.front().bounds.height, static_cast<float>(bounds.height() * scale));
    const auto identity = targets.front().identity;
    state.insert(QStringLiteral("enterRuns"), true);
    footer->setProperty("state", state);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    QCOMPARE(layout->hoverTargets(generation, targets), browse_count);
    QCOMPARE(targets.front().identity, identity);
    state.insert(QStringLiteral("selection"), 3);
    state.insert(QStringLiteral("revision"), QString::number(revision - 1));
    footer->setProperty("state", state);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    QCOMPARE(layout->hoverTargets(generation, targets), browse_count);
    QVERIFY(targets.front().identity != identity);
    submit = std::get_if<HistoryFooterIdentity>(&targets.front().identity.action);
    QVERIFY(submit != nullptr);
    QCOMPARE(submit->choice.revision, revision - 1);
    QCOMPARE(submit->choice.index, std::size_t{3});
  }

  Q_SLOT static void footerHoverTargetsRespectAbsenceAndKeepDisabledIdentities() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
        {QStringLiteral("state"), state},
        {QStringLiteral("colors"), themeColors({})},
        {QStringLiteral("pixelSize"), small_pixels},
        {QStringLiteral("width"), wide_width},
        {QStringLiteral("height"), footer_height},
    });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    const auto *layout = qobject_cast<HistoryFooterLayout *>(footer.get());
    QVERIFY(layout != nullptr);
    std::array<HistoryHoverTarget, HistoryFooter::capacity> targets;
    constexpr std::size_t actions = 3;
    constexpr std::uint64_t generation = 41;
    QTRY_COMPARE_WITH_TIMEOUT(layout->hoverTargets(generation, targets), actions, wait_ms);
    footer->setProperty("interactive", false);
    QCOMPARE(layout->hoverTargets(generation, targets), actions);
    QCOMPARE(layout->hoverTargets(generation, std::span{targets}.first(1)), std::size_t{1});
    state.insert(QStringLiteral("inspecting"), true);
    footer->setProperty("state", state);
    QVERIFY(waitForSynchronizedFrame(window, wait_ms));
    QCOMPARE(layout->hoverTargets(generation, targets), actions);
    const auto *visit = std::get_if<HistoryFooterIdentity>(&targets[actions - 1].identity.action);
    QVERIFY(visit != nullptr);
    QCOMPARE(visit->action, HistoryFooterAction::visit);
    state.insert(QStringLiteral("error"), QStringLiteral("fixture failure"));
    footer->setProperty("state", state);
    QTRY_COMPARE_WITH_TIMEOUT(layout->hoverTargets(generation, targets), std::size_t{0}, wait_ms);
    footer->setVisible(false);
    QCOMPARE(layout->hoverTargets(generation, targets), std::size_t{0});
  }

  Q_SLOT static void footerActionsNeedNoApplicationController() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
                                                                            {QStringLiteral("state"), state},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), footer_height},
                                                                        });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    QTRY_VERIFY_WITH_TIMEOUT(hintForAction(*footer, QStringLiteral("inspect")) != nullptr, wait_ms);
    const QSignalSpy activated{footer.get(), SIGNAL(actionTriggered(QString, QString))};
    qsizetype delivered = 0;
    for (const auto &action : {QStringLiteral("submit"), QStringLiteral("alternate"), QStringLiteral("inspect")}) {
      const auto *hint = hintForAction(*footer, action);
      QVERIFY(hint != nullptr);
      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint());
      ++delivered;
      QCOMPARE(activated.size(), delivered);
      QCOMPARE(activated.back().front().toString(), action);
    }

    constexpr int browse_actions = 3;
    QCOMPARE(activated.size(), browse_actions);
    state.insert(QStringLiteral("inspecting"), true);
    footer->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(hintForAction(*footer, QStringLiteral("visit")) != nullptr, wait_ms);
    const auto *scroll = hintForAction(*footer, QStringLiteral("none"));
    QVERIFY(scroll != nullptr && !scroll->property("actionable").toBool());
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, scroll->mapToScene(QPointF{scroll->width() / 2, scroll->height() / 2}).toPoint());
    QCOMPARE(activated.size(), browse_actions);
    const auto *visit = hintForAction(*footer, QStringLiteral("visit"));
    QVERIFY(visit != nullptr);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, visit->mapToScene(QPointF{visit->width() / 2, visit->height() / 2}).toPoint());
    constexpr int inspect_actions = 4;
    QCOMPARE(activated.size(), inspect_actions);
    QCOMPARE(activated.back().front().toString(), QStringLiteral("visit"));
    footer->setProperty("interactive", false);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, visit->mapToScene(QPointF{visit->width() / 2, visit->height() / 2}).toPoint());
    QCOMPARE(activated.size(), inspect_actions);
  }

  Q_SLOT static void footerCancelsPressesWhenTheChoiceChanges() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    state.insert(QStringLiteral("revision"), QStringLiteral("18446744073709551610"));
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
                                                                            {QStringLiteral("state"), state},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), footer_height},
                                                                        });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    QTRY_VERIFY_WITH_TIMEOUT(hintForAction(*footer, QStringLiteral("submit")) != nullptr, wait_ms);
    const auto *hint = hintForAction(*footer, QStringLiteral("submit"));
    const auto center = hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint();
    const QSignalSpy activated{footer.get(), SIGNAL(actionTriggered(QString, QString))};
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    state.insert(QStringLiteral("revision"), QStringLiteral("18446744073709551611"));
    footer->setProperty("state", state);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 0);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 1);
    QCOMPARE(activated.back().back().toString(), state.value(QStringLiteral("revision")).toString());
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    state.insert(QStringLiteral("enterRuns"), true);
    footer->setProperty("state", state);
    state.insert(QStringLiteral("enterRuns"), false);
    footer->setProperty("state", state);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 1);
  }

  Q_SLOT static void footerKeepsSemanticActionsAcrossSelectionRevisions() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    state.insert(QStringLiteral("revision"), QStringLiteral("100"));
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
                                                                            {QStringLiteral("state"), state},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), footer_height},
                                                                        });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    QTRY_VERIFY_WITH_TIMEOUT(hintForAction(*footer, QStringLiteral("inspect")) != nullptr, wait_ms);
    const auto *hint = hintForAction(*footer, QStringLiteral("inspect"));
    const auto center = hint->mapToScene(QPointF{hint->width() / 2, hint->height() / 2}).toPoint();
    const QSignalSpy activated{footer.get(), SIGNAL(actionTriggered(QString, QString))};
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, center);
    state.insert(QStringLiteral("revision"), QStringLiteral("101"));
    footer->setProperty("state", state);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, center);
    QCOMPARE(activated.size(), 1);
    QCOMPARE(activated.back().front().toString(), QStringLiteral("inspect"));
  }

  Q_SLOT static void footerFitsRangesAndReplacesControlsWithErrors() {
    QQuickWindow window;
    QQmlEngine engine;
    auto state = historyFooterState();
    auto footer = createChrome(engine, QStringLiteral("HistoryFooter"), {
                                                                            {QStringLiteral("state"), state},
                                                                            {QStringLiteral("colors"), themeColors({})},
                                                                            {QStringLiteral("pixelSize"), small_pixels},
                                                                            {QStringLiteral("width"), wide_width},
                                                                            {QStringLiteral("height"), footer_height},
                                                                        });
    footer->setParentItem(window.contentItem());
    window.resize(wide_width, footer_height);
    QVERIFY(showComponentWindow(window, wait_ms));
    QVERIFY(QTest::qWaitForWindowExposed(&window));
    followWindowSize(*footer, window);
    const auto *range = footer->findChild<QQuickItem *>(QStringLiteral("historyRange"));
    const auto *error = footer->findChild<QQuickItem *>(QStringLiteral("historyFooterError"));
    QVERIFY(range != nullptr && error != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(range->isVisible(), wait_ms);
    QCOMPARE(range->property("text").toString(), QStringLiteral("257–268  ·  ⇞ older  ·  fuzzy"));
    constexpr int constrained_width = 180;
    window.resize(constrained_width, footer_height);
    QTRY_COMPARE_WITH_TIMEOUT(footer->width(), qreal{constrained_width}, wait_ms);
    constexpr int browse_hints = 3;
    QTRY_VERIFY_WITH_TIMEOUT(footer->property("layout").toMap().value(QStringLiteral("hintCount")).toInt() < browse_hints, wait_ms);
    QVERIFY(!range->isVisible());
    window.resize(wide_width, footer_height);
    state.insert(QStringLiteral("count"), 0);
    footer->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(!range->isVisible(), wait_ms);
    state.insert(QStringLiteral("error"), QStringLiteral("The selected command is not loaded; cannot paste"));
    footer->setProperty("state", state);
    QTRY_VERIFY_WITH_TIMEOUT(error->isVisible(), wait_ms);
    QCOMPARE(error->property("text").toString(), state.value(QStringLiteral("error")).toString());
    QCOMPARE(footer->property("layout").toMap().value(QStringLiteral("hintCount")).toInt(), 0);
    state.insert(QStringLiteral("error"), QString{});
    state.insert(QStringLiteral("count"), 1);
    state.insert(QStringLiteral("inspecting"), true);
    footer->setProperty("state", state);
    constexpr int inspect_hints = 4;
    QTRY_COMPARE_WITH_TIMEOUT(footer->property("hints").toList().size(), inspect_hints, wait_ms);
    state.insert(QStringLiteral("inspecting"), false);
    state.insert(QStringLiteral("enterRuns"), true);
    footer->setProperty("state", state);
    QTRY_COMPARE_WITH_TIMEOUT(footer->property("hints").toList().size(), browse_hints, wait_ms);
    QCOMPARE(footer->property("hints").toList().front().toMap().value(QStringLiteral("word")).toString(), QStringLiteral("run"));
  }

  Q_SLOT static void inspectionScrollsTheWholeDocumentAndRetiresItsIdentity() {
    InspectionFixture fixture;
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    const auto layout = [&] {
      return fixture.item->property("layout").toMap();
    };
    QTRY_VERIFY_WITH_TIMEOUT(!layout().value(QStringLiteral("lines")).toList().isEmpty(), wait_ms);
    QCOMPARE(layout().value(QStringLiteral("lines")).toList().front().toMap().value(QStringLiteral("text")).toString(), QStringLiteral("echo inspection fixture"));
    QVERIFY(layout().value(QStringLiteral("maximumScroll")).toInt() > 0);
    QVERIFY(QMetaObject::invokeMethod(fixture.item.get(), "page", Q_ARG(QVariant, QVariant{false})));
    constexpr int page_lines = 10;
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->property("scroll").toInt(), page_lines, wait_ms);
    fixture.item->setProperty("scroll", std::numeric_limits<int>::max());
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->property("scroll").toInt(), layout().value(QStringLiteral("maximumScroll")).toInt(), wait_ms);
    fixture.item->setProperty("output", QString{});
    QTRY_VERIFY_WITH_TIMEOUT(fixture.item->property("scroll").toInt() < page_lines, wait_ms);
    fixture.item->setProperty("scroll", 1);
    auto details = inspectionDetails();
    details.insert(QStringLiteral("identity"), QStringLiteral("78"));
    fixture.item->setProperty("details", details);
    QCOMPARE(fixture.item->property("scroll").toInt(), 0);
    fixture.window.resize(narrow_width, InspectionFixture::height);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->width(), qreal{narrow_width}, wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(layout().value(QStringLiteral("lineCount")).toInt() > 0, wait_ms);
    const auto content = layout().value(QStringLiteral("content")).toRectF();
    for (const auto &value : layout().value(QStringLiteral("lines")).toList()) {
      const auto bounds = value.toMap().value(QStringLiteral("bounds")).toRectF();
      QVERIFY(content.contains(bounds));
    }
  }

  Q_SLOT static void inspectionActionsRetirePressedSelectionsAndModes() {
    InspectionFixture fixture;
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(inspectionAction(*fixture.item, QStringLiteral("submit")) != nullptr, wait_ms);
    auto *submit = inspectionAction(*fixture.item, QStringLiteral("submit"));
    const auto center = [&] {
      return submit->mapToScene(QPointF{submit->width() / 2, submit->height() / 2}).toPoint();
    };
    const QSignalSpy activated{fixture.item.get(), SIGNAL(actionTriggered(QString, QString))};
    QTest::mousePress(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    fixture.state.insert(QStringLiteral("revision"), QStringLiteral("78"));
    fixture.state.insert(QStringLiteral("selection"), 1);
    fixture.item->setProperty("browserState", fixture.state);
    QTest::mouseRelease(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    QCOMPARE(activated.size(), 0);
    QTest::mousePress(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    fixture.state.insert(QStringLiteral("enterRuns"), true);
    fixture.item->setProperty("browserState", fixture.state);
    QTest::mouseRelease(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    QCOMPARE(activated.size(), 0);
    QTest::mouseClick(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    QCOMPARE(activated.size(), 1);
    QCOMPARE(activated.front().front().toString(), QStringLiteral("submit"));
    QCOMPARE(activated.front().back().toString(), QStringLiteral("78"));
    QVERIFY(inspectionAction(*fixture.item, QStringLiteral("visit")) == nullptr);
    fixture.state.insert(QStringLiteral("paneOpen"), true);
    fixture.item->setProperty("browserState", fixture.state);
    QTRY_VERIFY_WITH_TIMEOUT(inspectionAction(*fixture.item, QStringLiteral("visit")) != nullptr, wait_ms);
    const auto *visit = inspectionAction(*fixture.item, QStringLiteral("visit"));
    const auto visit_center = visit->mapToScene(QPointF{visit->width() / 2, visit->height() / 2}).toPoint();
    QTest::mousePress(&fixture.window, Qt::LeftButton, Qt::NoModifier, visit_center);
    fixture.state.insert(QStringLiteral("paneOpen"), false);
    fixture.item->setProperty("browserState", fixture.state);
    QTest::mouseRelease(&fixture.window, Qt::LeftButton, Qt::NoModifier, visit_center);
    QTRY_VERIFY_WITH_TIMEOUT(inspectionAction(*fixture.item, QStringLiteral("visit")) == nullptr, wait_ms);
    QCOMPARE(activated.size(), 1);
    QTRY_VERIFY_WITH_TIMEOUT(inspectionAction(*fixture.item, QStringLiteral("submit")) != nullptr, wait_ms);
    submit = inspectionAction(*fixture.item, QStringLiteral("submit"));
    QTest::mouseClick(&fixture.window, Qt::LeftButton, Qt::NoModifier, center());
    QCOMPARE(activated.size(), 2);
    QCOMPARE(activated.back().front().toString(), QStringLiteral("submit"));
  }

  Q_SLOT static void inspectionAccumulatesFractionalWheelAndTrackpadInput() {
    InspectionFixture fixture;
    QVERIFY(showComponentWindow(fixture.window, wait_ms));
    QTRY_VERIFY_WITH_TIMEOUT(fixture.item->property("layout").toMap().value(QStringLiteral("maximumScroll")).toInt() > 0, wait_ms);
    const QPointF local{wide_width / 2.0, InspectionFixture::height / 2.0};
    const auto send = [&](QPoint pixels, QPoint angle, Qt::ScrollPhase phase) {
      const auto source = pixels.isNull() ? Qt::MouseEventNotSynthesized : Qt::MouseEventSynthesizedBySystem;
      QWheelEvent event{local, fixture.window.mapToGlobal(local.toPoint()), pixels, angle, Qt::NoButton, Qt::NoModifier, phase, false, source};
      QCoreApplication::sendEvent(&fixture.window, &event);

      return event.isAccepted();
    };
    constexpr int half_notch = 60;
    QVERIFY(send({}, {0, -half_notch}, Qt::ScrollBegin));
    QCOMPARE(fixture.item->property("scroll").toInt(), 0);
    QVERIFY(send({}, {0, -half_notch}, Qt::ScrollUpdate));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->property("scroll").toInt(), 1, wait_ms);
    QVERIFY(send({0, -cell_height / 2}, {0, -cell_height}, Qt::ScrollBegin));
    QCOMPARE(fixture.item->property("scroll").toInt(), 1);
    QVERIFY(send({0, -cell_height / 2}, {0, -cell_height}, Qt::ScrollUpdate));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->property("scroll").toInt(), 2, wait_ms);
    fixture.item->setProperty("interactive", false);
    QVERIFY(send({}, {0, -half_notch * 2}, Qt::NoScrollPhase));
    QCOMPARE(fixture.item->property("scroll").toInt(), 2);
    fixture.item->setProperty("interactive", true);
    QVERIFY(send({}, {0, half_notch * 2}, Qt::NoScrollPhase));
    QTRY_COMPARE_WITH_TIMEOUT(fixture.item->property("scroll").toInt(), 1, wait_ms);
  }


  Q_SLOT static void wheelMetadataKeepsStepAndPreciseUnitsSeparate() {
    constexpr int estimated_pixels = 20;
    constexpr int angle_notch = 120;
    constexpr double row_pixels = 40;
    const QPointF position{1, 1};
    constexpr qint64 mouse_device_id = 1;
    constexpr int single_point = 1;
    constexpr int no_buttons = 0;
    const QPointingDevice device{QStringLiteral("shared pointing device"), mouse_device_id, QInputDevice::DeviceType::Mouse, QPointingDevice::PointerType::Generic, QInputDevice::Capability::Position | QInputDevice::Capability::Scroll | QInputDevice::Capability::PixelScroll, single_point, no_buttons};
    const QWheelEvent mouse{position, position, {0, -estimated_pixels}, {0, -angle_notch}, Qt::NoButton, Qt::NoModifier, Qt::NoScrollPhase, false, Qt::MouseEventNotSynthesized, &device};
    const auto step = scrollSample(mouse, row_pixels);
    QVERIFY(!step.precise);
    QCOMPARE(step.delta, 1.0);
    const QWheelEvent trackpad{position, position, {0, -estimated_pixels}, {0, -angle_notch}, Qt::NoButton, Qt::NoModifier, Qt::ScrollBegin, false, Qt::MouseEventSynthesizedBySystem};
    const auto precise = scrollSample(trackpad, row_pixels);
    QVERIFY(precise.precise);
    QCOMPARE(precise.delta, static_cast<double>(estimated_pixels));
    WheelAccumulator accumulated;
    QCOMPARE(accumulated.consume(precise), 0);
    const QWheelEvent update{position, position, {0, -estimated_pixels}, {0, -angle_notch}, Qt::NoButton, Qt::NoModifier, Qt::ScrollUpdate, false, Qt::MouseEventSynthesizedBySystem};
    QCOMPARE(accumulated.consume(scrollSample(update, row_pixels)), 1);
  }

  Q_SLOT static void compatibilityBeginsPreserveTheNativeFraction() {
    const QPointF position{1, 1};
    constexpr int half_notch = 60;
    constexpr unsigned long gesture_time = 100;
    ScrollEventSequence sequence;
    WheelAccumulator accumulated;
    QWheelEvent begin{position, position, {}, {half_notch, half_notch}, Qt::NoButton, Qt::NoModifier, Qt::ScrollBegin, false};
    begin.setTimestamp(gesture_time);
    QVERIFY(!sequence.compatibilityEvent(begin));
    QCOMPARE(accumulated.consume(scrollSample(begin, cell_height)), 0);
    QWheelEvent compatibility{position, position, {}, {}, Qt::NoButton, Qt::NoModifier, Qt::ScrollBegin, false};
    compatibility.setTimestamp(gesture_time);
    QVERIFY(sequence.compatibilityEvent(compatibility));
    QWheelEvent update{position, position, {}, {half_notch, half_notch}, Qt::NoButton, Qt::NoModifier, Qt::ScrollUpdate, false};
    update.setTimestamp(gesture_time + 1);
    QVERIFY(!sequence.compatibilityEvent(update));
    QCOMPARE(accumulated.consume(scrollSample(update, cell_height)), -1);
    compatibility.setTimestamp(gesture_time + 2);
    QVERIFY(!sequence.compatibilityEvent(compatibility));
    QCOMPARE(accumulated.consume(scrollSample(compatibility, cell_height)), 0);
  }

};

}

QTEST_MAIN(HistoryControlsTest)
#include "history_controls_test.moc"
