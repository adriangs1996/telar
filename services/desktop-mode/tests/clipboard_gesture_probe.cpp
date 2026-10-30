#include "ui/workbench/terminal_clipboard.hpp"
#include "../../runtime-cpp/tests/desktop_test_support.hpp"
#include "../../runtime-cpp/tests/protocol_peer.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QKeySequence>
#include <QMimeData>
#include <QQuickWindow>
#include <fstream>
#include <poll.h>
#include <termios.h>

using namespace desktop_test;
using namespace telar;

namespace {
void writeAll(std::string_view bytes) {
  while (!bytes.empty()) {
    const auto count = ::write(STDOUT_FILENO, bytes.data(), bytes.size());
    if (count < 0 && errno == EINTR) {
      continue;
    }
    require(count > 0, "PTY child write failed");
    bytes.remove_prefix(static_cast<std::size_t>(count));
  }
}

std::string readInput(std::size_t endings) {
  std::string result;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};
  std::size_t received_endings = 0;
  while (received_endings != endings) {
    require(std::chrono::steady_clock::now() < deadline, "PTY child response timed out");
    pollfd pending{STDIN_FILENO, POLLIN, 0};
    if (::poll(&pending, 1, 50) <= 0) {
      continue;
    }
    char byte;
    const auto count = ::read(STDIN_FILENO, &byte, 1);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    require(count == 1, "PTY child response ended");
    result += byte;
    require(result.size() <= 8192, "PTY child response exceeds fixture bound");
    received_endings += result.ends_with("\x1b\\");
  }
  return result;
}

void expectCommand(char expected) {
  char actual;
  require(::read(STDIN_FILENO, &actual, 1) == 1 && actual == expected, "PTY fixture command changed");
}

int child(const char *path) {
  termios settings{};
  require(::tcgetattr(STDIN_FILENO, &settings) == 0, "Could not read private PTY settings");
  ::cfmakeraw(&settings);
  require(::tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0, "Could not set private PTY raw mode");
  writeAll("\x1b[?5522h\r\ngesture-ready\r\n");
  const auto listing = readInput(3);
  constexpr std::string_view prefix = "\x1b]5522;type=read:status=OK:pw=";
  require(listing.starts_with(prefix), "Paste did not produce a targets listing");
  const auto end = listing.find("\x1b\\", prefix.size());
  require(end != std::string::npos, "Paste listing password is missing");
  const auto password = listing.substr(prefix.size(), end - prefix.size());
  const auto decoded = QByteArray::fromBase64(QByteArray::fromStdString(password), QByteArray::AbortOnBase64DecodingErrors);
  require(decoded.size() == 22, "One-use paste password length changed");
  constexpr std::string_view alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  for (const auto byte : decoded) {
    require(alphabet.find(byte) != std::string_view::npos, "Invalid one-use paste password byte");
  }
  const auto expected = std::string{prefix} + password + "\x1b\\\x1b]5522;type=read:status=DATA:mime=Lg==:pw=" + password + ";dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1b\\\x1b]5522;type=read:status=DONE:pw=" + password + "\x1b\\";
  require(listing == expected, "Targets listing bytes changed");
  writeAll("\r\nlisting-delivered\r\n");
  expectCommand('R');
  writeAll("\x1b]5522;type=read:id=follow:name=QXBw:pw=" + password + ";dGV4dC9wbGFpbg==\x1b\\");
  require(readInput(3) == "\x1b]5522;type=read:status=OK:id=follow\x1b\\\x1b]5522;type=read:status=DATA:id=follow:mime=dGV4dC9wbGFpbg==;b3duZWQgcGFzdGU=\x1b\\\x1b]5522;type=read:status=DONE:id=follow\x1b\\", "Follow-up clipboard read bytes changed");
  writeAll("\x1b[?5522l\x1b[?2004h\r\nordinary-paste-ready\r\n");
  constexpr std::string_view ordinary = "\x1b[200~owned paste\x1b[201~";
  std::string pasted;
  while (pasted.size() < ordinary.size()) {
    char byte;
    require(::read(STDIN_FILENO, &byte, 1) == 1, "Ordinary paste ended");
    pasted += byte;
  }
  require(pasted == ordinary, "Ordinary bracketed paste bytes changed");
  std::ofstream report{path};
  report << "{\"listing_byte_exact\":true,\"password_valid\":true,\"followup_read_byte_exact\":true,\"ordinary_paste_byte_exact\":true}\n";
  report.close();
  require(report.good(), "Could not save private child report");
  writeAll("\r\ngesture-complete\r\n");
  char last;
  while (::read(STDIN_FILENO, &last, 1) > 0) {}
  return 0;
}

