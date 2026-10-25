#include "desktop_test_support.hpp"
#include "log_categories.hpp"
#include "protocol_peer.hpp"
#include "ui/workbench/runtime_connection.hpp"
#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>
#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>

namespace telar_log {
Q_LOGGING_CATEGORY(connection, "telar.connection")
Q_LOGGING_CATEGORY(frames, "telar.frames")
}

using workbench::RuntimeConnection;
using namespace desktop_test;

struct Seed {
  telar::WorkspaceLocation workspace;
  std::uint64_t first_tab;
  std::uint64_t second_tab;
  std::uint64_t first_pane;
  std::uint64_t second_pane;
};

static Seed seed(const char *socket) {
  ProtocolPeer peer{socket};
  const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "stty -echo; printf 'READY\\r\\n'; exec /bin/cat"};
  const telar::Launch launch{.cwd = "/tmp", .arguments = arguments};
  const auto first = peer.exchange<telar::PaneOpened>(telar::CreateWorkspace{.request_id = 1, .size = {80, 24, 8, 16}, .name = "Desktop session", .launch = launch});
  const auto second = peer.exchange<telar::TabCreated>(telar::CreateTab{.request_id = 2, .workspace = first.location.workspace, .label = "Second", .size = {80, 24, 8, 16}, .launch = launch});
  return {first.location.workspace, first.location.tab_id, second.location.tab_id, first.pane_id, second.root_pane_id};
}

class DesktopSessionProbe {
public:
  explicit DesktopSessionProbe(const char *socket) : socket_(socket), seed_(seed(socket)), connection_(QString::fromUtf8(socket), seed_.workspace) {}

  QJsonObject run() {
    loadAndAttach();
    inputAndResize();
    changeViewport();
    switchTabs();
    hideAndShow();
    createAndClosePanes();
    reconnect();
    require(connection_.error().isEmpty(), connection_.error().toStdString());
    return result_;
  }

private:
  const char *socket_;
  Seed seed_;
  RuntimeConnection connection_;
  QJsonObject result_;

  void waitForText(std::uint64_t pane, const QByteArray &marker) {
    await([&] { return connection_.screen(pane)->connected && text(*connection_.screen(pane)).contains(marker); }, marker.toStdString());
  }

  void loadAndAttach() {
    connection_.load();
    try {
      await([&] { return connection_.hasSnapshot(seed_.first_tab) && connection_.hasSnapshot(seed_.second_tab) && !connection_.ready(); }, "hidden workspace preload");
    } catch (...) {
      std::fprintf(stderr, "preload: workspace=%llu tabs=%zu snapshots=%d,%d ready=%d error=%s\n", seed_.workspace.id, connection_.tabs().size(), connection_.hasSnapshot(seed_.first_tab), connection_.hasSnapshot(seed_.second_tab), connection_.ready(), qPrintable(connection_.error()));
      throw;
    }
    require(connection_.tabs().size() == 2, "Expected two prefetched tabs");
    require(!connection_.screen(seed_.first_pane)->connected, "Hidden preload attached a pane");
    result_["hidden_preload"] = true;

    connection_.selectTab(seed_.first_tab);
    connection_.setVisible(true);
    waitForText(seed_.first_pane, "READY");
  }

  void inputAndResize() {
    connection_.input(seed_.first_pane, "Desktop \x1b[31mred\x1b[0m café 世界 👩‍💻\n");
    waitForText(seed_.first_pane, "世界");
    result_["styled_unicode"] = snapshot(*connection_.screen(seed_.first_pane));

    connection_.resize(seed_.first_pane, {96, 18, 8, 16});
    await([&] { const auto screen = connection_.screen(seed_.first_pane); return screen->columns == 96 && screen->rows == 18; }, "terminal resize");
    result_["resized"] = snapshot(*connection_.screen(seed_.first_pane));
  }

  void changeViewport() {
    QByteArray lines;
    for (int line = 0; line < 40; ++line) {
      lines += "scroll-" + QByteArray::number(line) + '\n';
    }

    connection_.input(seed_.first_pane, lines);
    waitForText(seed_.first_pane, "scroll-39");
    connection_.viewport(seed_.first_pane, 5);
    await([&] { return connection_.screen(seed_.first_pane)->scroll.offset == 5; }, "scrollback viewport");
    result_["scrollback"] = snapshot(*connection_.screen(seed_.first_pane));

    connection_.viewport(seed_.first_pane, 0);
    await([&] { return connection_.screen(seed_.first_pane)->scroll.offset == 0; }, "live viewport");
  }

