// Known-answer self-test of the core's slow hash (CryptoNight), which the wallet uses to turn its
// password into the keys-file and cache keys. A build whose slow hash gives wrong or unstable
// answers cannot reopen its own wallets, so the app runs this before it opens one.
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include "zephyr_ios_internal.h"

extern "C" void cn_slow_hash(const void* data, size_t length, char* hash, int variant, int prehashed, uint64_t height);

namespace {

struct kat {
  int variant;
  uint64_t height;
  const char* expect_hex;
  const char* input_hex;
};

// tests/hash/tests-slow{,-1,-2,-4}.txt of Monero/Zephyr (first two vectors of each)
const kat KATS[] = {
  {0, 0, "2f8e3df40bd11f9ac90c743ca8e32bb391da4fb98612aa3b6cdc639ee00b31f5", "6465206f6d6e69627573206475626974616e64756d"},
  {0, 0, "722fa8ccd594d40e4a41f3822734304c8d5eff7e1b528408e2229da38ba553c4", "6162756e64616e732063617574656c61206e6f6e206e6f636574"},
  {1, 0, "b5a7f63abb94d07d1a6445c36c07c7e8327fe61b1647e391b4c7edae5de57a3d", "00000000000000000000000000000000000000000000000000000000000000000000000000000000000000"},
  {2, 0, "353fdc068fd47b03c04b9431e005e00b68c2168a3cc7335c8b9b308156591a4f", "5468697320697320612074657374205468697320697320612074657374205468697320697320612074657374"},
  {2, 0, "72f134fc50880c330fe65a2cb7896d59b2e708a0221c6a9da3f69b3a702d8682", "4c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e67"},
  {4, 1806260, "f759588ad57e758467295443a9bd71490abff8e9dad1b95b6bf2f5d0d78387bc", "5468697320697320612074657374205468697320697320612074657374205468697320697320612074657374"},
  {4, 1806261, "5bb833deca2bdd7252a9ccd7b4ce0b6a4854515794b56c207262f7a5b9bdb566", "4c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e67"},
};

std::vector<unsigned char> unhex(const char* h) {
  std::vector<unsigned char> out;
  for (; h[0] && h[1]; h += 2) {
    unsigned v = 0;
    std::sscanf(h, "%2x", &v);
    out.push_back(static_cast<unsigned char>(v));
  }
  return out;
}

std::string hex(const char* d, size_t n) {
  static const char* x = "0123456789abcdef";
  std::string s;
  for (size_t i = 0; i < n; i++) {
    s += x[(static_cast<unsigned char>(d[i]) >> 4) & 15];
    s += x[static_cast<unsigned char>(d[i]) & 15];
  }
  return s;
}

std::string run(const kat& k) {
  std::vector<unsigned char> in = unhex(k.input_hex);
  char h[32];
  cn_slow_hash(in.data(), in.size(), h, k.variant, 0, k.height);
  return hex(h, 32);
}

}  // namespace

extern "C" char* zios_selftest(int verbose) {
  try {
    std::string out = "{\"tests\":[";
    int failed = 0;
    for (int pass = 0; pass < 3; pass++) {
      // pass 0: this thread; 1: the same thread again (state left from pass 0); 2: a fresh thread
      for (size_t i = 0; i < sizeof(KATS) / sizeof(KATS[0]); i++) {
        std::string got;
        if (pass == 2) {
          std::thread t([&]() { got = run(KATS[i]); });
          t.join();
        } else {
          got = run(KATS[i]);
        }
        bool ok = got == KATS[i].expect_hex;
        if (!ok) failed++;
        if (verbose || !ok) {
          if (out.back() == '}') out += ",";
          char buf[256];
          std::snprintf(buf, sizeof buf, "{\"pass\":%d,\"variant\":%d,\"ok\":%s,\"got\":\"%s\"}", pass,
                        KATS[i].variant, ok ? "true" : "false", got.c_str());
          out += buf;
        }
      }
    }
    out += "],\"failed\":" + std::to_string(failed) + ",\"ok\":" + (failed ? "false" : "true") + "}";
    return zios::dup(out);
  } catch (...) {
    return zios::dup("{\"ok\":false,\"error\":\"self-test threw\"}");
  }
}
