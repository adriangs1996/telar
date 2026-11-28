#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>
#include <memory>
#include <span>
#include <string_view>

#pragma once

import telar.base.ds;
import telar.tbc;

class QWindow;

namespace telar::gui::platform {

  // A row dragged out of the window, as the program it is let go on is given it.
  struct DraggedOut {
    // What a program that reads text is given: its path, after its machine when that is another.
    std::string_view text;
    // A file or a directory of the machine the window runs on: its path. Empty for one that is
    // elsewhere.
    std::string_view path;
    // A file or a directory of another machine the system is promised, under this name: it asks
    // for it once the row is let go. Empty for a row that promises none.
    std::string_view promised;
    // What names the promise to whoever writes what it promised.
    std::uint32_t row = 0;
    // Whether what is promised is a directory, which is written as one with what it holds.
    bool directory = false;
  };

  // A file or a directory the system asked for, of a row that promised it: where it wants it,
  // under which name, and the ticket that tells it how writing it ended.
  struct PromisedFile {
    std::uint32_t row = 0;
    std::uint64_t ticket = 0;
    std::string_view directory;
    std::string_view name;
  };

  // The system asked for a promised file. It is called on the thread of the window, and the
  // system then waits until `FileDrag::end` is given the file's ticket.
  using PromiseAsked = ds::Function<void(const PromisedFile& file)>;

#ifdef __APPLE__
  inline constexpr bool file_promises = true;

  // The rows a window gave to the system's drag, with the files they promise: the system asks
  // for a promised file after the drag ended, and is answered for as long as this lives. When
  // it goes, the system is told that the files it still waits for did not arrive.
  class FileDrag {
  public:
    FileDrag();
    ~FileDrag();
    FileDrag(const FileDrag&) = delete;
    FileDrag& operator=(const FileDrag&) = delete;
    FileDrag(FileDrag&&) = delete;
    FileDrag& operator=(FileDrag&&) = delete;

    // Gives the rows to the system's drag, from `window`, where the pointer holds them, in
    // place of the ones it was given before: a promise of those is asked for no more. What the
    // rows are on the pasteboard is made whether a drag begins or not. False when none does: no
    // button is held, or the window is not AppKit's.
    bool give(const QWindow& window, std::span<const DraggedOut> rows, tbc::val_a<PromiseAsked> asked);

    // Tells the system the promised file of `ticket` is whole, or with `failure` why it is not
    // there. A ticket that was told of already, or that no file has, tells nothing.
    void end(std::uint64_t ticket, std::string_view failure);

    // What it holds of AppKit's writers array, which tests inspect through an Objective-C bridge.
    [[nodiscard]] const void* nativeWriters() const noexcept;

  private:
    struct Native;
    // It keeps who the system's requests are given to, which it was given with the rows.
    tbc::val_a<std::unique_ptr<Native>> native_;
  };
#else
  inline constexpr bool file_promises = false;

  // Nothing promises a file here: no row is given to a drag of the system's.
  class FileDrag {
  public:
    [[nodiscard]] static bool give([[maybe_unused]] const QWindow& window, [[maybe_unused]] std::span<const DraggedOut> rows, [[maybe_unused]] const PromiseAsked& asked) noexcept {
      return false;
    }

    static void end([[maybe_unused]] std::uint64_t ticket, [[maybe_unused]] std::string_view failure) noexcept {}
  };
#endif

}
