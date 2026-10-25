#include "lua_environment.hpp"
#include "lua_vm.hpp"
#include "ui/lua_io.hpp"
#include <QCoreApplication>
#include <QFile>
#include <QFileInfo>
#include <QTimer>
#include <cstdio>

int main(int argc, char **argv) {
  QCoreApplication application(argc, argv);
  if (argc != 3) {
    std::fprintf(stderr, "Usage: traffic_dbg RUNTIME_SOCKET UI_API_LUA\n");
    return 2;
  }

  try {
    lua::Vm vm;
    lua::Environment environment{vm};
    ui::LuaIo io{environment, QFileInfo(QString::fromUtf8(argv[2])).absolutePath(), [](const QString &) {}, argv[1]};
    environment.withState([](lua_State *state) -> int {
      lua_newtable(state);
      lua_pushcfunction(state, [](lua_State *) -> int { return 0; });
      lua_setfield(state, -2, "configure_theme");
      lua_setglobal(state, "_telar_ui");
      lua_pushcfunction(state, [](lua_State *) -> int {
        std::puts("ready");
        std::fflush(stdout);
        return 0;
      });
      lua_setglobal(state, "test_ready");
      lua_pushcfunction(state, [](lua_State *) -> int {
        std::puts("packet verified");
        QCoreApplication::exit(0);
        return 0;
      });
      lua_setglobal(state, "test_done");
      return 0;
    }, nullptr);

    QFile api{QString::fromUtf8(argv[2])};
    if (!api.open(QIODevice::ReadOnly)) {
      throw std::runtime_error{"Unable to read Lua API"};
    }
    environment.execute(api.readAll().toStdString(), "@api.lua");
    environment.execute(R"lua(
local unsubscribe
unsubscribe = telar.traffic.subscribe({events = {packet = true}, filter = "udp port 53535"}, function(err, event)
  assert(not err, err)
  if event.kind == "ready" then test_ready() end
  if event.kind == "packet" then
    assert(event.offline == true and event.interface == "offline")
    assert(event.visibility == "wire" and event.link_type == 1)
    assert(event.bytes:sub(-3) == "a\0b")
    assert(event.captured_bytes == #event.bytes and not event.truncated)
    unsubscribe()
    test_done()
  end
end)
)lua", "@traffic-check.lua");
    io.activate();
    QTimer::singleShot(10000, &application, [] { QCoreApplication::exit(2); });
    return application.exec();
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
