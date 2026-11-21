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

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zios_wallet zios_wallet;

/* Version of the engine and of the pinned sources it was built from (static string). */
const char* zios_version(void);

void zios_free(char* s);

/* Creates a wallet from a zephyr-cpp monero_wallet_config JSON object, the same JSON that
 * zephyr-java's ZephyrWalletFull.createWallet passes to the core: path, password,
 * networkType (0 mainnet, 1 testnet, 2 stagenet), language, mnemonic, seedOffset,
 * primaryAddress, privateViewKey, privateSpendKey, restoreHeight, serverUri, ... */
zios_wallet* zios_wallet_create(const char* config_json, char** err);

/* Opens a wallet's files at path (path and path.keys). */
zios_wallet* zios_wallet_open(const char* path, const char* password, int network_type, char** err);

char* zios_wallet_primary_address(zios_wallet* w, char** err);
char* zios_wallet_mnemonic(zios_wallet* w, char** err);

/* Saves (when save != 0) and closes the wallet, then frees it. Returns 0, or -1 on failure
 * (the wallet is freed either way). */
int zios_wallet_close(zios_wallet* w, int save, char** err);

#ifdef __cplusplus
}
#endif

#endif
