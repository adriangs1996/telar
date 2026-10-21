#pragma once

#include <functional>
#include <memory>
#include <string_view>

namespace ui {
  struct Services;
}

struct QuickSurface;

namespace ui {
  class LuaUi final {
  public:
    LuaUi(ui::Services &services, QuickSurface &surface);
    ~LuaUi();

    LuaUi(const LuaUi &) = delete;
    LuaUi &operator=(const LuaUi &) = delete;

    void reload(std::string_view api_source, std::string_view source, std::string_view chunk_name);
    void setReloadHandler(std::function<void()> handler);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
  };
} // namespace ui
