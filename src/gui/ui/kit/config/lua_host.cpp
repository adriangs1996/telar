module telar.gui.ui.kit.config;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  LuaHost::LuaHost(QObject* parent)
      : QObject(parent),
        worker_(new QObject) {
    thread_.setObjectName(u"telar-lua"_s);
    if (worker_ != nullptr) {
      worker_->moveToThread(&thread_);
    }

    thread_.start();
  }

  LuaHost::~LuaHost() {
    // Queued calls are dropped; a call already running ends within its Lua deadline.
    thread_.quit();
    thread_.wait();
    delete worker_;
  }

}
