#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include "ui/app/panes/pane_motion_layout.hpp"
#include "ui/foundation/models/list_model.hpp"
#include <QGuiApplication>
#include <QQuickWindow>
#include <QRectF>
#include <QTimer>
#include <QtTest/QTest>
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

import telar.gui.features.workbench;
import telar.gui.foundation.core;
import telar.base.ds;

namespace {

  using namespace telar::gui;

  using namespace telar::gui::features::workbench;
  using namespace telar::gui::qt;
  using namespace telar::gui::test;

  constexpr int wait_ms = 5000;
  constexpr int window_width = 800;
  constexpr int window_height = 600;
  constexpr Rect whole{.width = window_width, .height = window_height};
  constexpr telar::ds::Array initial{PaneMotionSlot{.id = 1, .bounds = whole}};
  constexpr telar::ds::Array horizontal{PaneMotionSlot{.id = 1, .bounds = {.width = 390, .height = 600}}, PaneMotionSlot{.id = 2, .bounds = {.x = 410, .width = 390, .height = 600}}};
  constexpr telar::ds::Array vertical{PaneMotionSlot{.id = 1, .bounds = {.width = 800, .height = 290}}, PaneMotionSlot{.id = 2, .bounds = {.y = 310, .width = 800, .height = 290}}};

  // Times, in nanoseconds, at which a test changes the layout after the initial one at 0.
  constexpr std::uint64_t split_ns = 10;
  constexpr std::uint64_t resize_ns = 20;
  constexpr std::uint64_t snap_ns = 30;

  template <std::size_t index>
  Rect sample(const PaneMotions& motions, std::uint64_t now) {
    TabMotionFrame frame{.now_ns = now, .deadline_ns = telar::ds::none};

    return motions.place(index, frame);
  }

  QVariantMap record(const PaneMotionSlot& slot, const QString& context = QStringLiteral("tab-1")) {
    return {{QStringLiteral("key"), QString::number(slot.id)}, {QStringLiteral("motionContext"), context}, {QStringLiteral("x"), slot.bounds.x}, {QStringLiteral("y"), slot.bounds.y}, {QStringLiteral("width"), slot.bounds.width}, {QStringLiteral("height"), slot.bounds.height}};
  }

  QRectF visual(PaneMotionLayout& layout, int index) {
    const auto* model = layout.items();

    return model->data(model->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("visualBounds")).toRectF();
  }

  class PaneMotionTest final : public QObject {
    Q_OBJECT

    Q_SLOT static void splitsRevealFromTheFarEdgeWithoutChangingTargets() {
      for (const auto& split : {horizontal, vertical}) {
        PaneMotions motions;

        motions.update(initial, 0);
        QCOMPARE(sample<0>(motions, 0), whole);
        motions.update(split, split_ns);
        QCOMPARE(sample<0>(motions, split_ns), whole);
        const auto entrance = sample<1>(motions, split_ns);

        QVERIFY(entrance.width == 0 || entrance.height == 0);
        QCOMPARE(entrance.right(), split[1].bounds.right());
        QCOMPARE(entrance.bottom(), split[1].bounds.bottom());
        const auto middle = sample<1>(motions, split_ns + (PaneMotions::opening_ns / 2));

        QVERIFY(middle.width > 0 && middle.height > 0);
        QCOMPARE(sample<0>(motions, split_ns + PaneMotions::opening_ns), split[0].bounds);
        QCOMPARE(sample<1>(motions, split_ns + PaneMotions::opening_ns), split[1].bounds);
        TabMotionFrame frame{.now_ns = split_ns + PaneMotions::opening_ns, .deadline_ns = telar::ds::none};

        (void)motions.place(0, frame);
        (void)motions.place(1, frame);
        QVERIFY(!frame.deadline_ns);
      }
    }

    Q_SLOT static void closeAndInterruptedTransitionsStartAtTheVisiblePosition() {
      PaneMotions motions;

      motions.update(initial, 0);
      motions.update(horizontal, split_ns);
      const auto now = split_ns + (PaneMotions::opening_ns / 2);
      const auto visible = sample<0>(motions, now);

      motions.update(initial, now);
      QCOMPARE(sample<0>(motions, now), visible);
      QCOMPARE(sample<0>(motions, now + PaneMotions::closing_ns), whole);
    }

