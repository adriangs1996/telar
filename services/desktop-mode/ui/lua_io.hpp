#pragma once

#include <QString>
#include <QStringList>
#include <functional>
#include <memory>
#include <string>

namespace lua {
  struct Environment;
}

namespace ui {
  class LuaIo final {
  public:
    LuaIo(lua::Environment &environment,
          const QString &directory,
          std::function<void(const QString &)> observe_module,
          std::string runtime_socket = {});
    ~LuaIo();
    LuaIo(const LuaIo &) = delete;
    LuaIo &operator=(const LuaIo &) = delete;

    void activate();
    QStringList modulePaths() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace ui
