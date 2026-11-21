// Diagnostic of the keys-file round trip, step by step, with a throwaway account (never a user
// wallet): kv-serialization of the account, chacha20, account-key encryption, and the
// secret -> public check wallet2 runs when it loads a keys file (wallet2.cpp, "files doesn't
// correspond"). Prints only equal/not equal, sizes and the serialized blob's first bytes.
#include <cstring>
#include <sstream>
#include <string>

#include "zephyr_ios_internal.h"

#include "cryptonote_basic/account.h"
#include "crypto/chacha.h"
#include "crypto/crypto.h"
#include "storages/portable_storage_template_helper.h"

namespace {

bool same_keys(const cryptonote::account_keys& a, const cryptonote::account_keys& b) {
  return std::memcmp(&a.m_spend_secret_key, &b.m_spend_secret_key, sizeof(crypto::secret_key)) == 0 &&
         std::memcmp(&a.m_view_secret_key, &b.m_view_secret_key, sizeof(crypto::secret_key)) == 0 &&
         a.m_account_address.m_spend_public_key == b.m_account_address.m_spend_public_key &&
         a.m_account_address.m_view_public_key == b.m_account_address.m_view_public_key;
}

bool verifies(const cryptonote::account_keys& k) {
  crypto::public_key s, v;
  return crypto::secret_key_to_public_key(k.m_spend_secret_key, s) && s == k.m_account_address.m_spend_public_key &&
         crypto::secret_key_to_public_key(k.m_view_secret_key, v) && v == k.m_account_address.m_view_public_key;
}

std::string hex(const void* d, size_t n) {
  static const char* x = "0123456789abcdef";
  const unsigned char* p = static_cast<const unsigned char*>(d);
  std::string s;
  for (size_t i = 0; i < n; i++) { s += x[p[i] >> 4]; s += x[p[i] & 15]; }
  return s;
}

}  // namespace

extern "C" char* zios_diag_keys(void) {
  std::ostringstream o;
  try {
    o << "{\"sizeof\":{\"secret_key\":" << sizeof(crypto::secret_key) << ",\"public_key\":" << sizeof(crypto::public_key)
      << ",\"account_keys\":" << sizeof(cryptonote::account_keys) << ",\"chacha_iv\":" << sizeof(crypto::chacha_iv) << "}";

    cryptonote::account_base acc;
    acc.generate();
    const cryptonote::account_keys& k0 = acc.get_keys();
    o << ",\"generated_verifies\":" << (verifies(k0) ? "true" : "false");

    // 1. kv serialization round trip, no encryption
    {
      epee::byte_slice blob;
      bool st = epee::serialization::store_t_to_binary(acc, blob);
      std::string s(reinterpret_cast<const char*>(blob.data()), blob.size());
      cryptonote::account_base acc2;
      bool ld = epee::serialization::load_t_from_binary(acc2, s);
      o << ",\"kv\":{\"stored\":" << (st ? "true" : "false") << ",\"size\":" << blob.size()
        << ",\"head\":\"" << hex(blob.data(), blob.size() < 16 ? blob.size() : 16) << "\""
        << ",\"loaded\":" << (ld ? "true" : "false")
        << ",\"same\":" << (ld && same_keys(k0, acc2.get_keys()) ? "true" : "false")
        << ",\"verifies\":" << (ld && verifies(acc2.get_keys()) ? "true" : "false") << "}";
    }

    crypto::chacha_key key;
    crypto::generate_chacha_key("diag-password", 13, key, 1);

    // 2. chacha20 round trip and stability
    {
      std::string pt(97, 'a'), c1(97, 0), c2(97, 0), back(97, 0);
      crypto::chacha_iv iv;
      std::memset(&iv, 7, sizeof iv);
      crypto::chacha20(pt.data(), pt.size(), key, iv, &c1[0]);
      crypto::chacha20(pt.data(), pt.size(), key, iv, &c2[0]);
      crypto::chacha20(c1.data(), c1.size(), key, iv, &back[0]);
      o << ",\"chacha20\":{\"stable\":" << (c1 == c2 ? "true" : "false") << ",\"round_trip\":" << (back == pt ? "true" : "false") << "}";
    }

    // 3. account-key encryption round trip in memory
    {
      cryptonote::account_base a3 = acc;
      a3.encrypt_keys(key);
      bool changed = !same_keys(k0, a3.get_keys());
      a3.decrypt_keys(key);
      o << ",\"encrypt\":{\"changed\":" << (changed ? "true" : "false")
        << ",\"same_after_decrypt\":" << (same_keys(k0, a3.get_keys()) ? "true" : "false") << "}";
    }

    // 4. what wallet2 does: encrypt, serialize, load, decrypt, verify
    {
      cryptonote::account_base a4 = acc;
      a4.encrypt_keys(key);
      epee::byte_slice blob;
      bool st = epee::serialization::store_t_to_binary(a4, blob);
      std::string s(reinterpret_cast<const char*>(blob.data()), blob.size());
      cryptonote::account_base a5;
      bool ld = epee::serialization::load_t_from_binary(a5, s);
      bool iv_same = std::memcmp(&a4.get_keys().m_encryption_iv, &a5.get_keys().m_encryption_iv, sizeof(crypto::chacha_iv)) == 0;
      bool enc_same = ld && same_keys(a4.get_keys(), a5.get_keys());
      if (ld) a5.decrypt_keys(key);
      o << ",\"wallet2_path\":{\"stored\":" << (st ? "true" : "false") << ",\"loaded\":" << (ld ? "true" : "false")
        << ",\"iv_same\":" << (iv_same ? "true" : "false") << ",\"encrypted_same\":" << (enc_same ? "true" : "false")
        << ",\"same_after_decrypt\":" << (ld && same_keys(k0, a5.get_keys()) ? "true" : "false")
        << ",\"verifies\":" << (ld && verifies(a5.get_keys()) ? "true" : "false") << "}";
    }
    o << "}";
  } catch (const std::exception& e) {
    o << ",\"exception\":\"" << e.what() << "\"}";
  } catch (...) {
    o << ",\"exception\":\"unknown\"}";
  }
  return zios::dup(o.str());
}
