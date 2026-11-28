#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QObject>
#include <QProcess>
#include <QProcessEnvironment>
#include <QQmlEngine>
#include <QQmlError>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QtCore/qbytearrayview.h>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlatin1stringview.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qobject.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <QtTest/qtestkeyboard.h>
#include <QtTest/qtestmouse.h>
#include <cstdint>
#include <memory>

import telar.gui.foundation.core;
import telar.gui.ui.app;
import telar.gui.ui.app.panes.terminal;
import telar.gui.ui.design.controls;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.input;
import telar.gui.ui.kit.models;
import telar.gui.tests.frame_fixture;
import telar.gui.tests.qml_fixture;
import telar.gui.tests.qt_case;
import telar.gui.tests.screen_fixture;
import telar.gui.qt;
import telar.gui.ui.app.overlays.palette;

namespace {
  using Qt::StringLiterals::operator""_s;

  using namespace telar::gui;
  using namespace telar::gui::qt;
  using telar::gui::test::screenText;
  using telar::gui::test::ScreenTextLayout;

  constexpr int wait_ms = 10'000;
  constexpr int window_width = 1000;
  constexpr int window_height = 640;

  QString luaLiteral(const QString& text) {
    QString delimiter;

    while (text.contains(QLatin1Char(']') + delimiter + QLatin1Char(']'))) {
      delimiter += QLatin1Char('=');
    }

    return QLatin1Char('[') + delimiter + QLatin1Char('[') + text + QLatin1Char(']') + delimiter + QLatin1Char(']');
  }

  class [[qt::object]] SuggestionControlsTest final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

  private:
  private:
    [[qt::slot]] void initTestCase() {
      QVERIFY(directory_.isValid());
      marker_ = directory_.filePath(u"suggestion-ran"_s);
      socket_ = directory_.filePath(u"runtime.sock"_s);
      const auto configuration = directory_.filePath(u"config.lua"_s);
      const auto command = u"return {api_version=2,runtime={session={persist=false},engine={timeout_ms=1000,command={%1,%2,%3}}}}"_s
                               .arg(luaLiteral(QString::fromUtf8(TELAR_GUI_TEST_PYTHON)), luaLiteral(QString::fromUtf8(TELAR_GUI_SUGGESTION_FIXTURE)), luaLiteral(marker_))
                               .toUtf8();
      QFile file{configuration};

      QVERIFY(file.open(QIODevice::WriteOnly));
      QCOMPARE(file.write(command), command.size());
      file.close();
      auto environment = QProcessEnvironment::systemEnvironment();

      for (const auto& name : environment.keys()) {
        if (name.startsWith(QLatin1StringView("TELAR_"))) {
          environment.remove(name);
        }
      }

      environment.remove(u"ENV"_s);
      environment.remove(u"BASH_ENV"_s);
      environment.insert(u"XDG_DATA_HOME"_s, directory_.filePath(u"data"_s));
      environment.insert(u"XDG_CONFIG_HOME"_s, directory_.filePath(u"config"_s));
      runtime_.setProgram(qEnvironmentVariable("TELAR_GUI_TEST_RUNTIME"));
      runtime_.setArguments({u"server"_s, u"--fresh"_s, u"--config"_s, configuration, u"--socket"_s, socket_});
      runtime_.setWorkingDirectory(directory_.path());
      runtime_.setProcessEnvironment(environment);
      runtime_.start();
      QVERIFY(runtime_.waitForStarted());
      QTRY_VERIFY2_WITH_TIMEOUT(QFileInfo::exists(socket_), runtime_.readAllStandardError().constData(), wait_ms);
      bundledFonts();
      client_ = std::make_unique<ApplicationController>(memory_);
      client_->roster()->configureLaunch(directory_.path(), {u"/bin/sh"_s}, false);
      client_->loadConfiguration(configuration, {}, {});
      window_->resize(window_width, window_height);
      client_->setWindow(*window_);
      client_->machines()->open(socket_);
      QTRY_COMPARE_WITH_TIMEOUT(client_->panes()->rows()->rowCount(), 1, wait_ms);
      const auto record = client_->panes()->rows()->data(client_->panes()->rows()->index(0, 0), ListModel::record_role).toMap();

      pane_id_ = record.value(u"key"_s).toString().toULongLong();
      terminal_ = std::make_unique<TerminalItem>(window_->contentItem());
      terminal_->setController(client_->terminals());
      terminal_->setPaneId(QString::number(pane_id_));
      connect(&engine_, &QQmlEngine::warnings, this, [this](const QList<QQmlError>& errors) {
        for (const auto& error : errors) {
          errors_ += error.toString() + QLatin1Char('\n');
        }
      });

      panel_ = test::createChrome(engine_, u"PalettePanel"_s, {{u"controller"_s, QVariant::fromValue(client_->palette())}, {u"colors"_s, client_->colors()}, {u"typography"_s, client_->display()->geometry().value(u"typography"_s)}, {u"controlModifier"_s, ApplicationController::controlModifier()}, {u"ratio"_s, WindowDisplay::chromeRatio()}});
      panel_->setParentItem(window_->contentItem());
      connect(client_->display(), &WindowDisplay::changed, this, &SuggestionControlsTest::synchronizeSurfaces);
      connect(client_->palette(), &PaletteController::changed, this, &SuggestionControlsTest::synchronizeSurfaces);
      connect(client_->dialogs(), &Dialogs::changed, this, &SuggestionControlsTest::synchronizeSurfaces);
      synchronizeSurfaces();
      QVERIFY(test::showComponentWindow(*window_, wait_ms));
      QTRY_VERIFY_WITH_TIMEOUT(client_->pane(pane_id_) != nullptr && client_->pane(pane_id_)->screen.frameId() != 0, wait_ms);
    }

