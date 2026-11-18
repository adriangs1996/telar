#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "tbc/annotations.hpp"

import std;
import telar.testing;
import telar.base.ds;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;

  using namespace telar;

  // How many values are alive, shared by all of them as a Rust `Rc<Cell<i32>>` would be.
  class TBC_SHARED Lives {
  public:
    void born() noexcept {
      ++count_;
    }

    void died() noexcept {
      --count_;
    }

    [[nodiscard]] int count() const noexcept {
      return count_;
    }

  private:
    int count_ = 0;
  };

  // Counts the values alive, so that a test sees every construction matched by one destruction.
  struct Counted {
    explicit Counted(int value, Lives& lives) noexcept
        : value(value),
          lives(&lives) {
      lives.born();
    }

    Counted(const Counted& other) noexcept
        : value(other.value),
          lives(other.lives) {
      lives->born();
    }

    Counted(Counted&& other) noexcept
        : value(other.value),
          lives(other.lives) {
      lives->born();
    }

    Counted& operator=(const Counted&) noexcept = default;
    Counted& operator=(Counted&&) noexcept = default;

    ~Counted() {
      lives->died();
    }

    friend bool operator==(const Counted& left, const Counted& right) noexcept {
      return left.value == right.value;
    }

    int value;
    Lives* lives;
  };

  void testArray() {
    constexpr ds::Array values{1, 2, 3};

    static_assert(values.size() == 3 && values[1] == 2);
    static_assert(std::is_trivially_copyable_v<ds::Array<int, 4>> && sizeof(ds::Array<int, 4>) == sizeof(std::array<int, 4>));

    ds::Array<int, 3> copy = values;

    copy.atMut(0) = 7;
    check(copy[0] == 7 && values[0] == 1 && copy != values);
    copy.fill(4);
    check(std::ranges::equal(copy, std::array{4, 4, 4}) && copy.view().size() == 3);
  }

  void testOption() {
    static_assert(std::is_trivially_copyable_v<ds::Option<int>> && std::is_trivially_destructible_v<ds::Option<int>>);
    static_assert(sizeof(ds::Option<int>) == sizeof(ds::Option<int>));
    static_assert(!std::is_trivially_destructible_v<ds::Option<std::string>>);

    constexpr ds::Option<int> empty = ds::none;
    constexpr ds::Option<int> seven = 7;

    static_assert(!empty.hasValue() && empty == ds::none && seven.get() == 7 && empty.valueOr(3) == 3);

    Lives alive;

    {
      ds::Option<Counted> held = Counted{1, alive};
      auto copy = held;

      check(alive.count() == 2 && copy == held);
      auto taken = held.take();

      check(!held.hasValue() && taken.hasValue() && taken->value == 1 && alive.count() == 2);
      taken.emplace(2, alive);
      check(alive.count() == 2 && taken.get().value == 2);
      taken.getMut().value = 3;
      copy = taken;
      check(copy.get().value == 3 && alive.count() == 2);
      copy.reset();
      check(alive.count() == 1 && copy == ds::none);
    }

    check(alive.count() == 0);
  }

  void testVecGrowth() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::Vec<int, decltype(memory)> values{memory};

      for (int value = 0; value < 1000; ++value) {
        values.push(value);
      }

      check(values.size() == 1000 && values.capacity() >= 1000 && values[999] == 999);
      check(std::accumulate(values.begin(), values.end(), 0) == 999 * 1000 / 2);

      // A value of the Vec itself, pushed when the storage is full, is read before the storage moves.
      while (values.size() < values.capacity()) {
        values.push(1);
      }

      values.push(values[0]);
      check(values.back() == 0);
      const auto copy = values.clone();

      values.extend(copy.view());
      check(values.size() == 2 * copy.size() && values[copy.size()] == values[0]);

      const auto last = values.pop();

      check(last.hasValue() && last.get() == 0);
      values.clear();
      check(values.empty() && !values.pop().hasValue());
    }

    check(memory.liveBytes() == 0);
  }

  void testVecValues() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};
    Lives alive;

    {
      ds::Vec<Counted, decltype(memory)> values{memory};

      for (int value = 0; value < 100; ++value) {
        values.emplace(value, alive);
      }

      check(alive.count() == 100);
      values.insert(0, Counted{-1, alive});
      check(values.size() == 101 && values.front().value == -1 && values[1].value == 0 && alive.count() == 101);

      const auto removed = values.remove(1);

      check(removed.value == 0 && values[1].value == 1 && alive.count() == 101);
      values.resize(10, Counted{9, alive});
      check(values.size() == 10 && alive.count() == 11);
      values.resize(20, values[0]);
      check(values.size() == 20 && values.back().value == -1 && alive.count() == 21);

      auto copy = values.clone();

      check(copy == values && alive.count() == 41);
      values.atMut(0).value = 5;
      check(copy != values);
    }

    check(alive.count() == 0 && memory.liveBytes() == 0);
  }

  void testVecMoves() {
    SystemAllocator system;
    BudgetAllocator first{system, 1 << 20};
    BudgetAllocator second{system, 1 << 20};

    {
      ds::Vec<std::string, decltype(first)> source{first};

      source.push(std::string(64, 'a'));
      source.push(std::string(64, 'b'));

      auto moved = std::move(source);

      check(moved.size() == 2 && source.empty() && first.liveBytes() != 0);

      // Storage returns to the allocator it came from, so values move one by one between two.
      ds::Vec<std::string, decltype(second)> other{second};

      other = std::move(moved);
      check(other.size() == 2 && other[1] == std::string(64, 'b') && moved.empty() && first.liveBytes() == 0);
    }

    check(second.liveBytes() == 0);
  }

  void testVecExhaustion() {
    SystemAllocator system;
    BudgetAllocator memory{system, 256};
    ds::Vec<std::uint64_t, decltype(memory)> values{memory};
    bool thrown = false;

    try {
      values.reserve(64);
    } catch (const std::bad_alloc&) {
      thrown = true;
    }

    check(thrown && values.empty() && memory.liveBytes() == 0);
  }

  void testStringInline() {
    static_assert(sizeof(ds::String<SystemAllocator>) == 4 * sizeof(void*));

    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::String<decltype(memory)> text{memory};

      check(text.empty() && text.capacity() == 23 && text.data()[0] == '\0');
      text.append("hello");
      text.push(',');
      text.append(" world");
      check(text == "hello, world" && text.size() == 12 && text.data()[12] == '\0' && memory.liveBytes() == 0);

      // The 23rd byte's NUL is also the count of free inline bytes.
      ds::String<decltype(memory)> full{memory, "abcdefghijklmnopqrstuvw"};

      check(full.size() == 23 && full.data()[23] == '\0' && memory.liveBytes() == 0);
      full.push('x');
      check(full == "abcdefghijklmnopqrstuvwx" && full.data()[24] == '\0' && memory.liveBytes() != 0);
      check(full < text && full > std::string_view{"abc"} && text != full);
    }

    check(memory.liveBytes() == 0);
  }

  void testStringGrowth() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::String<decltype(memory)> text{memory};
      std::string expected;

      for (int index = 0; index < 1000; ++index) {
        text.push(static_cast<char>('a' + index % 26));
        expected.push_back(static_cast<char>('a' + index % 26));
      }

      check(text == expected && text.capacity() >= 1000 && std::strlen(text.data()) == 1000);
      const auto copy = text.clone();

      text.append(copy);
      check(text.size() == 2000 && text.view().substr(1000) == copy.view());
      text.clear();
      check(text.empty() && text.capacity() >= 2000 && text.data()[0] == '\0');

      ds::String<decltype(memory)> reserved{memory};

      reserved.reserve(100);
      const auto reserved_bytes = memory.liveBytes();

      reserved.append(std::string(100, 'z'));
      check(reserved.size() == 100 && reserved.capacity() >= 100 && memory.liveBytes() == reserved_bytes);
    }

    check(memory.liveBytes() == 0);
  }

  void testStringMoves() {
    SystemAllocator system;
    BudgetAllocator first{system, 1 << 20};
    BudgetAllocator second{system, 1 << 20};

    {
      ds::String<decltype(first)> source{first, std::string(64, 'a')};
      auto moved = std::move(source);

      check(moved.size() == 64 && source.empty() && first.liveBytes() != 0);

      ds::String<decltype(first)> other{first, "short"};

      other = std::move(moved);
      check(other == std::string(64, 'a') && moved.empty());

      // Storage returns to the allocator it came from, so bytes are copied between two.
      ds::String<decltype(second)> elsewhere{second};

      elsewhere = std::move(other);
      check(elsewhere == std::string(64, 'a') && other.empty() && first.liveBytes() == 0);

      // A Vec relocates Strings as their bytes, inline ones too.
      ds::Vec<ds::String<decltype(second)>, decltype(second)> texts{second};

      for (std::size_t length = 0; length < 100; ++length) {
        texts.push(ds::String<decltype(second)>{second, std::string(length, 'q')});
      }

      for (std::size_t length = 0; length < 100; ++length) {
        check(texts[length] == std::string(length, 'q') && texts[length].data()[length] == '\0');
      }
    }

    check(first.liveBytes() == 0 && second.liveBytes() == 0);
  }

  void testStringExhaustion() {
    SystemAllocator system;
    BudgetAllocator memory{system, 64};
    ds::String<decltype(memory)> text{memory, "short"};
    bool thrown = false;

    try {
      text.reserve(1000);
    } catch (const std::bad_alloc&) {
      thrown = true;
    }

    check(thrown && text == "short" && memory.liveBytes() == 0);
  }

  void testMapIntegers() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 22};

    {
      ds::Map<std::uint64_t, std::uint64_t, decltype(memory)> map{memory};
      std::unordered_map<std::uint64_t, std::uint64_t> expected;
      std::mt19937_64 random{7};

      check(map.empty() && map.find(1) == nullptr && map.begin() == map.end());

      // Few keys and many removals, so that removed slots fill the table and it rehashes in place.
      for (std::uint64_t step = 0; step < 50000; ++step) {
        const auto key = random() % 512;
        const auto found = expected.find(key);

        switch (random() % 4) {
        case 0:
          check(map.insert(key, step) == (found == expected.end()));
          expected.try_emplace(key, step);
          break;
        case 1:
          check(map.assign(key, step) == (found == expected.end()));
          expected.insert_or_assign(key, step);
          break;
        case 2: {
          const auto removed = map.remove(key);

          check(removed.hasValue() == (found != expected.end()));
          if (found != expected.end()) {
            check(removed.get() == found->second);
            expected.erase(found);
          }

          break;
        }
        default: {
          const auto* value = map.find(key);

          check((value != nullptr) == (found != expected.end()) && (value == nullptr || *value == found->second));
        }
        }

        check(map.size() == expected.size());
      }

      std::size_t visited = 0;

      for (const auto& [key, value] : map) {
        check(expected.at(key) == value);
        ++visited;
      }

      check(visited == expected.size());

      // Keys that differ only in high bits spread over the table as well.
      map.clear();
      check(map.empty() && map.begin() == map.end() && !map.contains(0));
      for (std::uint64_t index = 0; index < 10000; ++index) {
        map.insert(index << 40, index);
      }

      check(map.size() == 10000 && *map.find(std::uint64_t{9999} << 40) == 9999 && !map.contains(1));
      *map.findMut(0) = 7;
      check(*map.find(0) == 7);
    }

    check(memory.liveBytes() == 0);
  }

  void testMapValues() {
    SystemAllocator system;
    BudgetAllocator first{system, 1 << 20};
    BudgetAllocator second{system, 1 << 20};
    Lives alive;

    {
      ds::Map<int, Counted, decltype(first)> map{first};

      for (int key = 0; key < 100; ++key) {
        map.insert(key, Counted{key, alive});
      }

      check(alive.count() == 100 && map.size() == 100);
      check(!map.insert(5, Counted{-5, alive}) && map.find(5)->value == 5);
      check(!map.assign(5, Counted{-5, alive}) && map.find(5)->value == -5);
      check(alive.count() == 100);

      auto removed = map.remove(7);

      check(removed.hasValue() && removed->value == 7 && map.size() == 99 && alive.count() == 100);
      removed.reset();
      check(alive.count() == 99 && !map.remove(7).hasValue());

      auto copy = map.clone();

      check(copy.size() == 99 && copy.find(5)->value == -5 && alive.count() == 198);
      map.clear();
      check(map.empty() && alive.count() == 99);

      // Storage returns to the allocator it came from, so entries move one by one between two.
      ds::Map<int, Counted, decltype(second)> other{second};

      other = std::move(copy);
      check(other.size() == 99 && copy.empty() && other.find(99)->value == 99 && alive.count() == 99);

      auto moved = std::move(other);

      check(moved.size() == 99 && other.empty() && other.find(99) == nullptr);
    }

    check(alive.count() == 0 && first.liveBytes() == 0 && second.liveBytes() == 0);
  }

  void testMapText() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      using Text = ds::String<decltype(memory)>;
      ds::Map<Text, int, decltype(memory)> map{memory};

      for (int index = 0; index < 200; ++index) {
        check(map.insert(Text{memory, std::format("pane-{}", index)}, index));
      }

      // Long keys live on the heap, and are looked up by any text without building a key.
      map.insert(Text{memory, std::string(40, 'k')}, -1);
      check(map.size() == 201 && *map.find("pane-42") == 42 && map.find(std::string_view{"pane-200"}) == nullptr);
      check(*map.find(std::string(40, 'k')) == -1 && !map.insert(Text{memory, "pane-3"}, 0));

      const Text key{memory, "pane-7"};

      check(map.contains(key) && map.remove("pane-7").get() == 7 && !map.contains(key));

      int sum = 0;

      for (const auto& entry : map) {
        sum += entry.value;
      }

      check(sum == 199 * 200 / 2 - 7 - 1);

      // Each length takes one of the hash's paths: empty, up to 3 bytes, up to 16, up to 48, and past.
      ds::Map<Text, std::size_t, decltype(memory)> lengths{memory};

      for (std::size_t length = 0; length <= 120; ++length) {
        lengths.insert(Text{memory, std::string(length, 'x')}, length);
      }

      for (std::size_t length = 1; length <= 120; ++length) {
        check(*lengths.find(std::string(length, 'x')) == length && !lengths.contains(std::string(length, 'y')));
      }

      check(*lengths.find("") == 0);
    }

    check(memory.liveBytes() == 0);
  }

  void testMapExhaustion() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1024};

    {
      ds::Map<std::uint64_t, std::uint64_t, decltype(memory)> map{memory};
      bool thrown = false;

      try {
        for (std::uint64_t key = 0; key < 1000; ++key) {
          map.insert(key, key);
        }
      } catch (const std::bad_alloc&) {
        thrown = true;
      }

      check(thrown && !map.empty());
      for (std::uint64_t key = 0; key < map.size(); ++key) {
        check(*map.find(key) == key);
      }
    }

    check(memory.liveBytes() == 0);
  }

  // Larger than the default capacity of three pointers.
  struct Large {
    void operator()() const noexcept {}

    std::array<char, 64> bytes;
  };

  struct ThrowingMove {
    ThrowingMove() = default;

    ThrowingMove(ThrowingMove&&) noexcept(false) {}

    void operator()() const noexcept {}
  };

  int larger(int left, int right) {
    return std::max(left, right);
  }

  void testFunctionCalls() {
    static_assert(sizeof(ds::Function<void()>) == 5 * sizeof(void*));
    static_assert(!std::is_copy_constructible_v<ds::Function<void()>> && std::is_nothrow_move_constructible_v<ds::Function<void()>>);
    static_assert(!std::is_constructible_v<ds::Function<void()>, Large> && std::is_constructible_v<ds::Function<void(), 64>, Large>);
    static_assert(!std::is_constructible_v<ds::Function<void()>, ThrowingMove>);
    static_assert(!std::is_constructible_v<ds::Function<void(int)>, Large>);

    int total = 0;
    ds::Function<void(int)> add = [&total](int value) {
      total += value;
    };

    add(2);
    add(3);
    check(total == 5 && static_cast<bool>(add));

    ds::Function<int()> counter = [count = 0]() mutable {
      return ++count;
    };

    check(counter() == 1 && counter() == 2);
    auto moved = std::move(counter);

    check(moved() == 3 && !counter);

    ds::Function<long(int, int)> multiply = [](int left, int right) {
      return left * right;
    };

    ds::Function<std::size_t(std::string, const std::string&)> lengths = [](std::string left, const std::string& right) {
      return left.size() + right.size();
    };

    ds::Function<void()> empty;

    check(multiply(6, 7) == 42 && lengths(std::string(30, 'a'), std::string(5, 'b')) == 35 && !empty);
    multiply = &larger;
    check(multiply(6, 7) == 7);
  }

  void testFunctionLifetimes() {
    Lives alive;

    {
      ds::Function<int()> read = [held = Counted{4, alive}] {
        return held.value;
      };

      check(alive.count() == 1 && read() == 4);
      auto moved = std::move(read);

      check(alive.count() == 1 && moved() == 4 && !read);
      moved = [] {
        return 9;
      };

      check(alive.count() == 0 && moved() == 9);

      read = [held = Counted{5, alive}] {
        return held.value;
      };

      check(alive.count() == 1 && read() == 5);
    }

    check(alive.count() == 0);
  }

  // Edge cases: every accessor, each branch of assignment, failures part way, and sizes past what an
  // allocation can hold.

  void testArrayAccess() {
    constexpr auto squares = [] {
      ds::Array<int, 4> values{};

      for (std::size_t index = 0; index < values.size(); ++index) {
        values.atMut(index) = static_cast<int>(index * index);
      }

      return values;
    }();

    static_assert(squares[3] == 9 && squares.size() == 4 && *squares.data() == 0 && squares.view()[2] == 4);

    ds::Array<std::string, 3> names{"a", "b", "c"};
    const auto copy = names;

    *names.dataMut() = "z";
    names.viewMut()[1] = "y";
    check(names[0] == "z" && names[1] == "y" && copy[0] == "a" && copy != names);
    check(std::distance(names.begin(), names.end()) == 3 && names.end() - names.begin() == static_cast<std::ptrdiff_t>(names.size()));
    names.fill("x");
    check(std::ranges::all_of(names, [](const std::string& name) {
      return name == "x";
    }));
  }

  void testOptionAssignment() {
    Lives alive;

    {
      ds::Option<Counted> full = Counted{1, alive};
      ds::Option<Counted> empty;
      ds::Option<Counted> target;

      target = full;
      check(target.hasValue() && target->value == 1 && alive.count() == 2);
      target = full;
      check(alive.count() == 2);
      target = empty;
      check(!target.hasValue() && alive.count() == 1);
      target = std::move(full);
      check(target.hasValue() && alive.count() == 2);
      target = std::move(empty);
      check(!target.hasValue() && alive.count() == 1);

      auto& self = target;

      target = self;
      target = std::move(self);
      check(!target.hasValue() && !target.take().hasValue());
      target.emplace(2, alive);
      target.emplace(3, alive);
      check((*target).value == 3 && alive.count() == 2 && ds::none != target);
    }

    check(alive.count() == 0);

    // A value that cannot move is built in place; a temporary it copies is not kept.
    const ds::Option<std::atomic<int>> counter{std::in_place, 7};

    check(counter->load() == 7);

    const ds::Option<std::string> named = std::string{"name"};
    const ds::Option<std::string> nothing;

    check(named.valueOr("other") == "name" && nothing.valueOr("other") == "other");

    // Empty braces empty an Option, as they do a std::optional, for a scalar too; a value of its type
    // or one that converts to it fills it.
    ds::Option<int> number = 5;
    ds::Option<std::string> text = std::string{"text"};
    ds::Option<std::string_view> view;

    number = {};
    text = {};
    check(!number.hasValue() && !text.hasValue());
    number = 7;
    text = "literal";
    view = text.get();
    check(number == 7 && text == std::string_view{"literal"} && view == std::string_view{"literal"});

    // unwrap checks in every build, as std::optional::value does.
    bool thrown = false;

    try {
      static_cast<void>(ds::Option<int>{}.unwrap());
    } catch (const std::bad_optional_access&) {
      thrown = true;
    }

    check(thrown && number.unwrap() == 7);
  }

  // Throws when it is built from a negative number, as a constructor that allocates may.
  struct Refusing {
    explicit Refusing(int value)
        : value(value) {
      if (value < 0) {
        throw std::invalid_argument{"negative"};
      }
    }

    Refusing(const Refusing& other)
        : value(other.value) {
      if (other.value == 13) {
        throw std::invalid_argument{"unlucky"};
      }
    }

    Refusing(Refusing&&) noexcept = default;
    Refusing& operator=(const Refusing&) = default;
    Refusing& operator=(Refusing&&) noexcept = default;

    int value;
  };

  void testVecEdges() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::Vec<int, decltype(memory)> values{memory};
      ds::Vec<int, decltype(memory)> other{memory};

      values.extend({});
      check(values.empty() && values.capacity() == 0);
      values.extend(std::array{1, 2, 3});
      values.reserve(64);
      values.extend(std::array{4, 5});
      check(values.size() == 5 && values.capacity() >= 64);

      values.frontMut() = 10;
      values.backMut() = 50;
      values.dataMut()[1] = 20;
      values.viewMut()[2] = 30;
      check(std::ranges::equal(values, std::array{10, 20, 30, 4, 50}) && &values.memory() == &memory);

      // Moving between Vecs of one allocator hands the storage over.
      const auto* storage = values.data();

      other = std::move(values);
      check(other.data() == storage && values.empty() && values.data() == nullptr);

      auto& self = other;

      other = std::move(self);
      check(other.size() == 5 && other != values);
      check(other.insert(other.size(), 60) == 60 && other.back() == 60);
      check(other.remove(other.size() - 1) == 60 && other.size() == 5);
      other.resize(2);
      other.resize(4);
      check(std::ranges::equal(other, std::array{10, 20, 0, 0}));
      other.truncate(10);
      check(other.size() == 4);

      bool thrown = false;

      try {
        other.reserve(std::numeric_limits<std::size_t>::max() / 2);
      } catch (const std::bad_array_new_length&) {
        thrown = true;
      }

      check(thrown && other.size() == 4);
    }

    {
      // A value that fails to construct leaves the Vec as it was, whether or not it had to grow.
      ds::Vec<Refusing, decltype(memory)> values{memory};

      values.emplace(1);
      for (const auto fill : {false, true}) {
        while (fill && values.size() < values.capacity()) {
          values.emplace(2);
        }

        const auto size = values.size();
        const auto capacity = values.capacity();
        bool thrown = false;

        try {
          values.emplace(-1);
        } catch (const std::invalid_argument&) {
          thrown = true;
        }

        check(thrown && values.size() == size && values.capacity() == capacity && values[0].value == 1);
      }

      const std::array copies{Refusing{3}, Refusing{13}};
      const auto size = values.size();
      bool thrown = false;

      try {
        values.extend(copies);
      } catch (const std::invalid_argument&) {
        thrown = true;
      }

      check(thrown && values.size() == size);
    }

    check(memory.liveBytes() == 0);
  }

  void testStringEdges() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::String<decltype(memory)> text{memory, "short"};
      ds::String<decltype(memory)> other{memory};

      text.append({});
      check(text == "short" && text.size() == 5);

      // Exactly the inline capacity, then one byte past it.
      while (text.size() < 23) {
        text.push('.');
      }

      check(text.size() == 23 && memory.liveBytes() == 0 && text.data()[23] == '\0');
      text.push('!');
      check(text.size() == 24 && memory.liveBytes() != 0 && text.data()[24] == '\0');

      other = std::move(text);
      check(other.size() == 24 && text.empty());

      auto& self = other;

      other = std::move(self);
      check(other.size() == 24 && other > std::string_view{"a"} && other < std::string_view{"z"});

      bool thrown = false;

      try {
        other.reserve(std::numeric_limits<std::size_t>::max());
      } catch (const std::bad_array_new_length&) {
        thrown = true;
      }

      check(thrown && other.size() == 24);
    }

    check(memory.liveBytes() == 0);
  }

  void testMapEdges() {
    SystemAllocator system;
    BudgetAllocator memory{system, 1 << 20};

    {
      ds::Map<std::uint64_t, int, decltype(memory)> values{memory};
      ds::Map<std::uint64_t, int, decltype(memory)> other{memory};

      check(values.clone().empty() && values.begin() == values.end() && values.find(1) == nullptr && !values.remove(1).hasValue());
      check(values.insert(1, 10) && !values.insert(1, 11) && *values.find(1) == 10);
      check(!values.assign(1, 12) && *values.find(1) == 12 && values.assign(2, 20));

      const auto capacity = values.capacity();

      values.reserve(1);
      check(values.capacity() == capacity);

      other = std::move(values);
      check(other.size() == 2 && values.empty() && !values.contains(1));

      auto& self = other;

      other = std::move(self);
      check(other.size() == 2 && *other.find(2) == 20);

      bool thrown = false;

      try {
        other.reserve(std::numeric_limits<std::size_t>::max());
      } catch (const std::bad_array_new_length&) {
        thrown = true;
      }

      check(thrown && other.size() == 2);
    }

    check(memory.liveBytes() == 0);
  }

  void testFunctionEdges() {
    Lives alive;

    {
      ds::Function<int(int)> empty;
      ds::Function<int(int)> twice = [](int value) {
        return value * 2;
      };
      ds::Function<int(int)> counted = [kept = Counted{5, alive}](int value) {
        return value + kept.value;
      };

      check(!empty && twice && twice(4) == 8 && counted(1) == 6 && alive.count() == 1);

      auto& self = counted;

      counted = std::move(self);
      check(counted && counted(1) == 6 && alive.count() == 1);
      counted = std::move(twice);
      check(counted(4) == 8 && !twice && alive.count() == 0);
      empty = std::move(counted);
      check(empty(5) == 10 && !counted);
    }

    check(alive.count() == 0);
  }

  const telar::testing::Case case_array{"ds.array", testArray};
  const telar::testing::Case case_option{"ds.option", testOption};
  const telar::testing::Case case_vec_growth{"ds.vec_growth", testVecGrowth};
  const telar::testing::Case case_vec_values{"ds.vec_values", testVecValues};
  const telar::testing::Case case_vec_moves{"ds.vec_moves", testVecMoves};
  const telar::testing::Case case_vec_exhaustion{"ds.vec_exhaustion", testVecExhaustion};
  const telar::testing::Case case_string_inline{"ds.string_inline", testStringInline};
  const telar::testing::Case case_string_growth{"ds.string_growth", testStringGrowth};
  const telar::testing::Case case_string_moves{"ds.string_moves", testStringMoves};
  const telar::testing::Case case_string_exhaustion{"ds.string_exhaustion", testStringExhaustion};
  const telar::testing::Case case_map_integers{"ds.map_integers", testMapIntegers};
  const telar::testing::Case case_map_values{"ds.map_values", testMapValues};
  const telar::testing::Case case_map_text{"ds.map_text", testMapText};
  const telar::testing::Case case_map_exhaustion{"ds.map_exhaustion", testMapExhaustion};
  const telar::testing::Case case_function_calls{"ds.function_calls", testFunctionCalls};
  const telar::testing::Case case_function_lifetimes{"ds.function_lifetimes", testFunctionLifetimes};
  const telar::testing::Case case_array_access{"ds.array_access", testArrayAccess};
  const telar::testing::Case case_option_assignment{"ds.option_assignment", testOptionAssignment};
  const telar::testing::Case case_vec_edges{"ds.vec_edges", testVecEdges};
  const telar::testing::Case case_string_edges{"ds.string_edges", testStringEdges};
  const telar::testing::Case case_map_edges{"ds.map_edges", testMapEdges};
  const telar::testing::Case case_function_edges{"ds.function_edges", testFunctionEdges};

}
