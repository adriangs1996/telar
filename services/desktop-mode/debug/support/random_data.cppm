module;

#include <random>
#include <vector>
export module debug.support.random_data;

#ifndef TELAR_DEBUG_RANDOM_SEED
#define SEED 42
#else
#define SEED std::random_device{}()
#endif

export std::vector<char> randomAscii(std::size_t size) {
  constexpr int first_printable_ascii = 32;
  constexpr int las_printable_ascii = 126;

  std::mt19937 generator{SEED};
  std::uniform_int_distribution<int> distribution{first_printable_ascii, las_printable_ascii};

  std::vector<char> characters(size);

  for (char &character : characters) {
    character = static_cast<char>(distribution(generator));
  }

  return characters;
}
