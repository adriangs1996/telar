module;
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.plugins.run_worker;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.vocabulary.traffic;
import telar.lua;

import telar.runtime.http.message;

import telar.runtime.plugins.worker;

import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.memory.sensitive;

import telar.wire.vocabulary;
import telar.base.text;
import telar.runtime.traffic.control_protocol;
import telar.runtime.vocabulary.exchange;
import telar.base.ds;

// Interface: plugins/lua_effects.cppm
export {
  namespace telar::runtime::plugins {

    class LuaEffects {
    public:
      explicit LuaEffects(lua_State* state) noexcept;

      ~LuaEffects();

      LuaEffects(const LuaEffects&) = delete;
      LuaEffects& operator=(const LuaEffects&) = delete;

      EffectBatch read(int index);

    private:
      std::string_view string(int table, const char* field, bool required);

      lua_Integer integer(int table, const char* field, lua_Integer fallback);

      static NotificationLevel notificationLevel(std::string_view level);

      static constexpr std::size_t fields_per_effect = 6;
      static constexpr std::uint32_t default_duration_ms = 4000;
      lua_State* state_;
      int restored_top_;
    };

  }
}

// Interface: plugins/lua_exchange.cppm
export {
  namespace telar::runtime::plugins {

    class LuaExchange {
    public:
      static void push(lua_State* state, const ExchangeView& exchange, bool traffic = false);

    private:
      static void setIdentity(lua_State* state, const char* name, std::uint64_t value);

      static std::string_view protocolName(ExchangeProtocol protocol) noexcept;

      static std::string_view outcomeName(CaptureOutcome outcome) noexcept;

      static void pushHalf(lua_State* state, const ds::Option<HalfView>& half, bool traffic);

      static void pushHead(lua_State* state, std::span<const std::uint8_t> bytes, bool traffic);
    };

  }
}

// Interface: plugins/lua_traffic_value.cppm
export {
  namespace telar::runtime::plugins {

    class LuaTrafficValue {
    public:
      static void push(lua_State* state, const traffic::Event& event, std::uint64_t dropped);

      static traffic::Selection selection(const lua::Value& events, traffic::Selection fallback);

      // The message views strings of the Lua state, region `a`, which the caller's tables keep alive.
      static tbc::view<HttpMessageView, tbc::lt::a> message(const lua::Value& value);

    private:
      static std::size_t fields(const lua::Value& value, tbc::view<std::span<HttpMessageView::Field>, tbc::lt::a> fields);

      static void pushFields(lua_State* state, std::span<const HttpMessageView::Field> fields);

      static void pushMessage(lua_State* state, const HttpMessageView& message);
    };

  }
}

// Interface: plugins/lua_traffic_control.cppm
export {
  namespace telar::runtime::plugins {

    class LuaTrafficControl {
    public:
      static traffic::control::Request request(const lua::Value& options);

      static void push(lua_State* state, const traffic::control::Reply& reply);

    private:
      static std::uint64_t identity(const lua::Value& value);

      static void metadata(lua_State* state, const traffic::recording::Page& page);

      static void recordings(lua_State* state, const traffic::recording::Page& page);
    };

  }
}

