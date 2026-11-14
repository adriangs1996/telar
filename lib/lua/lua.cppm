module;
#include "tbc/hot_path.hpp"
#include "tbc/view.hpp"
#include <cstddef>

#include <lauxlib.h>
#include <lua.h>

#include <limits.h>

export module telar.lua;

import std;

export import telar.base.text;
export import telar.base.text.json;
export import telar.base.text.utf8;
import telar.base.memory.allocators;
import telar.base.memory.containers;

// Interface: telar_lua/vm.cppm
export {
  namespace telar::runtime::lua {

    class Error : public std::exception {
    public:
      explicit Error(std::string_view message) noexcept;

      const char* what() const noexcept override;

    private:
      std::array<char, 1024> message_;
    };

    struct Limits {
      std::size_t memory = std::size_t{256} * 1024 * 1024;
      std::uint64_t instructions = 50'000'000;
      std::chrono::nanoseconds deadline = std::chrono::seconds{2};
    };

    // The state is the C library's, reached by a pointer that never changes while the machine lives:
    // every call mutates it through that pointer, as Rust's Lua handle does through `&self`, so what a
    // value reads of it stays valid. The machine can be neither copied nor moved.
    template <Allocator Memory>
    class TBC_SHARED Vm {
    public:
      explicit Vm(Memory& memory, Limits limits = {});
      ~Vm();

      Vm(const Vm&) = delete;
      Vm& operator=(const Vm&) = delete;

      void resetBudget() noexcept;
      void resetBudget(std::uint64_t instructions, std::chrono::nanoseconds deadline) noexcept;
      void execute(std::string_view source, const char* name, int results = 1);
      void invoke(lua_CFunction function, void* context, int results);
      lua_State* state() const noexcept;
      std::size_t usedBytes() const noexcept;

    private:
      using Clock = std::chrono::steady_clock;
      static constexpr int instruction_interval = 1000;

      struct alignas(std::max_align_t) Allocation {
        std::size_t capacity;
      };

      static Vm& owner(lua_State* state) noexcept;
      static void* allocate(void* context, void* pointer, std::size_t old_size, std::size_t new_size) noexcept;
      void release(void* pointer) noexcept;
      static void instructionHook(lua_State* state, lua_Debug*);
      void check(int status);

      Memory& memory_;
      Limits limits_;
      Clock::time_point deadline_;
      std::uint64_t instructions_ = 0;
      std::size_t used_bytes_ = 0;
      lua_State* state_ = nullptr;
    };

    template <Allocator Memory>
    Vm(Memory& memory, Limits limits = {}) -> Vm<Memory>;

    extern template class Vm<Memory>;
    extern template class Vm<ConcurrentMemory>;
    extern template class Vm<ErasingMemory>;

  }
}

// Interface: telar_lua/json.cppm
export {
  namespace telar::runtime::lua {

    template <Allocator Memory>
    class JsonDecoder {
    public:
      static void install(lua_State* state, Memory& memory);

    private:
      explicit JsonDecoder(Memory& memory);

      static int decode(lua_State* state);
      void push(lua_State* state, const JsonValue& value, unsigned depth);
      void object(lua_State* state, const JsonValue& value, unsigned depth);

      static constexpr std::size_t maximum_input_bytes = 1024 * 1024;
      static constexpr unsigned maximum_depth = 64;
      String<Memory> text_;
    };

    extern template class JsonDecoder<Memory>;
    extern template class JsonDecoder<ConcurrentMemory>;
    extern template class JsonDecoder<ErasingMemory>;

  }
}

