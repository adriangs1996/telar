#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.base.ds;
import telar.base.memory.allocators;

// Each container of telar::ds runs a long random sequence of operations next to its standard
// counterpart, which serves as the model: after every operation both must hold the same values. The
// sequences are seeded, so a failure repeats.
namespace {

  using telar::testing::check;

  using namespace telar;

  using Budget = BudgetAllocator<SystemAllocator>;

  constexpr std::size_t operations = 20'000;

  // Texts on both sides of String's inline capacity, so that operations cross it both ways.
  std::string text(std::mt19937_64& random) {
    const auto length = std::uniform_int_distribution<std::size_t>{0, 40}(random);

    return std::string(length, static_cast<char>('a' + random() % 26));
  }

  template <typename Value, typename Memory>
  bool same(const ds::Vec<Value, Memory>& mine, const std::vector<Value>& model) {
    if (mine.size() != model.size() || mine.empty() != model.empty() || mine.capacity() < mine.size()) {
      return false;
    }

    if (!std::ranges::equal(mine, model) || !std::ranges::equal(mine.view(), model)) {
      return false;
    }

    return model.empty() || (mine.front() == model.front() && mine.back() == model.back() && *mine.data() == model.front());
  }

  void testVecModel() {
    SystemAllocator system;
    Budget memory{system, std::size_t{1} << 30};
    Budget other{system, std::size_t{1} << 30};
    std::mt19937_64 random{0x7e1a7};

    {
      ds::Vec<std::string, Budget> mine{memory};
      std::vector<std::string> model;

      for (std::size_t step = 0; step < operations; ++step) {
        const auto index = [&](std::size_t bound) {
          return bound == 0 ? 0 : static_cast<std::size_t>(random() % bound);
        };

        switch (random() % 16) {
        case 0:
        case 1:
        case 2: {
          auto value = text(random);

          check(mine.push(value) == value);
          model.push_back(std::move(value));
          break;
        }
        case 3: {
          const auto count = index(40);

          check(mine.emplace(count, 'e').size() == count);
          model.emplace_back(count, 'e');
          break;
        }
        case 4: {
          const auto popped = mine.pop();

          check(popped.hasValue() == !model.empty());
          if (!model.empty()) {
            check(popped.get() == model.back());
            model.pop_back();
          }

          break;
        }
        case 5: {
          const auto at = index(model.size() + 1);
          auto value = text(random);

          check(mine.insert(at, value) == value);
          model.insert(model.begin() + static_cast<std::ptrdiff_t>(at), std::move(value));
          break;
        }
        case 6:
          if (!model.empty()) {
            const auto at = index(model.size());

            check(mine.remove(at) == model[at]);
            model.erase(model.begin() + static_cast<std::ptrdiff_t>(at));
          }

          break;
        case 7: {
          const auto count = index(model.size() + 1);

          mine.truncate(count);
          model.resize(count);
          break;
        }
        case 8: {
          const auto count = index(model.size() + 20);

          mine.resize(count);
          model.resize(count);
          break;
        }
        case 9: {
          const auto count = index(model.size() + 20);
          auto value = text(random);

          mine.resize(count, value);
          model.resize(count, value);
          break;
        }
        case 10: {
          const std::vector<std::string> extra(index(30), text(random));

          mine.extend(extra);
          model.insert(model.end(), extra.begin(), extra.end());
          break;
        }
        case 11:
          if (!model.empty()) {
            const auto at = index(model.size());
            auto value = text(random);

            mine.atMut(at) = value;
            model[at] = std::move(value);
          }

          break;
        case 12: {
          const auto copy = mine.clone();

          check(copy == mine && same(copy, model));
          break;
        }
        case 13: {
          // Moves the values to another allocator and back, which moves them one by one each time.
          ds::Vec<std::string, Budget> moved{other};

          moved = std::move(mine);
          check(mine.empty() && same(moved, model));
          mine = std::move(moved);
          break;
        }
        case 14:
          mine.reserve(index(model.size() * 2 + 2));
          break;
        default:
          if (random() % 64 == 0) {
            mine.clear();
            model.clear();
          }

          break;
        }

        check(same(mine, model), "the Vec holds what the model holds");
      }
    }

    check(memory.liveBytes() == 0 && other.liveBytes() == 0);
  }

