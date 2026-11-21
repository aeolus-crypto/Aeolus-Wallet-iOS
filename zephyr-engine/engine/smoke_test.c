/*
 * Offline smoke test of the iOS engine, run in the iOS Simulator by CI (no node, no network):
 *  1. create a random mainnet wallet, read its address and 25-word mnemonic, save and close it
 *  2. open the saved files again: same address
 *  3. restore a second wallet from the mnemonic: same address
 *  4. a wrong password is refused
 * Prints only the address prefix and word count, never the mnemonic. Exit code 0 = pass.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zephyr_ios.h"

static int fail(const char* what, char* err) {
  fprintf(stderr, "FAIL: %s: %s\n", what, err ? err : "(no message)");
  zios_free(err);
  return 1;
}

static int words(const char* s) {
  int n = 0, in = 0;
  for (; *s; s++) {
    if (*s == ' ') in = 0;
    else if (!in) { in = 1; n++; }
  }
  return n;
}

int main(int argc, char** argv) {
  const char* dir = argc > 1 ? argv[1] : getenv("TMPDIR");
  if (!dir) dir = "/tmp";
  char p1[1024], p2[1024], cfg[4096];
  snprintf(p1, sizeof p1, "%s/zios-smoke-1", dir);
  snprintf(p2, sizeof p2, "%s/zios-smoke-2", dir);
  char k[1100];
  snprintf(k, sizeof k, "%s.keys", p1); remove(k); remove(p1);
  snprintf(k, sizeof k, "%s.keys", p2); remove(k); remove(p2);

  printf("%s\n", zios_version());
  char* err = NULL;

  snprintf(cfg, sizeof cfg,
           "{\"path\":\"%s\",\"password\":\"smoke-pw\",\"networkType\":0,\"language\":\"English\"}", p1);
  zios_wallet* w = zios_wallet_create(cfg, &err);
  if (!w) return fail("create random", err);
  char* addr = zios_wallet_primary_address(w, &err);
  if (!addr) return fail("address", err);
  char* mn = zios_wallet_mnemonic(w, &err);
  if (!mn) return fail("mnemonic", err);
  printf("created: address %.12s... (%zu chars), mnemonic %d words\n", addr, strlen(addr), words(mn));
  if (strncmp(addr, "ZEPHYR", 6) != 0) return fail("address prefix is not ZEPHYR", NULL);
  if (words(mn) != 25) return fail("mnemonic is not 25 words", NULL);
  if (zios_wallet_close(w, 1, &err) != 0) return fail("save and close", err);

  w = zios_wallet_open(p1, "smoke-pw", 0, &err);
  if (!w) return fail("reopen", err);
  char* addr2 = zios_wallet_primary_address(w, &err);
  if (!addr2) return fail("address after reopen", err);
  if (strcmp(addr, addr2) != 0) return fail("reopened address differs", NULL);
  zios_free(addr2);
  zios_wallet_close(w, 0, NULL);
  printf("reopened: same address\n");

  snprintf(cfg, sizeof cfg,
           "{\"path\":\"%s\",\"password\":\"smoke-pw\",\"networkType\":0,\"mnemonic\":\"%s\",\"restoreHeight\":0}",
           p2, mn);
  w = zios_wallet_create(cfg, &err);
  memset(cfg, 0, sizeof cfg);
  if (!w) return fail("restore from mnemonic", err);
  char* addr3 = zios_wallet_primary_address(w, &err);
  if (!addr3) return fail("address after restore", err);
  if (strcmp(addr, addr3) != 0) return fail("restored address differs", NULL);
  zios_free(addr3);
  zios_wallet_close(w, 0, NULL);
  printf("restored from mnemonic: same address\n");

  w = zios_wallet_open(p1, "wrong-pw", 0, &err);
  if (w) { zios_wallet_close(w, 0, NULL); return fail("wrong password was accepted", NULL); }
  printf("wrong password refused: %s\n", err ? err : "");
  zios_free(err); err = NULL;

  zios_free(mn);
  zios_free(addr);
  printf("PASS\n");
  return 0;
}
