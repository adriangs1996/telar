#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "pasteboard_fixture.h"
#include <QFile>
#include <QIODevice>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <sys/stat.h>
#include <unistd.h>

import telar.base.ds;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.platform;

namespace {

  using namespace telar::gui;
  using platform::ClipboardImageError;
  using platform::ClipboardImageFailure;
  using platform::ClipboardImageSource;
  using telar::testing::check;

  constexpr ClipboardCaptureRequest request{.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 2}}};
  constexpr std::uint32_t image_width = 2;
  constexpr std::uint32_t image_height = 3;
  constexpr std::size_t components = 4;
  constexpr telar::ds::Array<std::uint8_t, image_width * image_height * components> sample_pixels{
      255,
      0,
      0,
      255,
      0,
      255,
      0,
      255,
      0,
      0,
      255,
      255,
      255,
      255,
      0,
      255,
      255,
      0,
      255,
      255,
      0,
      255,
      255,
      255,
  };

  struct ReleasePasteboard {
    void operator()(void* board) const noexcept {
      telarTestPasteboardDestroy(board);
    }
  };

  void expectFailure(const ClipboardImageSource& source, ApplicationAllocator& memory, ClipboardImageError expected) {
    try {
      static_cast<void>(source.read(memory, request));
      check(false, "the rejected capture must report its exact reason");
    } catch (const ClipboardImageFailure& error) {
      check(error.code() == expected, "clipboard failures must preserve the named native reason");
    }
  }

  void encodedFormatsAndRevisionChanges(void* board, ApplicationAllocator& memory) {
    for (const std::uint8_t format : {telar_test_image_png, telar_test_image_tiff, telar_test_image_jpeg}) {
      check(telarTestPasteboardSetSampleImage(board, format, sample_pixels.data(), image_width, image_height), "the private board must accept fixture data");
      const auto source = ClipboardImageSource::retainPasteboard(board);
      const auto captured = source.read(memory, request);

      check(captured.request.capture == request.capture && captured.width == image_width && captured.height == image_height && captured.png.size() != 0, "supported formats must produce an owned PNG with exact capture identity");
      const auto bytes = captured.png.view();

      check(telarTestBytesArePng(bytes.data(), bytes.size()), "the worker must normalize each source to PNG");
      telarTestPasteboardClear(board);
      expectFailure(source, memory, ClipboardImageError::changed);
    }
  }

  void boundedOwnedFilesAndNonregularSources(void* board, ApplicationAllocator& memory) {
    const QTemporaryDir directory;

    check(directory.isValid(), "the owned fixture directory must exist");
    const QString path = directory.filePath(QStringLiteral("image.png"));

    check(telarTestPasteboardWritePngFile(path.toUtf8().constData(), sample_pixels.data(), image_width, image_height), "the owned fixture PNG must be written");
    check(telarTestPasteboardSetFileUrl(board, path.toUtf8().constData()), "the private board must hold a file URL");
    const auto source = ClipboardImageSource::retainPasteboard(board);
    const auto captured = source.read(memory, request);

    check(captured.width == image_width && captured.height == image_height, "owned regular files must capture");

    const QString link = directory.filePath(QStringLiteral("symlink.png"));

    check(::symlink(path.toUtf8().constData(), link.toUtf8().constData()) == 0, "the symlink fixture must exist");
    const QString fifo = directory.filePath(QStringLiteral("fifo.png"));

    check(::mkfifo(fifo.toUtf8().constData(), S_IRUSR | S_IWUSR) == 0, "the FIFO fixture must exist");
    for (const auto& rejected : {link, fifo}) {
      check(telarTestPasteboardSetFileUrl(board, rejected.toUtf8().constData()), "the private board must accept a rejected URL");
      const auto unsafe = ClipboardImageSource::retainPasteboard(board);

      expectFailure(unsafe, memory, ClipboardImageError::no_image);
    }

    QFile large{directory.filePath(QStringLiteral("too-large.png"))};

    check(large.open(QIODevice::WriteOnly) && large.resize(static_cast<qint64>(AttachmentLimits::maximum_source_bytes) + 1), "the oversized sparse fixture must exist");
    large.close();
    check(telarTestPasteboardSetFileUrl(board, large.fileName().toUtf8().constData()), "the private board must accept an oversized URL");
    const auto oversized = ClipboardImageSource::retainPasteboard(board);

    expectFailure(oversized, memory, ClipboardImageError::source_bytes);
  }

  void emptyBoard(void* board, ApplicationAllocator& memory) {
    telarTestPasteboardClear(board);
    const auto empty = ClipboardImageSource::retainPasteboard(board);

    expectFailure(empty, memory, ClipboardImageError::no_image);
  }

  template <void (*verify)(void*, ApplicationAllocator&)>
  void onPrivateBoard() {
    const std::unique_ptr<void, ReleasePasteboard> board{telarTestPasteboardCreate()};
    ApplicationMemory application_memory;

    verify(board.get(), application_memory.memory());
  }

  const telar::testing::Case case_empty_board{"clipboard_image_source.empty_board", onPrivateBoard<emptyBoard>};
  const telar::testing::Case case_encoded_formats_and_revision_changes{"clipboard_image_source.encoded_formats_and_revision_changes", onPrivateBoard<encodedFormatsAndRevisionChanges>};
  const telar::testing::Case case_bounded_owned_files_and_nonregular_sources{"clipboard_image_source.bounded_owned_files_and_nonregular_sources", onPrivateBoard<boundedOwnedFilesAndNonregularSources>};

}
