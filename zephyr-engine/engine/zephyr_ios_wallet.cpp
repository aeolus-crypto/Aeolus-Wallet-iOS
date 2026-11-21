// Wallet operations of the C interface (see zephyr_ios.h). Results are shaped like the Android
// plugin's (com.aeolus.wallet.ZephyrWalletPlugin), so the web page sees the same JSON on both.
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <limits>
#include <map>
#include <vector>

#include "zephyr_ios_internal.h"
#include "utils/monero_utils.h"

#include "rapidjson/document.h"
#include "rapidjson/stringbuffer.h"
#include "rapidjson/writer.h"

using namespace monero;
using zios::guarded;

namespace {

const char* const V2_ASSETS[] = {"ZPH", "ZSD", "ZRS", "ZYS"};

using Writer = rapidjson::Writer<rapidjson::StringBuffer>;

void key(Writer& w, const char* k) { w.Key(k); }
void str(Writer& w, const std::string& s) { w.String(s.c_str(), static_cast<rapidjson::SizeType>(s.size())); }
void kv(Writer& w, const char* k, const std::string& v) { key(w, k); str(w, v); }

char* finish(rapidjson::StringBuffer& sb) { return zios::dup(std::string(sb.GetString(), sb.GetSize())); }

monero_wallet_full* need(zios_wallet* w) {
  if (!w || !w->w) throw std::runtime_error("No wallet");
  return w->w;
}

// A double as a plain decimal string (no exponent), like Java's BigDecimal.toPlainString of the
// shortest round-trip representation.
std::string plain_decimal(double d) {
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.17g", d);
  // shortest representation that reads back as the same double
  for (int prec = 1; prec <= 17; prec++) {
    char t[64];
    std::snprintf(t, sizeof t, "%.*g", prec, d);
    if (std::strtod(t, nullptr) == d) { std::strcpy(buf, t); break; }
  }
  std::string s(buf);
  size_t e = s.find_first_of("eE");
  if (e == std::string::npos) return s;
  int exp = std::atoi(s.c_str() + e + 1);
  std::string mant = s.substr(0, e);
  bool neg = !mant.empty() && mant[0] == '-';
  if (neg) mant.erase(0, 1);
  size_t dot = mant.find('.');
  std::string digits = dot == std::string::npos ? mant : mant.substr(0, dot) + mant.substr(dot + 1);
  int point = static_cast<int>(dot == std::string::npos ? mant.size() : dot) + exp;
  std::string out;
  if (point <= 0) out = "0." + std::string(-point, '0') + digits;
  else if (point >= static_cast<int>(digits.size())) out = digits + std::string(point - digits.size(), '0');
  else out = digits.substr(0, point) + "." + digits.substr(point);
  return neg ? "-" + out : out;
}

// An atomic amount from the page: a decimal string or a non-negative integer, within uint64.
uint64_t parse_amount(const rapidjson::Value& v) {
  if (v.IsUint64()) return v.GetUint64();
  if (v.IsString()) {
    const char* s = v.GetString();
    if (!*s) throw std::runtime_error("Bad amount");
    for (const char* p = s; *p; p++) if (*p < '0' || *p > '9') throw std::runtime_error("Bad amount");
    errno = 0;
    unsigned long long x = std::strtoull(s, nullptr, 10);
    if (errno == ERANGE || x > std::numeric_limits<uint64_t>::max()) throw std::runtime_error("Amount too large");
    return static_cast<uint64_t>(x);
  }
  throw std::runtime_error("Bad amount");
}

const rapidjson::Value& member(const rapidjson::Value& o, const char* k) {
  auto it = o.FindMember(k);
  if (it == o.MemberEnd()) throw std::runtime_error(std::string("Missing ") + k);
  return it->value;
}

}  // namespace

extern "C" {

int zios_wallet_set_listener(zios_wallet* w, const zios_listener* l, char** err) {
  return guarded(err, -1, [&]() -> int {
    monero_wallet_full* x = need(w);
    if (w->listener) {
      x->remove_listener(*w->listener);
      w->listener.reset();
    }
    if (l) {
      w->listener.reset(new zios::listener_adapter(*l));
      x->add_listener(*w->listener);
    }
    return 0;
  });
}

int zios_wallet_set_daemon(zios_wallet* w, const char* uri, const char* user, const char* pass, char** err) {
  return guarded(err, -1, [&]() -> int {
    monero_wallet_full* x = need(w);
    if (!uri || !*uri) x->set_daemon_connection(boost::optional<monero_rpc_connection>());
    else x->set_daemon_connection(uri, user ? user : "", pass ? pass : "");
    return 0;
  });
}

char* zios_wallet_sync(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    monero_sync_result r = x->sync();
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    key(o, "fetched"); o.Uint64(r.m_num_blocks_fetched);
    key(o, "receivedMoney"); o.Bool(r.m_received_money);
    try { uint64_t h = x->get_height(); key(o, "height"); o.Uint64(h); } catch (...) { }
    try { uint64_t h = x->get_daemon_height(); key(o, "daemonHeight"); o.Uint64(h); } catch (...) { }
    try { bool s = x->is_daemon_synced(); key(o, "daemonSynced"); o.Bool(s); } catch (...) { }
    o.EndObject();
    return finish(sb);
  });
}

