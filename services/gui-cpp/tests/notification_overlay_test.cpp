#include "application/dependencies.hpp"
#include "application/notification_item.hpp"
#include "core/configuration.hpp"
#include "platform/window_activation.hpp"
#include "qml_fixture.hpp"
#include "qt/application.hpp"
#include "qt/list_model.hpp"
#include "qt/notification_layout.hpp"
#include "qt/projection.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "ui/bundled_fonts.hpp"
#include <QAbstractItemModel>
#include <QByteArray>
#include <QColor>
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qtestsupport_core.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;

constexpr int wait_ms = 5000;
constexpr int window_width = 900;
constexpr int window_height = 600;
constexpr int idle_observation_ms = 50;
constexpr std::uint64_t fixture_notification_duration_ns = 30'000'000'000;

QVariantMap properties(Application &client) {
  return {
      {QStringLiteral("width"), window_width},
      {QStringLiteral("height"), window_height},
      {QStringLiteral("controller"), QVariant::fromValue(&client)},
      {QStringLiteral("colors"), themeColors(Configuration{})},
  };
}

class NotificationOverlayTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void initTestCase() {
    ui::bundledFonts();
  }

  Q_SLOT static void cardsKeepOriginalPlacementAndOutsideClicksDoNotDismiss() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    client.publishNotification({.level = NotificationLevel::warning, .title = "Agent needs input", .message = "Agent in pane 1 is waiting for input", .link = {}});
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*overlay, QStringLiteral("notificationCard")).size(), 1, wait_ms);
    auto *layout = qobject_cast<NotificationLayout *>(overlay.get());
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(client.notifications().items().front().phase, NotificationItem::Phase::visible, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(layout->cards()->data(layout->cards()->index(0, 0), ListModel::record_role).toMap().value(QStringLiteral("opacity")).toFloat(), 1.0F, wait_ms);
    const auto *card = visualItems(*overlay, QStringLiteral("notificationCard")).front();
    const auto bounds = [&] {
      return card->property("record").toMap().value(QStringLiteral("bounds")).toRectF();
    };
    constexpr qreal margin = 16;
    QTRY_COMPARE_WITH_TIMEOUT(bounds().right(), layout->host().right() - margin, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(bounds().top(), layout->host().top() + margin, wait_ms);
    const auto record = card->property("record").toMap();
    QCOMPARE(record.value(QStringLiteral("accent")).toString(), QStringLiteral("yellow"));
    QCOMPARE(record.value(QStringLiteral("shadows")).toList().size(), 3);
    QVERIFY(!window.grabWindow().isNull());

    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, {0, 0});
    QCOMPARE(client.notifications().items().size(), std::size_t{1});
    QCOMPARE(client.notifications().items().front().phase, NotificationItem::Phase::visible);
    const auto close = visualItems(*overlay, QStringLiteral("notificationClose"));
    QCOMPARE(close.size(), 1);
    QTest::mouseClick(&window, Qt::LeftButton, Qt::NoModifier, close.front()->mapToScene({close.front()->width() / 2, close.front()->height() / 2}).toPoint());
    QCOMPARE(client.notifications().items().front().phase, NotificationItem::Phase::exiting);
    QTRY_VERIFY_WITH_TIMEOUT(client.notifications().items().empty(), wait_ms);
    QTRY_VERIFY_WITH_TIMEOUT(visualItems(*overlay, QStringLiteral("notificationCard")).empty(), wait_ms);
  }

  Q_SLOT static void newestTwoCardsRetainPainterOrderAndOwnedText() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    client.publishNotification({.title = "Oldest", .message = "first", .link = {}});
    client.publishNotification({.title = "Middle", .message = "second", .link = {}});
    client.publishNotification({.title = "Newest", .message = "first\nsecond\nthird\nfourth", .link = "https://example.com/path"});
    auto *layout = qobject_cast<NotificationLayout *>(overlay.get());
    QVERIFY(layout != nullptr);
    QTRY_COMPARE_WITH_TIMEOUT(layout->cards()->rowCount(), 2, wait_ms);
    const auto older = layout->cards()->data(layout->cards()->index(0, 0), ListModel::record_role).toMap();
    const auto newest = layout->cards()->data(layout->cards()->index(1, 0), ListModel::record_role).toMap();
    QCOMPARE(older.value(QStringLiteral("title")).toString(), QStringLiteral("Middle"));
    QCOMPARE(newest.value(QStringLiteral("title")).toString(), QStringLiteral("Newest"));
    QCOMPARE(newest.value(QStringLiteral("action")).toString(), QStringLiteral("Open example.com ↗"));
    const auto lines = newest.value(QStringLiteral("body")).toList();
    QCOMPARE(lines.size(), 3);
    QCOMPARE(lines.back().toMap().value(QStringLiteral("text")).toString(), QStringLiteral("third…"));
    QVERIFY(newest.value(QStringLiteral("accessible")).toString().contains(QStringLiteral("opens example.com")));
  }

  Q_SLOT static void anEmptyOverlayParksTheWindowAnimationTimer() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    const auto *timer = window.findChild<QTimer *>(QStringLiteral("agentStatusAnimation"));
    QVERIFY(timer != nullptr);
    QTRY_VERIFY_WITH_TIMEOUT(!timer->isActive(), wait_ms);
    QTest::qWait(idle_observation_ms);
    QVERIFY(!timer->isActive());
  }

  Q_SLOT static void pointerFocusAndHoverFollowTheTopmostControl() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    activateWindow(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isActive(), wait_ms);
    client.publishNotification({.title = "Review build", .message = "Open the build result", .link = "https://example.com/build", .duration_ns = fixture_notification_duration_ns});
    QTRY_COMPARE_WITH_TIMEOUT(client.notifications().items().front().phase, NotificationItem::Phase::visible, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(visualItems(*overlay, QStringLiteral("notificationClose")).size(), 1, wait_ms);
    auto *body = visualItems(*overlay, QStringLiteral("notificationBody")).front();
    const auto *close = visualItems(*overlay, QStringLiteral("notificationClose")).front();
    const auto body_point = body->mapToScene({body->width() / 2, body->height() / 2}).toPoint();
    const auto close_point = close->mapToScene({close->width() / 2, close->height() / 2}).toPoint();
    const auto *underline = visualItems(*overlay, QStringLiteral("notificationUnderline")).front();
    const auto *body_focus = visualItems(*overlay, QStringLiteral("notificationBodyFocus")).front();
    const auto *close_focus = visualItems(*overlay, QStringLiteral("notificationCloseFocus")).front();
    QTest::mouseMove(&window, body_point);
    QTRY_VERIFY_WITH_TIMEOUT(underline->isVisible(), wait_ms);
    const auto density = window.effectiveDevicePixelRatio();
    const auto underline_center = underline->mapToScene({underline->width() / 2, underline->height() / 2});
    const auto column = static_cast<int>(std::floor(underline_center.x() * density));
    const auto row = static_cast<int>(std::floor(underline_center.y() * density));
    const auto accent = underline->property("color").value<QColor>().rgba();
    QTRY_COMPARE_WITH_TIMEOUT(window.grabWindow().pixelColor(column, row).rgba(), accent, wait_ms);
    QVERIFY(!body_focus->isVisible() && !close_focus->isVisible());
    QTest::mouseMove(&window, close_point);
    QTRY_VERIFY_WITH_TIMEOUT(close->property("hovered").toBool(), wait_ms);
    QVERIFY(!underline->isVisible());
    body->forceActiveFocus(Qt::TabFocusReason);
    QTRY_VERIFY_WITH_TIMEOUT(body_focus->isVisible(), wait_ms);
    QVERIFY(!close_focus->isVisible());
    QTest::keyClick(&window, Qt::Key_Tab);
    QTRY_VERIFY_WITH_TIMEOUT(close_focus->isVisible(), wait_ms);
    QVERIFY(!body_focus->isVisible());
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, close_point);
    QCOMPARE(client.notifications().items().front().phase, NotificationItem::Phase::exiting);
    QTest::mouseMove(&window, {0, 0});
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, {0, 0});
    QTRY_VERIFY_WITH_TIMEOUT(client.notifications().items().empty(), wait_ms);
  }

  Q_SLOT static void keyboardActionsActivateOnPress() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    client.execute(Application::Action::toggle_sidebar);
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    activateWindow(window);
    QTRY_VERIFY_WITH_TIMEOUT(window.isActive(), wait_ms);
    constexpr std::array keys{Qt::Key_Return, Qt::Key_Enter, Qt::Key_Space};
    const std::array controls{QStringLiteral("notificationBody"), QStringLiteral("notificationClose")};
    for (const auto &control : controls) {
      for (const auto key : keys) {
        client.publishNotification({.title = "Keyboard notice", .message = "Ready", .link = {}, .duration_ns = fixture_notification_duration_ns});
        QTRY_COMPARE_WITH_TIMEOUT(client.notifications().items().front().phase, NotificationItem::Phase::visible, wait_ms);
        QTRY_COMPARE_WITH_TIMEOUT(visualItems(*overlay, control).size(), 1, wait_ms);
        auto *button = visualItems(*overlay, control).front();
        button->forceActiveFocus(Qt::TabFocusReason);
        QTest::keyPress(&window, key);
        QCOMPARE(client.notifications().items().front().phase, NotificationItem::Phase::exiting);
        QTest::keyRelease(&window, key);
        QTRY_VERIFY_WITH_TIMEOUT(client.notifications().items().empty(), wait_ms);
      }
    }
  }

  Q_SLOT static void configuredAndCallbackActionsPublishWithoutStealingFocus() {
    const QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("config.lua"));
    QFile file{path};
    QVERIFY(file.open(QIODevice::WriteOnly));
    const QByteArray source{R"(
      return {api_version=2,client={keybindings={
        telar.bind_global({'alt+n'},telar.action.notification{title='Configured notice',body='direct body',level='warning'}),
        telar.bind_global({'alt+b'},function()
          return telar.action.notification{title='Callback notice',body='callback body',level='success'}
        end)
      }}}
    )"};
    QCOMPARE(file.write(source), source.size());
    file.close();

    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    QQmlEngine engine;
    window.resize(window_width, window_height);
    client.setWindow(window);
    client.loadConfiguration(path, {}, {});
    QCOMPARE(client.error(), QString{});
    const auto overlay = createChrome(engine, QStringLiteral("NotificationOverlay"), properties(client));
    overlay->setParentItem(window.contentItem());
    window.show();
    QTRY_VERIFY_WITH_TIMEOUT(window.isExposed(), wait_ms);
    overlay->forceActiveFocus();
    QCOMPARE(window.activeFocusItem(), overlay.get());
    QTest::keyClick(&window, Qt::Key_N, Qt::AltModifier);
    QTRY_COMPARE_WITH_TIMEOUT(client.notifications().items().size(), std::size_t{1}, wait_ms);
    QCOMPARE(client.notifications().items().front().title.view(), std::string_view{"Configured notice"});
    QCOMPARE(client.notifications().items().front().level, NotificationLevel::warning);
    QTest::keyClick(&window, Qt::Key_B, Qt::AltModifier);
    QTRY_COMPARE_WITH_TIMEOUT(client.notifications().items().size(), std::size_t{2}, wait_ms);
    QCOMPARE(client.notifications().items().front().title.view(), std::string_view{"Callback notice"});
    QCOMPARE(client.notifications().items().front().level, NotificationLevel::success);
    QCOMPARE(client.error(), QString{});
    QCOMPARE(window.activeFocusItem(), overlay.get());
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  NotificationOverlayTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "notification_overlay_test.moc"
