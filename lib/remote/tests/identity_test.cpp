#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.ds;
import telar.remote.identity;
import telar.remote.tests.fixture;
import telar.testing;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::remote;

  constexpr std::string_view key_hex = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
  constexpr std::string_view secret_hex = "0123456789abcdef0123456789abcdef";

  bool rejectsEndpoint(std::string_view text) {
    try {
      static_cast<void>(Endpoint::parse(text));
    } catch (const std::invalid_argument&) {
      return true;
    }

    return false;
  }

  void endpointsRoundTrip() {
    ds::Array<char, 160> text{};
    const auto pairing = std::format_to_n(text.dataMut(), text.size(), "telar://box.example:9000#{}.{}", key_hex, secret_hex);
    const std::string_view address{text.data(), static_cast<std::size_t>(pairing.size)};
    const auto endpoint = Endpoint::parse(address);

    check(endpoint.host.view() == "box.example" && endpoint.port == 9000 && endpoint.secret.hasValue());
    check(endpoint.format().view() == address, "a pairing address formats as it was read");
    check(endpoint.destination().view() == address.substr(0, address.rfind('.')), "a saved address never keeps the secret");

    const auto saved = Endpoint::parse(endpoint.destination().view());

    check(saved.key == endpoint.key && !saved.secret.hasValue());
  }

  void endpointsReadAddressesOfEveryFamily() {
    ds::Array<char, 160> text{};
    const auto written = std::format_to_n(text.dataMut(), text.size(), "telar://[fd00::1]:7#{}", key_hex);
    const auto endpoint = Endpoint::parse({text.data(), static_cast<std::size_t>(written.size)});

    check(endpoint.host.view() == "fd00::1" && endpoint.port == 7);
    check(endpoint.destination().view() == std::string_view{text.data(), static_cast<std::size_t>(written.size)});

    const auto defaulted = std::format_to_n(text.dataMut(), text.size(), "telar://10.0.0.2#{}", key_hex);

    check(Endpoint::parse({text.data(), static_cast<std::size_t>(defaulted.size)}).port == default_port);
  }

  void endpointsRefuseWhatIsNoAddress() {
    check(rejectsEndpoint("ssh://box#00"));
    check(rejectsEndpoint("telar://box:9000"), "an address without a key pins nothing");
    check(rejectsEndpoint("telar://box:9000#abcd"));
    check(rejectsEndpoint("telar://box:0#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    check(rejectsEndpoint("telar://bo x:1#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"));
    check(rejectsEndpoint("telar://box:1#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.12"));
  }

  void identitiesAreMadeOnceAndReadBack() {
    const remote::tests::Gateway gateway;
    const auto first = Identity::loadOrCreate(gateway.state.directory());
    const auto second = Identity::loadOrCreate(gateway.state.directory());

    check(first.key == second.key, "a state directory keeps one identity");
    check(first.key != PublicKey{});
  }

  void clientsAreAdmittedRenamedAndRevoked() {
    const remote::tests::Gateway gateway;
    PublicKey laptop{};
    PublicKey desktop{};

    laptop.atMut(0) = 1;
    desktop.atMut(0) = 2;
    auto clients = AuthorizedClients::load(gateway.state.directory());

    check(clients.rows().empty() && !clients.admits(laptop));
    clients.admit(laptop, "ada laptop");
    clients.admit(desktop, "desk");
    clients.admit(laptop, "ada-air");
    clients.save(gateway.state.directory());

    auto loaded = AuthorizedClients::load(gateway.state.directory());

    check(loaded.rows().size() == 2 && loaded.admits(laptop) && loaded.admits(desktop));
    check(loaded.rows()[0].name.view() == "ada-air", "a client that pairs again keeps its row under its new name");
    check(loaded.revoke("desk") == 1 && !loaded.admits(desktop));

    const auto text = keyText(laptop);

    check(loaded.revoke({text.data(), text.size()}) == 1 && loaded.rows().empty());
  }

  void pairingCodesAdmitOnce() {
    const remote::tests::Gateway gateway;
    const auto secret = PairingCodes::mint(gateway.state.directory());
    Secret wrong = secret;

    wrong.atMut(0) ^= 1U;
    check(!PairingCodes::redeem(gateway.state.directory(), wrong));
    check(PairingCodes::redeem(gateway.state.directory(), secret));
    check(!PairingCodes::redeem(gateway.state.directory(), secret), "a code enrolls one client");
  }

  void statesRememberTheirPort() {
    const remote::tests::Gateway gateway;

    check(!gateway.state.port().hasValue());
    gateway.state.recordPort(9123);
    check(gateway.state.port() == std::uint16_t{9123});
  }

  const telar::testing::Case case_endpoints_round_trip{"identity.endpoints_round_trip", endpointsRoundTrip};
  const telar::testing::Case case_endpoints_read_addresses_of_every_family{"identity.endpoints_read_addresses_of_every_family", endpointsReadAddressesOfEveryFamily};
  const telar::testing::Case case_endpoints_refuse_what_is_no_address{"identity.endpoints_refuse_what_is_no_address", endpointsRefuseWhatIsNoAddress};
  const telar::testing::Case case_identities_are_made_once_and_read_back{"identity.identities_are_made_once_and_read_back", identitiesAreMadeOnceAndReadBack};
  const telar::testing::Case case_clients_are_admitted_renamed_and_revoked{"identity.clients_are_admitted_renamed_and_revoked", clientsAreAdmittedRenamedAndRevoked};
  const telar::testing::Case case_pairing_codes_admit_once{"identity.pairing_codes_admit_once", pairingCodesAdmitOnce};
  const telar::testing::Case case_states_remember_their_port{"identity.states_remember_their_port", statesRememberTheirPort};

}
