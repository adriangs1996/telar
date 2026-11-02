#pragma once

#include "../memory/allocator.hpp"
#include "api.hpp"
#include <array>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::lua {

class Error : public std::exception {
public:
  explicit Error(std::string_view message) noexcept {
    const auto size = std::min(message.size(), message_.size() - 1);
    if (size != 0) {
      std::memcpy(message_.data(), message.data(), size);
    }
    message_[size] = '\0';
  }

  const char *what() const noexcept override {
    return message_.data();
  }

private:
  std::array<char, 1024> message_;
};

struct Limits {
  std::size_t memory = 16 * 1024 * 1024;
  std::uint64_t instructions = 1'000'000;
  std::chrono::nanoseconds deadline = std::chrono::seconds{2};
};

template <Allocator Memory>
class Vm {
public:
  explicit Vm(Memory &memory, Limits limits = {})
      : memory_(memory),
        limits_(limits),
        deadline_(Clock::now() + limits.deadline) {
    state_ = lua_newstate(&allocate, this, 0);
    if (state_ == nullptr) {
      throw std::bad_alloc{};
    }

    lua_atpanic(state_, &panic);
    lua_sethook(state_, &instructionHook, LUA_MASKCOUNT, instruction_interval);
    try {
      invoke(&openSandbox, nullptr, 0);
    } catch (...) {
      lua_close(state_);
      throw;
    }
  }

  ~Vm() {
    lua_close(state_);
  }

  Vm(const Vm &) = delete;
  Vm &operator=(const Vm &) = delete;

  void resetBudget() noexcept {
    instructions_ = 0;
    deadline_ = Clock::now() + limits_.deadline;
  }

  void resetBudget(std::uint64_t instructions, std::chrono::nanoseconds deadline) noexcept {
    limits_.instructions = instructions;
    limits_.deadline = deadline;
    resetBudget();
  }

  void execute(std::string_view source, const char *name, int results = 1) {
    check(luaL_loadbufferx(state_, source.data(), source.size(), name, "t"));
    check(lua_pcall(state_, 0, results, 0));
  }

  void invoke(lua_CFunction function, void *context, int results) {
    lua_pushcfunction(state_, function);
    lua_pushlightuserdata(state_, context);
    check(lua_pcall(state_, 1, results, 0));
  }

  lua_State *state() const noexcept {
    return state_;
  }

  std::size_t usedBytes() const noexcept {
    return used_bytes_;
  }

private:
  using Clock = std::chrono::steady_clock;
  static constexpr int instruction_interval = 1000;

  struct alignas(std::max_align_t) Allocation {
    std::size_t capacity;
  };

  static Vm &owner(lua_State *state) noexcept {
    void *context = nullptr;
    lua_getallocf(state, &context);
    return *static_cast<Vm *>(context);
  }

  static void *allocate(void *context, void *pointer, std::size_t old_size, std::size_t new_size) noexcept {
    auto &vm = *static_cast<Vm *>(context);
    const auto previous = pointer == nullptr ? 0 : old_size;
    const auto retained = vm.used_bytes_ - previous;
    if (new_size == 0) {
      vm.release(pointer);
      vm.used_bytes_ = retained;
      return nullptr;
    }
    if (new_size > vm.limits_.memory - retained || new_size > std::numeric_limits<std::size_t>::max() - sizeof(Allocation)) {
      return nullptr;
    }

    if (pointer != nullptr && new_size <= previous) {
      vm.used_bytes_ = retained + new_size;
      return pointer;
    }

    auto *allocation = static_cast<Allocation *>(vm.memory_.allocate(sizeof(Allocation) + new_size, alignof(Allocation)));
    if (allocation == nullptr) {
      return nullptr;
    }

    allocation->capacity = new_size;
    if (pointer != nullptr) {
      std::memcpy(allocation + 1, pointer, previous);
      vm.release(pointer);
    }

    vm.used_bytes_ = retained + new_size;
    return allocation + 1;
  }

  void release(void *pointer) noexcept {
    if (pointer != nullptr) {
      auto *allocation = static_cast<Allocation *>(pointer) - 1;
      memory_.deallocate(allocation, sizeof(Allocation) + allocation->capacity, alignof(Allocation));
    }
  }

  static void instructionHook(lua_State *state, lua_Debug *) {
    auto &vm = owner(state);
    vm.instructions_ += instruction_interval;
    if (vm.instructions_ > vm.limits_.instructions || Clock::now() > vm.deadline_) {
      luaL_error(state, "Telar Lua execution budget exceeded");
    }
  }

  static int panic(lua_State *state) {
    std::size_t size = 0;
    const auto *message = lua_tolstring(state, -1, &size);
    throw Error{message == nullptr ? std::string_view{"Unprotected Lua failure"} : std::string_view{message, size}};
  }

  void check(int status) {
    if (status == LUA_OK) {
      return;
    }
    if (status == LUA_ERRMEM) {
      throw std::bad_alloc{};
    }

    panic(state_);
  }

  static int openSandbox(lua_State *state) {
    constexpr std::array libraries{
        luaL_Reg{"_G", luaopen_base},
        luaL_Reg{LUA_COLIBNAME, luaopen_coroutine},
        luaL_Reg{LUA_MATHLIBNAME, luaopen_math},
        luaL_Reg{LUA_STRLIBNAME, luaopen_string},
        luaL_Reg{LUA_TABLIBNAME, luaopen_table},
        luaL_Reg{LUA_UTF8LIBNAME, luaopen_utf8},
    };
    for (const auto &library : libraries) {
      luaL_requiref(state, library.name, library.func, 1);
      lua_pop(state, 1);
    }

    for (const auto *name : {"collectgarbage", "dofile", "getmetatable", "load", "loadfile", "print", "rawset", "setmetatable"}) {
      lua_pushnil(state);
      lua_setglobal(state, name);
    }

    return 0;
  }

  Memory &memory_;
  Limits limits_;
  Clock::time_point deadline_;
  std::uint64_t instructions_ = 0;
  std::size_t used_bytes_ = 0;
  lua_State *state_ = nullptr;
};

template <Allocator Memory>
Vm(Memory &memory, Limits limits = {}) -> Vm<Memory>;

}
