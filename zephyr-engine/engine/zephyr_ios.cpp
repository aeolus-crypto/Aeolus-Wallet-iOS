#include "zephyr_ios.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <string>

#include "wallet/monero_wallet_full.h"

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#endif

#ifndef ZIOS_SOURCES
#define ZIOS_SOURCES "unknown"
#endif

using namespace monero;

struct zios_wallet {
  monero_wallet* w;
};

namespace {

char* dup(const std::string& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (!p) return nullptr;
  std::memcpy(p, s.data(), s.size());
  p[s.size()] = '\0';
  return p;
}

void set_err(char** err, const char* msg) {
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

}  // namespace

extern "C" {

const char* zios_version(void) {
  return "zephyr-ios 0.1.0 (" ZIOS_SOURCES ")";
}

void zios_free(char* s) {
  if (!s) return;
  size_t n = std::strlen(s);
  volatile char* v = s;
  for (size_t i = 0; i < n; i++) v[i] = 0;
  std::free(s);
}

zios_wallet* zios_wallet_create(const char* config_json, char** err) {
  return guarded(err, static_cast<zios_wallet*>(nullptr), [&]() -> zios_wallet* {
    std::shared_ptr<monero_wallet_config> config =
        monero_wallet_config::deserialize(std::string(config_json ? config_json : ""));
    monero_wallet* w = monero_wallet_full::create_wallet(*config);
    return new zios_wallet{w};
  });
}

zios_wallet* zios_wallet_open(const char* path, const char* password, int network_type, char** err) {
  return guarded(err, static_cast<zios_wallet*>(nullptr), [&]() -> zios_wallet* {
    if (network_type < 0 || network_type > 2) throw std::runtime_error("invalid network type");
    monero_wallet* w = monero_wallet_full::open_wallet(path ? path : "", password ? password : "",
                                                       static_cast<monero_network_type>(network_type));
    return new zios_wallet{w};
  });
}

char* zios_wallet_primary_address(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    if (!w || !w->w) throw std::runtime_error("wallet is closed");
    return dup(w->w->get_primary_address());
  });
}

char* zios_wallet_mnemonic(zios_wallet* w, char** err) {
  return guarded(err, static_cast<char*>(nullptr), [&]() -> char* {
    if (!w || !w->w) throw std::runtime_error("wallet is closed");
    std::string m = w->w->get_mnemonic();
    char* r = dup(m);
    std::fill(m.begin(), m.end(), '\0');
    return r;
  });
}

int zios_wallet_close(zios_wallet* w, int save, char** err) {
  if (!w) return 0;
  int rc = guarded(err, -1, [&]() -> int {
    if (w->w) w->w->close(save != 0);
    return 0;
  });
  delete w->w;
  delete w;
  return rc;
}

#if defined(__APPLE__) && defined(__aarch64__)
// RandomX's ARM64 JIT calls __clear_cache, which Apple's toolchains do not provide on iOS.
// The wallet never runs RandomX; this keeps the link complete.
void __clear_cache(void* start, void* end) {
  sys_icache_invalidate(start, static_cast<char*>(end) - static_cast<char*>(start));
}
#endif

}  // extern "C"
