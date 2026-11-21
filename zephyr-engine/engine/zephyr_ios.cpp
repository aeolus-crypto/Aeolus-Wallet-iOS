#include "zephyr_ios_internal.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <algorithm>
#include <memory>
#include <stdexcept>
#include <string>

#include "wallet/monero_wallet_full.h"
#include "misc_log_ex.h"

#if defined(__APPLE__)
#include <libkern/OSCacheControl.h>
#endif

#ifndef ZIOS_SOURCES
#define ZIOS_SOURCES "unknown"
#endif

using namespace monero;

namespace {

uint8_t* dup_bytes(const std::string& s) {
  uint8_t* p = static_cast<uint8_t*>(std::malloc(s.size() ? s.size() : 1));
  if (!p) throw std::bad_alloc();
  if (!s.empty()) std::memcpy(p, s.data(), s.size());
  return p;
}

void wipe(std::string& s) {
  volatile char* v = &s[0];
  for (size_t i = 0; i < s.size(); i++) v[i] = 0;
}

}  // namespace

using zios::dup;
using zios::guarded;
using zios::set_err;

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

void zios_free_bytes(uint8_t* p, size_t len) {
  if (!p) return;
  volatile uint8_t* v = p;
  for (size_t i = 0; i < len; i++) v[i] = 0;
  std::free(p);
}

void zios_configure_logging(const char* path, int console) {
  try {
    mlog_configure(path ? path : "", console != 0);
  } catch (...) {
  }
}

void zios_set_log_level(int level) {
  try {
    mlog_set_log_level(level);
  } catch (...) {
  }
}

zios_wallet* zios_wallet_open_data(const char* password, int network_type,
                                   const uint8_t* keys, size_t keys_len,
                                   const uint8_t* cache, size_t cache_len, char** err) {
  return guarded(err, static_cast<zios_wallet*>(nullptr), [&]() -> zios_wallet* {
    if (network_type < 0 || network_type > 2) throw std::runtime_error("invalid network type");
    if (!keys || !keys_len) throw std::runtime_error("no keys data");
    std::string k(reinterpret_cast<const char*>(keys), keys_len);
    std::string c(cache && cache_len ? std::string(reinterpret_cast<const char*>(cache), cache_len) : std::string());
    monero_wallet_full* w = nullptr;
    try {
      w = monero_wallet_full::open_wallet_data(password ? password : "",
                                               static_cast<monero_network_type>(network_type), k, c);
    } catch (...) {
      wipe(k);
      throw;
    }
    wipe(k);
    { zios_wallet* h = new zios_wallet(); h->w = w; return h; }
  });
}

int zios_wallet_get_data(zios_wallet* w, const char* password,
                         uint8_t** keys, size_t* keys_len,
                         uint8_t** cache, size_t* cache_len, char** err) {
  return guarded(err, -1, [&]() -> int {
    if (!w || !w->w) throw std::runtime_error("wallet is closed");
    if (!keys || !keys_len || !cache || !cache_len) throw std::runtime_error("null output");
    std::string k = w->w->get_keys_file_buffer(epee::wipeable_string(password ? password : ""), false);
    std::string c = w->w->get_cache_file_buffer();
    uint8_t* kp = dup_bytes(k);
    uint8_t* cp = nullptr;
    try {
      cp = dup_bytes(c);
    } catch (...) {
      zios_free_bytes(kp, k.size());
      wipe(k);
      throw;
    }
    *keys = kp; *keys_len = k.size();
    *cache = cp; *cache_len = c.size();
    wipe(k);
    return 0;
  });
}

zios_wallet* zios_wallet_create(const char* config_json, char** err) {
  return guarded(err, static_cast<zios_wallet*>(nullptr), [&]() -> zios_wallet* {
    std::shared_ptr<monero_wallet_config> config =
        monero_wallet_config::deserialize(std::string(config_json ? config_json : ""));
    monero_wallet_full* w = monero_wallet_full::create_wallet(*config);
    { zios_wallet* h = new zios_wallet(); h->w = w; return h; }
  });
}

zios_wallet* zios_wallet_open(const char* path, const char* password, int network_type, char** err) {
  return guarded(err, static_cast<zios_wallet*>(nullptr), [&]() -> zios_wallet* {
    if (network_type < 0 || network_type > 2) throw std::runtime_error("invalid network type");
    monero_wallet_full* w = monero_wallet_full::open_wallet(path ? path : "", password ? password : "",
                                                       static_cast<monero_network_type>(network_type));
    { zios_wallet* h = new zios_wallet(); h->w = w; return h; }
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
  w->w = nullptr;
  w->listener.reset();
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