  void testStringModel() {
    SystemAllocator system;
    Budget memory{system, std::size_t{1} << 30};
    Budget other{system, std::size_t{1} << 30};
    std::mt19937_64 random{0x5791};

    {
      ds::String<Budget> mine{memory};
      std::string model;

      for (std::size_t step = 0; step < operations; ++step) {
        const auto position = [&](std::size_t bound) {
          return static_cast<std::size_t>(random() % (bound + 1));
        };

        switch (random() % 18) {
        case 0:
        case 1:
        case 2: {
          const auto piece = text(random);

          mine.append(piece);
          model.append(piece);
          break;
        }
        case 3:
        case 4: {
          const auto character = static_cast<char>('A' + random() % 26);

          mine.push(character);
          model.push_back(character);
          break;
        }
        case 5:
          // Appending a part of itself reads storage the append may replace.
          if (!model.empty()) {
            const auto from = static_cast<std::size_t>(random() % model.size());
            const auto part = model.substr(from);

            mine.append(mine.view().substr(from));
            model.append(part);
          }

          break;
        case 6:
          mine.reserve(static_cast<std::size_t>(random() % 200));
          break;
        case 7: {
          const auto copy = mine.clone();

          check(copy == mine && copy == std::string_view{model} && (copy <=> mine) == std::strong_ordering::equal);
          break;
        }
        case 8: {
          ds::String<Budget> moved{other};

          moved = std::move(mine);
          check(mine.empty() && moved == std::string_view{model});
          mine = std::move(moved);
          break;
        }
        case 9: {
          const auto at = position(model.size());
          const auto piece = text(random);

          mine.insert(at, piece);
          model.insert(at, piece);
          break;
        }
        case 10: {
          const auto at = position(model.size());
          const auto count = position(model.size() - at + 4);

          mine.remove(at, count);
          model.erase(at, count);
          break;
        }
        case 11: {
          const auto at = position(model.size());
          const auto count = position(model.size() - at);
          const auto piece = text(random);

          mine.replace(at, count, piece);
          model.replace(at, count, piece);
          break;
        }
        case 12:
          // Text that is a part of the String itself, replacing another part of it.
          if (!model.empty()) {
            const auto from = position(model.size() - 1);
            const auto length = position(model.size() - from);
            const auto at = position(model.size());
            const auto count = position(model.size() - at);
            const auto part = model.substr(from, length);

            mine.replace(at, count, mine.view().substr(from, length));
            model.replace(at, count, part);
          }

          break;
        case 13: {
          const auto count = position(model.size() + 30);

          mine.resize(count, 'r');
          model.resize(count, 'r');
          break;
        }
        case 14: {
          const auto popped = mine.pop();

          check(popped.hasValue() == !model.empty());
          if (!model.empty()) {
            check(popped.get() == model.back());
            model.pop_back();
          }

          break;
        }
        case 15:
          if (!model.empty()) {
            const auto from = position(model.size() - 1);
            const auto part = model.substr(from);

            mine.assign(mine.view().substr(from));
            model.assign(part);
          } else {
            const auto piece = text(random);

            mine.assign(piece);
            model.assign(piece);
          }

          break;
        case 16:
          if (!model.empty()) {
            const auto at = position(model.size() - 1);

            mine.atMut(at) = 'z';
            model[at] = 'z';
            mine.truncate(at + 1);
            model.resize(at + 1);
          }

          break;
        default:
          if (random() % 16 == 0) {
            mine.clear();
            model.clear();
          }

          break;
        }

        // Appending itself doubles the text, so it starts over before it gets large.
        if (model.size() > 4096) {
          mine.clear();
          model.clear();
        }

        const std::string_view view = mine;

        check(view == model && mine.size() == model.size() && mine.capacity() >= mine.size(), "the String holds what the model holds");
        check(mine.data()[mine.size()] == '\0', "the String stays terminated");
        check((mine <=> std::string_view{"m"}) == (std::string_view{model} <=> std::string_view{"m"}));
      }
    }

    check(memory.liveBytes() == 0 && other.liveBytes() == 0);
  }

  template <typename Key, typename Value, typename Memory, typename Hasher>
  bool same(const ds::Map<Key, Value, Memory, Hasher>& mine, const std::unordered_map<std::uint64_t, std::string>& model) {
    if (mine.size() != model.size() || mine.empty() != model.empty() || mine.capacity() < mine.size()) {
      return false;
    }

    std::size_t visited = 0;

    for (const auto& [key, value] : mine) {
      const auto found = model.find(key);
      if (found == model.end() || found->second != value) {
        return false;
      }

      ++visited;
    }

    return visited == model.size();
  }

