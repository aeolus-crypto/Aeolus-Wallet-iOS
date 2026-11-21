# Test fixtures

`linux-x86_64/` is a throwaway Zephyr mainnet wallet created by `zios_smoke --make-fixture` on
Linux x86_64 (zephyr v2.3.0 + zephyr-cpp, Boost 1.83). Its password is `fixture-pw` and it is
public: **never send funds to its address.** The simulator test opens it to check that a wallet
made on another platform loads on iOS.
