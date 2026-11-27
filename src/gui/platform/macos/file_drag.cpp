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

    static void dispatch(void* context, const TelarGuiPromiseRequest* request) {
      auto& self = *static_cast<Native*>(context);
      if (!self.asked || request == nullptr) {
        return;
      }

      self.asked({
          .row = request->row,
          .ticket = request->ticket,
          .directory = request->directory_data == nullptr ? std::string_view{} : std::string_view{request->directory_data, request->directory_size},
          .name = request->name_data == nullptr ? std::string_view{} : std::string_view{request->name_data, request->name_size},
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
    const void* const view = native ? std::bit_cast<const void*>(window.winId()) : nullptr;
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
    const TelarGuiFileDragRequest request{
        .ns_view = view,
        .rows = converted.empty() ? nullptr : converted.data(),
        .row_count = converted.size(),
        .callback = native_->asked ? &Native::dispatch : nullptr,
        .context = tbc::raw(native_.get()),
    };

    return telarGuiFileDragGive(native_->handle, &request);
  }

}
