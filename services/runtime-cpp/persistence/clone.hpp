#pragma once

#include "reader.hpp"
#include "writer.hpp"
#include <limits.h>

namespace telar::runtime::checkpoint {

inline std::span<const Byte> clone(std::span<const Byte> input, std::span<Byte> output, std::string_view shell) {
  if (shell.empty() || shell.front() != '/' || shell.size() >= PATH_MAX || shell.contains('\0')) {
    throw EncodingError{"Invalid clone shell"};
  }

  std::array<char, PATH_MAX> arguments;
  std::copy(shell.begin(), shell.end(), arguments.begin());
  arguments[shell.size()] = '\0';
  Reader reader{input};
  Writer writer{output, reader.counters};
  reader.read([&]<typename Record>(const Record &record) {
    if constexpr (std::same_as<Record, PaneRecord>) {
      writer.append(PaneRecord{.id = record.id, .workspace = record.workspace, .tab = record.tab, .cwd = record.cwd, .columns = record.columns, .rows = record.rows, .argument_count = 1, .arguments = {arguments.data(), shell.size() + 1}});
    } else if constexpr (!std::same_as<Record, WorktreeRecord>) {
      writer.append(record);
    }
  });
  if (writer.dropped != 0) {
    throw EncodingError{"Cloned session exceeds its size limit"};
  }
  return writer.finish();
}

}
