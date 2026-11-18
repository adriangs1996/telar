module telar.cli.render;

import telar.sys.posix;
import telar.sys.process;
import telar.render.document;
import telar.render.markdown;
import telar.render.terminal;

namespace telar::runtime::cli::render_command {

  RenderOptions RenderOptions::parse(std::span<char* const> words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingRenderKind"};
    }

    RenderOptions self;

    if (std::string_view{words.front()} != "markdown") {
      throw std::invalid_argument{"UnknownRenderKind"};
    }

    bool path_given = false;

    for (std::size_t index = 1; index < words.size(); ++index) {
      const std::string_view word = words[index];
      const auto value = [&](std::string_view missing) -> std::string_view {
        if (index + 1 >= words.size()) {
          throw std::invalid_argument{std::string{missing}};
        }

        return words[++index];
      };

      if (word == "--format") {
        const auto format = value("MissingRenderFormat");
        if (format == "auto") {
          self.format = Format::automatic;
        } else if (format == "native") {
          self.format = Format::native;
        } else if (format == "ansi") {
          self.format = Format::ansi;
        } else {
          throw std::invalid_argument{"InvalidRenderFormat"};
        }
      } else if (word == "--pager") {
        self.pager = true;
      } else if (word == "--width") {
        const auto text = value("MissingRenderWidth");
        const auto width = parseExact<std::uint16_t>(text).valueOr(0);
        if (width < render::terminal::min_width) {
          throw std::invalid_argument{"InvalidRenderWidth"};
        }

        self.width = width;
      } else if ((word.starts_with('-') && word != "-") || path_given) {
        throw std::invalid_argument{"UnknownRenderOption"};
      } else {
        self.path = word;
        path_given = true;
      }
    }