    [[qt::slot]] void defaultShortcutOpensTheSuggestionEditor() {
      terminal_->forceActiveFocus();
      QVERIFY(terminal_->hasActiveFocus());
      QTest::keyClick(window_.get(), Qt::Key_B, NativeKeyAdapter::control_modifier);
      QVERIFY2(client_->status()->prefixPending(), qPrintable(client_->status()->error()));
      QTest::keyClick(window_.get(), Qt::Key_Question);
      QTRY_COMPARE_WITH_TIMEOUT(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette, wait_ms);
      QCOMPARE(client_->palette()->state().value(u"editorText"_s).toString(), u"?"_s);
      query()->forceActiveFocus();
      QTRY_VERIFY_WITH_TIMEOUT(query()->hasActiveFocus(), wait_ms);
      QCOMPARE(state().value(u"heading"_s).toString(), u"Start with a task"_s);
      client_->commands()->execute(window_actions::Action::cancel);
    }

    [[qt::slot]] void replacementRequestsDiscardTheEarlierCommandAndPasteOnlyOnConfirmation() {
      open(u"?fixture:delay"_s);
      submit();
      QCOMPARE(state().value(u"heading"_s).toString(), u"Generating a command…"_s);
      client_->palette()->search(u"?fixture:alternate"_s);
      QCOMPARE(state().value(u"heading"_s).toString(), u"Start with a task"_s);
      submit();
      QTRY_VERIFY_WITH_TIMEOUT(state().value(u"ready"_s).toBool(), wait_ms);
      const auto command = state().value(u"text"_s).toString();

      QVERIFY(command.contains(QLatin1StringView("ALTERNATE_REVIEW")));
      QVERIFY(!QFileInfo::exists(marker_));
      query()->forceActiveFocus();
      QTest::keyClick(window_.get(), Qt::Key_Return);
      QTRY_VERIFY_WITH_TIMEOUT((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(client_->pane(pane_id_)->screen, ScreenTextLayout::logical).contains(command), wait_ms);
      QVERIFY(!QFileInfo::exists(marker_));
      terminal_->forceActiveFocus();
      QTest::keyClick(window_.get(), Qt::Key_Return);
      const QByteArray expected{"ALTERNATE_REVIEW"};

      QTRY_COMPARE_WITH_TIMEOUT(QFileInfo{marker_}.size(), expected.size(), wait_ms);
      QFile marker{marker_};

      QVERIFY(marker.open(QIODevice::ReadOnly));
      QCOMPARE(marker.readAll(), expected);
      marker.close();
      QVERIFY(marker.remove());
    }

    [[qt::slot]] void providerFailureAndTimeoutCanRetryWithoutClosingTheComponent() {
      open(u"?fixture:fail"_s);
      submit();
      QTRY_VERIFY_WITH_TIMEOUT(state().value(u"failed"_s).toBool(), wait_ms);
      QCOMPARE(state().value(u"message"_s).toString(), u"The engine could not answer. Try again."_s);
      client_->palette()->search(u"?fixture:timeout"_s);
      submit();
      QTRY_VERIFY_WITH_TIMEOUT(state().value(u"failed"_s).toBool(), wait_ms);
      QCOMPARE(state().value(u"message"_s).toString(), u"The engine timed out. Try again."_s);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      client_->palette()->search(u"?fixture:ready"_s);
      submit();
      QTRY_VERIFY_WITH_TIMEOUT(state().value(u"ready"_s).toBool(), wait_ms);
      auto const* button = panel_->findChild<QQuickItem*>(u"suggestionSubmit"_s);

      QVERIFY(button != nullptr);
      QVERIFY(test::waitForSynchronizedFrame(*window_, wait_ms));
      const auto point = button->mapToScene({button->width() / 2, button->height() / 2}).toPoint();

      QTest::mousePress(window_.get(), Qt::LeftButton, Qt::NoModifier, point);
      client_->palette()->search(u"?edited before release"_s);
      QTest::mouseRelease(window_.get(), Qt::LeftButton, Qt::NoModifier, point);
      QCOMPARE(client_->dialogs()->kind(), telar::gui::qt::ApplicationController::Dialog::palette);
      QCOMPARE(state().value(u"heading"_s).toString(), u"Start with a task"_s);
      QVERIFY(!QFileInfo::exists(marker_));
      client_->commands()->execute(window_actions::Action::cancel);
    }

    [[qt::slot]] void shortenedPreviewsKeepTheEntirePaste() {
      open(u"?fixture:long"_s);
      submit();
      QTRY_VERIFY_WITH_TIMEOUT(state().value(u"ready"_s).toBool(), wait_ms);
      const auto lines = client_->palette()->suggestionGeometry().value(u"lines"_s).toList();

      QVERIFY(!lines.empty() && lines.back().toMap().value(u"shortened"_s).toBool());
      const auto command = state().value(u"text"_s).toString();

      submit();
      QTRY_VERIFY_WITH_TIMEOUT((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none), wait_ms);
      QTRY_VERIFY_WITH_TIMEOUT(screenText(client_->pane(pane_id_)->screen, ScreenTextLayout::logical).contains(command), wait_ms);
      QVERIFY(!QFileInfo::exists(marker_));
      client_->terminals()->input(pane_id_, "\x15");
    }

    [[qt::slot]] void cleanupTestCase() {
      panel_.reset();
      terminal_.reset();
      window_.reset();
      client_.reset();
      runtime_.terminate();
      if (!runtime_.waitForFinished()) {
        runtime_.kill();
        runtime_.waitForFinished();
      }

      QCOMPARE(errors_, QString{});
    }

    void synchronizeSurfaces() {
      if (!client_ || !terminal_ || !panel_) {
        return;
      }

      const auto terminal = client_->display()->geometry().value(u"terminal"_s).toRectF();

      terminal_->setPosition(terminal.topLeft());
      terminal_->setSize(terminal.size());
      const auto palette = client_->palette()->geometry().value(u"bounds"_s).toRectF();

      panel_->setPosition(palette.topLeft());
      panel_->setSize(palette.size());
      panel_->setVisible(client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::palette);
      if ((client_->dialogs()->kind() == telar::gui::qt::ApplicationController::Dialog::none)) {
        terminal_->forceActiveFocus();
      }
    }

    [[nodiscard]] QVariantMap state() const {
      return client_->palette()->suggestion();
    }

    [[nodiscard]] NativeFormField* query() const {
      return panel_->findChild<NativeFormField*>(u"commandSearch"_s);
    }

    void open(const QString& task) {
      client_->commands()->execute(window_actions::Action::suggest_command);
      client_->palette()->search(task);
      QVERIFY(query() != nullptr);
      query()->forceActiveFocus();
    }

    void submit() {
      client_->palette()->submitSuggestion(state().value(u"revision"_s).toString());
    }

    ApplicationMemory application_memory_;
    ApplicationAllocator& memory_ = application_memory_.memory();
    QTemporaryDir directory_{QDir::tempPath() + u"/telar-suggest-XXXXXX"_s};
    QProcess runtime_;
    std::unique_ptr<QQuickWindow> window_ = std::make_unique<QQuickWindow>();
    QQmlEngine engine_;
    std::unique_ptr<ApplicationController> client_;
    std::unique_ptr<TerminalItem> terminal_;
    std::unique_ptr<QQuickItem> panel_;
    QString marker_;
    QString socket_;
    QString errors_;
    std::uint64_t pane_id_ = 0;
  };

  using telar::gui::test::QtCase;

  const QtCase<SuggestionControlsTest, "defaultShortcutOpensTheSuggestionEditor"> case_default_shortcut_opens_the_suggestion_editor{"suggestion_controls.default_shortcut_opens_the_suggestion_editor"};
  const QtCase<SuggestionControlsTest, "replacementRequestsDiscardTheEarlierCommandAndPasteOnlyOnConfirmation"> case_replacement_requests_discard_the_earlier_command_and_paste_only_on_confirmation{"suggestion_controls.replacement_requests_discard_the_earlier_command_and_paste_only_on_confirmation"};
  const QtCase<SuggestionControlsTest, "providerFailureAndTimeoutCanRetryWithoutClosingTheComponent"> case_provider_failure_and_timeout_can_retry_without_closing_the_component{"suggestion_controls.provider_failure_and_timeout_can_retry_without_closing_the_component"};
  const QtCase<SuggestionControlsTest, "shortenedPreviewsKeepTheEntirePaste"> case_shortened_previews_keep_the_entire_paste{"suggestion_controls.shortened_previews_keep_the_entire_paste"};

}

#ifndef TELAR_MOC_RUN
#include "suggestion_controls_test.moc"
#endif