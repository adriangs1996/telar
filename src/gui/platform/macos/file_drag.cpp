#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "platform/file_drag.hpp"
#include "platform/macos/file_drag_bridge.h"
#include <QGuiApplication>
#include <QLatin1StringView>
#include <QWindow>
#include <bit>
#include <cstdint>
#include <memory>
#include <span>
#include <string_view>
#include <utility>

import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;

namespace telar::gui::platform {

  struct FileDrag::Native {
    TelarGuiFileDrag* handle = nullptr;
    tbc::val_a<PromiseAsked> asked;

    Native()
        : handle(telarGuiFileDragCreate()) {}

    ~Native() {
      telarGuiFileDragDestroy(handle);
    }

    Native(const Native&) = delete;
    Native& operator=(const Native&) = delete;
    Native(Native&&) = delete;
    Native& operator=(Native&&) = delete;

    static void dispatch(
        void* context,
        std::uint32_t row,
        std::uint64_t ticket,
        const char* directory_data,
        std::size_t directory_size,
        const char* name_data,
        std::size_t name_size
    ) {
      auto& self = *static_cast<Native*>(context);
      if (!self.asked) {
        return;
      }

      self.asked({
          .row = row,
          .ticket = ticket,
          .directory = directory_data == nullptr ? std::string_view{} : std::string_view{directory_data, directory_size},
          .name = name_data == nullptr ? std::string_view{} : std::string_view{name_data, name_size},
      });
    }
  };

  FileDrag::FileDrag()
      : native_(std::make_unique<Native>()) {}

  FileDrag::~FileDrag() = default;

  const void* FileDrag::nativeWriters() const noexcept {
    return telarGuiFileDragWriters(native_->handle);
  }

  void FileDrag::end(std::uint64_t ticket, std::string_view failure) {
    telarGuiFileDragEnd(native_->handle, ticket, failure.data(), failure.size());
  }

  bool FileDrag::give(const QWindow& window, std::span<const DraggedOut> rows, tbc::val_a<PromiseAsked> asked) {
    // Only AppKit's window has a view: under another platform of Qt the handle is something else.
    const bool native = QGuiApplication::platformName() == QLatin1StringView{"cocoa"} && window.handle() != nullptr;
    void* const view = native ? std::bit_cast<void*>(window.winId()) : nullptr;
    SystemAllocator memory;
    ds::Vec<TelarGuiDraggedOut, SystemAllocator> converted{memory};

    converted.reserve(rows.size());
    for (const auto& row : rows) {
      converted.push({
          .text_data = row.text.data(),
          .text_size = row.text.size(),
          .path_data = row.path.data(),
          .path_size = row.path.size(),
          .promised_data = row.promised.data(),
          .promised_size = row.promised.size(),
          .row = row.row,
          .directory = row.directory,
      });
    }

    native_->asked = std::move(asked);
    return telarGuiFileDragGive(
        native_->handle,
        view,
        converted.empty() ? nullptr : converted.data(),
        converted.size(),
        native_->asked ? &Native::dispatch : nullptr,
        tbc::raw(native_.get())
    );
  }

}