// Interface: telar_lua/local_modules.cppm
export {
  namespace telar::runtime::lua {

    enum class ModuleDomain {
      configuration,
      package,
    };

    template <ModuleDomain domain>
    class LocalModules {
    public:
      explicit LocalModules(lua_State* state, std::string_view directory);

      LocalModules(const LocalModules&) = delete;
      LocalModules& operator=(const LocalModules&) = delete;

      [[nodiscard]] std::size_t configurationModuleCount() const noexcept
        requires(domain == ModuleDomain::configuration);

      // Generic over the caller's visitor, so it stays here and hands the walk to visitNames.
      template <typename Visitor>
      TBC_HOT_PATH void visitLoadedNames(lua_State* state, Visitor&& visit) const {
        using Target = std::remove_reference_t<Visitor>;

        visitNames(state, std::addressof(visit), [](void* target, std::string_view name) {
          (*static_cast<Target*>(target))(name);
        });
      }

    private:
      void visitNames(lua_State* state, void* target, void (*visit)(void*, std::string_view)) const;
      static int raise(lua_State* state, const char* configuration, const char* package);
      static int require(lua_State* state);

      static constexpr int module_limit = 1024;
      FixedText<PATH_MAX> directory_;
      int cache_ = LUA_NOREF;
      int loaded_ = 0;
    };

    extern template class LocalModules<ModuleDomain::configuration>;
    extern template class LocalModules<ModuleDomain::package>;

  }
}

// Interface: telar_lua/writer.cppm
export {
  namespace telar::runtime::lua {

    // Sets field `name` of the table on top of the stack. The overloads take exactly a text, a bool or
    // a Lua integer, so another integer type is ambiguous and must say how it converts.
    void setField(lua_State* state, const char* name, std::string_view value);
    void setField(lua_State* state, const char* name, bool value);
    void setField(lua_State* state, const char* name, lua_Integer value);

    // A 64-bit identity as decimal text: past 2^63 a Lua integer would turn it negative.
    void setDecimal(lua_State* state, const char* name, std::uint64_t value);

    // Replaces the table on top of the stack with a read-only view of it: reads reach the table,
    // writes raise `message`, and the view's metatable stays hidden.
    void pushReadOnly(lua_State* state, const char* message);

  }
}

// Interface: telar_lua/value.cppm
export {
  namespace telar::runtime::lua {

    class Value {
    public:
      // A value views a slot of the state; its label is its own copy.
      explicit Value(tbc::view<lua_State*, tbc::lt::a> state, int index, std::string_view label);
      ~Value();

      Value(const Value&) = delete;
      Value& operator=(const Value&) = delete;

      // The same value under another name: a profile's tables are reported as
      // the configuration's, as diagnostics name them.
      // Another value of the same state, in region `a`; it does not view this one.
      tbc::view<Value, tbc::lt::a> as(std::string_view label) const;
      tbc::view<Value, tbc::lt::a> field(const char* name) const;
      tbc::view<Value, tbc::lt::a> element(lua_Integer position) const;
      tbc::view<Value, tbc::lt::a> entry(std::string_view key) const;
      bool present() const noexcept;
      bool is(int type) const noexcept;
      void pushCopy() const;

      // The state's string, which outlives this slot while the table that holds it does.
      tbc::view<std::string_view, tbc::lt::a> string() const;

      bool boolean(bool fallback) const;
      lua_Integer integer() const;
      std::optional<lua_Integer> asInteger() const noexcept;
      std::uint64_t boundedInteger(std::uint64_t fallback, std::uint64_t minimum, std::uint64_t maximum) const;
      double boundedNumber(double fallback, double minimum, double maximum) const;
      void onlyFields(std::initializer_list<std::string_view> allowed, bool allow_children = false) const;
      void onlyFields(std::span<const std::string_view> allowed, bool allow_children = false) const;
      std::size_t arraySize() const;
      std::size_t listLength() const;

      // Generic over the caller's consumer, so it stays here and hands the walk to visitFields.
      template <typename Consumer>
      TBC_HOT_PATH void eachField(Consumer&& consume) const {
        using Target = std::remove_reference_t<Consumer>;

        visitFields(std::addressof(consume), [](void* target, std::string_view name, const Value& value) {
          (*static_cast<Target*>(target))(name, value);
        });
      }

      [[noreturn]] void fail(const char* message) const;

    private:
      Value(const Value& parent, std::string_view key);

      // A field names its whole path in diagnostics: config.client.sidebar.visible.
      Value(const Value& parent, const char* name);

      Value(const Value& parent, lua_Integer position);

      void visitFields(void* target, void (*consume)(void*, std::string_view, const Value&)) const;
      void require(int type, const char* message) const;

      tbc::view<lua_State*, tbc::lt::a> state_;
      int index_;
      int restored_top_;
      std::string label_;
    };

  }
}