struct MimeCounters {
  unsigned text_reads = 0;
};

class OwnedMimeData final : public QMimeData {
public:
  explicit OwnedMimeData(MimeCounters &counters) : counters_(counters) {
    setText(QStringLiteral("owned paste"));
    setHtml(QStringLiteral("<b>owned paste</b>"));
  }

protected:
  QVariant retrieveData(const QString &format, QMetaType type) const override {
    if (format == QStringLiteral("text/plain")) {
      ++counters_.text_reads;
    }
    return QMimeData::retrieveData(format, type);
  }

private:
  MimeCounters &counters_;
};

struct ClipboardFixture {
  QClipboard &clipboard;
  QPointer<OwnedMimeData> source;

  ~ClipboardFixture() {
    if (source && clipboard.mimeData() == source) {
      clipboard.clear();
    }
  }
};

void paste(workbench::TerminalItem &item) {
  const auto binding = QKeySequence::keyBindings(QKeySequence::Paste).front()[0];
  QKeyEvent gesture{QEvent::KeyPress, binding.key(), binding.keyboardModifiers()};
  require(gesture.matches(QKeySequence::Paste), "Key is not the platform paste binding");
  QCoreApplication::sendEvent(&item, &gesture);
  require(gesture.isAccepted(), "Terminal rejected paste gesture");
}

int parent(char **argv) {
  require(QGuiApplication::platformName() == "offscreen", "Gesture fixture requires private offscreen clipboard");
  const std::string report = std::string{argv[2]} + ".child";
  ProtocolPeer control{argv[1]};
  control.send(RequestRuntimeState{.client_identity = 104, .interactive = true});
  const std::array<std::string_view, 3> arguments{argv[0], "--clipboard-child", report};
  const auto pane = control.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = {80, 24, 8, 16}, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});
  workbench::RuntimeConnection connection{QString::fromUtf8(argv[1]), pane.location.workspace};
  auto screen = connection.screen(pane.pane_id);
  QQuickWindow window;
  workbench::TerminalItem item{screen, window.contentItem()};
  workbench::bindClipboardPaste(item, connection, pane.pane_id);
  item.desktopChanged = [&](ConfigurePaneDesktop state) { connection.desktop(pane.pane_id, state); };
  item.resized = [&](TerminalSize size) { connection.resize(pane.pane_id, size); };
  connection.painted = [&](std::uint64_t) { item.refresh(); };
  item.configure({{"font_size", 14}});
  window.resize(800, 480);
  item.setSize({800, 480});
  item.setPresented(true);
  window.show();
  connection.selectTab(pane.location.tab_id);
  connection.setVisible(true);
  await([&] { return screen->connected && screen->modes.paste_events && text(*screen).contains("gesture-ready"); }, "real desktop paste mode and attachment");
  MimeCounters counters;
  const QPointer<OwnedMimeData> source{new OwnedMimeData{counters}};
  auto *clipboard = QGuiApplication::clipboard();
  clipboard->setMimeData(source);
  const ClipboardFixture ownership{*clipboard, source};
  require(clipboard->mimeData() == source && counters.text_reads == 0, "Offscreen clipboard does not own fixture data");
  paste(item);
  await([&] { return text(*screen).contains("listing-delivered"); }, "paste gesture targets listing through runtime PTY");
  require(counters.text_reads == 0, "Targets-only paste materialized clipboard text");
  connection.input(pane.pane_id, "R");
  await([&] { return !screen->modes.paste_events && screen->modes.bracketed_paste && text(*screen).contains("ordinary-paste-ready"); }, "one-use read through Qt and runtime");
  require(counters.text_reads == 1, "One-use read did not materialize exactly one representation");
  require(source && clipboard->mimeData() == source, "Owned MIME data changed before ordinary paste");
  paste(item);
  await([&] { return text(*screen).contains("gesture-complete"); }, "ordinary paste round trip");
  require(counters.text_reads == 2, "Ordinary paste did not read exactly once");
  clipboard->clear();
  require(!source, "Offscreen clipboard retained fixture ownership");
  std::ofstream output{argv[2]};
  output << "{\"real_gestures\":2,\"listing_text_reads\":0,\"total_text_reads\":2,\"shared_controller_binding\":true,\"platform\":\"offscreen\"}\n";
  output.close();
  require(output.good(), "Could not save gesture report");
  connection.close(pane.pane_id);
  return 0;
}
}

int main(int argc, char **argv) {
  try {
    if (argc == 3 && std::string_view{argv[1]} == "--clipboard-child") {
      return child(argv[2]);
    }
    if (argc != 3) {
      return 2;
    }
    QGuiApplication application{argc, argv};
    return parent(argv);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
