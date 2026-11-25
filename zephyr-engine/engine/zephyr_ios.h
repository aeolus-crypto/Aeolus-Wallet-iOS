/*
 * zephyr_ios: a C interface to zephyr-cpp's in-process wallet (monero_wallet_full), for Swift.
 *
 * Conventions
 *  - Strings are UTF-8. Every char* this library returns is heap memory owned by the caller and
 *    must be released with zios_free(); zios_free() overwrites it with zeros first, because some
 *    results (a mnemonic, keys) are secrets.
 *  - Functions that can fail take `char** err`. On failure they return NULL / 0 / -1 and, when
 *    err is not NULL, set *err to a message (free it with zios_free). On success *err is untouched.
 *  - A zios_wallet* is not thread-safe: the caller runs every call on one serial queue, as the
 *    Android plugin runs every wallet call on its single "zw-wallet" executor.
 */
#ifndef ZEPHYR_IOS_H
#define ZEPHYR_IOS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zios_wallet zios_wallet;

/* Known-answer test of the core's slow hash (variants 0, 1, 2, 4; this thread twice and a new
 * thread). {"ok":b,"failed":n,"tests":[...]} (failures always listed, all with verbose != 0).
 * The app refuses to open wallets when ok is false. */
char* zios_selftest(int verbose);

/* Diagnostic of the keys-file round trip with a throwaway account (no user data): JSON of
 * equal / not equal per step. For tests only. */
char* zios_diag_keys(void);

/* Version of the engine and of the pinned sources it was built from (static string). */
const char* zios_version(void);

void zios_free(char* s);

/* Frees a byte buffer returned by this library after overwriting its len bytes with zeros. */
void zios_free_bytes(uint8_t* p, size_t len);

/* Core logging (wallet2 and friends). Off unless configured: path is a log file base path or
 * NULL/"" for none; console != 0 also logs to stdout. Level 0 (errors) .. 4 (trace). Never
 * enable above 0 in a release build: the core can log transaction details at higher levels. */
void zios_configure_logging(const char* path, int console);
void zios_set_log_level(int level);

/* Creates a wallet from a zephyr-cpp monero_wallet_config JSON object, the same JSON that
 * zephyr-java's ZephyrWalletFull.createWallet passes to the core: path, password,
 * networkType (0 mainnet, 1 testnet, 2 stagenet), language, mnemonic, seedOffset,
 * primaryAddress, privateViewKey, privateSpendKey, restoreHeight, serverUri, ... */
zios_wallet* zios_wallet_create(const char* config_json, char** err);

/* Opens a wallet's files at path (path and path.keys). */
zios_wallet* zios_wallet_open(const char* path, const char* password, int network_type, char** err);

/* Opens a wallet from in-memory keys and cache data (as returned by zios_wallet_get_data). */
zios_wallet* zios_wallet_open_data(const char* password, int network_type,
                                   const uint8_t* keys, size_t keys_len,
                                   const uint8_t* cache, size_t cache_len, char** err);

/* Returns the wallet's keys data (encrypted with password) and cache data, as the files would
 * hold them. Free both with zios_free_bytes. Returns 0, or -1 on failure. */
int zios_wallet_get_data(zios_wallet* w, const char* password,
                         uint8_t** keys, size_t* keys_len,
                         uint8_t** cache, size_t* cache_len, char** err);

char* zios_wallet_primary_address(zios_wallet* w, char** err);
char* zios_wallet_mnemonic(zios_wallet* w, char** err);

/* Saves (when save != 0) and closes the wallet, then frees it. Returns 0, or -1 on failure
 * (the wallet is freed either way). */
int zios_wallet_close(zios_wallet* w, int save, char** err);


/* ---------------------------------------------------------------- wallet operations
 * Everything below mirrors what Aeolus' Android plugin does with zephyr-java, with the results
 * shaped exactly like that plugin's (amounts as decimal strings of atomic units). JSON results
 * are UTF-8 strings to free with zios_free. */

/* Listener: callbacks arrive on the thread that runs zios_wallet_sync (or the core's own
 * threads). They must return quickly and must not call into the wallet. */
