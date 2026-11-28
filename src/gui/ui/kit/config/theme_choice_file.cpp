module telar.gui.ui.kit.config;

import std;
import telar.gui.qt;
import telar.platform.error;
import telar.platform.fs;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.sys.posix;

namespace telar::gui::qt {

  namespace {

    std::string_view view(const QByteArray& bytes) noexcept {
      return {bytes.constData(), static_cast<std::size_t>(bytes.size())};
    }

    std::string_view fileName(std::string_view path) {
      return path.substr(path.rfind('/') + 1);
    }

  }

  void ThemeChoiceFile::open(const QString& path) {
    path_ = path.isEmpty() ? QByteArray{} : QFile::encodeName(path);
    stamp_ = stamp();
  }

  bool ThemeChoiceFile::enabled() const noexcept {
    return !path_.isEmpty();
  }

  ds::Option<system::PrivateFileStamp> ThemeChoiceFile::stamp() const {
    return enabled() ? system::PrivateFileStamp::read(path_.constData()) : ds::none;
  }

  bool ThemeChoiceFile::changed() const {
    return enabled() && stamp() != stamp_;
  }

  ds::Option<ThemeChoiceFile::Choice> ThemeChoiceFile::read() {
    stamp_ = stamp();
    if (!stamp_) {
      return ds::none;
    }

    // A file that is not a private one this version wrote holds no choice.
    try {
      const auto parent = runtime::openPrivateParent(view(path_));
      SystemAllocator memory;
      ds::Vec<unsigned char, SystemAllocator> bytes{memory};
      if (!runtime::readPrivateFile(parent.get(), fileName(view(path_)), bytes, Choice::file_bytes)) {
        return ds::none;
      }

      const auto text = bytes.view();

      return Choice::parse({reinterpret_cast<const char*>(text.data()), text.size()}); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the file's bytes are its text
    } catch (const runtime::SystemError&) {
      return ds::none;
    }
  }

  void ThemeChoiceFile::write(const Choice& choice) {
    if (!enabled()) {
      return;
    }

    const auto path = view(path_);

    runtime::createPrivateDirectory(path.substr(0, path.rfind('/')));
    const auto parent = runtime::openPrivateParent(path);
    ds::Array<char, Choice::file_bytes> buffer{};
    const auto text = choice.format(buffer);
#pragma clang unsafe_buffer_usage begin
    const auto written = runtime::writePrivateFile(parent.get(), fileName(path), {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}, runtime::PrivateFileMode::replace); // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): the file takes the text as bytes, whose size the view gives
#pragma clang unsafe_buffer_usage end
    if (written != 0) {
      throw runtime::SystemError{"Save the chosen theme", written};
    }

    stamp_ = stamp();
  }

  void ThemeChoiceFile::remove() {
    if (!enabled()) {
      return;
    }

    if (::unlink(path_.constData()) != 0) {
      const auto error = sys::lastError();
      if (error != ENOENT) {
        throw runtime::SystemError{"Forget the chosen theme", error};
      }
    }

    stamp_ = stamp();
  }

}