void zios_wallet_stop_syncing(zios_wallet* w) {
  try {
    if (w && w->w) w->w->stop_syncing();
  } catch (...) {
  }
}

char* zios_wallet_info(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    kv(o, "address", x->get_primary_address());
    std::string vk = x->get_private_view_key();
    kv(o, "viewKey", vk);
    std::fill(vk.begin(), vk.end(), '\0');
    key(o, "viewOnly"); o.Bool(x->is_view_only());
    key(o, "restoreHeight"); o.Uint64(x->get_restore_height());
    key(o, "height"); o.Uint64(x->get_height());
    o.EndObject();
    return finish(sb);
  });
}

char* zios_wallet_create_subaddress(zios_wallet* w, const char* label, int min_count, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    if (min_count < 0 || min_count > 5000) throw std::runtime_error("Bad subaddress count");
    size_t have = x->get_subaddresses(0, std::vector<uint32_t>()).size();
    for (; have < static_cast<size_t>(min_count); have++) x->create_subaddress(0, "");
    monero_subaddress sub = x->create_subaddress(0, label ? label : "");
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    key(o, "index"); o.Uint64(sub.m_index ? *sub.m_index : have);
    kv(o, "address", sub.m_address ? *sub.m_address : "");
    o.EndObject();
    return finish(sb);
  });
}

char* zios_wallet_balances(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    std::map<std::string, uint64_t> tot = x->get_balance();
    std::map<std::string, uint64_t> unl = x->get_unlocked_balance();
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    for (int pass = 0; pass < 2; pass++) {
      const std::map<std::string, uint64_t>& m = pass == 0 ? tot : unl;
      key(o, pass == 0 ? "total" : "unlocked");
      o.StartObject();
      for (const char* a : V2_ASSETS) {
        auto it = m.find(a);
        kv(o, a, std::to_string(it == m.end() ? 0 : it->second));
      }
      o.EndObject();
    }
    o.EndObject();
    return finish(sb);
  });
}

char* zios_wallet_tx_history(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    std::vector<std::shared_ptr<monero_tx_wallet>> txs = x->get_txs();
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    key(o, "txs");
    o.StartArray();
    for (const auto& tx : txs) {
      if (!tx || !tx->m_hash) continue;
      o.StartObject();
      kv(o, "hash", *tx->m_hash);
      key(o, "height");
      boost::optional<uint64_t> h = tx->get_height();
      if (h) o.Uint64(*h); else o.Null();
      kv(o, "fee", std::to_string(tx->m_fee ? *tx->m_fee : 0));
      uint64_t ts = 0;
      if (tx->m_block && *tx->m_block && (*tx->m_block)->m_timestamp) ts = *(*tx->m_block)->m_timestamp;
      key(o, "timestamp"); o.Uint64(ts);
      key(o, "confirmations"); o.Uint64(tx->m_num_confirmations ? *tx->m_num_confirmations : 0);
      key(o, "confirmed"); o.Bool(tx->m_is_confirmed && *tx->m_is_confirmed);
      key(o, "inPool"); o.Bool(tx->m_in_tx_pool && *tx->m_in_tx_pool);
      key(o, "failed"); o.Bool(tx->m_is_failed && *tx->m_is_failed);
      key(o, "locked"); o.Bool(tx->m_is_locked && *tx->m_is_locked);
      if (tx->m_outgoing_transfer && *tx->m_outgoing_transfer) {
        const auto& og = *tx->m_outgoing_transfer;
        key(o, "out");
        o.StartObject();
        kv(o, "asset", og->m_asset_type);
        kv(o, "amount", std::to_string(og->m_amount ? *og->m_amount : 0));
        o.EndObject();
      }
      key(o, "in");
      o.StartArray();
      for (const auto& t : tx->m_incoming_transfers) {
        if (!t) continue;
        o.StartObject();
        kv(o, "asset", t->m_asset_type);
        kv(o, "amount", std::to_string(t->m_amount ? *t->m_amount : 0));
        o.EndObject();
      }
      o.EndArray();
      o.EndObject();
    }
    o.EndArray();
    o.EndObject();
    return finish(sb);
  });
}

