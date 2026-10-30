#include "core/memory.hpp"
#include "platform/clipboard_image_pipe.hpp"
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <system_error>

namespace {

enum class Argument : std::uint8_t { program, source, png, count };

std::size_t limit(std::string_view text) {
  std::size_t result = 0;
  const auto parsed = std::from_chars(text.data(), text.data() + text.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) {
    throw std::runtime_error{"InvalidLimit"};
  }

  return result;
}

}

int main(int argc, char *const *argv) try {
  if (argc != static_cast<int>(Argument::count)) {
    throw std::runtime_error{"MissingLimit"};
  }

  telar::gui::SystemAllocator memory;
  const telar::gui::platform::ClipboardImagePipeLimits limits{.source_bytes = limit(argv[static_cast<int>(Argument::source)]), .png_bytes = limit(argv[static_cast<int>(Argument::png)])};
  constexpr int standard_input = 0;
  const auto bytes = telar::gui::platform::ClipboardImagePipe::read(memory, standard_input, limits);
  std::cout << "ok\n";
  for (const auto byte : bytes.unsignedBytes()) {
    std::cout.put(static_cast<char>(byte));
  }

  return std::cout.good() ? 0 : 1;
} catch (const std::exception &failure) {
  std::cout << failure.what() << '\n';

  return std::cout.good() ? 0 : 1;
}