    return self;
  }

  bool writeAll(int descriptor, std::string_view bytes) noexcept {
    while (!bytes.empty()) {
      const auto written = ::write(descriptor, bytes.data(), bytes.size());
      if (written < 0) {
        if (sys::lastError() == EINTR) {
          continue;
        }

        return false;
      }

      bytes.remove_prefix(static_cast<std::size_t>(written));
    }

    return true;
  }

  // Reads all of descriptor, up to one byte past the limit so an oversized
  // source is detected without reading the rest of it.
  template <Allocator Memory>
  bool readSource(int descriptor, String<Memory>& source) {
    constexpr std::size_t chunk = 64 * 1024;
    const auto limit = render::markdown::max_source_bytes + 1;

    while (source.size() < limit) {
      const auto at = source.size();

      source.resize(std::min(at + chunk, limit));
      const auto got = ::read(descriptor, source.data() + at, source.size() - at);
      if (got < 0) {
        source.resize(at);
        if (sys::lastError() == EINTR) {
          continue;
        }

        return false;
      }

      source.resize(at + static_cast<std::size_t>(got));
      if (got == 0) {
        break;
      }
    }

    return true;
  }

  std::uint16_t terminalWidth(int descriptor) noexcept {
    winsize size{};
    if (::ioctl(descriptor, TIOCGWINSZ, &size) == 0 && size.ws_col != 0) {
      return size.ws_col;
    }

    return 80;
  }

  volatile std::sig_atomic_t stop_signal = 0;

  void onStopSignal(int signal) noexcept {
    stop_signal = signal;
  }

  // Holds the controlling terminal in raw mode on the alternate screen, and
  // restores both however the command ends.
  class Viewer {
  public:
    explicit Viewer(int descriptor) noexcept
        : descriptor_(descriptor) {}

    Viewer(const Viewer&) = delete;
    Viewer& operator=(const Viewer&) = delete;

    ~Viewer() {
      if (entered_) {
        static_cast<void>(writeAll(descriptor_, "\x1b[?25h\x1b[?1049l"));
        ::tcsetattr(descriptor_, TCSAFLUSH, &saved_);
      }

      ::close(descriptor_);
    }

    bool enter() noexcept {
      if (::tcgetattr(descriptor_, &saved_) != 0) {
        return false;
      }

      termios raw = saved_;

      ::cfmakeraw(&raw);
      if (::tcsetattr(descriptor_, TCSAFLUSH, &raw) != 0) {
        return false;
      }

      entered_ = true;
      return writeAll(descriptor_, "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J");
    }

    // Waits until the user quits: q, Escape, Ctrl-C or Ctrl-D, a hang-up or a stop signal. A
    // blocking read, as poll() rejects /dev/tty on macOS; the signal handlers are installed
    // without SA_RESTART, so a signal interrupts the read.
    void wait() noexcept {
      std::array<char, 64> keys;

      while (stop_signal == 0) {
        const auto got = ::read(descriptor_, keys.data(), keys.size());
        if (got < 0 && (sys::lastError() == EINTR || sys::lastError() == EAGAIN)) {
          continue;
        }

        if (got <= 0) {
          return;
        }

        const std::string_view typed{keys.data(), static_cast<std::size_t>(got)};
        // A lone Escape quits; an escape sequence (an arrow key) does not.
        if (typed == "\x1b" || typed.find_first_of("qQ\x03\x04") != std::string_view::npos) {
          return;
        }
      }
    }

  private:
    int descriptor_;
    termios saved_{};
    bool entered_ = false;
  };

  void report(std::string_view message) noexcept {
    std::fprintf(stderr, "telar render: %.*s\n", static_cast<int>(message.size()), message.data());
  }

  void reportDocumentLimit() noexcept {
    std::fprintf(stderr, "telar render: the document exceeds the %zu KiB limit render.max_document_bytes\n", render::max_document_bytes / 1024);
  }

  bool insidePane() noexcept {
    const char* pane = std::getenv("TELAR_PANE_ID");

    return pane != nullptr && *pane != '\0';
  }

  template <Allocator Memory>
  int showPager(Memory& memory, const render::Document<Memory>& document, std::string_view name) {
    const auto descriptor = ::open("/dev/tty", O_RDWR | O_CLOEXEC | O_NOCTTY);
    if (descriptor < 0) {
      report("native rendering needs a controlling terminal; use --format ansi");
      return 1;
    }

    String<Memory> output{AllocatorRef<char, Memory>{memory}};

    // Clients that cannot show documents still show what is running.
    output.append("\x1b[2mtelar render \xc2\xb7 ");
    for (const char byte : name) {
      if (static_cast<unsigned char>(byte) >= 0x20 && byte != 0x7f) {
        output.push_back(byte);
      }
    }

    output.append(" \xc2\xb7 q to quit\x1b[0m");
    if (!render::appendSequence(document, output)) {
      ::close(descriptor);
      reportDocumentLimit();
      return 1;
    }

    Viewer viewer{descriptor};
    struct sigaction action{};

    sys::signalHandler(action) = onStopSignal;
    sigemptyset(&action.sa_mask);
    for (const int signal : {SIGTERM, SIGHUP, SIGINT, SIGQUIT}) {
      ::sigaction(signal, &action, nullptr);
    }

    if (!viewer.enter() || !writeAll(descriptor, output)) {
      report("could not write to the terminal");
      return 1;
    }

    viewer.wait();
    return 0;
  }

  int run(Memory& memory, const RenderOptions& options) {
    const bool from_stdin = options.path.empty() || options.path == "-";
    if (from_stdin && ::isatty(STDIN_FILENO) == 1) {
      report("give a FILE or pipe the content to standard input");
      return 1;
    }

    String<Memory> source{AllocatorRef<char, Memory>{memory}};

    {
      const auto descriptor = from_stdin ? STDIN_FILENO : ::open(std::string{options.path}.c_str(), O_RDONLY | O_CLOEXEC);
      if (descriptor < 0) {
        std::fprintf(stderr, "telar render: %.*s: %s\n", static_cast<int>(options.path.size()), options.path.data(), std::strerror(sys::lastError()));
        return 1;
      }

      const bool read = readSource(descriptor, source);
      const auto error = sys::lastError();

      if (!from_stdin) {
        ::close(descriptor);
      }

      if (!read) {
        std::fprintf(stderr, "telar render: could not read the source: %s\n", std::strerror(error));
        return 1;
      }
    }

    render::Document<Memory> document{memory};

    switch (render::markdown::render(source, document)) {
    case render::markdown::Error::none:
      break;
    case render::markdown::Error::too_large:
      report("the source exceeds the 4 MiB limit render.max_markdown_bytes");
      return 1;
    case render::markdown::Error::document_too_large:
      reportDocumentLimit();
      return 1;
    case render::markdown::Error::parser:
      report("the Markdown parser failed");
      return 1;
    }

    const bool native = options.format == RenderOptions::Format::native ||
                        (options.format == RenderOptions::Format::automatic && insidePane() && ::isatty(STDOUT_FILENO) == 1);
    if (native && options.pager) {
      return showPager(memory, document, from_stdin ? std::string_view{"stdin"} : options.path);
    }

    // Natively, the styled text sits between the OSCs that begin and end the document's zone:
    // a client that draws documents shows the document in place of the text, any other the text.
    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    if (native && !render::appendSequence(document, output)) {
      reportDocumentLimit();
      return 1;
    }

    render::terminal::render(document, options.width.valueOr(terminalWidth(STDOUT_FILENO)), output);
    if (native) {
      render::appendEnd(output);
    }

    if (!writeAll(STDOUT_FILENO, output)) {
      std::fprintf(stderr, "telar render: could not write the output: %s\n", std::strerror(sys::lastError()));
      return 1;
    }

    return 0;
  }

}
