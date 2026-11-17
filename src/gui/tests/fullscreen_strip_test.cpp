#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "../core/memory.hpp"
#include "../core/terminal_size.hpp"
#include "../terminal/screen.hpp"
#include "qml_fixture.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_config/graphics/limits.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/app/panes/fullscreen_strip_layout.hpp"
#include "ui/app/panes/pane_projection.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QFont>
#include <QGuiApplication>
#include <QObject>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSignalSpy>
#include <QSizeF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobjectdefs.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestmouse.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <tuple>
#include <utility>
#include <variant>

#include "core/memory.hpp"
#include "ui/app/panes/fullscreen_strip_layout.hpp"
#include "ui/app/panes/pane_projection.hpp"
#include "ui/foundation/fonts/bundled_fonts.hpp"
#include "ui/foundation/models/projection.hpp"

import telar.gui.application.workspace_replica;
import telar.gui.core.metrics;
import telar.gui.graphics.texture_cache;
import telar.gui.presentation.activity_order;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int expanded_width = 1100;
  constexpr int compact_width = 320;
  constexpr int narrow_width = 100;
  constexpr int strip_height = 30;

  QVariantMap focusedRecord() {
    return {
        {QStringLiteral("agent"), QVariantMap{{QStringLiteral("statusCode"), static_cast<int>(AgentStatus::blocked)}, {QStringLiteral("blockedReason"), static_cast<int>(AgentBlockedReason::permission)}, {QStringLiteral("statusColor"), QStringLiteral("yellow")}}},
        {QStringLiteral("activityKind"), static_cast<int>(TabActivity::Kind::progress)},
        {QStringLiteral("activityColor"), QStringLiteral("teal")},
        {QStringLiteral("progressText"), QStringLiteral("70%")},
    };
  }

  QVariantList entries(int focused) {
    QVariantList result;
    constexpr int pane_count = 4;

    for (int index = 0; index < pane_count; ++index) {
      result.append(QVariantMap{
          {QStringLiteral("key"), QString::number(index + 1)},
          {QStringLiteral("index"), QString::number(index + 1)},
          {QStringLiteral("program"), QStringLiteral("program-%1").arg(index + 1)},
          {QStringLiteral("focused"), index == focused},
          {QStringLiteral("glyph"), QStringLiteral("\uea85")},
          {QStringLiteral("attentionColor"), index == focused ? QString{} : QStringLiteral("yellow")},
      });
    }

    return result;
  }

  QQuickItem* entryFor(QQuickItem& strip, const QString& key) {
    for (auto* item : visualItems(strip, QStringLiteral("fullscreenPaneEntry"))) {
      if (item->property("entry").toMap().value(QStringLiteral("key")).toString() == key) {
        return item;
      }
    }

    return nullptr;
  }

  class FullscreenStripTest final : public QObject {
    Q_OBJECT

    Q_SLOT static void initTestCase() {
      bundledFonts();
      QGuiApplication::setFont(QFont{QStringLiteral("IBM Plex Sans")});
    }

    Q_SLOT static void init() {
      QTest::failOnWarning(QRegularExpression{QStringLiteral(".*")});
    }

    Q_SLOT static void projectionUsesProgramOrderAndCurrentPaneGeneration() {
      SystemAllocator system;
      telar::MemoryAdapter adapter{system};
      telar::Memory& memory = adapter;
      GraphicsBudget budget;
      constexpr std::uint64_t pane_id = 7;
      Pane pane{memory, pane_id, budget};

      pane.location.tab_id = 1;
      pane.generation = 2;
      pane.attachment_generation = 3;
      pane.foreground = "claude";
      std::array<Agent<Memory>, 1> agents{{Agent<Memory>{memory}}};
      auto& agent = agents.front();

      agent.location = pane.location;
      agent.pane_id = pane.id;
      agent.pane_generation = pane.generation;
      agent.status = AgentStatus::blocked;
      const auto source = std::span<const Agent<Memory>>{agents};
      const FullscreenPaneEntry entry{.pane_id = pane.id, .index = 4};
      const auto record = fullscreenPaneRecord(&pane, source, entry);

      QCOMPARE(record.value(QStringLiteral("index")).toString(), QStringLiteral("4"));
      QCOMPARE(record.value(QStringLiteral("program")).toString(), QStringLiteral("claude"));
      QCOMPARE(record.value(QStringLiteral("attentionColor")).toString(), QStringLiteral("yellow"));
      QVERIFY(record.value(QStringLiteral("providerMark")).toInt() != 0);
      ++agent.pane_generation;
      QVERIFY(fullscreenPaneRecord(&pane, source, entry).value(QStringLiteral("attentionColor")).toString().isEmpty());
      agent.pane_generation = pane.generation;
      QVERIFY(fullscreenPaneRecord(&pane, source, {.pane_id = pane.id, .index = 4, .focused = true}).value(QStringLiteral("attentionColor")).toString().isEmpty());
      const auto missing = fullscreenPaneRecord<Memory>(nullptr, source, entry);

      QCOMPARE(missing.value(QStringLiteral("program")).toString(), QStringLiteral("shell"));
      QCOMPARE(missing.value(QStringLiteral("key")).toString(), QString::number(pane.id));
    }

    Q_SLOT static void independentStripKeepsFocusAndRoutesOnlyHiddenEntries() {
      QQmlEngine engine;
      QQuickWindow window;

      window.resize(expanded_width, strip_height);
      const ChromeMetrics chrome;
      const QVariantMap typography{{QStringLiteral("body"), chrome.body}, {QStringLiteral("small"), chrome.small}};
      constexpr int focused_index = 2;
      auto item = createChrome(engine, QStringLiteral("FullscreenStrip"), {
                                                                              {QStringLiteral("entries"), entries(focused_index)},
                                                                              {QStringLiteral("record"), focusedRecord()},
                                                                              {QStringLiteral("colors"), themeColors(Configuration{})},
                                                                              {QStringLiteral("typography"), typography},
                                                                          });

      item->setParentItem(window.contentItem());
      item->setSize({expanded_width, strip_height});
      const auto* layout = qobject_cast<FullscreenStripLayout*>(item.get());

      QVERIFY(layout != nullptr);
      const QSignalSpy selected{item.get(), SIGNAL(selected(QString))};
      const QSignalSpy leave{item.get(), SIGNAL(leaveFullscreen())};

      QVERIFY(selected.isValid() && leave.isValid());
      window.show();
      QTRY_VERIFY_WITH_TIMEOUT(window.isExposed() && layout->items().size() == 4 && layout->named(), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(layout->chipBounds().width() > 0 && layout->progressBounds().width() > 0, wait_ms);
      const auto* hidden = entryFor(*item, QStringLiteral("1"));

      QVERIFY(hidden != nullptr);
      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, hidden->mapToScene({hidden->width() / 2, hidden->height() / 2}).toPoint());
      QCOMPARE(selected.size(), 1);
      QCOMPARE(selected.front().front().toString(), QStringLiteral("1"));
      const auto* focused = entryFor(*item, QStringLiteral("3"));

      QVERIFY(focused != nullptr);
      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, focused->mapToScene({focused->width() / 2, focused->height() / 2}).toPoint());
      QCOMPARE(selected.size(), 1);
      QTest::mouseMove(&window, hidden->mapToScene({hidden->width() / 2, hidden->height() / 2}).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, wait_ms);
      QTest::mouseMove(&window, focused->mapToScene({focused->width() / 2, focused->height() / 2}).toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::ArrowCursor, wait_ms);
      QTest::mouseMove(&window, layout->leaveBounds().center().toPoint());
      QTRY_COMPARE_WITH_TIMEOUT(window.cursor().shape(), Qt::PointingHandCursor, wait_ms);
      item->setWidth(compact_width);
      item->ensurePolished();
      QTRY_VERIFY_WITH_TIMEOUT(!layout->named() && entryFor(*item, QStringLiteral("3")) != nullptr, wait_ms);
      item->setWidth(narrow_width);
      item->ensurePolished();
      QTRY_VERIFY_WITH_TIMEOUT(layout->progressBounds().isEmpty() && entryFor(*item, QStringLiteral("3")) != nullptr, wait_ms);
      QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, layout->leaveBounds().center().toPoint());
      QCOMPARE(leave.size(), 1);
      QCOMPARE(selected.size(), 1);
      item->setProperty("entries", entries(3));
      item->ensurePolished();
      QTRY_VERIFY_WITH_TIMEOUT(entryFor(*item, QStringLiteral("4")) != nullptr && entryFor(*item, QStringLiteral("3")) == nullptr, wait_ms);
      item->setProperty("entries", QVariantList{});
      item->ensurePolished();
      QTRY_VERIFY_WITH_TIMEOUT(layout->items().isEmpty() && layout->leaveBounds().isEmpty(), wait_ms);
    }
  };

}

QTEST_MAIN(FullscreenStripTest)
#include "fullscreen_strip_test.moc"
