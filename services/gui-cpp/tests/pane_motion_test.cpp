#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "frame_fixture.hpp"
#include "gui_wait.hpp"
#include <algorithm>
#include <cstdint>
#include <limits>
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <variant>
#include <cmath>
#include "../qt/list_model.hpp"
#include "../qt/pane_motion_layout.hpp"
#include <QGuiApplication>
#include <QQuickWindow>
#include <QRectF>
#include <QTimer>
#include <QtTest/QTest>

#include "qt/list_model.hpp"
#include "qt/pane_motion_layout.hpp"


import telar.gui.presentation.frame_pacer;

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr Rect whole{.width = 800, .height = 600};
constexpr std::array initial{PaneMotionSlot{.id = 1, .bounds = whole}};
constexpr std::array horizontal{PaneMotionSlot{.id = 1, .bounds = {.width = 390, .height = 600}}, PaneMotionSlot{.id = 2, .bounds = {.x = 410, .width = 390, .height = 600}}};
constexpr std::array vertical{PaneMotionSlot{.id = 1, .bounds = {.width = 800, .height = 290}}, PaneMotionSlot{.id = 2, .bounds = {.y = 310, .width = 800, .height = 290}}};

Rect sample(const PaneMotions &motions, std::size_t index, std::uint64_t now) {
  TabMotionFrame frame{.now_ns = now, .deadline_ns = std::nullopt};
  return motions.place(index, frame);
}

QVariantMap record(const PaneMotionSlot &slot, const QString &context = QStringLiteral("tab-1")) {
  return {{QStringLiteral("key"), QString::number(slot.id)}, {QStringLiteral("motionContext"), context}, {QStringLiteral("x"), slot.bounds.x}, {QStringLiteral("y"), slot.bounds.y}, {QStringLiteral("width"), slot.bounds.width}, {QStringLiteral("height"), slot.bounds.height}};
}

QRectF visual(PaneMotionLayout &layout, int index) {
  const auto *model = layout.items();
  return model->data(model->index(index, 0), ListModel::record_role).toMap().value(QStringLiteral("visualBounds")).toRectF();
}

class PaneMotionTest final : public QObject {
  Q_OBJECT

  Q_SLOT static void splitsRevealFromTheFarEdgeWithoutChangingTargets() {
    for (const auto &split : {horizontal, vertical}) {
      PaneMotions motions;
      motions.update(initial, 0);
      QCOMPARE(sample(motions, 0, 0), whole);
      motions.update(split, 10);
      QCOMPARE(sample(motions, 0, 10), whole);
      const auto entrance = sample(motions, 1, 10);
      QVERIFY(entrance.width == 0 || entrance.height == 0);
      QCOMPARE(entrance.right(), split[1].bounds.right());
      QCOMPARE(entrance.bottom(), split[1].bounds.bottom());
      const auto middle = sample(motions, 1, 10 + PaneMotions::opening_ns / 2);
      QVERIFY(middle.width > 0 && middle.height > 0);
      QCOMPARE(sample(motions, 0, 10 + PaneMotions::opening_ns), split[0].bounds);
      QCOMPARE(sample(motions, 1, 10 + PaneMotions::opening_ns), split[1].bounds);
      TabMotionFrame frame{.now_ns = 10 + PaneMotions::opening_ns, .deadline_ns = std::nullopt};
      (void)motions.place(0, frame);
      (void)motions.place(1, frame);
      QVERIFY(!frame.deadline_ns);
    }
  }

  Q_SLOT static void closeAndInterruptedTransitionsStartAtTheVisiblePosition() {
    PaneMotions motions;
    motions.update(initial, 0);
    motions.update(horizontal, 10);
    const auto now = 10 + PaneMotions::opening_ns / 2;
    const auto visible = sample(motions, 0, now);
    motions.update(initial, now);
    QCOMPARE(sample(motions, 0, now), visible);
    QCOMPARE(sample(motions, 0, now + PaneMotions::closing_ns), whole);
  }

  Q_SLOT static void unchangedRefreshDoesNotRestartAndManualResizeIsImmediate() {
    PaneMotions motions;
    motions.update(initial, 0);
    motions.update(horizontal, 10);
    motions.update(horizontal, 10 + PaneMotions::opening_ns / 2);
    QCOMPARE(sample(motions, 0, 10 + PaneMotions::opening_ns), horizontal[0].bounds);
    auto resized = horizontal;
    resized[0].bounds.width = 300;
    resized[1].bounds.x = 320;
    resized[1].bounds.width = 480;
    motions.update(resized, 20);
    QCOMPARE(sample(motions, 0, 20), resized[0].bounds);
    QCOMPARE(sample(motions, 1, 20), resized[1].bounds);
    motions.update(initial, 30, true);
    QCOMPARE(sample(motions, 0, 30), whole);
  }

  Q_SLOT static void unrelatedViewsNeverAnimate() {
    PaneMotions motions;
    motions.update(initial, 0);
    auto unrelated = horizontal;
    unrelated[0].id = 3;
    unrelated[1].id = 4;
    motions.update(unrelated, 10);
    QCOMPARE(sample(motions, 0, 10), unrelated[0].bounds);
    QCOMPARE(sample(motions, 1, 10), unrelated[1].bounds);
  }

  Q_SLOT static void nativeLayoutSettlesAndStopsTheSharedTimer() {
    QQuickWindow window;
    ListModel model;
    PaneMotionLayout layout(window.contentItem());
    window.resize(800, 600);
    layout.setSize({800, 600});
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
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
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
    window.resize(800, 600);
    layout.setSize({800, 600});
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
