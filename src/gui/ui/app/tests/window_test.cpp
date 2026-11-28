#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/window.hpp"
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

import telar.gui.foundation.core;
import telar.base.ds;
import telar.gui.ui.app;
import telar.gui.ui.app.panes.terminal;
import telar.gui.ui.kit.fonts;
import telar.gui.tests.qt_case;
import telar.gui.qt;

namespace {
  using Qt::StringLiterals::operator""_s;

  using namespace telar::gui;
  using namespace telar::gui::qt;

  constexpr int native_wait_ms = 5'000;

  class [[qt::object]] WindowTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
  private:
    [[qt::slot]] static void initTestCase() {
      bundledFonts();
    }

    [[qt::slot]] static void readingControlsDoesNotCreateNativeResources() {
      const QWindow window;

      QVERIFY(window.handle() == nullptr);
      QCOMPARE(platform::windowControls(window), 0.0F);
      QVERIFY(window.handle() == nullptr);
    }

    [[qt::slot]] static void rebindingTheCurrentWindowPreservesConnections() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      QQuickWindow window;

      client.setWindow(window);
      const QSignalSpy geometry{client.display(), &WindowDisplay::changed};

      client.setWindow(window);
      QCOMPARE(geometry.size(), 0);

      window.screenChanged(window.screen());
      QCOMPARE(geometry.size(), 1);
    }

    [[qt::slot]] static void aPreviousWindowCannotPublishScreenChanges() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      QQuickWindow previous;
      QQuickWindow current;

      client.setWindow(previous);
      client.setWindow(current);
      const QSignalSpy geometry{client.display(), &WindowDisplay::changed};

      previous.screenChanged(previous.screen());
      QCOMPARE(geometry.size(), 0);

      current.screenChanged(current.screen());
      QCOMPARE(geometry.size(), 1);
    }

    [[qt::slot]] static void destroyingAPreviousWindowPreservesTheCurrentBinding() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      auto previous = std::make_unique<QQuickWindow>();
      QQuickWindow current;

      client.setWindow(*previous);
      client.setWindow(current);
      previous.reset();
      const QSignalSpy geometry{client.display(), &WindowDisplay::changed};

      client.setWindow(current);
      QCOMPARE(geometry.size(), 0);

      current.screenChanged(current.screen());
      QCOMPARE(geometry.size(), 1);
    }

    [[qt::slot]] static void onlyTheCurrentWindowPublishesDensityChanges() {
      constexpr QSize target_size{320, 240};
      constexpr qreal scale_factor = 1.25;
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      QImage image{target_size, QImage::Format_ARGB32_Premultiplied};
      QQuickWindow previous;
      QQuickWindow current;

      client.setWindow(previous);
      client.setWindow(current);
      const QSignalSpy geometry{client.display(), &WindowDisplay::changed};
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

    [[qt::slot]] static void aWindowCanBeDestroyedBeforeItsApplication() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};

      {
        QQuickWindow previous;

        client.setWindow(previous);
      }

      QQuickWindow current;

      client.setWindow(current);
      const QSignalSpy geometry{client.display(), &WindowDisplay::changed};

      current.screenChanged(current.screen());
      QCOMPARE(geometry.size(), 1);
    }

    [[qt::slot]] static void chromeBandsAndRowsFollowTheRenderTargetDensity() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
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

      constexpr telar::ds::Array samples{
          Sample{.density = 0.8, .navigation = 38, .footer = 33, .small_row = 13},
          Sample{.density = 1, .navigation = 47, .footer = 41, .small_row = 17},
          Sample{.density = 1.25, .navigation = 59, .footer = 51, .small_row = 21},
          Sample{.density = 2, .navigation = 94, .footer = 81, .small_row = 34},
      };

      for (const auto sample : samples) {
        auto target = QQuickRenderTarget::fromPaintDevice(&image);

        target.setDevicePixelRatio(sample.density);
        window.setRenderTarget(target);
        QEvent changed{QEvent::DevicePixelRatioChange};

        QCoreApplication::sendEvent(&window, &changed);
        QCOMPARE(window.effectiveDevicePixelRatio(), sample.density);
        const auto geometry = client.display()->geometry();
        const auto typography = geometry.value(u"typography"_s).toMap();

        QCOMPARE(geometry.value(u"navigation"_s).toRectF().height(), sample.navigation / sample.density);
        QCOMPARE(geometry.value(u"status"_s).toRectF().height(), sample.footer / sample.density);
        QCOMPARE(typography.value(u"smallRow"_s).toReal(), sample.small_row / sample.density);
        const auto sidebar = client.sidebar()->regions();

        QCOMPARE(sidebar.value(u"typography"_s).toMap().value(u"smallRow"_s).toReal(), sample.small_row / sample.density);
      }
    }

    [[qt::slot]] static void nativeWindowDimensionsNeedNoQmlObserver() {
      constexpr QSize initial_size{900, 700};
      constexpr QSize replacement_size{1100, 800};
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      QQuickWindow window;

      window.resize(initial_size);
      client.setWindow(window);
      QCOMPARE(client.display()->geometry().value(u"navigation"_s).toRectF().width(), initial_size.width());

      window.resize(replacement_size);
      QTRY_COMPARE_WITH_TIMEOUT(window.size(), replacement_size, native_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client.display()->geometry().value(u"navigation"_s).toRectF().width(), replacement_size.width(), native_wait_ms);
      QTRY_COMPARE_WITH_TIMEOUT(client.display()->geometry().value(u"status"_s).toRectF().bottom(), replacement_size.height(), native_wait_ms);
    }

    [[qt::slot]] static void densityChangesRemeasureAnIndependentTerminal() {
      constexpr QSize target_size{320, 240};
      constexpr telar::ds::Array scales{1.25, 2.0, 1.0};
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      ApplicationController client{memory};
      QImage image{target_size, QImage::Format_ARGB32_Premultiplied};
      QQuickWindow window;
      TerminalItem terminal{window.contentItem()};

      terminal.setController(client.terminals());
      for (const auto scale : scales) {
        auto target = QQuickRenderTarget::fromPaintDevice(&image);

        target.setDevicePixelRatio(scale);
        window.setRenderTarget(target);
        QEvent density{QEvent::DevicePixelRatioChange};

        QCoreApplication::sendEvent(&window, &density);
        QCOMPARE(window.effectiveDevicePixelRatio(), scale);
        QCOMPARE(terminal.cellSize(), client.display()->resolveFont(scale).font.cell);
      }
    }

    [[qt::slot]] static void anApplicationCanBeDestroyedBeforeItsWindow() {
      ApplicationMemory application_memory;
      ApplicationAllocator& memory = application_memory.memory();
      QQuickWindow window;
      auto client = std::make_unique<ApplicationController>(memory);

      client->setWindow(window);
      const QPointer<ApplicationController> lifetime{client.get()};
      const QSignalSpy geometry{client->display(), &WindowDisplay::changed};

      client.reset();
      QVERIFY(lifetime.isNull());

      window.screenChanged(window.screen());
      QEvent density{QEvent::DevicePixelRatioChange};

      QCoreApplication::sendEvent(&window, &density);
      QCOMPARE(geometry.size(), 0);
    }
  };

  using telar::gui::test::QtCase;

  const QtCase<WindowTest, "readingControlsDoesNotCreateNativeResources"> case_reading_controls_does_not_create_native_resources{"window.reading_controls_does_not_create_native_resources"};
  const QtCase<WindowTest, "rebindingTheCurrentWindowPreservesConnections"> case_rebinding_the_current_window_preserves_connections{"window.rebinding_the_current_window_preserves_connections"};
  const QtCase<WindowTest, "aPreviousWindowCannotPublishScreenChanges"> case_a_previous_window_cannot_publish_screen_changes{"window.a_previous_window_cannot_publish_screen_changes"};
  const QtCase<WindowTest, "destroyingAPreviousWindowPreservesTheCurrentBinding"> case_destroying_a_previous_window_preserves_the_current_binding{"window.destroying_a_previous_window_preserves_the_current_binding"};
  const QtCase<WindowTest, "onlyTheCurrentWindowPublishesDensityChanges"> case_only_the_current_window_publishes_density_changes{"window.only_the_current_window_publishes_density_changes"};
  const QtCase<WindowTest, "aWindowCanBeDestroyedBeforeItsApplication"> case_a_window_can_be_destroyed_before_its_application{"window.a_window_can_be_destroyed_before_its_application"};
  const QtCase<WindowTest, "chromeBandsAndRowsFollowTheRenderTargetDensity"> case_chrome_bands_and_rows_follow_the_render_target_density{"window.chrome_bands_and_rows_follow_the_render_target_density"};
  const QtCase<WindowTest, "nativeWindowDimensionsNeedNoQmlObserver"> case_native_window_dimensions_need_no_qml_observer{"window.native_window_dimensions_need_no_qml_observer"};
  const QtCase<WindowTest, "densityChangesRemeasureAnIndependentTerminal"> case_density_changes_remeasure_an_independent_terminal{"window.density_changes_remeasure_an_independent_terminal"};
  const QtCase<WindowTest, "anApplicationCanBeDestroyedBeforeItsWindow"> case_an_application_can_be_destroyed_before_its_window{"window.an_application_can_be_destroyed_before_its_window"};

}

#ifndef TELAR_MOC_RUN
#include "window_test.moc"
#endif