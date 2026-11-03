#include "core/memory.hpp"
#include "platform/font.h"
#include "telar_platform/read_file.hpp"
#include "terminal_font_requests_variant.hpp"
#include <array>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

using namespace telar;
using namespace telar::gui;

constexpr std::size_t maximum_row_cells = 4096;

bool readBytes(void *data, std::size_t size) {
  return std::fread(data, 1, size, stdin) == size;
}

bool readHeader(std::array<std::uint32_t, 2> &header) {
  const auto size = sizeof(header);
  const auto count = std::fread(header.data(), 1, size, stdin);
  if (count == 0 && std::feof(stdin)) {
    return false;
  }

  if (count != size) {
    throw std::runtime_error{"TruncatedHeader"};
  }

  return true;
}

void writeValue(std::uint32_t value) {
  if (std::fwrite(&value, sizeof(value), 1, stdout) != 1) {
    throw std::runtime_error{"OutputFailed"};
  }
}

int main(int argc, char **argv) {
  try {
    if (argc < 2) {
      throw std::runtime_error{"ExpectedFontFiles"};
    }

    SystemAllocator memory;
    std::vector<Vector<Byte, SystemAllocator>> files;
    std::vector<std::shared_ptr<ResidentFonts>> sets;
    for (int index = 1; index < argc; ++index) {
      const auto source = telar::runtime::readFile(memory, argv[index], telar_font_max_bytes);
      files.emplace_back(source.cbegin(), source.cend(), AllocatorRef<Byte, SystemAllocator>{memory});
      sets.push_back(std::make_shared<ResidentFonts>(files.back()));
    }

    Catalog catalog;
    TerminalItem item;
    item.font_catalog_ = &catalog;
    std::array<std::uint32_t, 2> header{};
    while (readHeader(header)) {
      if (header[0] >= sets.size() || header[1] > maximum_row_cells) {
        throw std::runtime_error{"InvalidRecord"};
      }

      catalog.current = sets[header[0]];
      item.install(&catalog);
      std::vector<CellValue> cells(header[1]);
      for (auto &cell : cells) {
        std::array<std::uint8_t, 4> metadata{};
        if (!readBytes(metadata.data(), metadata.size()) || metadata[1] > cell.text.size() || metadata[0] > static_cast<Byte>(CellWidth::wide) || !readBytes(cell.text.data(), metadata[1])) {
          throw std::runtime_error{"InvalidCell"};
        }

        cell.width = static_cast<CellWidth>(metadata[0]);
        cell.length = metadata[1];
        cell.style.flags = static_cast<std::uint16_t>(metadata[2] | (metadata[3] << 8));
      }

      catalog.requests.clear();
      item.requestRowFonts(cells);
      writeValue(static_cast<std::uint32_t>(catalog.requests.size()));
      for (const auto &text : catalog.requests) {
        writeValue(static_cast<std::uint32_t>(text.role));
        writeValue(static_cast<std::uint32_t>(text.text.size()));
        if (std::fwrite(text.text.data(), 1, text.text.size(), stdout) != text.text.size()) {
          throw std::runtime_error{"OutputFailed"};
        }
      }
    }

    return std::fflush(stdout) == 0 ? 0 : 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
