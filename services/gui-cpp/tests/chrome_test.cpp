#include "application/records.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "graphics/store.hpp"
#include "presentation/application_mark.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include "presentation/workspace_mark.hpp"
#include "presentation/workspace_window.hpp"
#include "qml_fixture.hpp"
#include "qt/list_model.hpp"
#include "qt/projection.hpp"
#include "qt/provider_artwork.hpp"
#include "qt/provider_mark.hpp"
#include "qt/sidebar_projection.hpp"
#include "qt/tab_strip_layout.hpp"
#include "qt/typography_projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QGuiApplication>
#include <QImage>
#include <QList>
#include <QMetaMethod>
#include <QMetaObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QString>
#include <QTest>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>
#include <array>
#include <cstddef>
#include <memory>
#include <span>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using test::createChrome;
using test::visualItems;

constexpr int fixture_height = 932;
constexpr int fixture_sidebar_width = 280;
constexpr int fixture_rail_width = 52;
constexpr int fixture_wait_ms = 5'000;

QList<QVariantMap> tabRecords(WorkspaceWindow::Selection selection) {
  QList<QVariantMap> rows;
  for (std::size_t index = 0; index < selection.count; ++index) {
    rows.append({
        {QStringLiteral("key"), QStringLiteral("tab:%1").arg(index)},
        {QStringLiteral("label"), QStringLiteral("Terminal %1").arg(index)},
        {QStringLiteral("application"), QStringLiteral("sh")},
        {QStringLiteral("selected"), index == selection.active},
    });
  }

  return rows;
}

QVariantMap tabProperties(ListModel &tabs, int width) {
  const ChromeMetrics chrome;

  return {
      {QStringLiteral("width"), width},
      {QStringLiteral("height"), chrome.top_bar},
      {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&tabs))},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}}},
  };
}

QRectF tabBounds(const QAbstractItemModel &model, int row) {
  return model.data(model.index(row, 0), ListModel::record_role).toMap().value(QStringLiteral("bounds")).toRectF();
}

QList<QVariantMap> workspaceRecords(WorkspaceWindow::Selection selection) {
  QList<QVariantMap> rows;
  for (std::size_t index = 0; index < selection.count; ++index) {
    const auto name = QStringLiteral("project-%1").arg(index);
    const auto bytes = name.toUtf8();
    const auto mark = WorkspaceMark::resolve({bytes.constData(), static_cast<std::size_t>(bytes.size())});
    rows.append({
        {QStringLiteral("key"), QStringLiteral("workspace:%1").arg(index)},
        {QStringLiteral("name"), name},
        {QStringLiteral("path"), QStringLiteral("/projects/") + name},
        {QStringLiteral("selected"), selection.active == index},
        {QStringLiteral("initial"), toQString(mark.initial.view())},
        {QStringLiteral("markHue"), QString::fromLatin1(palette_names[static_cast<std::size_t>(mark.hue)])},
    });
  }

  return rows;
}

QVariantMap sidebarProperties(ListModel &workspaces, ListModel &agents, bool expanded, int selected) {
  const ChromeMetrics chrome;
  const auto width = expanded ? fixture_sidebar_width : fixture_rail_width;
  const Rect area{.width = static_cast<float>(width), .height = fixture_height};
  auto geometry = sidebarRegionsRecord(area, {.chrome = chrome}, static_cast<std::size_t>(workspaces.rowCount()));
  geometry.insert(QStringLiteral("rail"), workspaceRailRecord(workspaces, area, {.chrome = chrome}, selected));
  const QVariantMap typography{
      {QStringLiteral("body"), chrome.body},
      {QStringLiteral("small"), chrome.small},
      {QStringLiteral("bodyRow"), ChromeMetrics::lineHeight(chrome.body)},
      {QStringLiteral("smallRow"), ChromeMetrics::lineHeight(chrome.small)},
  };

  return {
      {QStringLiteral("width"), width},
      {QStringLiteral("height"), fixture_height},
      {QStringLiteral("expanded"), expanded},
      {QStringLiteral("preferredWidth"), fixture_sidebar_width},
      {QStringLiteral("regions"), geometry},
      {QStringLiteral("typography"), typography},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("workspaceModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&workspaces))},
      {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&agents))},
  };
}

class ChromeTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
  }

  Q_SLOT static void uncoveredLabelsKeepDimensions() {
    QQmlEngine engine;
    const ChromeMetrics chrome;
    const QVariantMap properties{{QStringLiteral("pixelSize"), chrome.body}, {QStringLiteral("text"), QStringLiteral("\u4e2d")}};
    const auto label = createChrome(engine, QStringLiteral("ChromeText"), properties);
    QTRY_VERIFY_WITH_TIMEOUT(label->implicitWidth() > 0, fixture_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(label->implicitHeight() > 0, fixture_wait_ms);
  }

  Q_SLOT static void expandedSidebarNeedsNoApplicationController() {
    QQmlEngine engine;
    ListModel workspaces;
    ListModel agents;
    workspaces.reconcile(workspaceRecords({.count = 1, .active = 0}));
    auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), sidebarProperties(workspaces, agents, true, 0));
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
    const auto *projects = sidebar->findChild<QQuickItem *>(QStringLiteral("workspaceList"));
    QVERIFY(projects != nullptr);
    constexpr QPointF expected_position{8, 31};
    constexpr QSizeF expected_size{263, 52};
    QCOMPARE(projects->position(), expected_position);
    QCOMPARE(projects->size(), expected_size);
  }

  Q_SLOT static void physicalSidebarRowsNeedNoApplicationController() {
    QQmlEngine engine;
    ListModel workspaces;
    ListModel agents;
    const Configuration configuration;
    constexpr qreal density = 2;
    const CellMetrics cells;
    const auto display = DisplayMetrics::resolve(configuration, {.width = 800, .height = 500}, cells, density);
    const Rect area{.width = display.geometry.sidebar.width, .height = display.geometry.sidebar.height};
    const auto regions = sidebarRegionsRecord(area, display, 1);
    const auto cards = regions.value(QStringLiteral("cards")).toMap();
    constexpr qreal expected_workspace_height = 51.5;
    constexpr qreal expected_card_height = 68;
    QCOMPARE(regions.value(QStringLiteral("workspaceHeight")).toReal(), expected_workspace_height);
    QCOMPARE(cards.value(QStringLiteral("height")).toReal(), expected_card_height);
    workspaces.reconcile(workspaceRecords({.count = 1, .active = 0}));
    const QVariantMap properties{
        {QStringLiteral("width"), display.geometry.sidebar.width / density},
        {QStringLiteral("height"), display.geometry.sidebar.height / density},
        {QStringLiteral("expanded"), true},
        {QStringLiteral("preferredWidth"), configuration.sidebar_width},
        {QStringLiteral("regions"), regions},
        {QStringLiteral("typography"), chromeTypographyRecord(display, configuration.font)},
        {QStringLiteral("colors"), themeColors(configuration)},
        {QStringLiteral("workspaceModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&workspaces))},
        {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&agents))},
    };
    const auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), properties);
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
    const auto *projects = sidebar->findChild<QQuickItem *>(QStringLiteral("workspaceList"));
    QVERIFY(projects != nullptr);
    QCOMPARE(projects->height(), expected_workspace_height);
    const auto edge = sidebar->property("edgeWidth").toReal();
    QCOMPARE(edge * density, qreal{1});
  }

  Q_SLOT static void applicationMarksNeedNoApplicationController() {
    QQuickWindow window;
    QQmlEngine engine;
    const ChromeMetrics chrome;
    constexpr int mark_side = 28;
    const auto colors = themeColors(Configuration{});
    const auto background = colors.value(QStringLiteral("base")).value<QColor>();
    const QVariantMap properties{
        {QStringLiteral("width"), mark_side},
        {QStringLiteral("height"), mark_side},
        {QStringLiteral("pixelSize"), chrome.body},
        {QStringLiteral("colors"), colors},
        {QStringLiteral("mark"), QVariantMap{}},
    };
    auto mark = createChrome(engine, QStringLiteral("ApplicationMark"), properties);
    mark->setParentItem(window.contentItem());
    window.resize(mark_side, mark_side);
    window.setColor(background);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    const auto *sprite = mark->findChild<ProviderMark *>(QStringLiteral("applicationProviderMark"));
    const auto *glyph = mark->findChild<QQuickItem *>(QStringLiteral("applicationGlyph"));
    QVERIFY(sprite != nullptr);
    QVERIFY(glyph != nullptr);
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());

    for (const auto *const name : {"Claude Code", "CODEX.EXE", "pi", "Cursor Agent", "OpenCode"}) {
      const auto resolved = ApplicationMark::forApplication(name);
      const QVariantMap record{{QStringLiteral("providerMark"), static_cast<int>(resolved.provider)}, {QStringLiteral("glyph"), toQString(resolved.glyph)}};
      QVERIFY(mark->setProperty("mark", record));
      QCOMPARE(sprite->provider(), static_cast<int>(resolved.provider));
      QVERIFY(sprite->isVisible());
      QVERIFY(!glyph->isVisible());
      QVERIFY(ProviderArtwork::image(resolved.provider, ApplicationMark::minimum_cell).hasAlphaChannel());
      const auto pixels = window.grabWindow();
      QVERIFY(!pixels.isNull());
      QImage empty{pixels.size(), pixels.format()};
      empty.fill(background);
      QVERIFY(pixels != empty);
      QVERIFY(mark->setProperty("dimmed", true));
      QCOMPARE(sprite->opacity(), static_cast<qreal>(ApplicationMark::dimmed_alpha));
      QVERIFY(mark->setProperty("dimmed", false));
      QCOMPARE(sprite->opacity(), 1);
    }

    QVERIFY(mark->setProperty("mark", QVariantMap{{QStringLiteral("glyph"), QStringLiteral("\ue62b")}}));
    QVERIFY(!sprite->isVisible());
    QVERIFY(glyph->isVisible());
    QVERIFY(ProviderArtwork::image(telar::AgentProvider::unknown, mark_side).isNull());
    QVERIFY(ProviderArtwork::image(telar::AgentProvider::claude, ApplicationMark::maximum_cell + 1).isNull());
  }

  Q_SLOT static void ancestorMotionKeepsProviderInkOnPhysicalPixels() {
    QQuickWindow window;
    QQuickItem holder{window.contentItem()};
    QQuickItem ancestor{window.contentItem()};
    ProviderMark mark{&ancestor};
    constexpr int window_side = 64;
    constexpr int mark_side = 14;
    constexpr qreal early_fraction = 0.1;
    constexpr qreal late_fraction = 0.9;
    window.resize(window_side, window_side);
    window.setColor(Qt::black);
    mark.setSize({mark_side, mark_side});
    mark.setProvider(static_cast<int>(telar::AgentProvider::codex));
    mark.setColor(Qt::white);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    const auto scale = window.effectiveDevicePixelRatio();
    ancestor.setPosition({early_fraction / scale, early_fraction / scale});
    const auto first = window.grabWindow();
    QVERIFY(!first.isNull());
    ancestor.setPosition({late_fraction / scale, late_fraction / scale});
    QCOMPARE(window.grabWindow(), first);

    ancestor.setPosition({});
    ancestor.setParentItem(&holder);
    holder.setPosition({early_fraction / scale, early_fraction / scale});
    const auto reparented = window.grabWindow();
    holder.setPosition({late_fraction / scale, late_fraction / scale});
    QCOMPARE(window.grabWindow(), reparented);
    ancestor.setParentItem(window.contentItem());
  }

  Q_SLOT static void tabCaptionsUseOnlyAnEligibleFocusedAgent() {
    SystemAllocator memory;
    GraphicsBudget budget;
    const telar::TabLocation location{.workspace = {.kind = telar::WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
    Tab tab{memory, location};
    Pane pane{memory, 1, budget};
    pane.location = location;
    pane.cwd = "/work/telar";
    pane.foreground = "Python";
    std::array agents{Agent{memory}, Agent{memory}};
    agents.front().pane_id = pane.id;
    agents.back().pane_id = pane.id;
    agents.front().location = {.workspace = location.workspace, .tab_id = 2};
    agents.front().title = "Other tab";
    agents.front().title_state = telar::AgentTitleState::ready;
    agents.back().location = location;
    agents.back().title = "Session title";
    for (const auto state : {telar::AgentTitleState::placeholder, telar::AgentTitleState::pending, telar::AgentTitleState::ready, telar::AgentTitleState::failed}) {
      agents.back().title_state = state;
      const auto record = tabRecord(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true);
      QCOMPARE(record.value(QStringLiteral("label")).toString(), state == telar::AgentTitleState::placeholder ? QStringLiteral("telar · Python") : QStringLiteral("Session title"));
      QCOMPARE(record.value(QStringLiteral("application")).toString(), QStringLiteral("Python"));
    }

    agents.front().location = location;
    agents.front().title_state = telar::AgentTitleState::placeholder;
    QCOMPARE(tabRecord(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true).value(QStringLiteral("label")).toString(), QStringLiteral("telar · Python"));
    tab.label = "Review";
    tab.fullscreen = true;
    QCOMPARE(tabRecord(tab, &pane, std::span<const Agent<SystemAllocator>>{agents}, true).value(QStringLiteral("label")).toString(), QStringLiteral("Review ⛶"));
  }

  Q_SLOT static void tabsPackAndKeepTheirWidthsWhileHovered() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    constexpr int strip_width = 300;
    constexpr std::size_t tab_count = 4;
    tabs.reconcile(tabRecords({.count = tab_count, .active = 0}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), static_cast<int>(tab_count), fixture_wait_ms);
    const auto first = tabBounds(*layout->items(), 0);
    const auto second = tabBounds(*layout->items(), 1);
    QCOMPARE(first.top(), (ChromeMetrics::logical_top_bar - TabStripGeometry::pill_height) / 2);
    QCOMPARE(second.left(), first.right() + TabStripGeometry::gap);
    QVERIFY(first.width() > second.width());

    layout->setHovered(true);
    tabs.reconcile(tabRecords({.count = tab_count, .active = 1}));
    const auto selected = [&] {
      return layout->items()->data(layout->items()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("tab")).toMap().value(QStringLiteral("selected")).toBool();
    };
    QTRY_VERIFY_WITH_TIMEOUT(selected(), fixture_wait_ms);
    QCOMPARE(tabBounds(*layout->items(), 0), first);
    QCOMPARE(tabBounds(*layout->items(), 1), second);
    layout->setHovered(false);
    QTRY_VERIFY_WITH_TIMEOUT(tabBounds(*layout->items(), 1).width() > second.width(), fixture_wait_ms);
  }

  Q_SLOT static void aHiddenTabCounterSelectsTheNearestTab() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    constexpr int strip_width = 120;
    constexpr std::size_t tab_count = 64;
    constexpr std::size_t selected_index = tab_count / 2;
    tabs.reconcile(tabRecords({.count = tab_count, .active = selected_index}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, fixture_wait_ms);
    const auto expected_key = QStringLiteral("tab:%1").arg(selected_index - 1);
    QCOMPARE(layout->counter().value(QStringLiteral("key")).toString(), expected_key);
    QCOMPARE(layout->counter().value(QStringLiteral("count")).toULongLong(), tab_count - 1);
    const auto signal = strip->metaObject()->method(strip->metaObject()->indexOfSignal("selected(QString)"));
    QVERIFY(signal.isValid());
    const QSignalSpy selected{strip.get(), signal};
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    const auto center = layout->counter().value(QStringLiteral("bounds")).toRectF().center().toPoint();
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, center);
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, fixture_wait_ms);
    QCOMPARE(selected.front().front().toString(), expected_key);

    layout->setHovered(true);
    tabs.reconcile(tabRecords({.count = tab_count, .active = 0}));
    const auto shown_key = [&] {
      return layout->items()->data(layout->items()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("key")).toString();
    };
    QTRY_COMPARE_WITH_TIMEOUT(shown_key(), QStringLiteral("tab:0"), fixture_wait_ms);
    QCOMPARE(layout->counter().value(QStringLiteral("key")).toString(), QStringLiteral("tab:1"));
  }

  Q_SLOT static void destroyingThePreviousTabModelPreservesTheNewBinding() {
    QQuickWindow window;
    QQmlEngine engine;
    auto previous = std::make_unique<ListModel>();
    ListModel current;
    constexpr int strip_width = 300;
    previous->reconcile(tabRecords({.count = 4, .active = 0}));
    current.reconcile(tabRecords({.count = 1, .active = 0}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(*previous, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 4, fixture_wait_ms);
    QVERIFY(strip->setProperty("model", QVariant::fromValue(static_cast<QAbstractItemModel *>(&current))));
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, fixture_wait_ms);
    previous.reset();
    QCOMPARE(layout->model(), &current);
    QCOMPARE(layout->items()->rowCount(), 1);
  }

  Q_SLOT static void prefixNumbersPreserveCompressedTabGeometry() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    constexpr int strip_width = 120;
    constexpr std::size_t tab_count = 64;
    constexpr std::size_t selected_index = tab_count / 2;
    tabs.reconcile(tabRecords({.count = tab_count, .active = selected_index}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, fixture_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*strip, QStringLiteral("tabNumber")).size(), 1, fixture_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*strip, QStringLiteral("applicationGlyph")).size(), 1, fixture_wait_ms);
    const auto *number = visualItems(*strip, QStringLiteral("tabNumber")).front();
    const auto *glyph = visualItems(*strip, QStringLiteral("applicationGlyph")).front();
    QVERIFY(!number->isVisible() && glyph->isVisible());
    const auto bounds = tabBounds(*layout->items(), 0);
    const auto counter = layout->counter();
    const auto plus = layout->plus();
    QVERIFY(strip->setProperty("prefixPending", true));
    QVERIFY(number->isVisible() && !glyph->isVisible());
    QCOMPARE(number->property("text").toString(), QString::number(selected_index + 1));
    QCOMPARE(tabBounds(*layout->items(), 0), bounds);
    QCOMPARE(layout->counter(), counter);
    QCOMPARE(layout->plus(), plus);

    QVERIFY(strip->setProperty("prefixPending", false));
    QVERIFY(!number->isVisible() && glyph->isVisible());
    QCOMPARE(tabBounds(*layout->items(), 0), bounds);
  }

  Q_SLOT static void collapsedSidebarCreatesOnlyItsVisibleMarks() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel workspaces;
    ListModel agents;
    constexpr int workspace_count = 128;
    workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = workspace_count - 1}));
    const auto properties = sidebarProperties(workspaces, agents, false, workspace_count - 1);
    auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), properties);
    sidebar->setParentItem(window.contentItem());
    window.resize(fixture_rail_width, fixture_height);
    window.show();
    const auto rail = properties.value(QStringLiteral("regions")).toMap().value(QStringLiteral("rail")).toMap();
    const auto expected = rail.value(QStringLiteral("marks")).toList().size();
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*sidebar, QStringLiteral("workspaceRailMark")).size(), expected, fixture_wait_ms);
    QVERIFY(expected < workspace_count);
  }

  Q_SLOT static void aRailClickEmitsOnlyTheWorkspaceIdentity() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel workspaces;
    ListModel agents;
    workspaces.reconcile(workspaceRecords({.count = 1, .active = 0}));
    auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), sidebarProperties(workspaces, agents, false, 0));
    sidebar->setParentItem(window.contentItem());
    window.resize(fixture_rail_width, fixture_height);
    const auto signal = sidebar->metaObject()->method(sidebar->metaObject()->indexOfSignal("workspaceSelected(QString)"));
    QVERIFY(signal.isValid());
    const QSignalSpy selected{sidebar.get(), signal};
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    constexpr QPoint mark_center{25, 30};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, mark_center);
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, fixture_wait_ms);
    QCOMPARE(selected.front().front().toString(), QStringLiteral("workspace:0"));
  }
};

}

QTEST_MAIN(ChromeTest)
#include "chrome_test.moc"
