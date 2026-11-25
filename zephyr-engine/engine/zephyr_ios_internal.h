// Shared by zephyr_ios.cpp and zephyr_ios_wallet.cpp. Not part of the public interface.
#pragma once

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "zephyr_ios.h"
#include "wallet/monero_wallet_full.h"

namespace zios {

// Forwards the core's listener callbacks to the C callbacks; no wallet calls in here.
struct listener_adapter : public monero::monero_wallet_listener {
  zios_listener l;
  explicit listener_adapter(const zios_listener& x) : l(x) {}

  void on_sync_progress(uint64_t height, uint64_t start_height, uint64_t end_height, double percent_done,
                        const std::string&) override {
    if (l.on_progress) l.on_progress(l.ctx, height, start_height, end_height, percent_done);
  }
  void on_balances_changed(uint64_t balance, uint64_t unlocked, const std::string& asset) override {
    if (l.on_balances) l.on_balances(l.ctx, std::to_string(balance).c_str(), std::to_string(unlocked).c_str(), asset.c_str());
  }
  void on_output_received(const monero::monero_output_wallet& o) override { output(0, o); }
  void on_output_spent(const monero::monero_output_wallet& o) override { output(1, o); }

 private:
  void output(int spent, const monero::monero_output_wallet& o) {
    if (!l.on_output) return;
    int64_t height = -1;
    std::string txid;
    if (o.m_tx) {
      boost::optional<uint64_t> h = o.m_tx->get_height();
      if (h) height = static_cast<int64_t>(*h);
      if (o.m_tx->m_hash) txid = *o.m_tx->m_hash;
    }
    l.on_output(l.ctx, spent, height, txid.empty() ? nullptr : txid.c_str());
  }
};

inline char* dup(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (!p) return nullptr;
  std::memcpy(p, s.data(), s.size());
  p[s.size()] = '\0';
  return p;
}

inline void set_err(char** err, const char* msg) {
  if (err) *err = dup(msg ? msg : "unknown error");
}

template <typename R, typename F>
R guarded(char** err, R fail, F f) {
  try {
    return f();
  } catch (const std::exception& e) {
    set_err(err, e.what());
  } catch (...) {
    set_err(err, "unknown native error");
  }
  return fail;
}

}  // namespace zios

struct zios_wallet {
  monero::monero_wallet_full* w = nullptr;
  // zios_wallet_prepare_txs: built and signed, not broadcast yet (relay data in m_metadata)
  std::vector<std::shared_ptr<monero::monero_tx_wallet>> prepared;
  // deleted after the wallet (the core holds a reference to it until it is closed)
  std::unique_ptr<zios::listener_adapter> listener;
};
