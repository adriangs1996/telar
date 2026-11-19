// Measures the containers of telar::ds against their standard counterparts, in nanoseconds per
// operation, best of several rounds. Build it in a Release tree, where assertions are off:
//   tools/cpp build <preset> -- --target ds-bench && out/<preset>/lib/base/ds-bench
import std;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using namespace telar;

  // Keeps the compiler from proving a result unused and dropping the work that produced it.
  template <typename Value>
  void keep(const Value& value) {
    asm volatile("" : : "r,m"(value) : "memory");
  }

  template <typename Run>
  double nanoseconds(std::size_t operations, const Run& run) {
    auto best = std::numeric_limits<double>::infinity();

    for (int round = 0; round < 15; ++round) {
      const auto start = std::chrono::steady_clock::now();

      run();
      const std::chrono::duration<double, std::nano> elapsed = std::chrono::steady_clock::now() - start;

      best = std::min(best, elapsed.count() / static_cast<double>(operations));
    }

    return best;
  }

  void report(std::string_view what, double ds, double vector, double standard) {
    std::println("{:<34} ds {:7.3f}  telar::Vector {:7.3f}  std {:7.3f}  ds/std {:5.2f}", what, ds, vector, standard, ds / standard);
  }

  struct Record {
    std::uint64_t key;
    std::uint64_t value;
    double weight;
    std::uint32_t flags;
  };

  // Best of several rounds of `run`, each on what a fresh `setup` returns, which is not timed.
  template <typename Setup, typename Run>
  double timedOn(std::size_t operations, const Setup& setup, const Run& run) {
    auto best = std::numeric_limits<double>::infinity();

    for (int round = 0; round < 15; ++round) {
      auto subject = setup();
      const auto start = std::chrono::steady_clock::now();

      run(subject);
      const std::chrono::duration<double, std::nano> elapsed = std::chrono::steady_clock::now() - start;

      keep(subject);
      best = std::min(best, elapsed.count() / static_cast<double>(operations));
    }

    return best;
  }

  // Each operation of Vec past appending, against std::vector, on `count` values made by `make`.
  template <typename Make>
  void vecOperations(std::string_view kind, std::size_t count, const Make& make) {
    using Value = decltype(make(std::size_t{}));

    SystemAllocator system;
    std::vector<Value> source;

    for (std::size_t index = 0; index < count; ++index) {
      source.push_back(make(index));
    }

    const auto mine = [&] {
      ds::Vec<Value, SystemAllocator> values{system};

      values.extend(source);
      return values;
    };
    const auto standard = [&] {
      return source;
    };
    const auto empty_mine = [&] {
      return ds::Vec<Value, SystemAllocator>{system};
    };
    const auto empty_standard = [] {
      return std::vector<Value>{};
    };
    const auto nan = std::numeric_limits<double>::quiet_NaN();
    // Insertion and removal at the front move every value, so they run on a smaller Vec.
    const auto shifted = std::min<std::size_t>(count, 4096);

    report(
        std::format("vec insert front, {}", kind),
        timedOn(shifted, empty_mine, [&](auto& values) {
          for (std::size_t index = 0; index < shifted; ++index) {
            values.insert(0, source[index]);
          }
        }),
        nan,
        timedOn(shifted, empty_standard, [&](auto& values) {
          for (std::size_t index = 0; index < shifted; ++index) {
            values.insert(values.begin(), source[index]);
          }
        })
    );
    report(
        std::format("vec remove front, {}", kind),
        timedOn(shifted, [&] {
          ds::Vec<Value, SystemAllocator> values{system};

          values.extend(std::span{source}.first(shifted));
          return values;
        },
            [&](auto& values) {
              while (!values.empty()) {
                keep(values.remove(0));
              }
            }),
        nan,
        timedOn(shifted, [&] {
          return std::vector<Value>(source.begin(), source.begin() + static_cast<std::ptrdiff_t>(shifted));
        },
            [&](auto& values) {
              while (!values.empty()) {
                keep(values.front());
                values.erase(values.begin());
              }
            })
    );
    report(
        std::format("vec pop, {}", kind),
        timedOn(count, mine, [&](auto& values) {
          while (const auto last = values.pop()) {
            keep(*last);
          }
        }),
        nan,
        timedOn(count, standard, [&](auto& values) {
          // Takes each value out, as Vec::pop hands it over.
          while (!values.empty()) {
            const auto last = std::move(values.back());

            values.pop_back();
            keep(last);
          }
        })
    );
    report(
        std::format("vec extend, {}", kind),
        timedOn(count, empty_mine, [&](auto& values) {
          values.extend(source);
        }),
        nan,
        timedOn(count, empty_standard, [&](auto& values) {
          values.insert(values.end(), source.begin(), source.end());
        })
    );
    report(
        std::format("vec resize with a value, {}", kind),
        timedOn(count, empty_mine, [&](auto& values) {
          values.resize(count, source.front());
        }),
        nan,
        timedOn(count, empty_standard, [&](auto& values) {
          values.resize(count, source.front());
        })
    );
    report(
        std::format("vec clone, {}", kind),
        timedOn(count, mine, [&](const auto& values) {
          keep(values.clone());
        }),
        nan,
        timedOn(count, standard, [&](const auto& values) {
          const auto copy = values;

          keep(copy);
        })
    );
    report(
        std::format("vec truncate, {}", kind),
        timedOn(count, mine, [&](auto& values) {
          values.truncate(0);
        }),
        nan,
        timedOn(count, standard, [&](auto& values) {
          values.clear();
        })
    );
  }

  // Array against std::array: reading every value, filling and copying, `rounds` times.
  void arrays(std::size_t rounds) {
    constexpr std::size_t size = 256;

    ds::Array<std::uint32_t, size> mine{};
    std::array<std::uint32_t, size> standard{};

    for (std::size_t index = 0; index < size; ++index) {
      mine.atMut(index) = static_cast<std::uint32_t>(index);
      standard[index] = static_cast<std::uint32_t>(index);
    }

    const auto nan = std::numeric_limits<double>::quiet_NaN();
    const auto indexed = [&](const auto& values) {
      return nanoseconds(rounds * size, [&] {
        std::uint64_t sum = 0;

        for (std::size_t round = 0; round < rounds; ++round) {
          keep(values);
          for (std::size_t index = 0; index < size; ++index) {
            sum += values[index];
          }
        }

        keep(sum);
      });
    };
    const auto filled = [&](auto values) {
      return nanoseconds(rounds * size, [&] {
        for (std::size_t round = 0; round < rounds; ++round) {
          values.fill(static_cast<std::uint32_t>(round));
          keep(values);
        }
      });
    };
    const auto copied = [&](const auto& values) {
      return nanoseconds(rounds * size, [&] {
        for (std::size_t round = 0; round < rounds; ++round) {
          keep(values);
          auto copy = values;

          keep(copy);
        }
      });
    };

    report("array read by index, 256 uint32", indexed(mine), nan, indexed(standard));
    report("array fill, 256 uint32", filled(mine), nan, filled(standard));
    report("array copy, 256 uint32", copied(mine), nan, copied(standard));
  }

  // Appends `count` values made by `make`, into an empty container each round.
  template <typename Make>
  void appends(std::string_view what, std::size_t count, const Make& make) {
    using Value = decltype(make(std::size_t{}));

    SystemAllocator system;
    const auto ds = nanoseconds(count, [&] {
      ds::Vec<Value, SystemAllocator> values{system};

      for (std::size_t index = 0; index < count; ++index) {
        values.push(make(index));
      }

      keep(values.data());
    });

    const auto vector = nanoseconds(count, [&] {
      std::vector<Value, AllocatorRef<Value, SystemAllocator>> values{AllocatorRef<Value, SystemAllocator>{system}};

      for (std::size_t index = 0; index < count; ++index) {
        values.push_back(make(index));
      }

      keep(values.data());
    });

    const auto standard = nanoseconds(count, [&] {
      std::vector<Value> values;

      for (std::size_t index = 0; index < count; ++index) {
        values.push_back(make(index));
      }

      keep(values.data());
    });

    report(what, ds, vector, standard);
  }

  // Sums `count` integers by index and by iteration, from containers filled once.
  void reads(std::size_t count) {
    SystemAllocator system;
    ds::Vec<std::uint32_t, SystemAllocator> mine{system};
    std::vector<std::uint32_t, AllocatorRef<std::uint32_t, SystemAllocator>> vector{AllocatorRef<std::uint32_t, SystemAllocator>{system}};
    std::vector<std::uint32_t> standard;

    for (std::size_t index = 0; index < count; ++index) {
      mine.push(static_cast<std::uint32_t>(index));
      vector.push_back(static_cast<std::uint32_t>(index));
      standard.push_back(static_cast<std::uint32_t>(index));
    }

    const auto indexed = [&](const auto& values) {
      return nanoseconds(count, [&] {
        std::uint64_t sum = 0;

        for (std::size_t index = 0; index < values.size(); ++index) {
          sum += values[index];
        }

        keep(sum);
      });
    };

    const auto iterated = [&](const auto& values) {
      return nanoseconds(count, [&] {
        std::uint64_t sum = 0;

        for (const auto value : values) {
          sum += value;
        }

        keep(sum);
      });
    };

    report("read by index, uint32", indexed(mine), indexed(vector), indexed(standard));
    report("read by iteration, uint32", iterated(mine), iterated(vector), iterated(standard));
  }

  // Fills, reads and empties an optional value `count` times.
  template <typename Value, typename Make>
  void options(std::string_view what, std::size_t count, const Make& make) {
    const auto mine = nanoseconds(count, [&] {
      ds::Option<Value> slot;
      std::size_t total = 0;

      for (std::size_t index = 0; index < count; ++index) {
        slot.emplace(make(index));
        total += slot.hasValue() ? 1 : 0;
        keep(slot.get());
        slot.reset();
      }

      keep(total);
    });

    const auto standard = nanoseconds(count, [&] {
      ds::Option<Value> slot;
      std::size_t total = 0;

      for (std::size_t index = 0; index < count; ++index) {
        slot.emplace(make(index));
        total += slot.hasValue() ? 1 : 0;
        keep(*slot);
        slot.reset();
      }

      keep(total);
    });

    report(what, mine, std::numeric_limits<double>::quiet_NaN(), standard);
  }

  // Builds a String or a std::string from `text` `count` times, each destroyed before the next.
  void constructs(std::string_view what, std::size_t count, std::string_view text) {
    SystemAllocator system;
    const auto mine = nanoseconds(count, [&] {
      for (std::size_t index = 0; index < count; ++index) {
        const ds::String<SystemAllocator> built{system, text};

        keep(built.data());
      }
    });

    const auto standard = nanoseconds(count, [&] {
      for (std::size_t index = 0; index < count; ++index) {
        const std::string built{text};

        keep(built.data());
      }
    });

    report(what, mine, std::numeric_limits<double>::quiet_NaN(), standard);
  }

  // Appends `count` pieces of text, and as many bytes one at a time, to an empty string each round.
  void appendsText(std::size_t count) {
    SystemAllocator system;
    constexpr std::string_view piece = "0123456789abcdef";
    const auto pieces = [&](auto& text) {
      for (std::size_t index = 0; index < count; ++index) {
        text.append(piece);
      }

      keep(text.data());
    };

    const auto bytes = [&](auto& text, auto push) {
      for (std::size_t index = 0; index < count; ++index) {
        push(text, static_cast<char>('a' + index % 26));
      }

      keep(text.data());
    };

    const auto mine_pieces = nanoseconds(count, [&] {
      ds::String<SystemAllocator> text{system};

      pieces(text);
    });

    const auto standard_pieces = nanoseconds(count, [&] {
      std::string text;

      pieces(text);
    });

    const auto mine_bytes = nanoseconds(count, [&] {
      ds::String<SystemAllocator> text{system};

      bytes(text, [](auto& target, char character) {
        target.push(character);
      });
    });

    const auto standard_bytes = nanoseconds(count, [&] {
      std::string text;

      bytes(text, [](auto& target, char character) {
        target.push_back(character);
      });
    });

    report("string append 16 bytes", mine_pieces, std::numeric_limits<double>::quiet_NaN(), standard_pieces);
    report("string push 1 byte", mine_bytes, std::numeric_limits<double>::quiet_NaN(), standard_bytes);
  }

  // Times `run` on what `setup` builds, best of several rounds, leaving the setup out.
  template <typename Setup, typename Run>
  double nanosecondsAfter(std::size_t operations, const Setup& setup, const Run& run) {
    auto best = std::numeric_limits<double>::infinity();

    for (int round = 0; round < 15; ++round) {
      auto state = setup();
      const auto start = std::chrono::steady_clock::now();

      run(state);
      const std::chrono::duration<double, std::nano> elapsed = std::chrono::steady_clock::now() - start;

      best = std::min(best, elapsed.count() / static_cast<double>(operations));
    }

    return best;
  }

  // Inserts, finds, misses and removes `keys` in a ds::Map and a std::unordered_map. `own` makes a
  // key each map stores from a lookup key, and `standard_key` the key std::unordered_map is looked up
  // by, as it has no heterogeneous lookup without a transparent hash.
  template <typename DsKey, typename StdKey, typename Lookup, typename Own, typename StandardKey>
  void maps(std::string_view what, const std::vector<Lookup>& keys, const std::vector<Lookup>& misses, const Own& own, const StandardKey& standard_key) {
    using Mine = ds::Map<DsKey, std::uint64_t, SystemAllocator>;
    using Standard = std::unordered_map<StdKey, std::uint64_t>;

    SystemAllocator system;
    const auto count = keys.size();
    const std::vector<StdKey> standard_keys(std::from_range, keys | std::views::transform(standard_key));
    const std::vector<StdKey> standard_misses(std::from_range, misses | std::views::transform(standard_key));
    const auto fill_mine = [&] {
      Mine map{system};

      for (std::size_t index = 0; index < count; ++index) {
        map.insert(own(system, keys[index]), index);
      }

      return map;
    };

    const auto fill_standard = [&] {
      Standard map;

      for (std::size_t index = 0; index < count; ++index) {
        map.try_emplace(standard_keys[index], index);
      }

      return map;
    };

    const auto insert_mine = nanoseconds(count, [&] {
      keep(fill_mine().size());
    });

    const auto insert_standard = nanoseconds(count, [&] {
      keep(fill_standard().size());
    });

    const auto filled_mine = fill_mine();
    const auto filled_standard = fill_standard();
    const auto find_mine = [](const Mine& map, const Lookup& key) {
      return map.find(key);
    };

    const auto find_standard = [](const Standard& map, const StdKey& key) -> const std::uint64_t* {
      const auto found = map.find(key);

      return found == map.end() ? nullptr : &found->second;
    };

    const auto lookups = [&](const auto& map, const auto& looked_up, const auto& find) {
      return nanoseconds(count, [&] {
        std::uint64_t sum = 0;

        for (const auto& key : looked_up) {
          if (const auto* value = find(map, key)) {
            sum += *value;
          }
        }

        keep(sum);
      });
    };

    const auto remove_mine = nanosecondsAfter(count, fill_mine, [&](Mine& map) {
      for (const auto& key : keys) {
        keep(map.remove(key));
      }
    });

    const auto remove_standard = nanosecondsAfter(count, fill_standard, [&](Standard& map) {
      for (const auto& key : standard_keys) {
        keep(map.erase(key));
      }
    });

    report(std::format("map insert, {}", what), insert_mine, std::numeric_limits<double>::quiet_NaN(), insert_standard);
    report(std::format("map find hit, {}", what), lookups(filled_mine, keys, find_mine), std::numeric_limits<double>::quiet_NaN(), lookups(filled_standard, standard_keys, find_standard));
    report(std::format("map find miss, {}", what), lookups(filled_mine, misses, find_mine), std::numeric_limits<double>::quiet_NaN(), lookups(filled_standard, standard_misses, find_standard));
    report(std::format("map remove, {}", what), remove_mine, std::numeric_limits<double>::quiet_NaN(), remove_standard);
  }

  // Builds a callable that captures a copy of `capture`, keeps the compiler from seeing which one it
  // holds, and calls it, `count` times. libc++ has no std::move_only_function to compare with.
  template <typename Capture>
  void functions(std::string_view what, std::size_t count, const Capture& capture) {
    const auto run = [&]<typename Callable>(std::type_identity<Callable>) {
      return nanoseconds(count, [&] {
        std::uint64_t sum = 0;

        for (std::size_t index = 0; index < count; ++index) {
          Callable call = [captured = capture](std::uint64_t value) {
            return value + captured.size();
          };

          keep(call);
          sum = call(sum);
        }

        keep(sum);
      });
    };

    const auto mine = run(std::type_identity<ds::Function<std::uint64_t(std::uint64_t)>>{});
    const auto standard = run(std::type_identity<std::function<std::uint64_t(std::uint64_t)>>{});

    report(what, mine, std::numeric_limits<double>::quiet_NaN(), standard);
  }

  // Calls one callable `count` times, which the compiler cannot see through.
  void calls(std::size_t count) {
    const auto run = [&]<typename Callable>(std::type_identity<Callable>) {
      std::uint64_t step = 3;
      Callable call = [&step](std::uint64_t value) {
        return value * 31 + step;
      };

      return nanoseconds(count, [&] {
        std::uint64_t sum = 0;

        for (std::size_t index = 0; index < count; ++index) {
          keep(call);
          sum = call(sum);
        }

        keep(sum);
      });
    };

    const auto mine = run(std::type_identity<ds::Function<std::uint64_t(std::uint64_t)>>{});
    const auto standard = run(std::type_identity<std::function<std::uint64_t(std::uint64_t)>>{});

    report("function call", mine, std::numeric_limits<double>::quiet_NaN(), standard);
  }

  // Keys of about 16 bytes, as names and identifiers are, from `random`.
  std::vector<std::string> names(std::size_t count, std::mt19937_64& random) {
    std::vector<std::string> made;

    made.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
      made.push_back(std::format("pane-{:x}", random() >> (random() % 40)));
    }

    return made;
  }

}