// Interface: plugins/lua_traffic.cppm
export {
  namespace telar::runtime::plugins {

    template <Allocator Memory>
    class LuaTraffic {
      struct Binding {
        TrafficRegistration registration;
        int callback = LUA_NOREF;
      };

      struct QueuedDecision {
        std::uint32_t registration;
        std::size_t offset;
        std::size_t bytes;
      };
      enum class Operation {
        subscribe,
        intercept,
        decide,
        cancel,
        control,
      };

    public:
      explicit LuaTraffic(Memory& memory, ServiceSpec specification);

      void install(lua_State* state);

      bool listening() const noexcept;

      void begin() noexcept;

      void invoke(lua_State* state, const TrafficEvent& event);

      tbc::view<std::span<const Byte>, tbc::lt::a> finish(std::uint64_t event_id, tbc::view<std::span<Byte>, tbc::lt::a> output);

    private:
      static int call(lua_State* state);

      static std::uint32_t identifier(lua_State* state, int index);

      Binding* find(std::uint32_t id) noexcept;

      // Not inlined, as registerCallback and decide: call() runs one of them per Lua call, and inlined,
      // every call would carry the largest of their frames.
      [[gnu::noinline]] std::uint32_t registerControl(lua_State* state);

      [[gnu::noinline]] std::uint32_t registerCallback(lua_State* state, bool intercept);

      // Binds the function at stack index 2 to `registration` in a free slot, under a new id.
      std::uint32_t bind(lua_State* state, TrafficRegistration registration);

      void unbind(lua_State* state, Binding& binding) noexcept;

      static void subscription(const lua::Value& options, TrafficRegistration& registration);

      static void interception(const lua::Value& options, TrafficRegistration& registration);

      [[gnu::noinline]] bool decide(lua_State* state);

      ServiceSpec specification_;
      ds::Array<Binding, TrafficLimits::registrations> bindings_;
      std::uint32_t next_identifier_ = 0;
      bool changed_ = true;
      SensitiveAllocation<Memory> scratch_;
      ByteQueue<Memory> decisions_;
      SensitiveAllocation<Memory> effects_;
      std::size_t effect_bytes_ = 0;
      ds::Array<QueuedDecision, TrafficLimits::decisions> queued_;
      std::size_t decision_count_ = 0;
      ds::Box<TrafficReply, Memory> reply_;
    };

  }
}

// Interface: plugins/host.cppm
export {
  namespace telar::runtime::plugins {

    class Host {
    public:
      explicit Host(Memory& memory, const char* entry_path, const ServiceSpec* traffic = nullptr);

      Host(const Host&) = delete;
      Host& operator=(const Host&) = delete;

      tbc::view<std::span<const Byte>, tbc::lt::a> trafficSetup(tbc::view<std::span<Byte>, tbc::lt::a> output);

      tbc::view<std::span<const Byte>, tbc::lt::a> invokeTraffic(const TrafficEvent& event, tbc::view<std::span<Byte>, tbc::lt::a> output);

      tbc::view<std::span<const Byte>, tbc::lt::a> invoke(const ExchangeView& exchange, tbc::view<std::span<Byte>, tbc::lt::a> output);

    private:
      struct Entrypoint {
        Host& host;
        std::string_view source;
      };

      struct TrafficInvocation {
        Host& host;
        const TrafficEvent& event;
      };

      // What a protected call was handed, which outlives the call; Lua only carries its address.
      static tbc::view<void*, tbc::lt::static_storage> callContext(lua_State* state) noexcept;

      static int invokeTrafficCallback(lua_State* state);

      struct Invocation {
        Host& host;
        const ExchangeView& exchange;
        std::span<Byte> output;
        std::size_t encoded_bytes = 0;
        bool encoding_failed = false;
      };

      static tbc::view<Host&, tbc::lt::static_storage> context(lua_State* state) noexcept;

      static std::string_view errorMessage(lua_State* state);

      static int install(lua_State* state);

      static int loadEntrypoint(lua_State* state);

      static int invokeCallback(lua_State* state);

      static int redactSecrets(lua_State* state);

      using SensitiveMemory = RecyclingAllocator<Memory>;
      SensitiveMemory memory_;
      // The machine compiles once, for any Memory: it reaches the recycling allocator through the adapter.
      MemoryAdapter<SensitiveMemory> erased_{memory_};
      lua::Vm<ErasingMemory> vm_;
      FixedText<PATH_MAX> package_root_;
      ds::Option<lua::LocalModules<lua::ModuleDomain::package>> modules_;
      int callback_reference_ = LUA_NOREF;
      ds::Option<LuaTraffic<SensitiveMemory>> traffic_;
    };

  }
}

// Interface: plugins/run_worker.cppm
export {
  namespace telar::runtime::plugins {

    void runWorker(Memory& memory, const char* entry_path, bool traffic = false);

  }
}