    Q_SLOT static void unchangedRefreshDoesNotRestartAndManualResizeIsImmediate() {
      PaneMotions motions;

      motions.update(initial, 0);
      motions.update(horizontal, split_ns);
      motions.update(horizontal, split_ns + (PaneMotions::opening_ns / 2));
      QCOMPARE(sample<0>(motions, split_ns + PaneMotions::opening_ns), horizontal[0].bounds);
      auto resized = horizontal;

      constexpr float resized_width = 300;
      constexpr float resized_gap = 20;

      resized.atMut(0).bounds.width = resized_width;
      resized.atMut(1).bounds.x = resized_width + resized_gap;
      resized.atMut(1).bounds.width = whole.width - resized_width - resized_gap;
      motions.update(resized, resize_ns);
      QCOMPARE(sample<0>(motions, resize_ns), resized[0].bounds);
      QCOMPARE(sample<1>(motions, resize_ns), resized[1].bounds);
      motions.update(initial, snap_ns, true);
      QCOMPARE(sample<0>(motions, snap_ns), whole);
    }

    Q_SLOT static void unrelatedViewsNeverAnimate() {
      PaneMotions motions;

      motions.update(initial, 0);
      auto unrelated = horizontal;

      unrelated.atMut(0).id = 3;
      unrelated.atMut(1).id = 4;
      motions.update(unrelated, split_ns);
      QCOMPARE(sample<0>(motions, split_ns), unrelated[0].bounds);
      QCOMPARE(sample<1>(motions, split_ns), unrelated[1].bounds);
    }

    Q_SLOT static void nativeLayoutSettlesAndStopsTheSharedTimer() {
      QQuickWindow window;
      ListModel model;
      PaneMotionLayout layout(window.contentItem());

      window.resize(window_width, window_height);
      layout.setSize({window_width, window_height});
      layout.setMotionEnabled(true);
      layout.setModel(&model);
      model.reconcile({record(initial[0])});
      QVERIFY(showComponentWindow(window, wait_ms));
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 1;
      },
          wait_ms));
      model.reconcile({record(horizontal[0]), record(horizontal[1])});
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 2;
      },
          wait_ms));
      QVERIFY(visual(layout, 0).width() > horizontal[0].bounds.width);
      QVERIFY(visual(layout, 1).width() < horizontal[1].bounds.width);
      // The source model, and therefore the PTY/grid geometry, already has its final size.
      QCOMPARE(model.data(model.index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("width")).toFloat(), horizontal[0].bounds.width);
      QVERIFY(waitForGuiCondition([&] {
        return visual(layout, 1) == QRectF(410, 0, 390, 600);
      },
          wait_ms));
      model.reconcile({record(initial[0])});
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 1;
      },
          wait_ms));
      QVERIFY(visual(layout, 0).width() < 800);
      QVERIFY(waitForGuiCondition([&] {
        return visual(layout, 0) == QRectF(0, 0, 800, 600);
      },
          wait_ms));
      const auto* timer = window.findChild<QTimer*>(QStringLiteral("agentStatusAnimation"));

      QVERIFY(timer != nullptr);
      QVERIFY(waitForGuiCondition([&] {
        return !timer->isActive();
      },
          wait_ms));
    }

    Q_SLOT static void contextChangesAndDisabledMotionSnapToTheTarget() {
      QQuickWindow window;
      ListModel model;
      PaneMotionLayout layout(window.contentItem());

      window.resize(window_width, window_height);
      layout.setSize({window_width, window_height});
      layout.setModel(&model);
      model.reconcile({record(initial[0])});
      QVERIFY(showComponentWindow(window, wait_ms));
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 1;
      },
          wait_ms));
      model.reconcile({record(horizontal[0], QStringLiteral("tab-2")), record(horizontal[1], QStringLiteral("tab-2"))});
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 2;
      },
          wait_ms));
      QCOMPARE(visual(layout, 1), QRectF(410, 0, 390, 600));
      layout.setMotionEnabled(false);
      model.reconcile({record(initial[0], QStringLiteral("tab-2"))});
      QVERIFY(waitForGuiCondition([&] {
        return layout.items()->rowCount() == 1;
      },
          wait_ms));
      QCOMPARE(visual(layout, 0), QRectF(0, 0, 800, 600));
    }
  };

}

QTEST_MAIN(PaneMotionTest)
#include "pane_motion_test.moc"
