/*
 * Offline smoke test of the engine (no node, no network). Runs in the iOS Simulator in CI and on
 * Linux for comparison. Every check runs even when an earlier one fails, so one run shows the
 * whole picture; the exit code is the number of failed checks.
 *
 *   zios_smoke <dir> [fixture_dir] [log_level]
 *     dir          scratch directory; the wallets it creates stay there for inspection
 *     fixture_dir  a wallet made elsewhere: fixture_dir/fixture{,.keys} with password
 *                  "fixture-pw" and its address in fixture_dir/address.txt
 *     log_level    core log level 0..4 (default 1), written to dir/zios.log
 *
 *   zios_smoke --make-fixture <dir>   creates dir/fixture{,.keys} and dir/address.txt
 *
 * Checks: create a random mainnet wallet (25 words, ZEPHYR address); export its keys and cache
 * to memory and reopen from those buffers; save, close and reopen from the files; restore from
 * the mnemonic; refuse a wrong password; open the fixture; the wallet operations the app uses
 * that work offline (info, balances, subaddresses, history, address validation, a listener, and
 * a sync and a send that must fail cleanly without a node). Prints only address prefixes and
 * word counts, never a mnemonic or key.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "zephyr_ios.h"

static int failures = 0;

static void check(int ok, const char* what, char* err) {
  printf("%s: %s%s%s\n", ok ? "ok  " : "FAIL", what, err ? ": " : "", err ? err : "");
  if (!ok) failures++;
  zios_free(err);
}

static int count_cb = 0;
static void cb_progress(void* ctx, uint64_t h, uint64_t s, uint64_t e, double p) { (void)ctx; (void)h; (void)s; (void)e; (void)p; count_cb++; }
static void cb_balances(void* ctx, const char* b, const char* u, const char* a) { (void)ctx; (void)b; (void)u; (void)a; count_cb++; }
static void cb_output(void* ctx, int spent, int64_t h, const char* t) { (void)ctx; (void)spent; (void)h; (void)t; count_cb++; }

static int has(const char* json, const char* part) { return json && strstr(json, part) != NULL; }

static int words(const char* s) {
  int n = 0, in = 0;
  for (; *s; s++) {
    if (*s == ' ') in = 0;
    else if (!in) { in = 1; n++; }
  }
  return n;
}

static long fsize(const char* path) {
  struct stat st;
  return stat(path, &st) == 0 ? (long)st.st_size : -1;
}

static int make_fixture(const char* dir) {
  char path[1024], cfg[2048], k[1100];
  snprintf(path, sizeof path, "%s/fixture", dir);
  snprintf(k, sizeof k, "%s.keys", path); remove(k); remove(path);
  snprintf(cfg, sizeof cfg, "{\"path\":\"%s\",\"password\":\"fixture-pw\",\"networkType\":0,\"language\":\"English\"}", path);
  char* err = NULL;
  zios_wallet* w = zios_wallet_create(cfg, &err);
  if (!w) { fprintf(stderr, "create: %s\n", err ? err : ""); return 1; }
  char* addr = zios_wallet_primary_address(w, &err);
  if (!addr || zios_wallet_close(w, 1, &err) != 0) { fprintf(stderr, "fixture: %s\n", err ? err : ""); return 1; }
  snprintf(k, sizeof k, "%s/address.txt", dir);
  FILE* f = fopen(k, "w");
  if (!f) return 1;
  fprintf(f, "%s\n", addr);
  fclose(f);
  printf("fixture %s: %.12s...\n", path, addr);
  zios_free(addr);
  return 0;
}

int main(int argc, char** argv) {
  setvbuf(stdout, NULL, _IONBF, 0);   /* nothing lost if the process crashes */
  if (argc == 3 && strcmp(argv[1], "--make-fixture") == 0) return make_fixture(argv[2]);
  const char* dir = argc > 1 ? argv[1] : "/tmp";
  const char* fixture = argc > 2 && argv[2][0] ? argv[2] : NULL;
  int level = argc > 3 ? atoi(argv[3]) : 1;

  char p1[1024], p2[1024], p1k[1100], cfg[4096], logbase[1100];
  snprintf(p1, sizeof p1, "%s/zios-smoke-1", dir);
  snprintf(p2, sizeof p2, "%s/zios-smoke-2", dir);
  snprintf(p1k, sizeof p1k, "%s.keys", p1);
  snprintf(cfg, sizeof cfg, "%s.keys", p2);
  remove(p1k); remove(p1); remove(cfg); remove(p2);
  snprintf(logbase, sizeof logbase, "%s/zios.log", dir);
  zios_configure_logging(logbase, 0);
  zios_set_log_level(level);

  printf("%s\n", zios_version());
  {
    char* st = zios_selftest(1);
    check(st && strstr(st, "\"ok\":true") != NULL, "slow-hash known answers", NULL);
    printf("      %s\n", st ? st : "(null)");
    zios_free(st);
  }
  {
    char* dg = zios_diag_keys();
    check(dg && strstr(dg, "false") == NULL && strstr(dg, "exception") == NULL, "keys round trip diagnostic", NULL);
    printf("      %s\n", dg ? dg : "(null)");
    zios_free(dg);
  }
  char* err = NULL;

  /* 1. create */
  snprintf(cfg, sizeof cfg,
           "{\"path\":\"%s\",\"password\":\"smoke-pw\",\"networkType\":0,\"language\":\"English\"}", p1);
  zios_wallet* w = zios_wallet_create(cfg, &err);
  check(w != NULL, "create random wallet", err); err = NULL;
  if (!w) { printf("RESULT: %d failure(s)\n", failures); return failures; }
  char* addr = zios_wallet_primary_address(w, &err);
  check(addr != NULL, "primary address", err); err = NULL;
  char* mn = zios_wallet_mnemonic(w, &err);
  check(mn != NULL, "mnemonic", err); err = NULL;
  if (!addr || !mn) { printf("RESULT: %d failure(s)\n", failures + 1); return failures + 1; }
  printf("      address %.12s... (%zu chars), mnemonic %d words\n", addr, strlen(addr), words(mn));
  check(strncmp(addr, "ZEPHYR", 6) == 0, "address prefix ZEPHYR", NULL);
  check(words(mn) == 25, "mnemonic has 25 words", NULL);
  printf("      after create: %s %ld bytes, keys %ld bytes\n", p1, fsize(p1), fsize(p1k));

  /* 2. in-memory round trip, before the files are touched again */
  uint8_t *kb = NULL, *cb = NULL;
  size_t kl = 0, cl = 0;
  int rc = zios_wallet_get_data(w, "smoke-pw", &kb, &kl, &cb, &cl, &err);
  check(rc == 0, "export keys and cache to memory", err); err = NULL;
  if (rc == 0) {
    printf("      memory: keys %zu bytes, cache %zu bytes\n", kl, cl);
    zios_wallet* wm = zios_wallet_open_data("smoke-pw", 0, kb, kl, cb, cl, &err);
    check(wm != NULL, "open from memory buffers", err); err = NULL;
    if (wm) {
      char* am = zios_wallet_primary_address(wm, &err);
      check(am && strcmp(am, addr) == 0, "memory round trip: same address", err); err = NULL;
      zios_free(am);
      zios_wallet_close(wm, 0, NULL);
    }
    zios_free_bytes(kb, kl);
    zios_free_bytes(cb, cl);
  }

  /* 3. save, close, reopen from the files */
  rc = zios_wallet_close(w, 1, &err);
  check(rc == 0, "save and close", err); err = NULL;
  printf("      after save: %s %ld bytes, keys %ld bytes\n", p1, fsize(p1), fsize(p1k));
  w = zios_wallet_open(p1, "smoke-pw", 0, &err);
  check(w != NULL, "reopen from files", err); err = NULL;
  if (w) {
    char* a2 = zios_wallet_primary_address(w, &err);
    check(a2 && strcmp(a2, addr) == 0, "reopen: same address", err); err = NULL;
    zios_free(a2);
    zios_wallet_close(w, 0, NULL);
  }

  /* 4. restore from the mnemonic */
  snprintf(cfg, sizeof cfg,
           "{\"path\":\"%s\",\"password\":\"smoke-pw\",\"networkType\":0,\"mnemonic\":\"%s\",\"restoreHeight\":0}",
           p2, mn);
  w = zios_wallet_create(cfg, &err);
  memset(cfg, 0, sizeof cfg);
  check(w != NULL, "restore from mnemonic", err); err = NULL;
  if (w) {
    char* a3 = zios_wallet_primary_address(w, &err);
    check(a3 && strcmp(a3, addr) == 0, "restore: same address", err); err = NULL;
    zios_free(a3);
    zios_wallet_close(w, 0, NULL);
  }

  /* 5. wrong password */
  w = zios_wallet_open(p1, "wrong-pw", 0, &err);
  check(w == NULL, "wrong password refused", err); err = NULL;
  if (w) zios_wallet_close(w, 0, NULL);

  /* 6. wallet operations the app uses, offline */
  w = zios_wallet_open(p1, "smoke-pw", 0, &err);
  check(w != NULL, "open for wallet operations", err); err = NULL;
  if (w) {
    char* j = zios_wallet_info(w, &err);
    check(has(j, "\"address\":\"ZEPHYR") && has(j, "\"viewOnly\":false") && has(j, "\"viewKey\":\""),
          "info: address, view key, not view-only", err); err = NULL;
    zios_free(j);
    j = zios_wallet_balances(w, &err);
    check(has(j, "\"total\":{\"ZPH\":\"0\",\"ZSD\":\"0\",\"ZRS\":\"0\",\"ZYS\":\"0\"}") &&
          has(j, "\"unlocked\":{\"ZPH\":\"0\""), "balances: four V2 assets, zero", err); err = NULL;
    if (j) printf("      %s\n", j);
    zios_free(j);
    j = zios_wallet_create_subaddress(w, "smoke", 3, &err);
    check(has(j, "\"index\":3") && has(j, "\"address\":\"ZEPHs"), "subaddress: index 3 after min_count 3", err); err = NULL;
    if (j) printf("      %.40s...\n", j);
    zios_free(j);
    /* the core reads the pool from the node for the history: offline it must fail cleanly
       (the Android library, on the same core, behaves the same) or return no transactions */
    j = zios_wallet_tx_history(w, &err);
    check((j && strcmp(j, "{\"txs\":[]}") == 0) || (!j && err), "history: empty or a clean error offline", NULL);
    if (err) printf("      history error: %s\n", err);
    zios_free(j); zios_free(err); err = NULL;
    char* reason = NULL;
    check(zios_validate_address(addr, 0, &reason) == 1, "validate own address", reason); reason = NULL;
    char bad[256];
    snprintf(bad, sizeof bad, "%s", addr);
    bad[20] = bad[20] == 'a' ? 'b' : 'a';
    int v = zios_validate_address(bad, 0, &reason);
    check(v == 0 && reason != NULL, "tampered address refused", NULL);
    if (reason) printf("      reason: %s\n", reason);
    zios_free(reason); reason = NULL;
    zios_listener l = { NULL, cb_progress, cb_balances, cb_output };
    check(zios_wallet_set_listener(w, &l, &err) == 0, "set listener", err); err = NULL;
    check(zios_wallet_set_daemon(w, "http://127.0.0.1:1", "", "", &err) == 0, "set unreachable node", err); err = NULL;
    j = zios_wallet_sync(w, &err);
    check(j == NULL && err != NULL, "sync without a node fails cleanly", NULL);
    if (err) printf("      sync error: %s\n", err);
    zios_free(j); zios_free(err); err = NULL;
    j = zios_wallet_create_txs(w, "{\"destinations\":[{\"address\":\"x\",\"amount\":\"1\"}],\"sourceCurrency\":\"ZPH\",\"destinationCurrency\":\"ZPH\",\"relay\":false}", &err);
    check(j == NULL && err != NULL, "send without a node fails cleanly", NULL);
    if (err) printf("      send error: %s\n", err);
    zios_free(j); zios_free(err); err = NULL;
    j = zios_wallet_create_txs(w, "{\"destinations\":[{\"address\":\"x\",\"amount\":\"-5\"}],\"sourceCurrency\":\"ZPH\",\"destinationCurrency\":\"ZPH\"}", &err);
    check(j == NULL && err && strcmp(err, "Bad amount") == 0, "negative amount refused", NULL);
    zios_free(j); zios_free(err); err = NULL;
    zios_wallet_stop_syncing(w);
    check(zios_wallet_set_listener(w, NULL, &err) == 0, "remove listener", err); err = NULL;
    printf("      listener callbacks seen: %d\n", count_cb);
    check(zios_wallet_close(w, 1, &err) == 0, "save and close after operations", err); err = NULL;
  }

  /* 7. a wallet made on another platform */
  if (fixture) {
    char fp[1024], ap[1100], expect[256] = {0};
    snprintf(fp, sizeof fp, "%s/fixture", fixture);
    snprintf(ap, sizeof ap, "%s/address.txt", fixture);
    FILE* f = fopen(ap, "r");
    if (f) { if (!fgets(expect, sizeof expect, f)) expect[0] = 0; fclose(f); }
    expect[strcspn(expect, "\r\n")] = 0;
    w = zios_wallet_open(fp, "fixture-pw", 0, &err);
    check(w != NULL, "open fixture made on another platform", err); err = NULL;
    if (w) {
      char* af = zios_wallet_primary_address(w, &err);
      check(af && expect[0] && strcmp(af, expect) == 0, "fixture: expected address", err); err = NULL;
      zios_free(af);
      zios_wallet_close(w, 0, NULL);
    }
  }

  zios_free(mn);
  zios_free(addr);
  printf("RESULT: %s (%d failure(s))\n", failures ? "FAIL" : "PASS", failures);
  return failures;
}
