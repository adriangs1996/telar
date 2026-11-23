export module telar.remote.identity;

// Who a gateway is and whom it lets in: the key each account's gateway holds, the address that
// pins a gateway to its key, the clients a gateway admits and the codes that enroll a new one.
import std;

import telar.base.ds;
import telar.base.memory.containers;
import telar.platform.paths;
import telar.platform.primitives;
import telar.sys.posix;
import telar.tls;

// Interface: telar_remote/keys.cppm
export {
  namespace telar::remote {

    inline constexpr std::size_t key_bytes = runtime::public_key_digest_bytes;
    inline constexpr std::size_t secret_bytes = 16;

    // The port a gateway listens on unless told another.
    inline constexpr std::uint16_t default_port = 8352;

    // The SHA-256 of a public key: how each end names the other.
    using PublicKey = ds::Array<std::uint8_t, key_bytes>;
    using KeyText = ds::Array<char, key_bytes * 2>;

    // What a pairing address carries once, so that its bearer becomes an admitted client.
    using Secret = ds::Array<std::uint8_t, secret_bytes>;
    using SecretText = ds::Array<char, secret_bytes * 2>;

    KeyText keyText(const PublicKey& key) noexcept;
    SecretText secretText(const Secret& secret) noexcept;

    // The bytes `text` spells in hexadecimal, of either case; false unless it spells exactly
    // `bytes.size()` of them.
    bool parseHex(std::string_view text, std::span<std::uint8_t> bytes) noexcept;

    // Whether two digests are equal, in a time that does not depend on where they differ.
    bool sameBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept;

  }
}

// Interface: telar_remote/endpoint.cppm
export {
  namespace telar::remote {

    // A gateway's address and the key it must hold, `telar://HOST:PORT#KEY`. A pairing address
    // adds `.SECRET`, which a saved one never keeps.
    struct Endpoint {
      static constexpr std::string_view scheme = "telar://";
      static constexpr std::size_t host_bytes = 253;
      static constexpr std::size_t port_digits = 5;
      static constexpr std::size_t text_bytes = scheme.size() + host_bytes + port_digits + (key_bytes * 2) + (secret_bytes * 2) + 5;

      using Text = runtime::FixedText<text_bytes>;

      runtime::FixedText<host_bytes> host;
      std::uint16_t port = default_port;
      PublicKey key{};
      ds::Option<Secret> secret;

      // Throws std::invalid_argument for a text that is no gateway address.
      [[nodiscard]] static Endpoint parse(std::string_view text);

      // The address with its secret, when it carries one.
      [[nodiscard]] Text format() const;

      // The address a profile saves: the secret left out.
      [[nodiscard]] Text destination() const;

    private:
      [[nodiscard]] Text write(bool with_secret) const;
    };

  }
}

// Interface: telar_remote/state.cppm
export {
  namespace telar::remote {

    // The private directory that keeps an account's gateway files: TELAR_GATEWAY_STATE, else
    // `telar/gateway` under XDG_STATE_HOME or ~/.local/state.
    class State {
    public:
      // Opens the directory, creating it for its owner alone.
      [[nodiscard]] static State open(const runtime::EnvironmentSource& environment);

      [[nodiscard]] int directory() const noexcept;
      [[nodiscard]] std::string_view path() const noexcept;

      // The port the gateway of this account last listened on; none before it ever did.
      [[nodiscard]] ds::Option<std::uint16_t> port() const;
      void recordPort(std::uint16_t port) const;

    private:
      runtime::FileDescriptor directory_;
      runtime::FixedText<PATH_MAX> path_;
    };

  }
}

// Interface: telar_remote/identity.cppm
export {
  namespace telar::remote {

    // The key this account presents to a gateway, and the one its own gateway presents.
    struct Identity {
      runtime::CertificatePair pair;
      PublicKey key{};

      // The identity `directory` keeps, made the first time. OpenSSL must be configured.
      [[nodiscard]] static Identity loadOrCreate(int directory);
    };

  }
}

// Interface: telar_remote/authorized_clients.cppm
export {
  namespace telar::remote {

    // The clients a gateway admits, one line each in `authorized_clients`: the key and the name
    // the client gave when it paired.
    class AuthorizedClients {
    public:
      static constexpr std::size_t maximum = 64;
      static constexpr std::size_t name_bytes = 64;

      struct Client {
        PublicKey key{};
        runtime::FixedText<name_bytes> name;
      };

      [[nodiscard]] static AuthorizedClients load(int directory);

      [[nodiscard]] bool admits(const PublicKey& key) const noexcept;
      [[nodiscard]] std::span<const Client> rows() const noexcept;

      // Adds a client under a name made of what a line may hold; a key already there keeps its
      // row and takes the name. Throws std::length_error when the list is full.
      void admit(const PublicKey& key, std::string_view name);

      // Removes the clients a key in hexadecimal or a name selects, and says how many.
      std::size_t revoke(std::string_view selector) noexcept;

      void save(int directory) const;

    private:
      ds::Array<Client, maximum> rows_;
      std::size_t count_ = 0;
    };

    // Serializes the processes that rewrite a state directory's files; released when it goes.
    class StateLock {
    public:
      explicit StateLock(int directory);

    private:
      runtime::FileDescriptor file_;
    };

  }
}

// Interface: telar_remote/pairing.cppm
export {
  namespace telar::remote {

    // The codes that enroll a client, kept in `pairing` as the SHA-256 of each secret and when
    // it expires. A code admits one client, once.
    struct PairingCodes {
      static constexpr std::size_t maximum = 8;
      static constexpr auto lifetime = std::chrono::minutes{10};

      // A new code, after dropping the expired ones. Throws std::length_error when `maximum`
      // are still pending.
      [[nodiscard]] static Secret mint(int directory);

      // Whether `secret` is a pending code, which it then no longer is.
      [[nodiscard]] static bool redeem(int directory, const Secret& secret);
    };

  }
}
