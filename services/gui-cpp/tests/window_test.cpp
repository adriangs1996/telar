#include "application/dependencies.hpp"
#include "platform/window.hpp"
#include "qt/application.hpp"
#include "qt/terminal_item.hpp"
#include "ui/bundled_fonts.hpp"
#include <QCoreApplication>
#include <QEvent>
#include <QGuiApplication>
#include <QImage>
#include <QObject>
#include <QPointer>
#include <QQuickRenderTarget>
#include <QQuickWindow>
#include <QRectF>
#include <QSignalSpy>
#include <QSize>
#include <QString>
#include <QWindow>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <memory>

namespace {

using namespace telar::gui;
using namespace telar::gui::qt;

constexpr int native_wait_ms = 5'000;

class WindowTest final : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void readingControlsDoesNotCreateNativeResources() {
    const QWindow window;
    QVERIFY(window.handle() == nullptr);
    QCOMPARE(platform::windowControls(window), 0.0F);
    QVERIFY(window.handle() == nullptr);
  }

  Q_SLOT static void rebindingTheCurrentWindowPreservesConnections() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    client.setWindow(window);
    const QSignalSpy geometry{&client, &Application::windowGeometryChanged};
    client.setWindow(window);
    QCOMPARE(geometry.size(), 0);

    window.screenChanged(window.screen());
    QCOMPARE(geometry.size(), 1);
  }

  Q_SLOT static void aPreviousWindowCannotPublishScreenChanges() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow previous;
    QQuickWindow current;
    client.setWindow(previous);
    client.setWindow(current);
    const QSignalSpy geometry{&client, &Application::windowGeometryChanged};
    previous.screenChanged(previous.screen());
    QCOMPARE(geometry.size(), 0);

    current.screenChanged(current.screen());
    QCOMPARE(geometry.size(), 1);
  }

  Q_SLOT static void destroyingAPreviousWindowPreservesTheCurrentBinding() {
    ApplicationAllocator memory;
    Application client{memory};
    auto previous = std::make_unique<QQuickWindow>();
    QQuickWindow current;
    client.setWindow(*previous);
    client.setWindow(current);
    previous.reset();
    const QSignalSpy geometry{&client, &Application::windowGeometryChanged};
    client.setWindow(current);
    QCOMPARE(geometry.size(), 0);

    current.screenChanged(current.screen());
    QCOMPARE(geometry.size(), 1);
  }

  Q_SLOT static void onlyTheCurrentWindowPublishesDensityChanges() {
    constexpr QSize target_size{320, 240};
    constexpr qreal scale_factor = 1.25;
    ApplicationAllocator memory;
    Application client{memory};
    QImage image{target_size, QImage::Format_ARGB32_Premultiplied};
    QQuickWindow previous;
    QQuickWindow current;
    client.setWindow(previous);
    client.setWindow(current);
    const QSignalSpy geometry{&client, &Application::windowGeometryChanged};
    auto target = QQuickRenderTarget::fromPaintDevice(&image);
    target.setDevicePixelRatio(current.effectiveDevicePixelRatio() * scale_factor);
    previous.setRenderTarget(target);
    current.setRenderTarget(target);
    QEvent previous_density{QEvent::DevicePixelRatioChange};
    QCoreApplication::sendEvent(&previous, &previous_density);
    QCOMPARE(geometry.size(), 0);

    QEvent current_density{QEvent::DevicePixelRatioChange};
    QCoreApplication::sendEvent(&current, &current_density);
    QCOMPARE(geometry.size(), 1);

    QCoreApplication::sendEvent(&current, &current_density);
    QCOMPARE(geometry.size(), 1);
  }

  Q_SLOT static void aWindowCanBeDestroyedBeforeItsApplication() {
    ApplicationAllocator memory;
    Application client{memory};
    {
      QQuickWindow previous;
      client.setWindow(previous);
    }

    QQuickWindow current;
    client.setWindow(current);
    const QSignalSpy geometry{&client, &Application::windowGeometryChanged};
    current.screenChanged(current.screen());
    QCOMPARE(geometry.size(), 1);
  }

  Q_SLOT static void chromeBandsAndRowsFollowTheRenderTargetDensity() {
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    constexpr QSize logical_size{801, 503};
    constexpr QSize target_size{64, 64};
    window.resize(logical_size);
    client.setWindow(window);
    QImage image{target_size, QImage::Format_ARGB32_Premultiplied};

    struct Sample {
      qreal density;
      qreal navigation;
      qreal footer;
      qreal small_row;
    };

    constexpr std::array samples{
        Sample{.density = 0.8, .navigation = 34, .footer = 21, .small_row = 12},
        Sample{.density = 1, .navigation = 42, .footer = 26, .small_row = 15},
        Sample{.density = 1.25, .navigation = 53, .footer = 33, .small_row = 19},
        Sample{.density = 2, .navigation = 84, .footer = 52, .small_row = 29},
    };
    for (const auto sample : samples) {
      auto target = QQuickRenderTarget::fromPaintDevice(&image);
      target.setDevicePixelRatio(sample.density);
      window.setRenderTarget(target);
      QEvent changed{QEvent::DevicePixelRatioChange};
      QCoreApplication::sendEvent(&window, &changed);
      QCOMPARE(window.effectiveDevicePixelRatio(), sample.density);
      const auto geometry = client.windowGeometry();
      const auto typography = geometry.value(QStringLiteral("typography")).toMap();
      QCOMPARE(geometry.value(QStringLiteral("navigation")).toRectF().height(), sample.navigation / sample.density);
      QCOMPARE(geometry.value(QStringLiteral("status")).toRectF().height(), sample.footer / sample.density);
      QCOMPARE(typography.value(QStringLiteral("smallRow")).toReal(), sample.small_row / sample.density);
      const auto sidebar = client.sidebarGeometry();
      QCOMPARE(sidebar.value(QStringLiteral("typography")).toMap().value(QStringLiteral("smallRow")).toReal(), sample.small_row / sample.density);
    }
  }

  Q_SLOT static void nativeWindowDimensionsNeedNoQmlObserver() {
    constexpr QSize initial_size{900, 700};
    constexpr QSize replacement_size{1100, 800};
    ApplicationAllocator memory;
    Application client{memory};
    QQuickWindow window;
    window.resize(initial_size);
    client.setWindow(window);
    QCOMPARE(client.windowGeometry().value(QStringLiteral("navigation")).toRectF().width(), initial_size.width());

    window.resize(replacement_size);
    QTRY_COMPARE_WITH_TIMEOUT(window.size(), replacement_size, native_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client.windowGeometry().value(QStringLiteral("navigation")).toRectF().width(), replacement_size.width(), native_wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(client.windowGeometry().value(QStringLiteral("status")).toRectF().bottom(), replacement_size.height(), native_wait_ms);
  }

  Q_SLOT static void densityChangesRemeasureAnIndependentTerminal() {
    constexpr QSize target_size{320, 240};
    constexpr std::array scales{1.25, 2.0, 1.0};
    ApplicationAllocator memory;
    Application client{memory};
    QImage image{target_size, QImage::Format_ARGB32_Premultiplied};
    QQuickWindow window;
    TerminalItem terminal{window.contentItem()};
    terminal.setApplication(&client);
    for (const auto scale : scales) {
      auto target = QQuickRenderTarget::fromPaintDevice(&image);
      target.setDevicePixelRatio(scale);
      window.setRenderTarget(target);
      QEvent density{QEvent::DevicePixelRatioChange};
      QCoreApplication::sendEvent(&window, &density);
      QCOMPARE(window.effectiveDevicePixelRatio(), scale);
      QCOMPARE(terminal.cellSize(), client.resolveFont(scale).font.cell);
    }
  }

  Q_SLOT static void anApplicationCanBeDestroyedBeforeItsWindow() {
    ApplicationAllocator memory;
    QQuickWindow window;
    auto client = std::make_unique<Application>(memory);
    client->setWindow(window);
    const QPointer<Application> lifetime{client.get()};
    const QSignalSpy geometry{client.get(), &Application::windowGeometryChanged};
    client.reset();
    QVERIFY(lifetime.isNull());

    window.screenChanged(window.screen());
    QEvent density{QEvent::DevicePixelRatioChange};
    QCoreApplication::sendEvent(&window, &density);
    QCOMPARE(geometry.size(), 0);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  ui::bundledFonts();
  WindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "window_test.moc"
