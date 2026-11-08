#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>

import std;
import telar.base.memory;
import telar.runtime.paths.query_task;

using namespace telar;
using namespace telar::runtime;

int main(int argc, char **argv) {
  if (argc != 2) {
    return 2;
  }

  SystemAllocator memory;
  FuzzyMatch match{memory};
  std::ofstream dump{argv[1], std::ios::binary};
  std::minstd_rand random{731};
  constexpr std::string_view alphabet = "aAbBcCdDeEfFgGhH0123456789/._- café界";
  for (unsigned iteration = 0; iteration < 12000; ++iteration) {
    const auto length = random() % 1100;
    std::string path;
    for (unsigned index = 0; index < length; ++index) {
      path += alphabet[random() % alphabet.size()];
    }

    std::string query;
    if (iteration % 3 == 0) {
      const auto selected = std::min<std::size_t>(length, random() % 65);
      for (unsigned index = 0; index < selected; ++index) {
        query += path[index * length / selected];
      }
    } else if (iteration % 3 == 1 && length <= 64) {
      query = path;
    } else {
      const auto selected = random() % 70;
      for (unsigned index = 0; index < selected; ++index) {
        query += alphabet[random() % alphabet.size()];
      }
    }

    std::array<std::uint16_t, 70> positions;
    const auto ranked = match.score(path, query);
    const auto highlighted = match.score(path, query, positions);
    if (ranked != highlighted) {
      return 1;
    }

    dump.put(ranked ? 1 : 0);
    if (ranked) {
      dump.write(reinterpret_cast<const char *>(&*ranked), sizeof(*ranked));
      dump.write(reinterpret_cast<const char *>(positions.data()), static_cast<std::streamsize>(query.size() * sizeof(positions.front())));
    }
  }
  return dump.good() ? 0 : 1;
}
