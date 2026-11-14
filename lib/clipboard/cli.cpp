// The reader's command line. main.cpp runs it, and the macOS tests call it without that main.
import std;
import telar.clipboard;
import telar.sys.posix;

namespace telar::clipboard {
  int runCli(int argc, char** argv) {
    const char* output_path = nullptr;

    if (argc == 2 && std::string_view(argv[1]) == "--help") {
      std::puts("Usage: clipboard [--output PATH]\nRead current text or image. Images keep their original format.\nBinary output requires --output PATH or redirected stdout.");
      return 0;
    }

    if (argc == 3 && std::string_view(argv[1]) == "--output") {
      output_path = argv[2];
    } else if (argc != 1) {
      std::println(stderr, "Usage: clipboard [--output PATH]");
      return 1;
    }

    const auto result = read();
    if (!result) {
      std::println(stderr, "{}", error_message(result.error()));
      return 1;
    }

    if (output_path == nullptr && result->mime_type.starts_with("image/") && isatty(STDOUT_FILENO)) {
      std::println(stderr, "Clipboard contains {:.{}}; use --output PATH or redirect stdout.", result->mime_type.data(), static_cast<int>(result->mime_type.size()));
      return 1;
    }

    std::FILE* output = output_path != nullptr ? std::fopen(output_path, "wb") : stdout;
    if (output == nullptr) {
      std::perror("Could not open output file");
      return 1;
    }

    const auto& bytes = result->bytes;
    const bool written = bytes.empty() || std::fwrite(bytes.data(), 1, bytes.size(), output) == bytes.size();
    const bool closed = output_path != nullptr ? std::fclose(output) == 0 : std::fflush(output) == 0;
    if (!written || !closed) {
      std::println(stderr, "Could not write clipboard content.");
      return 1;
    }

    if (output_path != nullptr) {
      std::println(stderr, "Saved {:.{}} ({} bytes).", result->mime_type.data(), static_cast<int>(result->mime_type.size()), bytes.size());
    }

    return 0;
  }
} // namespace telar::clipboard
