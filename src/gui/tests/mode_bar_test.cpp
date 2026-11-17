#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "qml_fixture.hpp"
#include "ui/app/chrome/mode_bar/mode_projection.hpp"
#include "ui/design/controls/cell_text_grid.hpp"
#include "ui/design/controls/native_cell_text.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QCoreApplication>
#include <QDebug>
#include <QFont>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSGRendererInterface>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtCore/qvariant.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string_view>

import telar.gui.input.copy_pointer;
import telar.gui.foundation.actions;
import telar.gui.input.key_encoder;
import telar.gui.foundation.keys;
import telar.gui.presentation.history_inspection;
import telar.gui.presentation.history_meta_geometry;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int wide_width = 1200;
  constexpr int narrow_width = 100;
  constexpr int row_height = 26;
  constexpr int cell_test_window_height = 32;
  constexpr int cell_width = 9;
  constexpr int cell_height = 20;
  constexpr int font_pixels = 15;
  constexpr int small_pixels = 12;
  constexpr int baseline = 15;

  QVariantMap testGrid() {
    return {{QStringLiteral("cellWidth"), cell_width}, {QStringLiteral("cellHeight"), cell_height}, {QStringLiteral("pixelHeight"), font_pixels}, {QStringLiteral("baseline"), baseline}, {QStringLiteral("family"), QString{}}, {QStringLiteral("style"), QString{}}};
  }

  class ModeBarTest final : public QObject {
    Q_OBJECT

  private:
    Q_SLOT static void initTestCase() {
      bundledFonts();
      QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
    }

    Q_SLOT static void init() {
      QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
    }

    Q_SLOT static void hintsKeepConfiguredAliasOrderAndSkipLongSequences() {
      constexpr KeyChord prefix{.key = KeyChord::Key::character, .character = 'a', .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
      constexpr KeyChord first{.key = KeyChord::Key::character, .character = 'z'};
      constexpr KeyChord second{.key = KeyChord::Key::character, .character = 'a'};
      using Binding = KeyBinding<BindingAction>;
      constexpr std::array bindings{
          Binding{.keys = {prefix, first}, .length = 2, .action = {.kind = BindingActionKind::new_tab}},
          Binding{.keys = {prefix, second}, .length = 2, .action = {.kind = BindingActionKind::new_tab}},
          Binding{.keys = {prefix, {.key = KeyChord::Key::up}}, .length = 2, .action = {.kind = BindingActionKind::split_horizontal}},
          Binding{.keys = {prefix, {.key = KeyChord::Key::down}, first}, .length = 3, .action = {.kind = BindingActionKind::copy_mode}},
      };

      const KeyRouter router{BindingMap<BindingAction>{bindings}, prefix};
      const auto hints = ModeHints::resolve(router);

      QCOMPARE(hints.items().size(), std::size_t{2});
      QCOMPARE(hints.items().front().label, std::string_view{"split right"});
      QCOMPARE(hints.items().back().label, std::string_view{"new tab"});
      QVERIFY(hints.items().back().key == first);
      const KeyRouter without_prefix{BindingMap<BindingAction>{bindings}};

      QVERIFY(ModeHints::resolve(without_prefix).items().empty());
    }

    Q_SLOT static void unicodeKeyHintsPreservePackedUtf8() {
      for (const auto scalar : {U'ñ', U'中', U'😀'}) {
        const KeyChord key{.character = KeyCharacter::pack(scalar), .modifiers = static_cast<unsigned>(KeyChord::Modifier::control)};
        const auto label = ModeKeyLabel::format(key);
        const auto expected = QStringLiteral("Ctrl+") + QString::fromUcs4(&scalar, 1);

        QCOMPARE(QString::fromUtf8(label.view()), expected);
        QCOMPARE(KeyCharacter::codepoint(key.character), static_cast<std::uint32_t>(scalar));
      }
    }

    Q_SLOT static void prefixLabelsLeadWithCancelThenTheBoundActions() {
      ModeHints hints;

      hints.append({.key = {.key = KeyChord::Key::character, .character = 's'}, .label = "split right"});
      const auto labels = ModeBarLabels::resolve(StatusMode::prefix, hints);

      QCOMPARE(labels.title(), std::string_view{"PREFIX"});
      QCOMPARE(labels.hints().size(), std::size_t{2});
      QCOMPARE(labels.hints().front().key.view(), ModeBarLabels::cancel_key);
      QCOMPARE(labels.hints().back().key.view(), std::string_view{"s"});
      QCOMPARE(labels.hints().back().word.view(), std::string_view{"split right"});
      QVERIFY(ModeBarLabels::resolve(StatusMode::normal, hints).title().empty());
    }

    Q_SLOT static void standaloneModeBarDropsWholeHintsAndKeepsTheTitle() {
      QQuickWindow window;
      QQmlEngine engine;
      const QVariantMap properties{
          {QStringLiteral("width"), wide_width},
          {QStringLiteral("height"), row_height},
          {QStringLiteral("typography"), QVariantMap{{QStringLiteral("small"), small_pixels}}},
          {QStringLiteral("colors"), themeColors(Configuration{})},
          {QStringLiteral("mode"), statusModeRecord(StatusMode::copy)},
      };

      auto bar = createChrome(engine, QStringLiteral("ModeBar"), properties);

      bar->setParentItem(window.contentItem());
      window.resize(wide_width, row_height);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
      QVERIFY(!engine.rootContext()->contextProperty(QStringLiteral("telar")).isValid());
      QCOMPARE(bar->property("title").toString(), QStringLiteral("COPY"));
      const auto count = [&bar] {
        return bar->property("layout").toMap().value(QStringLiteral("hintCount")).toULongLong();
      };

      QTRY_COMPARE_WITH_TIMEOUT(count(), qulonglong{ModeBarLabels::copy_hints.size()}, wait_ms);
      const auto title = bar->property("layout").toMap().value(QStringLiteral("title")).toRectF();

      QVERIFY(title.width() > 0);
      bar->setWidth(title.width() + 1);
      QTRY_COMPARE_WITH_TIMEOUT(count(), qulonglong{0}, wait_ms);
      QCOMPARE(bar->property("layout").toMap().value(QStringLiteral("title")).toRectF().width(), title.width());
    }

    Q_SLOT static void cellTextRetainsItsWidthAndUsesWholeCellClipping() {
      QQuickWindow window;
      NativeCellText text{window.contentItem()};

      text.setGrid(testGrid());
      text.setText(QStringLiteral("WI"));
      text.setColor(Qt::white);
      text.setSize({2 * cell_width, row_height});
      window.setColor(Qt::black);
      window.resize(narrow_width, cell_test_window_height);
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && text.available(), wait_ms);
      qInfo() << "Scene graph API:" << window.rendererInterface()->graphicsApi();
      const auto density = window.effectiveDevicePixelRatio();
      const auto resolved = CellTextGrid::resolve(testGrid(), density);
      const auto expected_width = (2 * resolved.metrics.width) / density;

      QCOMPARE(text.implicitWidth(), expected_width);
      const auto regular = window.grabWindow();

      QVERIFY(!regular.isNull());
      text.setBold(true);
      const auto bold = window.grabWindow();

      QVERIFY(!bold.isNull() && regular != bold);
      text.setWidth(cell_width - 1);
      const auto clipped = window.grabWindow();
      QImage empty{clipped.size(), clipped.format()};

      empty.setDevicePixelRatio(clipped.devicePixelRatio());
      empty.fill(Qt::black);
      QCOMPARE(clipped, empty);
      QCOMPARE(text.implicitWidth(), expected_width);
      text.setWidth(2 * cell_width);
      QCOMPARE(window.grabWindow(), bold);
    }
  };

}

QTEST_MAIN(ModeBarTest)
#include "mode_bar_test.moc"