int main() {
  constexpr std::size_t count = std::size_t{1} << 20;

  appends("append uint32", count, [](std::size_t index) {
    return static_cast<std::uint32_t>(index);
  });

  appends("append 32-byte record", count, [](std::size_t index) {
    return Record{.key = index, .value = index * 3, .weight = 0.5, .flags = 1};
  });

  appends("append short std::string", count / 8, [](std::size_t index) {
    return std::string(index % 15, 'x');
  });

  appends("append 64-byte std::string", count / 8, [](std::size_t) {
    return std::string(64, 'x');
  });

  reads(count);
  vecOperations("uint32", count, [](std::size_t index) {
    return static_cast<std::uint32_t>(index);
  });
  vecOperations("32-byte std::string", count / 8, [](std::size_t index) {
    return std::string(32, static_cast<char>('a' + index % 26));
  });
  arrays(std::size_t{1} << 14);
  options<std::uint64_t>("option uint64", count, [](std::size_t index) {
    return static_cast<std::uint64_t>(index);
  });

  options<std::string>("option 64-byte std::string", count / 8, [](std::size_t) {
    return std::string(64, 'x');
  });

  constructs("string construct 12 bytes", count, "pane-1234567");
  constructs("string construct 22 bytes", count, "pane-12345678901234567");
  constructs("string construct 64 bytes", count / 8, std::string(64, 'x'));
  appendsText(count);

  std::mt19937_64 random{42};
  std::vector<std::uint64_t> integers(std::size_t{1} << 18);
  std::vector<std::uint64_t> other_integers(integers.size());

  std::ranges::generate(integers, std::ref(random));
  std::ranges::generate(other_integers, std::ref(random));
  maps<std::uint64_t, std::uint64_t>(
      "uint64",
      integers,
      other_integers,
      [](SystemAllocator&, std::uint64_t key) {
        return key;
      },
      std::identity{}
  );

  const auto texts = names(std::size_t{1} << 16, random);
  const auto other_texts = names(texts.size(), random);

  maps<ds::String<SystemAllocator>, std::string>(
      "text",
      std::vector<std::string_view>(texts.begin(), texts.end()),
      std::vector<std::string_view>(other_texts.begin(), other_texts.end()),
      [](SystemAllocator& system, std::string_view key) {
        return ds::String<SystemAllocator>{system, key};
      },
      [](std::string_view key) {
        return std::string{key};
      }
  );
  functions("function construct+call, string_view", count, std::string_view{"capture"});
  functions("function construct+call, std::string", count, std::string{"capture"});
  calls(count);
  std::println("sizeof Option<uint64> {} optional {}; Vec<int> {} std::vector+AllocatorRef {} std::vector {}", sizeof(ds::Option<std::uint64_t>), sizeof(ds::Option<std::uint64_t>), sizeof(ds::Vec<int, SystemAllocator>), sizeof(std::vector<int, AllocatorRef<int, SystemAllocator>>), sizeof(std::vector<int>));
  std::println("sizeof String {} std::string {}; Map {} std::unordered_map {}; Function {} std::function {}", sizeof(ds::String<SystemAllocator>), sizeof(std::string), sizeof(ds::Map<std::uint64_t, std::uint64_t, SystemAllocator>), sizeof(std::unordered_map<std::uint64_t, std::uint64_t>), sizeof(ds::Function<void()>), sizeof(std::function<void()>));
}
