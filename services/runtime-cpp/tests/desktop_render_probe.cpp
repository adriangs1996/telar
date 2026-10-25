#include "desktop_test_support.hpp"
#include "log_categories.hpp"
#include "protocol_peer.hpp"
#include "ui/workbench/runtime_connection.hpp"
#include "ui/workbench/terminal_item.hpp"
#include <QCryptographicHash>
#include <QGuiApplication>
#include <QInputMethodEvent>
#include <QJsonDocument>
#include <QKeyEvent>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <array>
#include <set>

namespace telar_log {
Q_LOGGING_CATEGORY(connection, "telar.connection")
Q_LOGGING_CATEGORY(frames, "telar.frames")
Q_LOGGING_CATEGORY(terminal, "telar.terminal")
}

using namespace desktop_test;

static telar::PaneOpened seed(const char *socket) {
  ProtocolPeer peer{socket};
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "stty -echo; printf '\\033[?25lREADY\\r\\n'; exec /bin/cat"};
  return peer.exchange<telar::PaneOpened>(telar::CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .name = "Desktop rendering", .launch = {.cwd = "/tmp", .arguments = arguments}});
}

static void input(workbench::TerminalItem &item, const QString &value) {
  QInputMethodEvent composition;
  composition.setCommitString(value);
  QCoreApplication::sendEvent(&item, &composition);
  require(composition.isAccepted(), "IME commit was rejected");

  QKeyEvent enter{QEvent::KeyPress, Qt::Key_Return, Qt::NoModifier};
  QCoreApplication::sendEvent(&item, &enter);
  require(enter.isAccepted(), "Return key was rejected");
}

static QJsonObject render(QQuickWindow &window, const QString &path, bool native) {
  QImage image;
  await([&] { image = window.grabWindow(); return !image.isNull(); }, "Qt Quick terminal render");
  image = image.convertToFormat(QImage::Format_RGBA8888);
  std::set<QRgb> colors;
  for (int row = 0; row < image.height(); ++row) {
    for (int column = 0; column < image.width(); ++column) {
      colors.insert(image.pixel(column, row));
    }
  }

  require(colors.size() > 16, "Qt Quick rendered an empty or uniform surface");
  require(image.save(path), "Could not save the rendered terminal");
  const auto pixels = QByteArrayView{reinterpret_cast<const char *>(image.constBits()), image.sizeInBytes()};
  const auto digest = QCryptographicHash::hash(pixels, QCryptographicHash::Sha256).toHex();
  if (native) {
    std::ofstream raw{(path + ".rgba").toStdString(), std::ios::binary};
    raw.write(pixels.data(), pixels.size());
    require(raw.good(), "Could not save Metal pixel readback");
  }
  return {{"width", image.width()}, {"height", image.height()}, {"colors", static_cast<qint64>(colors.size())}, {"pixels_sha256", QString::fromLatin1(digest)}};
}

static QJsonObject exercise(const char *socket, const char *output, bool native) {
  const auto pane = seed(socket);
  workbench::RuntimeConnection connection{QString::fromUtf8(socket), pane.location.workspace};
  auto screen = connection.screen(pane.pane_id);
  QQuickWindow window;
  workbench::TerminalItem item{screen, window.contentItem()};
  item.send = [&](const QByteArray &bytes) { connection.input(pane.pane_id, bytes); };
  item.resized = [&](telar::TerminalSize size) { connection.resize(pane.pane_id, size); };
  item.scrolled = [&](std::uint32_t offset) { connection.viewport(pane.pane_id, offset); };
  connection.painted = [&](std::uint64_t) { item.refresh(); };
  item.configure({{"font_size", 14}});
  window.resize(800, 480);
  item.setSize({800, 480});
  item.setPresented(true);
  window.show();
  connection.selectTab(pane.location.tab_id);
  connection.setVisible(true);
  await([&] { return screen->connected && text(*screen).contains("READY"); }, "render pane attachment");

  input(item, QString::fromUtf8("IME café 世界 👩‍💻"));
  await([&] { return text(*screen).contains("世界"); }, "IME and Return round trip");
  connection.input(pane.pane_id, "\x1b[31mRED\x1b[0m \x1b[1mBOLD\x1b[0m \x1b[4mUNDERLINE\x1b[0m DONE\n");
  await([&] { return text(*screen).contains("DONE"); }, "styled output");
  QJsonObject result{{"screen", snapshot(*screen)}, {"render", render(window, QString::fromUtf8(output) + ".png", native)}};
  if (native) {
    require(QGuiApplication::platformName() == "cocoa", "Native fixture did not use the macOS platform");
    require(window.rendererInterface()->graphicsApi() == QSGRendererInterface::Metal, "Native fixture did not use Metal");
    require(window.rendererInterface()->getResource(&window, QSGRendererInterface::DeviceResource) != nullptr, "Native fixture has no graphics device");
    result["graphics_api"] = "metal";
    result["platform"] = QGuiApplication::platformName();
  }

  window.resize(960, 540);
  item.setSize({960, 540});
  const auto columns = static_cast<std::uint16_t>(960 / item.cellSize().width());
  const auto rows = static_cast<std::uint16_t>(540 / item.cellSize().height());
  await([&] { return screen->columns == columns && screen->rows == rows; }, "render-driven terminal resize");
  input(item, "RESIZED");
  await([&] { return text(*screen).contains("RESIZED"); }, "input after GUI resize");
  result["resized_screen"] = snapshot(*screen);
  result["resized_render"] = render(window, QString::fromUtf8(output) + ".resized.png", native);
  require(connection.error().isEmpty(), connection.error().toStdString());
  connection.painted = {};
  connection.setVisible(false);
  window.hide();
  return result;
}

int main(int count, char **arguments) {
  const bool native = count == 4 && std::string_view{arguments[3]} == "native";
  QQuickWindow::setGraphicsApi(native ? QSGRendererInterface::Metal : QSGRendererInterface::Software);
  QGuiApplication application{count, arguments};
  if (count != 3 && !native) {
    return 2;
  }

  try {
    const auto output = QJsonDocument{exercise(arguments[1], arguments[2], native)}.toJson(QJsonDocument::Indented);
    std::ofstream file{arguments[2]};
    file.write(output.constData(), output.size());
    require(file.good(), "Could not save Desktop rendering results");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
