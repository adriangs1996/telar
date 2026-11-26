#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "frame_fixture.hpp"
#include "qml_fixture.hpp"
#include "ui/app/application_controller.hpp"
#include "ui/app/chrome/metrics_projection.hpp"
#include "ui/app/chrome/sidebar_projection.hpp"
#include "ui/app/chrome/tabs/tab_strip_layout.hpp"
#include "ui/design/controls/provider_artwork.hpp"
#include "ui/design/controls/provider_mark.hpp"
#include "ui/kit/fonts/bundled_fonts.hpp"
#include "ui/kit/fonts/typography_projection.hpp"
#include "ui/kit/models/list_model.hpp"
#include "ui/kit/models/projection.hpp"
#include "ui/kit/scene/window_animation_clock.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QCoreApplication>
#include <QEvent>
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
#include <QTemporaryFile>
#include <QTest>
#include <QTimer>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qquickitemgrabresult.h>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

import telar.gui.application;
import telar.gui.features.terminal.graphics;
import telar.gui.features.activity;
import telar.gui.features.workbench;
import telar.gui.features.notifications;
import telar.gui.features.window;
import telar.gui.features.status_bar;
import telar.base.ds;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace {

  using namespace telar::gui;

  using namespace telar::gui::features::workbench;

  using namespace telar::gui::features::activity;

  using namespace telar::gui::features::window;

  using namespace telar::gui::features::terminal::graphics;
  using namespace telar::gui::qt;
  using telar::CellColor;
  using test::createChrome;
  using test::visualItems;

  constexpr int fixture_height = 932;
  constexpr int fixture_sidebar_width = 280;
  constexpr int fixture_rail_width = 52;
  constexpr int fixture_wait_ms = 5'000;
  constexpr int tab_font_pixel_size = 13;

  // How many rows a fixture holds and which one is selected.
  struct Selection {
    std::size_t count = 0;
    std::size_t active = 0;
  };

  QList<QVariantMap> tabRecords(Selection selection) {
    QList<QVariantMap> rows;

    for (std::size_t index = 0; index < selection.count; ++index) {
      rows.append({
          {QStringLiteral("key"), QStringLiteral("tab:%1").arg(index)},
          {QStringLiteral("label"), QStringLiteral("Terminal %1").arg(index)},
          {QStringLiteral("application"), QStringLiteral("sh")},
          {QStringLiteral("selected"), index == selection.active},
          {QStringLiteral("cards"), QVariantList{QVariantMap{{QStringLiteral("key"), QString::number(index + 1)}, {QStringLiteral("focused"), true}, {QStringLiteral("glyph"), QStringLiteral("\uea85")}, {QStringLiteral("providerMark"), 0}}}},
      });
    }

    return rows;
  }

  QVariantMap tabProperties(ListModel& tabs, int width) {
    const ChromeMetrics chrome;

    return {
        {QStringLiteral("width"), width},
        {QStringLiteral("height"), chrome.top_bar},
        {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&tabs))},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("title"), chrome.title}, {QStringLiteral("small"), chrome.small}}},
    };
  }

  QVariantMap navigationProperties(ListModel& tabs, int width) {
    auto properties = tabProperties(tabs, width);

    properties.insert(QStringLiteral("tabModel"), properties.take(QStringLiteral("model")));
    properties.insert(QStringLiteral("workspace"), QVariantMap{});
    properties.insert(QStringLiteral("controlsInset"), 0);

    return properties;
  }

  // The key of the one tab whose caption is selected, "multiple" when several are.
  QString selectedTabKey(QQuickItem& strip) {
    QString selected;

    for (const auto* caption : visualItems(strip, QStringLiteral("tabCaption"))) {
      if (!caption->parentItem()->property("source").toMap().value(QStringLiteral("selected")).toBool()) {
        continue;
      }

      if (!selected.isEmpty()) {
        return QStringLiteral("multiple");
      }

      selected = caption->parentItem()->property("tabKey").toString();
    }

    return selected;
  }

  QRectF tabBounds(const QAbstractItemModel& model, int row) {
    return model.data(model.index(row, 0), ListModel::record_role).toMap().value(QStringLiteral("bounds")).toRectF();
  }

  QList<QVariantMap> workspaceRecords(Selection selection) {
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

  // A workspace track with `room` to draw in; it sizes itself to what that room holds.
  QVariantMap workspaceTrackProperties(ListModel& workspaces, int room, int selected) {
    const ChromeMetrics chrome;

    return {
        {QStringLiteral("room"), room},
        {QStringLiteral("height"), chrome.top_bar},
        {QStringLiteral("model"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&workspaces))},
        {QStringLiteral("selectedIndex"), selected},
        {QStringLiteral("colors"), themeColors(Configuration{})},
        {QStringLiteral("typography"), QVariantMap{{QStringLiteral("body"), chrome.body}, {QStringLiteral("title"), chrome.title}, {QStringLiteral("small"), chrome.small}}},
    };
  }

  QVariantMap sidebarProperties(const ListModel& workspaces, ListModel& agents, bool expanded, int /*unused*/) {
    const ChromeMetrics chrome;
    const auto width = expanded ? fixture_sidebar_width : fixture_rail_width;
    const Rect area{.width = static_cast<float>(width), .height = fixture_height};
    auto geometry = sidebarRegionsRecord(area, {.chrome = chrome}, static_cast<std::size_t>(workspaces.rowCount()));
    const QVariantMap typography{
        {QStringLiteral("body"), chrome.body},
        {QStringLiteral("title"), chrome.title},
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
        {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&agents))},
    };
  }

  // The bands whose background takes a role other than the top bar's.
  struct ChromeBands {
    const QQuickItem* sidebar = nullptr;
    const QQuickItem* status = nullptr;
  };

  QString bandBackgroundRole(const QQuickItem* band, ChromeBands bands) {
    if (band == bands.status) {
      return QStringLiteral("bottombarBackground");
    }

    if (band == bands.sidebar) {
      return QStringLiteral("sidebarBackground");
    }

    return QStringLiteral("topbarBackground");
  }

  class ChromeTest final : public QObject {
    Q_OBJECT

  private:
    Q_SLOT static void initTestCase() {
      bundledFonts();
    }

    // The prompt editor highlights shell syntax with the theme's syntax roles.
    Q_SLOT static void syntaxColorsReachQml() {
      Configuration configuration;
      const auto keyword = QStringLiteral("syntax_keyword");
      constexpr CellColor keyword_color{.kind = CellColor::Kind::rgb, .channels = {0x95, 0xa7, 0xba}};

      QCOMPARE(themeColors(configuration).value(keyword).value<QColor>(), toQColor(configuration.theme.foreground));
      configuration.theme.syntax.atMut(static_cast<std::size_t>(SyntaxRole::keyword)) = keyword_color;
      QCOMPARE(themeColors(configuration).value(keyword).value<QColor>(), QColor(keyword_color.channels[0], keyword_color.channels[1], keyword_color.channels[2]));
    }

    Q_SLOT static void chromeBandsKeepThemeRelativeSurfacesAndWindowTransparency() {
      QQuickWindow window;
      QQmlEngine engine;
      ListModel tabs;
      const ListModel workspaces;
      ListModel agents;
      constexpr int width = 1000;
      const ChromeMetrics chrome;
      const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), navigationProperties(tabs, width));
      const auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), sidebarProperties(workspaces, agents, true, 0));
      const QVariantMap status_properties{
          {QStringLiteral("width"), width},
          {QStringLiteral("height"), chrome.top_bar},
          {QStringLiteral("metrics"), metricsRecord(features::status_bar::metrics(features::status_bar::State{}))},
          {QStringLiteral("colors"), themeColors(Configuration{})},
          {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), chrome.small}}},
      };

      const auto status = createChrome(engine, QStringLiteral("StatusBar"), status_properties);
      const telar::ds::Array<QQuickItem*, 3> bands{navigation.get(), sidebar.get(), status.get()};

      for (auto* band : bands) {
        band->setParentItem(window.contentItem());
        // Controls and separators may cover content; isolate the band's background.
        for (auto* child : band->childItems()) {
          child->setVisible(false);
        }
      }

      window.setColor(Qt::transparent);
      window.resize(width, fixture_height);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
      Configuration configuration;
      constexpr auto explicit_panel = Color::rgb(0x405060);
      constexpr CellColor explicit_panel_cell{.kind = CellColor::Kind::rgb, .channels = {0x40, 0x50, 0x60}};
      constexpr telar::ds::Array opacities{0.0F, 0.25F, 0.75F, 1.0F, 0.5F};

      for (const bool custom_panel : {false, true}) {
        configuration.theme.chrome.atMut(static_cast<std::size_t>(PaletteRole::panel_bg)) = custom_panel ? explicit_panel_cell : CellColor{};
        const auto covering = toQColor(custom_panel ? explicit_panel : configuration.theme.background);

        for (const auto opacity : opacities) {
          configuration.background_opacity = opacity;
          const auto colors = themeColors(configuration);
          const QColor expected = opacity < 1 ? QColor{Qt::transparent} : covering;

          QCOMPARE(colors.value(QStringLiteral("panelBackground")).value<QColor>(), expected);
          QCOMPARE(colors.value(QStringLiteral("panel_bg")).value<QColor>(), covering);
          for (auto* band : bands) {
            QVERIFY(band->setProperty("colors", colors));
            const auto role = bandBackgroundRole(band, {.sidebar = sidebar.get(), .status = status.get()});
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
            const telar::ds::Array differences{qRed(actual_ink) - qRed(expected_ink), qGreen(actual_ink) - qGreen(expected_ink), qBlue(actual_ink) - qBlue(expected_ink)};

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
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};

      application.loadConfiguration(configuration.fileName(), {}, {});
      QCOMPARE(application.status()->error(), QString{});
      QQmlEngine engine;
      const QVariantMap properties{
          {QStringLiteral("controller"), QVariant::fromValue(application.attachments())},
          {QStringLiteral("colors"), application.colors()},
          {QStringLiteral("typography"), application.display()->geometry().value(QStringLiteral("typography"))},
      };

      const auto load = [&](const QString& path) {
        QQmlComponent component{&engine, QUrl::fromLocalFile(path)};
        auto object = std::unique_ptr<QObject>{component.createWithInitialProperties(properties)};
        if (!object) {
          throw std::runtime_error{component.errorString().toStdString()};
        }

        return object;
      };

      const auto shelf = load(QFINDTESTDATA("../ui/app/panes/attachments/AttachmentShelf.qml"));
      const auto modal = load(QFINDTESTDATA("../ui/app/panes/attachments/AttachmentModal.qml"));
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

      constexpr int width = 1000;

      tabs.reconcile(tabRecords({.count = 2, .active = 0}));
      const auto properties = navigationProperties(tabs, width);
      const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), properties);

      navigation->setParentItem(window.contentItem());
      window.resize(width, ChromeMetrics{}.top_bar);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
      const auto* strip = navigation->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(strip != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*navigation, QStringLiteral("tabPill")).size(), 2, fixture_wait_ms);
      QVERIFY(navigation->setProperty("rail", true));
      QTRY_VERIFY_WITH_TIMEOUT(strip->width() > 0, fixture_wait_ms);
      // The room of the tabs starts above the sidebar, and the tabs sit in the middle of it.
      const auto* room = strip->parentItem();

      QVERIFY(room->mapToItem(navigation.get(), QPointF{}).x() < fixture_sidebar_width);
      QVERIFY(room->mapToItem(navigation.get(), QPointF{room->width(), 0}).x() <= width);
      QTRY_VERIFY_WITH_TIMEOUT(strip->x() > room->width() / 4, fixture_wait_ms);

      const QVariantMap bottom_properties{
          {QStringLiteral("controller"), QVariant::fromValue(static_cast<QObject*>(nullptr))},
          {QStringLiteral("surface"), QVariantMap{{QStringLiteral("kind"), QStringLiteral("tabs")}}},
          {QStringLiteral("colors"), themeColors(Configuration{})},
          {QStringLiteral("typography"), properties.value(QStringLiteral("typography"))},
      };

      const auto bottom = createChrome(engine, QStringLiteral("ComponentSlot"), bottom_properties);

      QCOMPARE(bottom->implicitWidth(), qreal{0});
      QVERIFY(bottom->findChild<TabStripLayout*>() == nullptr);
    }

    Q_SLOT static void selectedTabEmphasisDoesNotMoveAdjacentTabs() {
      QQuickWindow window;
      QQmlEngine engine;
      ListModel tabs;

      constexpr int width = 600;

      tabs.reconcile(tabRecords({.count = 2, .active = 0}));
      auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, width));

      strip->setParentItem(window.contentItem());
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      window.resize(width, ChromeMetrics{}.top_bar);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), fixture_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 2, fixture_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(selectedTabKey(*strip), QStringLiteral("tab:0"), fixture_wait_ms);
      const telar::ds::Array before{tabBounds(*layout->items(), 0), tabBounds(*layout->items(), 1)};

      tabs.reconcile(tabRecords({.count = 2, .active = 1}));
      QTRY_COMPARE_WITH_TIMEOUT(selectedTabKey(*strip), QStringLiteral("tab:1"), fixture_wait_ms);
      QCOMPARE(tabBounds(*layout->items(), 0), before[0]);
      QCOMPARE(tabBounds(*layout->items(), 1), before[1]);
    }

    Q_SLOT static void machineWorkspacesAndTabsReadInThatOrderInBothSidebarModes() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController application{memory};
      QQuickWindow window;
      QQmlEngine engine;
      ListModel tabs;
      ListModel workspaces;

      // Wide enough that the tabs do not fill their room.
      constexpr int width = 1200;
      constexpr int controls_inset = 80;
      constexpr std::size_t workspace_count = 3;

      tabs.reconcile(tabRecords({.count = 3, .active = 0}));
      workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = 1}));
      auto properties = navigationProperties(tabs, width);

      properties.insert(QStringLiteral("tabs"), QVariant::fromValue(application.tabs()));
      properties.insert(QStringLiteral("machineChrome"), QVariant::fromValue(application.machineChrome()));
      properties.insert(QStringLiteral("workspaceModel"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&workspaces)));
      properties.insert(QStringLiteral("workspace"), QVariantMap{{QStringLiteral("name"), QStringLiteral("project-1")}, {QStringLiteral("index"), 1}});
      properties.insert(QStringLiteral("controlsInset"), controls_inset);
      const auto navigation = createChrome(engine, QStringLiteral("NavigationBar"), properties);

      navigation->setParentItem(window.contentItem());
      window.resize(width, ChromeMetrics{}.top_bar);
      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      const auto* layout = navigation->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      const auto machines = visualItems(*navigation, QStringLiteral("topBarMachineLabel"));
      const auto tracks = visualItems(*navigation, QStringLiteral("workspaceTrack"));

      QCOMPARE(machines.size(), 1);
      QCOMPARE(tracks.size(), 1);
      const auto* machine = machines.front();
      auto* track = tracks.front();
      const auto active = application.machineChrome()->active();

      QVERIFY(!machine->property("text").toString().isEmpty());
      QCOMPARE(machine->property("text").toString(), active.value(QStringLiteral("label")).toString());
      QCOMPARE(active.value(QStringLiteral("initial")).toString(), machine->property("text").toString().left(1).toUpper());
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*track, QStringLiteral("workspaceSegment")).size(), static_cast<qsizetype>(workspace_count), fixture_wait_ms);
      // No breadcrumb names the workspace a second time, and nothing lists the projects on the right.
      QVERIFY(visualItems(*navigation, QStringLiteral("workspaceContextName")).isEmpty());
      QVERIFY(visualItems(*navigation, QStringLiteral("projectSwitcher")).isEmpty());
      for (const bool rail : {false, true}) {
        QVERIFY(navigation->setProperty("rail", rail));
        QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
        QVERIFY(track->isVisible() && machine->isVisible());
        const auto track_bounds = track->mapRectToItem(navigation.get(), track->boundingRect());
        const auto machine_bounds = machine->mapRectToItem(navigation.get(), machine->boundingRect());

        QVERIFY(machine_bounds.left() >= controls_inset);
        QVERIFY(machine_bounds.right() <= track_bounds.left());
        QVERIFY(track_bounds.right() < layout->mapToItem(navigation.get(), QPointF{}).x());
        // The tabs sit in the middle of the room the bar leaves them after the track.
        const auto* well = visualItems(*navigation, QStringLiteral("tabWell")).front();
        const auto* strip = well->parentItem();

        QVERIFY(well->width() < strip->width());
        QVERIFY2(qAbs(well->x() + well->width() / 2 - strip->width() / 2) <= 1, qPrintable(QStringLiteral("well %1+%2 in %3").arg(well->x()).arg(well->width()).arg(strip->width())));
        QVERIFY(strip->mapToItem(navigation.get(), QPointF{}).x() > track_bounds.right());
        // Three workspaces: the one in front keeps its name, the others their mark.
        qsizetype named = 0;

        for (const auto* name : visualItems(*track, QStringLiteral("workspaceSegmentName"))) {
          named += static_cast<qsizetype>(name->isVisible());
        }

        QCOMPARE(named, qsizetype{1});
        QVERIFY(visualItems(*navigation, QStringLiteral("topBarTelarMark")).isEmpty());

        const auto segments = visualItems(*track, QStringLiteral("workspaceSegment"));

        QTest::mouseMove(&window, segments.front()->mapRectToScene(segments.front()->boundingRect()).center().toPoint());
        QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, fixture_wait_ms);
      }
    }

    Q_SLOT static void tabsShareOneWellAndOneSelectionCapsule() {
      QQuickWindow window;
      QQmlEngine engine;
      ListModel tabs;

      constexpr int width = 800;

      tabs.reconcile(tabRecords({.count = 3, .active = 0}));
      const auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, width));

      strip->setParentItem(window.contentItem());
      window.resize(width, ChromeMetrics{}.top_bar);
      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 3, fixture_wait_ms);
      const auto wells = visualItems(*strip, QStringLiteral("tabWell"));
      const auto selections = visualItems(*strip, QStringLiteral("tabSelection"));

      QCOMPARE(wells.size(), 1);
      QCOMPARE(selections.size(), 1);
      QCOMPARE(layout->selectionBounds(), tabBounds(*layout->items(), 0));
      const auto* well = wells.front();
      const auto* selection = selections.front();

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

    // NOLINTNEXTLINE(readability-identifier-naming): Qt requires the _data suffix.
    Q_SLOT static void tabWellFitsNarrowAndScaledStrips_data() {
      constexpr int narrow_width = 48;
      constexpr int overflow_width = 120;
      constexpr int fractional_width = 180;
      constexpr qreal fractional_ratio = 1.5;
      constexpr int double_width = 800;

      QTest::addColumn<int>("width");
      QTest::addColumn<qreal>("ratio");
      QTest::newRow("narrow") << narrow_width << qreal{1};
      QTest::newRow("overflow") << overflow_width << qreal{1};
      QTest::newRow("fractional") << fractional_width << fractional_ratio;
      QTest::newRow("double") << double_width << qreal{2};
    }

    Q_SLOT static void tabWellFitsNarrowAndScaledStrips() {
      QFETCH(const int, width);
      QFETCH(const qreal, ratio);
      QQuickWindow window;
      QQmlEngine engine;
      ListModel tabs;

      constexpr std::size_t tab_count = 64;

      tabs.reconcile(tabRecords({.count = tab_count, .active = tab_count / 2}));
      auto properties = tabProperties(tabs, width);
      const auto height = ChromeMetrics::logical_top_bar * ratio;

      properties.insert(QStringLiteral("height"), height);
      properties.insert(QStringLiteral("ratio"), ratio);
      const auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), properties);

      strip->setParentItem(window.contentItem());
      window.resize(width, static_cast<int>(height));
      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QTRY_VERIFY_WITH_TIMEOUT(layout->items()->rowCount() > 0, fixture_wait_ms);
      const auto wells = visualItems(*strip, QStringLiteral("tabWell"));

      QCOMPARE(wells.size(), 1);
      const auto* well = wells.front();

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
      QVERIFY(sidebar->findChild<QQuickItem*>(QStringLiteral("workspaceList")) == nullptr);
      const auto* activity = sidebar->findChild<QQuickItem*>(QStringLiteral("sidebarActivity"));

      QVERIFY(activity != nullptr);
      constexpr QPointF expected_position{8, 40};
      constexpr QSizeF expected_size{264, 884};

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
      constexpr qreal expected_workspace_height = 55.5;
      // Card insets follow the default font, one size above the design font.
      constexpr qreal expected_card_height = 77;

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
          {QStringLiteral("agentModel"), QVariant::fromValue(static_cast<QAbstractItemModel*>(&agents))},
      };

      const auto sidebar = createChrome(engine, QStringLiteral("Sidebar"), properties);

      QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
      const auto* activity = sidebar->findChild<QQuickItem*>(QStringLiteral("sidebarActivity"));

      QVERIFY(activity != nullptr);
      QCOMPARE(activity->height(), regions.value(QStringLiteral("activity")).toRectF().height());
      QVERIFY(sidebar->findChild<QQuickItem*>(QStringLiteral("workspaceList")) == nullptr);
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
      const auto* sprite = mark->findChild<ProviderMark*>(QStringLiteral("applicationProviderMark"));
      const auto* glyph = mark->findChild<QQuickItem*>(QStringLiteral("applicationGlyph"));

      QVERIFY(sprite != nullptr);
      QVERIFY(glyph != nullptr);
      QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());

      for (const auto* const name : {"Claude Code", "CODEX.EXE", "pi", "Cursor Agent", "OpenCode"}) {
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
      for (const auto* const name : {u"bot", u"chevron-down", u"chevron-right", u"git-branch", u"server", u"square-terminal"}) {
        const auto icon = ProviderArtwork::symbol(name, mark_side);

        QVERIFY2(!icon.isNull() && icon.hasAlphaChannel(), "every bundled line icon must rasterize");
        QVERIFY(std::ranges::any_of(std::span{icon.constBits(), static_cast<std::size_t>(icon.sizeInBytes())}, [](uchar byte) {
          return byte != 0;
        }));
      }

      QVERIFY(ProviderArtwork::symbol(u"../fonts/telar-mark", mark_side).isNull());
      QVERIFY(ProviderArtwork::symbol(u"server", ApplicationMark::maximum_cell + 1).isNull());
      const auto application_artwork = ProviderArtwork::telar(mark_side);

      QCOMPARE(application_artwork.size(), QSize(mark_side, mark_side));
      QCOMPARE(application_artwork.pixelColor(0, 0).alpha(), 0);
      QImage transparent{application_artwork.size(), application_artwork.format()};

      transparent.fill(Qt::transparent);
      QVERIFY(application_artwork != transparent);
      const auto default_mark = ProviderArtwork::telar(mark_side, false);

      QVERIFY(!default_mark.isNull());
      // The default mark wears Zenburn's brand colors; Cybervenom keeps its own violet mark.
      QVERIFY(ProviderArtwork::telar(mark_side, false, static_cast<int>(ThemeName::cybervenom)) != default_mark);
      QVERIFY(ProviderArtwork::telar(mark_side, false, static_cast<int>(ThemeName::zenburn)) != default_mark);
      QCOMPARE(ProviderArtwork::telar(mark_side, false, std::numeric_limits<int>::max()), default_mark);
      const auto catppuccin_mark = ProviderArtwork::telar(mark_side, false, static_cast<int>(ThemeName::catppuccin));

      QVERIFY(!catppuccin_mark.isNull());
      QVERIFY(catppuccin_mark != default_mark);
      QCOMPARE(ProviderArtwork::telar(mark_side, true, static_cast<int>(ThemeName::catppuccin)), ProviderArtwork::telar(mark_side, true));
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
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::Memory& memory = adapter;
      GraphicsBudget budget;
      const telar::TabLocation location{.workspace = {.kind = telar::WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
      Tab tab{memory, location};
      application::Pane pane{memory, 1, budget};

      pane.location = location;
      pane.cwd.assign("/work/telar");
      pane.foreground.assign("Python");
      telar::ds::Array agents{Agent{memory}, Agent{memory}};

      agents.atMut(0).pane_id = pane.id;
      agents.atMut(agents.size() - 1).pane_id = pane.id;
      agents.atMut(0).location = {.workspace = location.workspace, .tab_id = 2};
      agents.atMut(0).title.assign("Other tab");
      agents.atMut(0).title_state = telar::AgentTitleState::ready;
      agents.atMut(agents.size() - 1).location = location;
      agents.atMut(agents.size() - 1).title.assign("Session title");
      for (const auto state : {telar::AgentTitleState::placeholder, telar::AgentTitleState::pending, telar::AgentTitleState::ready, telar::AgentTitleState::failed}) {
        agents.atMut(agents.size() - 1).title_state = state;
        const auto record = tabRecord(tab, &pane, telar::ds::Array<const application::Pane<telar::Memory>*, 1>{&pane}, std::span<const Agent<telar::Memory>>{agents}, true);

        QCOMPARE(record.value(QStringLiteral("label")).toString(), state == telar::AgentTitleState::placeholder ? QStringLiteral("telar · Python") : QStringLiteral("Session title"));
        QCOMPARE(record.value(QStringLiteral("application")).toString(), QStringLiteral("Python"));
      }

      agents.atMut(0).location = location;
      agents.atMut(0).title_state = telar::AgentTitleState::placeholder;
      QCOMPARE(tabRecord(tab, &pane, telar::ds::Array<const application::Pane<telar::Memory>*, 1>{&pane}, std::span<const Agent<telar::Memory>>{agents}, true).value(QStringLiteral("label")).toString(), QStringLiteral("telar · Python"));
      tab.label.assign("Review");
      tab.fullscreen = true;
      QCOMPARE(tabRecord(tab, &pane, telar::ds::Array<const application::Pane<telar::Memory>*, 1>{&pane}, std::span<const Agent<telar::Memory>>{agents}, true).value(QStringLiteral("label")).toString(), QStringLiteral("Review ⛶"));
    }

    Q_SLOT static void unloadedTabsShowTheirListedPanes() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::Memory& memory = adapter;
      const telar::TabLocation location{.workspace = {.kind = telar::WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 2};
      Tab tab{memory, location};
      const telar::ds::Array panes{telar::TabPane{.pane_id = 4, .foreground = "zsh", .cwd = "/work/telar"}, telar::TabPane{.pane_id = 5, .foreground = "nvim", .cwd = "/work/other"}};

      tab.observePanes(panes);
      telar::ds::Array agents{Agent{memory}};

      agents.atMut(0).pane_id = panes[1].pane_id;
      agents.atMut(0).location = location;
      agents.atMut(0).status = telar::AgentStatus::blocked;
      const auto record = tabRecord(tab, static_cast<const application::Pane<telar::Memory>*>(nullptr), std::span<const application::Pane<telar::Memory>* const>{}, std::span<const Agent<telar::Memory>>{agents}, false);

      QCOMPARE(record.value(QStringLiteral("title")).toString(), QStringLiteral("zsh"));
      QCOMPARE(record.value(QStringLiteral("path")).toString(), QStringLiteral("/work/telar"));
      const auto cards = record.value(QStringLiteral("cards")).toList();

      QCOMPARE(cards.size(), 2);
      QCOMPARE(cards[0].toMap().value(QStringLiteral("key")).toString(), QStringLiteral("4"));
      QVERIFY(cards[0].toMap().value(QStringLiteral("focused")).toBool());
      QCOMPARE(cards[1].toMap().value(QStringLiteral("program")).toString(), QStringLiteral("nvim"));
      QVERIFY(!cards[1].toMap().value(QStringLiteral("attentionColor")).toString().isEmpty());

      tab.loaded = true;
      QVERIFY(tabRecord(tab, static_cast<const application::Pane<telar::Memory>*>(nullptr), std::span<const application::Pane<telar::Memory>* const>{}, std::span<const Agent<telar::Memory>>{agents}, false).value(QStringLiteral("cards")).toList().isEmpty());
    }

    Q_SLOT static void transitioningTabsUseAnAlreadyScheduledFrame() {
      QQuickWindow window;
      ListModel tabs;
      QList<QVariantMap> rows;
      constexpr int tab_count = 4;
      constexpr QSize strip_size{800, 42};

      for (int id = 1; id <= tab_count; ++id) {
        rows.append({{QStringLiteral("key"), QString::number(id)}, {QStringLiteral("label"), QStringLiteral("Terminal")}});
      }

      tabs.reconcile(rows);
      TabStripLayout layout{window.contentItem()};

      layout.setSize(QSizeF{strip_size});
      layout.setContext(1, telar::WorkspaceLocation{.id = 1});
      QFont font{QStringLiteral("IBM Plex Sans")};

      font.setPixelSize(tab_font_pixel_size);
      layout.setFont(font);
      layout.setPixelSize(tab_font_pixel_size);
      layout.setModel(&tabs);
      window.resize(strip_size);
      window.show();
      QVERIFY(QTest::qWaitForWindowExposed(&window, fixture_wait_ms));
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      std::ranges::reverse(rows);
      tabs.reconcile(rows);
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QVERIFY(layout.transitioning());
      auto& clock = WindowAnimationClock::forWindow(window);
      auto* timer = clock.findChild<QTimer*>(QStringLiteral("agentStatusAnimation"));

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

      constexpr int strip_width = 800;

      layout.setSize(QSizeF{strip_width, ChromeMetrics::logical_top_bar});
      layout.setContext(1, telar::WorkspaceLocation{.id = 1});
      QFont font{QStringLiteral("IBM Plex Sans")};

      font.setPixelSize(tab_font_pixel_size);
      layout.setFont(font);
      layout.setPixelSize(tab_font_pixel_size);
      layout.setModel(&tabs);
      window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
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
      const telar::ds::Array sizes{
          Geometry::Measure{.caption = 180, .chip = Geometry::chip_widths[0]},
          Geometry::Measure{.caption = 20, .chip = Geometry::chip_widths[0]},
      };

      const auto room = sizes[0].whole(metrics) + metrics.gap + sizes[1].whole(metrics);
      const auto plan = Geometry::arrange(sizes, 0, {.width = room, .metrics = metrics});

      QCOMPARE(plan.hidden(), std::size_t{0});
      for (std::size_t index = 0; index < sizes.size(); ++index) {
        QCOMPARE(plan.fits[index], Geometry::Fit::full);
        QCOMPARE(plan.widths[index], sizes[index].whole(metrics));
      }

      constexpr float single_room = 150.0F;
      const auto single = Geometry::arrange(std::span{sizes}.first(1), 0, {.width = single_room, .metrics = metrics});

      QCOMPARE(single.widths[0], single_room);
      QCOMPARE(single.fits[0], Geometry::Fit::truncated);
    }

    Q_SLOT static void tabsKeepTheirCaptionsBeforeAnyTabCollapses() {
      using Geometry = TabStripGeometry;
      const auto metrics = Geometry::Metrics::scaled(1);
      telar::ds::Array<Geometry::Measure, 3> sizes;

      constexpr float long_caption = 400;

      sizes.fill({.caption = long_caption, .chip = Geometry::chip_widths[0]});
      const auto minimum_room = (sizes[0].truncated(metrics) * static_cast<float>(sizes.size())) + (metrics.gap * static_cast<float>(sizes.size() - 1));

      for (const auto room : {minimum_room, minimum_room + 30}) {
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
      constexpr int narrow_width = 180;
      constexpr int wide_width = 400;
      constexpr int label_length = 64;

      font.setPixelSize(tab_font_pixel_size);
      layout.setFont(font);
      layout.setPixelSize(tab_font_pixel_size);
      layout.setContext(1, telar::WorkspaceLocation{.id = 1});
      layout.setModel(&tabs);
      layout.setHovered(true);
      layout.setSize(QSizeF{narrow_width, ChromeMetrics::logical_top_bar});
      window.resize(wide_width, static_cast<int>(ChromeMetrics::logical_top_bar));
      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QList<QVariantMap> rows;

      for (int id = 1; id <= 3; ++id) {
        rows.append({{QStringLiteral("key"), QString::number(id)}, {QStringLiteral("label"), QString(label_length, QLatin1Char('W'))}, {QStringLiteral("selected"), id == 1}});
      }

      tabs.reconcile(rows);
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QVERIFY(!layout.counter().isEmpty());
      layout.setWidth(wide_width);
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
      constexpr int strip_width = 800;
      constexpr std::size_t tab_count = 4;

      tabs.reconcile(tabRecords({.count = tab_count, .active = 0}));
      auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(tabs, strip_width));

      strip->setParentItem(window.contentItem());
      window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
      window.show();
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), static_cast<int>(tab_count), fixture_wait_ms);
      const auto first = tabBounds(*layout->items(), 0);
      const auto second = tabBounds(*layout->items(), 1);

      QCOMPARE(first.top(), (ChromeMetrics::logical_top_bar - TabStripGeometry::pill_height) / 2);
      QCOMPARE(second.left(), first.right() + TabStripGeometry::gap);
      QCOMPARE(first.width(), second.width());

      layout->setHovered(true);
      tabs.reconcile(tabRecords({.count = tab_count, .active = 1}));
      const auto selected = [&] {
        return layout->items()->data(layout->items()->index(1, 0), ListModel::record_role).toMap().value(QStringLiteral("tab")).toMap().value(QStringLiteral("selected")).toBool();
      };

      QTRY_VERIFY_WITH_TIMEOUT(selected(), fixture_wait_ms);
      QCOMPARE(tabBounds(*layout->items(), 0), first);
      QCOMPARE(tabBounds(*layout->items(), 1), second);
      layout->setHovered(false);
      QTRY_COMPARE_WITH_TIMEOUT(tabBounds(*layout->items(), 1), second, fixture_wait_ms);
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
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

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
      constexpr int strip_width = 800;

      previous->reconcile(tabRecords({.count = 4, .active = 0}));
      current.reconcile(tabRecords({.count = 1, .active = 0}));
      auto strip = createChrome(engine, QStringLiteral("TerminalTabs"), tabProperties(*previous, strip_width));

      strip->setParentItem(window.contentItem());
      window.resize(strip_width, static_cast<int>(ChromeMetrics::logical_top_bar));
      window.show();
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 4, fixture_wait_ms);
      QVERIFY(strip->setProperty("model", QVariant::fromValue(static_cast<QAbstractItemModel*>(&current))));
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
      auto* layout = strip->findChild<TabStripLayout*>(QStringLiteral("tabStripLayout"));

      QVERIFY(layout != nullptr);
      QTRY_COMPARE_WITH_TIMEOUT(layout->items()->rowCount(), 1, fixture_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*strip, QStringLiteral("applicationNumber")).size(), 1, fixture_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*strip, QStringLiteral("applicationGlyph")).size(), 1, fixture_wait_ms);
      const auto* number = visualItems(*strip, QStringLiteral("applicationNumber")).front();
      const auto* glyph = visualItems(*strip, QStringLiteral("applicationGlyph")).front();

      QVERIFY(!number->isVisible() && glyph->isVisible());
      const auto bounds = tabBounds(*layout->items(), 0);
      const auto counter = layout->counter();

      QVERIFY(strip->setProperty("prefixPending", true));
      QVERIFY(number->isVisible() && !glyph->isVisible());
      QCOMPARE(number->property("text").toString(), QString::number(selected_index + 1));
      QCOMPARE(tabBounds(*layout->items(), 0), bounds);
      QCOMPARE(layout->counter(), counter);

      QVERIFY(strip->setProperty("prefixPending", false));
      QVERIFY(!number->isVisible() && glyph->isVisible());
      QCOMPARE(tabBounds(*layout->items(), 0), bounds);
    }

    Q_SLOT static void workspaceTrackShortensToItsRoomAndKeepsTheSelectionInView() {
      QQuickWindow window;
      QQmlEngine engine;
      ListModel workspaces;
      constexpr int workspace_count = 128;
      constexpr int room = 240;
      constexpr int wide_window = 1400;

      workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = workspace_count - 1}));
      const auto track = createChrome(engine, QStringLiteral("WorkspaceTrack"), workspaceTrackProperties(workspaces, room, workspace_count - 1));

      track->setParentItem(window.contentItem());
      window.resize(wide_window, static_cast<int>(ChromeMetrics::logical_top_bar));
      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      const auto selected = [&] -> QQuickItem* {
        for (auto* segment : visualItems(*track, QStringLiteral("workspaceSegment"))) {
          if (segment->property("record").toMap().value(QStringLiteral("selected")).toBool()) {
            return segment;
          }
        }

        return nullptr;
      };
      const auto inView = [&] {
        const auto* segment = selected();

        return segment != nullptr && track->boundingRect().contains(segment->mapRectToItem(track.get(), segment->boundingRect()));
      };
      const auto shownNames = [&] {
        qsizetype count = 0;

        for (const auto* name : visualItems(*track, QStringLiteral("workspaceSegmentName"))) {
          count += static_cast<qsizetype>(name->isVisible());
        }

        return count;
      };

      // More workspaces than the room holds: it never grows past the room, the one in front keeps
      // its name and stays in view, and the control at the end counts the ones it hides.
      QTRY_VERIFY_WITH_TIMEOUT(inView(), fixture_wait_ms);
      QVERIFY(track->width() <= room);
      QCOMPARE(shownNames(), qsizetype{1});
      const auto more = visualItems(*track, QStringLiteral("workspaceTrackMore"));
      const auto counts = visualItems(*track, QStringLiteral("workspaceTrackMoreLabel"));

      QCOMPARE(more.size(), 1);
      QCOMPARE(counts.size(), 1);
      QVERIFY(counts.front()->isVisible());
      QVERIFY(counts.front()->property("text").toString().startsWith(QLatin1Char('+')));
      QVERIFY(track->property("shownCount").toInt() < workspace_count);
      const auto signal = track->metaObject()->method(track->metaObject()->indexOfSignal("listRequested()"));

      QVERIFY(signal.isValid());
      const QSignalSpy requested{track.get(), signal};

      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, more.front()->mapRectToScene(more.front()->boundingRect()).center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(requested.size(), 1, fixture_wait_ms);
      workspaces.reconcile(workspaceRecords({.count = workspace_count, .active = 0}));
      QVERIFY(track->setProperty("selectedIndex", 0));
      QTRY_VERIFY_WITH_TIMEOUT(inView(), fixture_wait_ms);

      // Three workspaces or more: every mark shows and only the one in front keeps its name,
      // whatever the room, so the track leaves the tabs theirs.
      constexpr int few = 4;
      constexpr int pair = 2;

      workspaces.reconcile(workspaceRecords({.count = few, .active = 0}));
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*track, QStringLiteral("workspaceSegment")).size(), qsizetype{few}, fixture_wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(!counts.front()->isVisible(), fixture_wait_ms);
      QCOMPARE(shownNames(), qsizetype{1});
      QCOMPARE(track->property("shownCount").toInt(), few);

      QVERIFY(track->setProperty("room", wide_window));
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QCOMPARE(shownNames(), qsizetype{1});
      QCOMPARE(track->property("shownCount").toInt(), few);

      // Two workspaces with room for both names: each shows its own, and choosing the other
      // moves neither.
      workspaces.reconcile(workspaceRecords({.count = pair, .active = 0}));
      QVERIFY(track->setProperty("selectedIndex", 0));
      QTRY_COMPARE_WITH_TIMEOUT(shownNames(), qsizetype{pair}, fixture_wait_ms);
      // Each segment's bounds in the track, by its position in the list.
      const auto bounds = [&] {
        telar::ds::Array<QRectF, pair> placed{};

        for (const auto* segment : visualItems(*track, QStringLiteral("workspaceSegment"))) {
          placed.atMut(static_cast<std::size_t>(segment->property("index").toInt())) = segment->mapRectToItem(track.get(), segment->boundingRect());
        }

        return placed;
      };
      // The list places its segments on the frame after their widths change.
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      const auto before = bounds();

      workspaces.reconcile(workspaceRecords({.count = pair, .active = pair - 1}));
      QVERIFY(track->setProperty("selectedIndex", pair - 1));
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      const auto after = bounds();

      for (std::size_t index = 0; index < before.size(); ++index) {
        QCOMPARE(after[index], before[index]);
      }

      // No workspace, no track.
      workspaces.reconcile({});
      QVERIFY(track->setProperty("selectedIndex", -1));
      QTRY_COMPARE_WITH_TIMEOUT(track->implicitWidth(), qreal{0}, fixture_wait_ms);
      QVERIFY(!track->isVisible());
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
      const auto first_area = [&] -> QQuickItem* {
        for (auto* item : visualItems(*strip, QString{})) {
          if (item->inherits("QQuickMouseArea") && item->isVisible() && item->width() > 0) {
            return item;
          }
        }

        return nullptr;
      };

      QTRY_VERIFY_WITH_TIMEOUT(first_area() != nullptr, fixture_wait_ms);
      const auto* area = first_area();

      QTest::mouseMove(&window, area->mapRectToScene(area->boundingRect()).center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, fixture_wait_ms);
    }

    // NOLINTNEXTLINE(readability-identifier-naming): Qt requires the _data suffix.
    Q_SLOT static void buttonsShowThePointingCursorOnlyWhileEnabled_data() {
      QTest::addColumn<QString>("type");
      QTest::addColumn<QByteArray>("availability");
      QTest::newRow("chrome") << QStringLiteral("ChromeButton") << QByteArrayLiteral("enabled");
      QTest::newRow("form") << QStringLiteral("FormButton") << QByteArrayLiteral("interactive");
    }

    Q_SLOT static void buttonsShowThePointingCursorOnlyWhileEnabled() {
      QFETCH(const QString, type);
      QFETCH(const QByteArray, availability);
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

    Q_SLOT static void aWorkspaceClickEmitsOnlyItsWorkspaceIdentity() {
      QQuickWindow window;
      QQmlEngine engine;
      ListModel workspaces;

      constexpr int room = 600;

      workspaces.reconcile(workspaceRecords({.count = 3, .active = 0}));
      const auto track = createChrome(engine, QStringLiteral("WorkspaceTrack"), workspaceTrackProperties(workspaces, room, 0));

      track->setParentItem(window.contentItem());
      window.resize(room, static_cast<int>(ChromeMetrics::logical_top_bar));
      const auto signal = track->metaObject()->method(track->metaObject()->indexOfSignal("selected(QString)"));

      QVERIFY(signal.isValid());
      const QSignalSpy selected{track.get(), signal};

      window.show();
      QVERIFY(test::waitForSynchronizedFrame(window, fixture_wait_ms));
      QTRY_COMPARE_WITH_TIMEOUT(visualItems(*track, QStringLiteral("workspaceSegment")).size(), qsizetype{3}, fixture_wait_ms);
      const auto segments = visualItems(*track, QStringLiteral("workspaceSegment"));
      const auto* last = *std::ranges::max_element(segments, {}, [](const QQuickItem* segment) {
        return segment->property("index").toInt();
      });
      const auto record = last->property("record").toMap();

      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, last->mapRectToScene(last->boundingRect()).center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(selected.size(), 1, fixture_wait_ms);
      QCOMPARE(selected.front().front().toString(), record.value(QStringLiteral("key")).toString());
    }
  };

}

QTEST_MAIN(ChromeTest)
#include "chrome_test.moc"