typedef struct {
  void* ctx;
  void (*on_progress)(void* ctx, uint64_t height, uint64_t start_height, uint64_t end_height, double percent);
  void (*on_balances)(void* ctx, const char* balance, const char* unlocked, const char* asset);
  /* spent = 0 received, 1 spent; height = -1 when unknown (pool); txid may be NULL */
  void (*on_output)(void* ctx, int spent, int64_t height, const char* txid);
} zios_listener;

/* Replaces the wallet's listener (NULL removes it). Only call while no sync runs. */
int zios_wallet_set_listener(zios_wallet* w, const zios_listener* l, char** err);

/* Node connection; uri NULL or "" disconnects. The caller checks the host allowlist. */
int zios_wallet_set_daemon(zios_wallet* w, const char* uri, const char* user, const char* pass, char** err);

/* Syncs from the wallet's own height. {"fetched":n,"receivedMoney":b,"height":n,
 * "daemonHeight":n,"daemonSynced":b}; heights are omitted when the node is unreachable. */
char* zios_wallet_sync(zios_wallet* w, char** err);

/* Interrupts a running sync. The ONE call that may run on another thread during a sync. */
void zios_wallet_stop_syncing(zios_wallet* w);

/* {"address","viewKey","viewOnly":b,"restoreHeight":n,"height":n} */
char* zios_wallet_info(zios_wallet* w, char** err);

/* Ensures at least min_count subaddresses of account 0 exist, then makes one more with label:
 * {"index":n,"address":"..."} */
char* zios_wallet_create_subaddress(zios_wallet* w, const char* label, int min_count, char** err);

/* {"total":{ZPH,ZSD,ZRS,ZYS},"unlocked":{...}} */
char* zios_wallet_balances(zios_wallet* w, char** err);

/* {"txs":[{hash,height|null,fee,timestamp,confirmations,confirmed,inPool,failed,locked,
 *          out:{asset,amount}|absent,in:[{asset,amount}]}],"viewOnly":bool} */
char* zios_wallet_tx_history(zios_wallet* w, char** err);

/* {"reserveRatio","reserveRatioMa","numStables","numReserves","hfVersion":n} */
char* zios_wallet_reserve_info(zios_wallet* w, char** err);

/* Two-step send, as the Android plugin's prepareTxs / relayPrepared / discardPrepared.
 *
 * zios_wallet_prepare_txs builds and signs WITHOUT broadcasting and keeps the result inside the
 * handle (replacing anything prepared before). In: the page's JSON {accountIndex,
 * destinations:[{address,amount(atomic string)}], sourceCurrency, destinationCurrency,
 * subaddressIndices?}; any other field (relay, fee, ...) is ignored. sweep != 0 spends all
 * unlocked sourceCurrency to the one destination (sends only, no amount). The built transactions
 * are checked: they must spend sourceCurrency and, for one destination, pay that address.
 * Out: {"fee","amount","count",["minted"]} (atomic strings; minted = incoming destinationCurrency
 * of a conversion). Refused for a view-only wallet.
 *
 * zios_wallet_relay_prepared broadcasts what was prepared and forgets it: {"txs":[{hash,fee}]}.
 * The caller enforces the send PIN (and the review timeout) before calling.
 * zios_wallet_discard_prepared forgets it without broadcasting. */
char* zios_wallet_prepare_txs(zios_wallet* w, const char* page_json, int sweep, char** err);
char* zios_wallet_relay_prepared(zios_wallet* w, char** err);
void zios_wallet_discard_prepared(zios_wallet* w);

/* Sets the restore height and rescans the chain from it with the stored keys (no seed needed);
 * also discards a prepared send. Needs a daemon. {"height":n} afterwards. */
char* zios_wallet_rescan(zios_wallet* w, uint64_t height, char** err);

/* Full address check (base58, network prefix, Keccak checksum). 1 valid, 0 invalid with
 * *reason set (free with zios_free). */
int zios_validate_address(const char* address, int network_type, char** reason);

#ifdef __cplusplus
}
#endif

#endif
