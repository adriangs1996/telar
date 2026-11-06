#include "application/dependencies.hpp"
#include "application/records.hpp"
#include "core/configuration.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "core/theme_values.hpp"
#include "graphics/store.hpp"
#include "frame_fixture.hpp"
#include "presentation/application_mark.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/tab_strip_geometry.hpp"
#include "presentation/workspace_mark.hpp"
#include "presentation/workspace_window.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/list_model.hpp"
#include "qt/metrics_projection.hpp"
#include "qt/projection.hpp"
#include "qt/provider_artwork.hpp"
#include "qt/provider_mark.hpp"
#include "qt/sidebar_projection.hpp"
#include "qt/tab_strip_layout.hpp"
#include "qt/typography_projection.hpp"
#include "qt/window_animation_clock.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "qt/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QCoreApplication>
#include <QEvent>
#include <QColor>
#include <QGuiApplication>
#include <QImage>
#include <QList>
#include <QMetaMethod>
#include <QMetaObject>
#include <QQmlComponent>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QQuickItem>
#include <QQuickWindow>
#include <QSignalSpy>
#include <QString>
#include <QTest>
#include <QTimer>
#include <QTemporaryFile>
#include <QtQuick/qquickitemgrabresult.h>
#include <algorithm>
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
using telar::CellColor;
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

QVariantMap navigationProperties(ListModel &tabs, int width) {
  auto properties = tabProperties(tabs, width);
  properties.insert(QStringLiteral("tabModel"), properties.take(QStringLiteral("model")));
  properties.insert(QStringLiteral("workspace"), QVariantMap{});
  properties.insert(QStringLiteral("controlsInset"), 0);
  properties.insert(QStringLiteral("workbenchLeft"), fixture_sidebar_width);

  return properties;
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

QVariantMap projectSwitcherProperties(ListModel &workspaces, int width, int selected) {
  const ChromeMetrics chrome;
  return {
      {QStringLiteral("width"), width},
      {QStringLiteral("height"), chrome.top_bar},
      {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&workspaces))},
      {QStringLiteral("selectedIndex"), selected},
      {QStringLiteral("colors"), themeColors(Configuration{})},
      {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}}},
  };
}

QVariantMap sidebarProperties(ListModel &workspaces, ListModel &agents, bool expanded, int) {
  const ChromeMetrics chrome;
  const auto width = expanded ? fixture_sidebar_width : fixture_rail_width;
  const Rect area{.width = static_cast<float>(width), .height = fixture_height};
  auto geometry = sidebarRegionsRecord(area, {.chrome = chrome}, static_cast<std::size_t>(workspaces.rowCount()));
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
      {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&agents))},
  };
}

class ChromeTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    bundledFonts();
  }

  Q_SLOT static void chromeBandsKeepThemeRelativeSurfacesAndWindowTransparency() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    ListModel workspaces;
    ListModel agents;
    constexpr int width = 1000;
    const ChromeMetrics chrome;
    const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), navigationProperties(tabs, width));
    const auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), sidebarProperties(workspaces, agents, true, 0));
    const QVariantMap status_properties{
        {QStringLiteral("width"), width},
        {QStringLiteral("height"), chrome.top_bar},
        {QStringLiteral("metrics"), metricsRecord({})},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), chrome.small}}},
    };
    const auto status = createChrome(engine, QStringLiteral("StatusBar"), status_properties);
    const std::array<QQuickItem *, 3> bands{navigation.get(), sidebar.get(), status.get()};
    for (auto *band : bands) {
      band->setParentItem(window.contentItem());
      // Controls and separators may cover content; isolate the band's background.
      for (auto *child : band->childItems()) {
        child->setVisible(false);
      }
    }

    window.setColor(Qt::transparent);
    window.resize(width, fixture_height);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    Configuration configuration;
    constexpr auto explicit_panel = Color::rgb(0x405060);
    constexpr std::array opacities{0.0F, 0.25F, 0.75F, 1.0F, 0.5F};
    for (const bool custom_panel : {false, true}) {
      configuration.theme.chrome[static_cast<std::size_t>(PaletteRole::panel_bg)] = custom_panel ? CellColor{.kind = CellColor::Kind::rgb, .channels = {0x40, 0x50, 0x60}} : CellColor{};
      const auto covering = toQColor(custom_panel ? explicit_panel : configuration.theme.background);
      for (const auto opacity : opacities) {
        configuration.background_opacity = opacity;
        const auto colors = themeColors(configuration);
        const QColor expected = opacity < 1 ? QColor{Qt::transparent} : covering;
        QCOMPARE(colors.value(QStringLiteral("panelBackground")).value<QColor>(), expected);
        QCOMPARE(colors.value(QStringLiteral("panel_bg")).value<QColor>(), covering);
        for (auto *band : bands) {
          QVERIFY(band->setProperty("colors", colors));
          const auto role = band == status.get() ? QStringLiteral("bottombarBackground") : band == sidebar.get() ? QStringLiteral("sidebarBackground")
                                                                                                                 : QStringLiteral("topbarBackground");
          const auto band_color = colors.value(role).value<QColor>();
          QCOMPARE(band->property("color").value<QColor>(), band_color);
          QCOMPARE(band->opacity(), qreal{1});
          const auto capture = band->grabToImage();
          QVERIFY(!capture.isNull());
          QTRY_VERIFY_WITH_TIMEOUT(!capture->image().isNull(), fixture_wait_ms);
          const auto image = capture->image();
          const auto pixel = image.pixelColor(2, 2);
          const auto diagnostic = QStringLiteral("%1 at opacity %2: actual %3, expected %4").arg(QString::fromLatin1(band->metaObject()->className())).arg(opacity).arg(pixel.name(QColor::HexArgb), band_color.name(QColor::HexArgb));
          // QColor retains 16-bit channels; the render target quantizes premultiplied ink to eight bits.
          const auto actual_ink = qPremultiply(pixel.rgba());
          const auto expected_ink = qPremultiply(band_color.rgba());
          QCOMPARE(qAlpha(actual_ink), qAlpha(expected_ink));
          const std::array differences{qRed(actual_ink) - qRed(expected_ink), qGreen(actual_ink) - qGreen(expected_ink), qBlue(actual_ink) - qBlue(expected_ink)};
          QVERIFY2(std::ranges::all_of(differences, [](int difference) {
                     return difference >= -1 && difference <= 1;
                   }),
                   qPrintable(diagnostic));
        }
      }
    }
  }

  Q_SLOT static void attachmentOverlaysKeepCoveringPanelColors() {
    QTemporaryFile configuration;
    QVERIFY(configuration.open());
    const QByteArray source{"return {api_version=2,theme='terminal',gui={window={background_opacity=0.5}}}"};
    QCOMPARE(configuration.write(source), source.size());
    configuration.close();
    ApplicationAllocator memory;
    Application application{memory};
    application.loadConfiguration(configuration.fileName(), {}, {});
    QCOMPARE(application.error(), QString{});
    QQmlEngine engine;
    const QVariantMap properties{{QStringLiteral("application"), QVariant::fromValue(&application)}};
    const auto load = [&](const QString &path) {
      QQmlComponent component{&engine, QUrl::fromLocalFile(path)};
      auto object = std::unique_ptr<QObject>{component.createWithInitialProperties(properties)};
      if (!object) {
        throw std::runtime_error{component.errorString().toStdString()};
      }

      return object;
    };
    const auto shelf = load(QFINDTESTDATA("../qt/AttachmentShelf.qml"));
    const auto modal = load(QFINDTESTDATA("../qt/AttachmentModal.qml"));
    QQmlExpression modal_color{qmlContext(modal.get()), modal.get(), QStringLiteral("modal.color")};
    const auto actual = modal_color.evaluate().value<QColor>();
    QVERIFY2(!modal_color.hasError(), qPrintable(modal_color.error().toString()));
    const auto expected = application.colors().value(QStringLiteral("panel_bg")).value<QColor>();
    QCOMPARE(expected.alpha(), 255);
    QCOMPARE(shelf->property("color").value<QColor>(), expected);
    QCOMPARE(actual, expected);
  }

  Q_SLOT static void tabsLiveInNavigationRatherThanConfiguredBottomSlots() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    tabs.reconcile(tabRecords({.count = 2, .active = 0}));
    auto properties = navigationProperties(tabs, 1000);
    const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), properties);
    navigation->setParentItem(window.contentItem());
    window.resize(1000, ChromeMetrics{}.top_bar);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    const auto *strip = navigation->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(strip != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*navigation, QStringLiteral("tabPill")).size(), 2, fixture_wait_ms);
    QVERIFY(strip->mapToItem(navigation.get(), QPointF{}).x() >= fixture_sidebar_width);
    QVERIFY(navigation->setProperty("rail", true));
    QTRY_VERIFY_WITH_TIMEOUT(strip->width() > 0, fixture_wait_ms);
    QVERIFY(strip->mapToItem(navigation.get(), QPointF{}).x() < fixture_sidebar_width);

    const QVariantMap bottom_properties{
        {QStringLiteral("controller"), QVariant::fromValue(static_cast<QObject *>(nullptr))},
        {QStringLiteral("surface"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("tabs")}}},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), properties.value(QStringLiteral("typography"))},
    };
    const auto bottom = createChrome(engine, QStringLiteral("ComponentSlot"), bottom_properties);
    QCOMPARE(bottom->implicitWidth(), qreal{0});
    QVERIFY(bottom->findChild<TabStripLayout *>() == nullptr);
  }

  Q_SLOT static void selectedTabEmphasisDoesNotMoveAdjacentTabs() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    tabs.reconcile(tabRecords({.count = 2, .active = 0}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, 600));
    strip->setParentItem(window.contentItem());
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    window.resize(600, ChromeMetrics{}.top_bar);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, fixture_wait_ms);
    const auto selected_caption = [&] {
      QString selected;
      for (const auto *caption : visualItems(*strip, QStringLiteral("tabCaption"))) {
        if (caption->property("emphasized").toBool()) {
          if (!selected.isEmpty()) {
            return QStringLiteral("multiple");
          }
          selected = caption->parentItem()->property("tabKey").toString();
        }
      }
      return selected;
    };
    QTRY_COMPARE_WITH_TIMEOUT(selected_caption(), QStringLiteral("tab:0"), fixture_wait_ms);
    const std::array before{tabBounds(*layout->items(), 0), tabBounds(*layout->items(), 1)};
    tabs.reconcile(tabRecords({.count = 2, .active = 1}));
    QTRY_COMPARE_WITH_TIMEOUT(selected_caption(), QStringLiteral("tab:1"), fixture_wait_ms);
    QCOMPARE(tabBounds(*layout->items(), 0), before[0]);
    QCOMPARE(tabBounds(*layout->items(), 1), before[1]);
  }

  Q_SLOT static void workspaceAndMachineStayVisibleInBothSidebarModes() {
    ApplicationAllocator memory;
    Application application{memory};
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    tabs.reconcile(tabRecords({.count = 3, .active = 0}));
    auto properties = navigationProperties(tabs, 1000);
    properties.insert(QStringLiteral("controller"), QVariant::fromValue(&application));
    properties.insert(QStringLiteral("workspace"), QVariantMap{{QStringLiteral("name"), QStringLiteral("telar")}});
    properties.insert(QStringLiteral("controlsInset"), 80);
    const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), properties);
    navigation->setParentItem(window.contentItem());
    window.resize(1000, ChromeMetrics{}.top_bar);
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    auto *layout = navigation->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    const auto names = visualItems(*navigation, QStringLiteral("workspaceContextName"));
    const auto machines = visualItems(*navigation, QStringLiteral("topBarMachineLabel"));
    QCOMPARE(names.size(), 1);
    QCOMPARE(machines.size(), 1);
    const auto *name = names.front();
    const auto *machine = machines.front();
    QCOMPARE(name->property("text").toString(), QStringLiteral("telar"));
    QVERIFY(!machine->property("text").toString().isEmpty());
    QCOMPARE(machine->property("text").toString(), application.machineContext().value(QStringLiteral("label")).toString());
    for (const bool rail : {false, true}) {
      QVERIFY(navigation->setProperty("rail", rail));
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QVERIFY(name->isVisible() && machine->isVisible());
      const auto name_bounds = name->mapRectToItem(navigation.get(), name->boundingRect());
      const auto machine_bounds = machine->mapRectToItem(navigation.get(), machine->boundingRect());
      QVERIFY(name_bounds.left() >= 80);
      QVERIFY(name_bounds.bottom() <= machine_bounds.top());
      QVERIFY(machine_bounds.right() < layout->mapToItem(navigation.get(), QPointF{}).x());
    }
  }

  Q_SLOT static void tabsShareOneWellAndOneSelectionCapsule() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    tabs.reconcile(tabRecords({.count = 3, .active = 0}));
    const auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, 800));
    strip->setParentItem(window.contentItem());
    window.resize(800, ChromeMetrics{}.top_bar);
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 3, fixture_wait_ms);
    const auto wells = visualItems(*strip, QStringLiteral("tabWell"));
    const auto selections = visualItems(*strip, QStringLiteral("tabSelection"));
    QCOMPARE(wells.size(), 1);
    QCOMPARE(selections.size(), 1);
    QCOMPARE(layout->selectionBounds(), tabBounds(*layout->items(), 0));
    const auto *well = wells.front();
    const auto *selection = selections.front();
    QVERIFY(well->width() > selection->width());
    QVERIFY(well->mapRectToItem(strip.get(), well->boundingRect()).contains(selection->mapRectToItem(strip.get(), selection->boundingRect())));
    QCOMPARE(selection->property("radius").toReal(), selection->height() / 2);
    tabs.reconcile(tabRecords({.count = 3, .active = 2}));
    QTRY_COMPARE_WITH_TIMEOUT(layout->selectionBounds(), tabBounds(*layout->items(), 2), fixture_wait_ms);
    QCOMPARE(visualItems(*strip, QStringLiteral("tabSelection")).size(), 1);
    tabs.reconcile({});
    QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 0, fixture_wait_ms);
    QVERIFY(!well->isVisible() && !selection->isVisible());
  }

  Q_SLOT static void tabWellFitsNarrowAndScaledStrips_data() {
    QTest::addColumn<int>("width");
    QTest::addColumn<qreal>("ratio");
    QTest::newRow("narrow") << 48 << qreal{1};
    QTest::newRow("overflow") << 120 << qreal{1};
    QTest::newRow("fractional") << 180 << qreal{1.5};
    QTest::newRow("double") << 800 << qreal{2};
  }

  Q_SLOT static void tabWellFitsNarrowAndScaledStrips() {
    QFETCH(int, width);
    QFETCH(qreal, ratio);
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    tabs.reconcile(tabRecords({.count = 64, .active = 32}));
    auto properties = tabProperties(tabs, width);
    const auto height = ChromeMetrics::logical_top_bar * ratio;
    properties.insert(QStringLiteral("height"), height);
    properties.insert(QStringLiteral("ratio"), ratio);
    const auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), properties);
    strip->setParentItem(window.contentItem());
    window.resize(width, static_cast<int>(height));
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    auto *layout = strip->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(layout != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(layout->items()->rowCount() > 0, fixture_wait_ms);
    const auto wells = visualItems(*strip, QStringLiteral("tabWell"));
    QCOMPARE(wells.size(), 1);
    const auto *well = wells.front();
    QVERIFY(well->isVisible());
    QVERIFY(well->width() <= width);
    QVERIFY(well->height() <= height);
    QVERIFY(layout->selectionBounds().height() <= well->height());
    QVERIFY(!layout->counter().isEmpty());
    const auto selection = layout->selectionBounds().translated(layout->position());
    QVERIFY(selection.left() >= 0 && selection.right() <= width);
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
    QVERIFY(sidebar->findChild<QQuickItem *>(QStringLiteral("workspaceList")) == nullptr);
    const auto *activity = sidebar->findChild<QQuickItem *>(QStringLiteral("sidebarActivity"));
    QVERIFY(activity != nullptr);
    constexpr QPointF expected_position{8, 31};
    constexpr QSizeF expected_size{263, 893};
    QCOMPARE(activity->position(), expected_position);
    QCOMPARE(activity->size(), expected_size);
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
        {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&agents))},
    };
    const auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), properties);
    QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
    const auto *activity = sidebar->findChild<QQuickItem *>(QStringLiteral("sidebarActivity"));
    QVERIFY(activity != nullptr);
    QCOMPARE(activity->height(), regions.value(QStringLiteral("activity")).toRectF().height());
    QVERIFY(sidebar->findChild<QQuickItem *>(QStringLiteral("workspaceList")) == nullptr);
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
    QVERIFY(ProviderArtwork::telar(ApplicationMark::minimum_cell - 1).isNull());
    QVERIFY(ProviderArtwork::telar(ApplicationMark::maximum_cell + 1).isNull());
    const auto application_artwork = ProviderArtwork::telar(mark_side);
    QCOMPARE(application_artwork.size(), QSize(mark_side, mark_side));
    QCOMPARE(application_artwork.pixelColor(0, 0).alpha(), 0);
    QImage transparent{application_artwork.size(), application_artwork.format()};
    transparent.fill(Qt::transparent);
    QVERIFY(application_artwork != transparent);
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

  Q_SLOT static void transitioningTabsUseAnAlreadyScheduledFrame() {
    QQuickWindow window;
    ListModel tabs;
    QList<QVariantMap> rows;
    constexpr int tab_count = 4;
    for (int id = 1; id <= tab_count; ++id) {
      rows.append({{QStringLiteral("key"), QString::number(id)}, {QStringLiteral("label"), QStringLiteral("Terminal")}});
    }
    tabs.reconcile(rows);
    TabStripLayout layout{window.contentItem()};
    layout.setSize(QSizeF{800, 42});
    layout.setContext(1, telar::WorkspaceLocation{.id = 1});
    QFont font{QStringLiteral("IBM Plex Sans")};
    font.setPixelSize(13);
    layout.setFont(font);
    layout.setPixelSize(13);
    layout.setModel(&tabs);
    window.resize(800, 42);
    window.show();
    QVERIFY(QTest::qWaitForWindowExposed(&window, fixture_wait_ms));
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    std::reverse(rows.begin(), rows.end());
    tabs.reconcile(rows);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(layout.transitioning());
    auto &clock = WindowAnimationClock::forWindow(window);
    auto *timer = clock.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    // Isolate frame preparation from the deadline path, even on a slow host.
    QObject::disconnect(&window, &QQuickWindow::afterAnimating, &clock, nullptr);
    QCoreApplication::removePostedEvents(&clock, QEvent::MetaCall);
    timer->stop();
    QSignalSpy samples{&layout, &TabStripLayout::layoutChanged};
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(!samples.isEmpty());
    layout.setVisible(false);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    samples.clear();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QCOMPARE(samples.size(), 0);
  }

  Q_SLOT static void selectionCapsuleAnimatesAndResetsWithItsWorkspace() {
    QQuickWindow window;
    ListModel tabs;
    QList<QVariantMap> rows;
    for (int id = 1; id <= 3; ++id) {
      rows.append({{QStringLiteral("key"), QString::number(id)}, {QStringLiteral("label"), QStringLiteral("Terminal")}, {QStringLiteral("selected"), id == 1}});
    }
    tabs.reconcile(rows);
    TabStripLayout layout{window.contentItem()};
    layout.setSize(QSizeF{800, ChromeMetrics::logical_top_bar});
    layout.setContext(1, telar::WorkspaceLocation{.id = 1});
    QFont font{QStringLiteral("IBM Plex Sans")};
    font.setPixelSize(13);
    layout.setFont(font);
    layout.setPixelSize(13);
    layout.setModel(&tabs);
    window.resize(800, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QCOMPARE(layout.selectionBounds(), tabBounds(*layout.items(), 0));
    layout.setHovered(true);
    rows[0].insert(QStringLiteral("selected"), false);
    rows[2].insert(QStringLiteral("selected"), true);
    tabs.reconcile(rows);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(layout.transitioning());
    QVERIFY(layout.selectionBounds().left() < tabBounds(*layout.items(), 2).left());
    QTRY_VERIFY_WITH_TIMEOUT(!layout.transitioning(), fixture_wait_ms);
    QCOMPARE(layout.selectionBounds(), tabBounds(*layout.items(), 2));
    rows[2].insert(QStringLiteral("selected"), false);
    rows[0].insert(QStringLiteral("selected"), true);
    layout.setContext(1, telar::WorkspaceLocation{.id = 2});
    tabs.reconcile(rows);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QCOMPARE(layout.selectionBounds(), tabBounds(*layout.items(), 0));
    QVERIFY(!layout.transitioning());
    layout.setSize(QSizeF{});
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(layout.selectionBounds().isEmpty() && layout.stripBounds().isEmpty());
    QVERIFY(!layout.transitioning());
  }

  Q_SLOT static void tabsUseTheirNaturalWidthsWhenTheyFit() {
    using Geometry = TabStripGeometry;
    const auto metrics = Geometry::Metrics::scaled(1);
    const std::array sizes{
        Geometry::Measure{.caption = 180, .chip = Geometry::chip_side},
        Geometry::Measure{.caption = 20, .chip = Geometry::chip_side},
    };
    const auto room = sizes[0].whole(metrics) + metrics.gap + sizes[1].whole(metrics);
    const auto plan = Geometry::arrange(sizes, 0, {.width = room, .metrics = metrics});
    QCOMPARE(plan.hidden(), std::size_t{0});
    for (std::size_t index = 0; index < sizes.size(); ++index) {
      QCOMPARE(plan.fits[index], Geometry::Fit::full);
      QCOMPARE(plan.widths[index], sizes[index].whole(metrics));
    }
    const auto single = Geometry::arrange(std::span{sizes}.first(1), 0, {.width = 150, .metrics = metrics});
    QCOMPARE(single.widths[0], 150.0F);
    QCOMPARE(single.fits[0], Geometry::Fit::truncated);
  }

  Q_SLOT static void tabsKeepTheirCaptionsBeforeAnyTabCollapses() {
    using Geometry = TabStripGeometry;
    const auto metrics = Geometry::Metrics::scaled(1);
    std::array<Geometry::Measure, 3> sizes;
    sizes.fill({.caption = 400, .chip = Geometry::chip_side});
    const auto minimum_room = sizes[0].truncated(metrics) * static_cast<float>(sizes.size()) + metrics.gap * static_cast<float>(sizes.size() - 1);
    for (const auto room : {minimum_room, 350.0F}) {
      for (std::size_t focus = 0; focus < sizes.size(); ++focus) {
        const auto plan = Geometry::arrange(sizes, focus, {.width = room, .metrics = metrics});
        QCOMPARE(plan.hidden(), std::size_t{0});
        QVERIFY(plan.footprint(metrics) <= room);
        for (std::size_t index = 0; index < sizes.size(); ++index) {
          QVERIFY(plan.fits[index] != Geometry::Fit::compact);
          QVERIFY(plan.widths[index] >= sizes[index].truncated(metrics));
        }
      }
    }
  }

  Q_SLOT static void restoredAndSwitchedWorkspacesExpandTabsWithoutPointerMovement() {
    QQuickWindow window;
    ListModel tabs;
    TabStripLayout layout{window.contentItem()};
    QFont font{QStringLiteral("IBM Plex Sans")};
    font.setPixelSize(13);
    layout.setFont(font);
    layout.setPixelSize(13);
    layout.setContext(1, telar::WorkspaceLocation{.id = 1});
    layout.setModel(&tabs);
    layout.setHovered(true);
    layout.setSize(QSizeF{180, ChromeMetrics::logical_top_bar});
    window.resize(400, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QList<QVariantMap> rows;
    for (int id = 1; id <= 3; ++id) {
      rows.append({{QStringLiteral("key"), QString::number(id)}, {QStringLiteral("label"), QString(64, QLatin1Char('W'))}, {QStringLiteral("selected"), id == 1}});
    }
    tabs.reconcile(rows);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(!layout.counter().isEmpty());
    layout.setWidth(400);
    QTRY_VERIFY_WITH_TIMEOUT(!layout.transitioning() && layout.items()->rowCount() == 3, fixture_wait_ms);
    const auto record = [&](int index) {
      return layout.items()->data(layout.items()->index(index, 0), ListModel::record_role).toMap();
    };
    QVERIFY(layout.counter().isEmpty());
    for (int index = 0; index < 3; ++index) {
      QVERIFY(!record(index).value(QStringLiteral("compact")).toBool());
    }
    QVERIFY(tabBounds(*layout.items(), 0).width() > tabBounds(*layout.items(), 2).width());
    rows[0].insert(QStringLiteral("selected"), false);
    rows[2].insert(QStringLiteral("selected"), true);
    layout.setContext(1, telar::WorkspaceLocation{.id = 2});
    tabs.reconcile(rows);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QVERIFY(!layout.transitioning());
    QVERIFY(tabBounds(*layout.items(), 2).width() > tabBounds(*layout.items(), 0).width());
    for (int index = 0; index < 3; ++index) {
      QVERIFY(!record(index).value(QStringLiteral("compact")).toBool());
    }
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

  Q_SLOT static void projectSwitcherBoundsItsDelegatesAndRevealsTheSelection() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel workspaces;
    constexpr int workspace_count = 128;
    constexpr int width = 180;
    workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = workspace_count - 1}));
    const auto switcher = createChrome(engine, QStringLiteral("ProjectSwitcher"), projectSwitcherProperties(workspaces, width, workspace_count - 1));
    switcher->setParentItem(window.contentItem());
    window.resize(width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    const auto selected = [&]() -> QQuickItem * {
      for (auto *mark : visualItems(*switcher, QStringLiteral("projectSwitcherMark"))) {
        if (mark->property("record").toMap().value(QStringLiteral("selected")).toBool()) {
          return mark;
        }
      }
      return nullptr;
    };
    QTRY_VERIFY_WITH_TIMEOUT(selected() != nullptr, fixture_wait_ms);
    const auto marks = visualItems(*switcher, QStringLiteral("projectSwitcherMark"));
    QVERIFY(marks.size() <= 8);
    QVERIFY(switcher->boundingRect().contains(selected()->mapRectToItem(switcher.get(), selected()->boundingRect())));
    const auto overflow = visualItems(*switcher, QStringLiteral("projectSwitcherOverflow"));
    QCOMPARE(overflow.size(), 1);
    QVERIFY(overflow.front()->isVisible());
    const auto signal = switcher->metaObject()->method(switcher->metaObject()->indexOfSignal("overflowRequested()"));
    QVERIFY(signal.isValid());
    const QSignalSpy requested{switcher.get(), signal};
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, overflow.front()->mapRectToScene(overflow.front()->boundingRect()).center().toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(requested.size(), 1, fixture_wait_ms);
    workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = 0}));
    QVERIFY(switcher->setProperty("selectedIndex", 0));
    QTRY_VERIFY_WITH_TIMEOUT(selected() != nullptr && switcher->boundingRect().contains(selected()->mapRectToItem(switcher.get(), selected()->boundingRect())), fixture_wait_ms);
    switcher->setWidth(20);
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    QCOMPARE(overflow.front()->width(), qreal{20});
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, overflow.front()->mapRectToScene(overflow.front()->boundingRect()).center().toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(requested.size(), 2, fixture_wait_ms);
    workspaces.reconcile({});
    QVERIFY(switcher->setProperty("selectedIndex", -1));
    QTRY_VERIFY_WITH_TIMEOUT(!overflow.front()->isVisible(), fixture_wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(visualItems(*switcher, QStringLiteral("projectSwitcherMark")).isEmpty(), fixture_wait_ms);
  }

  Q_SLOT static void projectsLiveOnTheRightOfNavigationWithoutOverlappingTabs() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    ListModel workspaces;
    tabs.reconcile(tabRecords({.count = 4, .active = 0}));
    workspaces.reconcile(workspaceRecords({.count = 3, .active = 0}));
    auto properties = navigationProperties(tabs, 1000);
    properties.insert(QStringLiteral("workspaceModel"), QVariant::fromValue(static_cast<QAbstractItemModel *>(&workspaces)));
    properties.insert(QStringLiteral("workspace"), QVariantMap{{QStringLiteral("index"), 0}});
    const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), properties);
    navigation->setParentItem(window.contentItem());
    window.resize(1000, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    auto *strip = navigation->findChild<TabStripLayout *>(QStringLiteral("tabStripLayout"));
    QVERIFY(strip != nullptr);
    const auto switchers = visualItems(*navigation, QStringLiteral("projectSwitcher"));
    QCOMPARE(switchers.size(), 1);
    auto *switcher = switchers.front();
    for (const bool rail : {false, true}) {
      QVERIFY(navigation->setProperty("rail", rail));
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      const auto bounds = switcher->mapRectToItem(navigation.get(), switcher->boundingRect());
      QCOMPARE(bounds.right(), qreal{992});
      QVERIFY(strip->mapRectToItem(navigation.get(), strip->boundingRect()).right() < bounds.left());
      const auto marks = visualItems(*switcher, QStringLiteral("projectSwitcherMark"));
      QCOMPARE(marks.size(), 3);
      QTest::mouseMove(&window, marks.front()->mapRectToScene(marks.front()->boundingRect()).center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, fixture_wait_ms);
    }
  }

  Q_SLOT static void tabsShowThePointingCursor() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel tabs;
    constexpr int strip_width = 300;
    constexpr std::size_t tab_count = 2;
    tabs.reconcile(tabRecords({.count = tab_count, .active = 0}));
    auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, strip_width));
    strip->setParentItem(window.contentItem());
    window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    const auto firstArea = [&]() -> QQuickItem * {
      for (auto *item : visualItems(*strip, QString{})) {
        if (item->inherits("QQuickMouseArea") && item->isVisible() && item->width() > 0) {
          return item;
        }
      }

      return nullptr;
    };
    QTRY_VERIFY_WITH_TIMEOUT(firstArea() != nullptr, fixture_wait_ms);
    const auto *area = firstArea();
    QTest::mouseMove(&window, area->mapRectToScene(area->boundingRect()).center().toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, fixture_wait_ms);
  }

  Q_SLOT static void buttonsShowThePointingCursorOnlyWhileEnabled_data() {
    QTest::addColumn<QString>("type");
    QTest::addColumn<QByteArray>("availability");
    QTest::newRow("chrome") << QStringLiteral("ChromeButton") << QByteArrayLiteral("enabled");
    QTest::newRow("form") << QStringLiteral("FormButton") << QByteArrayLiteral("interactive");
  }

  Q_SLOT static void buttonsShowThePointingCursorOnlyWhileEnabled() {
    QFETCH(QString, type);
    QFETCH(QByteArray, availability);
    QQuickWindow window;
    QQmlEngine engine;
    const ChromeMetrics chrome;
    constexpr qreal disabled_alpha = 0.5;
    constexpr qreal pressed_alpha = 0.7;
    constexpr qreal radius = 4;
    const QVariantMap properties{
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("pixelSize"), chrome.body},
        {QStringLiteral("text"), QStringLiteral("Action")},
    };
    auto required = properties;
    if (type == QStringLiteral("FormButton")) {
      required.insert({
          {QStringLiteral("radius"), radius},
          {QStringLiteral("disabledAlpha"), disabled_alpha},
          {QStringLiteral("pressedAlpha"), pressed_alpha},
      });
    }

    auto button = createChrome(engine, type, required);
    button->setParentItem(window.contentItem());
    constexpr QSize window_size{120, 40};
    button->setSize(window_size);
    window.resize(window_size);
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
    constexpr QPoint inside{60, 20};
    QTest::mouseMove(&window, inside);
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, fixture_wait_ms);

    QVERIFY(button->setProperty(availability.constData(), false));
    constexpr QPoint moved{62, 20};
    QTest::mouseMove(&window, moved);
    QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::ArrowCursor, fixture_wait_ms);
  }

  Q_SLOT static void aProjectClickEmitsOnlyItsWorkspaceIdentity() {
    QQuickWindow window;
    QQmlEngine engine;
    ListModel workspaces;
    workspaces.reconcile(workspaceRecords({.count = 3, .active = 0}));
    const auto switcher = createChrome(engine, QStringLiteral("ProjectSwitcher"), projectSwitcherProperties(workspaces, 120, 0));
    switcher->setParentItem(window.contentItem());
    window.resize(120, static_cast<int>(ChromeMetrics::logical_top_bar));
    const auto signal = switcher->metaObject()->method(switcher->metaObject()->indexOfSignal("selected(QString)"));
    QVERIFY(signal.isValid());
    const QSignalSpy selected{switcher.get(), signal};
    window.show();
    QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
    const auto marks = visualItems(*switcher, QStringLiteral("projectSwitcherMark"));
    QCOMPARE(marks.size(), 3);
    const auto *mark = marks.back();
    const auto record = mark->property("record").toMap();
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, mark->mapRectToScene(mark->boundingRect()).center().toPoint());
    QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, fixture_wait_ms);
    QCOMPARE(selected.front().front().toString(), record.value(QStringLiteral("key")).toString());
  }
};

}

QTEST_MAIN(ChromeTest)
#include "chrome_test.moc"
