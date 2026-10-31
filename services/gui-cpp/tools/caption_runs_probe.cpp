#include "probe_io.hpp"
#include "text/caption_runs.hpp"
#include <cstdint>
#include <cstdio>
#include <exception>
#include <iostream>
#include <string>

int main() try {
  using namespace telar::gui;
  for (auto incoming = std::getc(stdin); incoming != EOF; incoming = std::getc(stdin)) {
    const auto length = probe::read<std::uint16_t>();
    std::string text(length, '\0');
    if (std::fread(text.data(), 1, text.size(), stdin) != text.size()) {
      return 2;
    }

    CaptionRuns runs{text};
    while (const auto run = runs.next()) {
      probe::write(static_cast<std::uint16_t>(run->size()));
      if (std::fwrite(run->data(), 1, run->size(), stdout) != run->size()) {
        return 2;
      }
    }

    probe::write(std::uint16_t{0});
  }

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
