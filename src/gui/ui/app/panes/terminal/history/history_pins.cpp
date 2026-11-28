module telar.gui.ui.app.panes.terminal.history;

import std;
import telar.gui.qt;
import telar.platform.error;
import telar.platform.fs;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    std::string_view view(const QByteArray& bytes) noexcept {
      return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
    }

    // Every pin escaped, a newline each: the most the file holds.
    constexpr std::size_t file_bytes = application::history::HistoryPins::capacity * ((2 * application::history::HistoryPins::maximum_command_bytes) + 1);

  }

  void HistoryController::setPinsPath(const QString& path) {
    pins_path_ = path.isEmpty() ? QByteArray{} : QFile::encodeName(path);
    if (pins_path_.isEmpty()) {
      return;
    }

    // A file that is not a private one holds no pins.
    try {
      const auto file = view(pins_path_);
      const auto parent = runtime::openPrivateParent(file);
      ds::Vec<unsigned char, SystemAllocator> bytes{pins_memory_};

      if (runtime::readPrivateFile(parent.get(), file.substr(file.rfind('/') + 1), bytes, file_bytes)) {
        const auto text = bytes.view();

        pins_.read({reinterpret_cast<const char*>(text.data()), text.size()}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the file's bytes are its text
      }
    } catch (const runtime::SystemError&) {
      return;
    }
  }

  void HistoryController::savePins() {
    if (pins_path_.isEmpty()) {
      return;
    }

    const auto file = view(pins_path_);
    ds::String<Memory> text{pins_adapter_};

    pins_.write(text);
    runtime::createPrivateDirectory(file.substr(0, file.rfind('/')));
    const auto parent = runtime::openPrivateParent(file);
#pragma clang unsafe_buffer_usage begin
    const auto written = runtime::writePrivateFile(parent.get(), file.substr(file.rfind('/') + 1), {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}, runtime::PrivateFileMode::replace); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the file takes the text as bytes, whose size the view gives
#pragma clang unsafe_buffer_usage end
    if (written != 0) {
      throw runtime::SystemError{"Save the pinned commands", written};
    }
  }

}