char* zios_wallet_reserve_info(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    boost::multiprecision::uint128_t zeph_reserve = 0, num_stables = 0, num_reserves = 0, assets = 0,
        assets_ma = 0, liabilities = 0, equity = 0, equity_ma = 0, zyield_circ = 0, zyield_rsv = 0;
    double reserve_ratio = 0, reserve_ratio_ma = 0;
    uint8_t hf_version = 0;
    x->get_reserve_info(zeph_reserve, num_stables, num_reserves, assets, assets_ma, liabilities, equity,
                        equity_ma, reserve_ratio, reserve_ratio_ma, hf_version, zyield_circ, zyield_rsv);
    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    kv(o, "reserveRatio", plain_decimal(reserve_ratio));
    kv(o, "reserveRatioMa", plain_decimal(reserve_ratio_ma));
    kv(o, "numStables", num_stables.convert_to<std::string>());
    kv(o, "numReserves", num_reserves.convert_to<std::string>());
    key(o, "hfVersion"); o.Uint(hf_version);
    o.EndObject();
    return finish(sb);
  });
}

char* zios_wallet_create_txs(zios_wallet* w, const char* page_json, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    monero_wallet_full* x = need(w);
    rapidjson::Document in;
    in.Parse(page_json ? page_json : "");
    if (in.HasParseError() || !in.IsObject()) throw std::runtime_error("Bad transaction config");

    // Rebuild the config from the fields the Android plugin accepts, and nothing else.
    rapidjson::StringBuffer cb;
    Writer c(cb);
    c.StartObject();
    const rapidjson::Value& ds = member(in, "destinations");
    if (!ds.IsArray() || ds.Empty()) throw std::runtime_error("No destinations");
    key(c, "destinations");
    c.StartArray();
    for (const auto& d : ds.GetArray()) {
      if (!d.IsObject()) throw std::runtime_error("Bad destination");
      const rapidjson::Value& a = member(d, "address");
      if (!a.IsString()) throw std::runtime_error("Bad address");
      c.StartObject();
      kv(c, "address", a.GetString());
      key(c, "amount"); c.Uint64(parse_amount(member(d, "amount")));
      c.EndObject();
    }
    c.EndArray();
    const rapidjson::Value& sc = member(in, "sourceCurrency");
    const rapidjson::Value& dc = member(in, "destinationCurrency");
    if (!sc.IsString() || !dc.IsString()) throw std::runtime_error("Bad currency");
    kv(c, "sourceCurrency", sc.GetString());
    kv(c, "destinationCurrency", dc.GetString());
    int account = 0;
    auto ai = in.FindMember("accountIndex");
    if (ai != in.MemberEnd()) {
      if (!ai->value.IsInt() || ai->value.GetInt() < 0) throw std::runtime_error("Bad account index");
      account = ai->value.GetInt();
    }
    key(c, "accountIndex"); c.Uint(static_cast<unsigned>(account));
    bool relay = false;
    auto ri = in.FindMember("relay");
    if (ri != in.MemberEnd() && ri->value.IsBool()) relay = ri->value.GetBool();
    key(c, "relay"); c.Bool(relay);
    auto si = in.FindMember("subaddressIndices");
    if (si != in.MemberEnd() && si->value.IsArray() && !si->value.Empty()) {
      key(c, "subaddressIndices");
      c.StartArray();
      for (const auto& v : si->value.GetArray()) {
        if (!v.IsInt() || v.GetInt() < 0) throw std::runtime_error("Bad subaddress index");
        c.Uint(static_cast<unsigned>(v.GetInt()));
      }
      c.EndArray();
    }
    c.EndObject();

    std::shared_ptr<monero_tx_config> cfg = monero_tx_config::deserialize(std::string(cb.GetString(), cb.GetSize()));
    std::vector<std::shared_ptr<monero_tx_wallet>> txs = x->create_txs(*cfg);

    rapidjson::StringBuffer sb;
    Writer o(sb);
    o.StartObject();
    key(o, "txs");
    o.StartArray();
    for (const auto& tx : txs) {
      if (!tx) continue;
      o.StartObject();
      kv(o, "hash", tx->m_hash ? *tx->m_hash : "");
      kv(o, "fee", std::to_string(tx->m_fee ? *tx->m_fee : 0));
      o.EndObject();
    }
    o.EndArray();
    o.EndObject();
    return finish(sb);
  });
}

int zios_validate_address(const char* address, int network_type, char** reason) {
  try {
    if (network_type < 0 || network_type > 2) throw std::runtime_error("invalid network type");
    monero_utils::validate_address(address ? address : "", static_cast<monero_network_type>(network_type));
    return 1;
  } catch (const std::exception& e) {
    zios::set_err(reason, e.what());
  } catch (...) {
    zios::set_err(reason, "invalid address");
  }
  return 0;
}

}  // extern "C"
