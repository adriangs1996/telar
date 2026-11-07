#include "lua_host.hpp"

namespace telar::gui::qt {

LuaHost::LuaHost(QObject *parent)
    : QObject(parent),
      worker_(new QObject) {
  thread_.setObjectName(QStringLiteral("telar-lua"));
  worker_->moveToThread(&thread_);
  thread_.start();
}

LuaHost::~LuaHost() {
  // Queued calls are dropped; a call already running ends within its Lua deadline.
  thread_.quit();
  thread_.wait();
  delete worker_;
}

}