  void switchTabs() {
    connection_.selectTab(seed_.second_tab);
    waitForText(seed_.second_pane, "READY");
    require(!connection_.screen(seed_.first_pane)->connected, "Previous tab remained attached");
    connection_.input(seed_.second_pane, "SECOND-TAB\n");
    waitForText(seed_.second_pane, "SECOND-TAB");
    result_["second_tab"] = snapshot(*connection_.screen(seed_.second_pane));

    connection_.selectTab(seed_.first_tab);
    waitForText(seed_.first_pane, "scroll-39");
    require(!connection_.screen(seed_.second_pane)->connected, "Second tab remained attached");
  }

  void hideAndShow() {
    const auto retained = text(*connection_.screen(seed_.first_pane));
    connection_.setVisible(false);
    require(!connection_.screen(seed_.first_pane)->connected, "Hidden workspace remained attached");
    require(text(*connection_.screen(seed_.first_pane)) == retained, "Hidden workspace lost its cached cells");

    connection_.setVisible(true);
    waitForText(seed_.first_pane, "scroll-39");
    connection_.input(seed_.first_pane, "AFTER-HIDDEN\n");
    waitForText(seed_.first_pane, "AFTER-HIDDEN");
    result_["visibility_preserves_process"] = true;
  }

  void exerciseShell(std::uint64_t pane) {
    await([&] { return connection_.screen(pane)->connected; }, "new shell attachment");
    connection_.input(pane, "printf 'SHELL-%s\\n' 'EXECUTED'\n");
    waitForText(pane, "SHELL-EXECUTED");
  }

  void createAndClosePanes() {
    connection_.split(seed_.first_pane);
    await([&] { return connection_.tabs().at(seed_.first_tab).size() == 2; }, "split creation");
    const auto split = connection_.tabs().at(seed_.first_tab).back();
    exerciseShell(split);
    connection_.close(split);
    await([&] { return connection_.tabs().at(seed_.first_tab).size() == 1; }, "split closure");
    result_["split_shell_and_close"] = true;

    std::uint64_t created_tab = 0;
    connection_.created = [&](std::uint64_t tab) { created_tab = tab; connection_.selectTab(tab); };
    connection_.createTab(seed_.first_pane);
    await([&] { return created_tab != 0 && connection_.tabs().contains(created_tab); }, "tab creation");
    const auto pane = connection_.tabs().at(created_tab).front();
    exerciseShell(pane);
    connection_.close(pane);
    await([&] { return !connection_.tabs().contains(created_tab); }, "tab closure");
    connection_.created = {};
    connection_.selectTab(seed_.first_tab);
    waitForText(seed_.first_pane, "AFTER-HIDDEN");
    result_["tab_shell_and_close"] = true;
  }

  void reconnect() {
    ProtocolPeer control{socket_};
    const auto clients = control.exchange<telar::ClientList>(telar::QueryClients{.request_id = 1});
    require(clients.entries.size() == 1, "Expected exactly one interactive Desktop client");
    const auto target = clients.entries.front();
    control.exchange<telar::RequestCompleted>(telar::DetachClient{.request_id = 2, .client_id = target.id, .client_generation = target.generation});
    await([&] { return !connection_.ready(); }, "forced disconnect");
    require(!connection_.screen(seed_.first_pane)->connected, "Disconnected pane remained attached");
    require(text(*connection_.screen(seed_.first_pane)).contains("AFTER-HIDDEN"), "Disconnect lost cached cells");

    waitForText(seed_.first_pane, "AFTER-HIDDEN");
    connection_.input(seed_.first_pane, "AFTER-RECONNECT\n");
    waitForText(seed_.first_pane, "AFTER-RECONNECT");
    result_["reconnected"] = snapshot(*connection_.screen(seed_.first_pane));
  }
};

int main(int count, char **arguments) {
  QCoreApplication application{count, arguments};
  if (count != 3) {
    return 2;
  }

  try {
    DesktopSessionProbe probe{arguments[1]};
    const auto output = QJsonDocument{probe.run()}.toJson(QJsonDocument::Indented);
    std::ofstream file{arguments[2]};
    file.write(output.constData(), output.size());
    require(file.good(), "Could not save Desktop session results");
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