  void testMapModel() {
    SystemAllocator system;
    Budget memory{system, std::size_t{1} << 30};
    Budget other{system, std::size_t{1} << 30};
    std::mt19937_64 random{0x3a9};

    {
      ds::Map<std::uint64_t, std::string, Budget> mine{memory};
      std::unordered_map<std::uint64_t, std::string> model;

      for (std::size_t step = 0; step < operations; ++step) {
        // Few keys, so that inserts meet removed slots and the table rehashes in place.
        const auto key = static_cast<std::uint64_t>(random() % 512);

        switch (random() % 12) {
        case 0:
        case 1:
        case 2: {
          auto value = text(random);
          const bool fresh = !model.contains(key);

          check(mine.insert(key, value) == fresh);
          model.try_emplace(key, std::move(value));
          break;
        }
        case 3:
        case 4: {
          auto value = text(random);
          const bool fresh = !model.contains(key);

          check(mine.assign(key, value) == fresh);
          model.insert_or_assign(key, std::move(value));
          break;
        }
        case 5:
        case 6: {
          const auto removed = mine.remove(key);
          const auto found = model.find(key);

          check(removed.hasValue() == (found != model.end()));
          if (found != model.end()) {
            check(removed.get() == found->second);
            model.erase(found);
          }

          break;
        }
        case 7: {
          const auto* found = mine.find(key);
          const auto expected = model.find(key);

          check((found != nullptr) == (expected != model.end()) && mine.contains(key) == (expected != model.end()));
          check(found == nullptr || *found == expected->second);
          break;
        }
        case 8:
          if (auto* found = mine.findMut(key)) {
            found->append("+");
            model[key].append("+");
          }

          break;
        case 9: {
          const auto copy = mine.clone();

          check(same(copy, model));
          break;
        }
        case 10: {
          ds::Map<std::uint64_t, std::string, Budget> moved{other};

          moved = std::move(mine);
          check(mine.empty() && same(moved, model));
          mine = std::move(moved);
          break;
        }
        default:
          if (random() % 32 == 0) {
            mine.clear();
            model.clear();
          } else {
            mine.reserve(static_cast<std::size_t>(random() % 1024));
          }

          break;
        }

        check(same(mine, model), "the Map holds what the model holds");
      }
    }

    check(memory.liveBytes() == 0 && other.liveBytes() == 0);
  }

  void testOptionModel() {
    std::mt19937_64 random{0x0b7};
    ds::Option<std::string> mine;
    ds::Option<std::string> model;

    for (std::size_t step = 0; step < operations; ++step) {
      switch (random() % 8) {
      case 0: {
        auto value = text(random);

        mine.emplace(value);
        model.emplace(std::move(value));
        break;
      }
      case 1:
        mine.reset();
        model.reset();
        break;
      case 2: {
        const auto taken = mine.take();

        check(taken.hasValue() == model.hasValue() && (!model || taken.get() == *model));
        model.reset();
        break;
      }
      case 3: {
        // Copies in every combination of full and empty.
        const ds::Option<std::string> source = random() % 2 == 0 ? ds::Option<std::string>{text(random)} : ds::Option<std::string>{ds::none};
        const ds::Option<std::string> expected = source.hasValue() ? ds::Option{source.get()} : ds::none;

        mine = source;
        model = expected;
        break;
      }
      case 4: {
        auto source = random() % 2 == 0 ? ds::Option<std::string>{text(random)} : ds::Option<std::string>{ds::none};

        model = source.hasValue() ? ds::Option{source.get()} : ds::none;
        mine = std::move(source);
        break;
      }
      case 5:
        if (mine.hasValue()) {
          mine.getMut().push_back('!');
          model.getMut().push_back('!');
        }

        break;
      default:
        check(mine.valueOr("fallback") == model.valueOr("fallback"));
        break;
      }

      check(mine.hasValue() == model.hasValue() && static_cast<bool>(mine) == model.hasValue() && (mine == ds::none) == !model.hasValue());
      check(!model || (*mine == *model && mine->size() == model->size()));
    }
  }

  const telar::testing::Case case_vec_model{"ds_model.vec", testVecModel};
  const telar::testing::Case case_string_model{"ds_model.string", testStringModel};
  const telar::testing::Case case_map_model{"ds_model.map", testMapModel};
  const telar::testing::Case case_option_model{"ds_model.option", testOptionModel};

}
