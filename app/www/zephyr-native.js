// zephyr-native.js
// index.html talks to its wallet through one small command protocol
// (_wCmd -> worker.postMessage -> _wOnMessage). This file answers that protocol with the
// native ZephyrWallet plugin (myzephyr-java) instead of a WASM Web Worker.
// Nothing else in index.html had to change. Loaded just before </body>.
(function () {
  'use strict';

  function plugin() {
    return window.Capacitor && window.Capacitor.Plugins && window.Capacitor.Plugins.ZephyrWallet;
  }

  // ONE native event listener for the whole life of the page. index.html re-creates its
  // "worker" after a wallet delete + import; a listener per worker would deliver every
  // balance event twice and double the deltas.
  var sink = null, listenerReady = null;
  function ensureListener(P) {
    if (!listenerReady) {
      listenerReady = P.addListener('wallet', function (ev) { if (sink) sink({ data: ev }); });
    }
    return listenerReady;
  }

  async function makeNativeWorker(onmessage) {
    var P = plugin();
    sink = onmessage;
    await ensureListener(P);

    // old worker command  ->  plugin call
    var calls = {
      loadWasm:    function ()  { return P.warmUp(); },
      openWallet:  function (m) {
        var addr = '';
        try { addr = (typeof W !== 'undefined' && W.wallet && W.wallet.address) || ''; } catch (e) {}
        return P.open({ config: m.config, expectAddress: addr });
      },
      setDaemon:   function (m) { return P.setDaemon({ url: m.url, user: m.user || '', pass: m.pass || '' }); },
      setListener: function ()  { return P.setListener(); },
      sync:        function (m) {
        var opts = {};
        if (m && typeof m.startHeight === 'number' && m.startHeight > 0) opts.startHeight = m.startHeight;
        return P.sync(opts);
      },
      stopSyncing: function ()  { return P.stopSyncing(); },
      createSubaddress: function (m) { return P.createSubaddress({ label: m.label || '', minCount: m.minCount || 0 }); },
      // Two-step send: build without broadcasting (exact fee), then broadcast after the PIN.
      prepareTxs:      function (m) { return P.prepareTxs({ txConfigJson: m.txConfigJson, nodeUrl: m.nodeUrl || '', sweep: !!m.sweep }); },
      relayPrepared:   function (m) { return P.relayPrepared({ token: m.token, nodeUrl: m.nodeUrl || '' }); },
      discardPrepared: function () { return P.discardPrepared(); },
      getTxHistory: function () { return P.getTxHistory(); },
      getBalances:  function () { return P.getBalances(); },
      rescanWallet: function (m) { return P.rescanWallet({ height: (m && m.height) || 0 }); },
      getReserveInfo: function () { return P.getReserveInfo(); },
      closeWallet: function ()  { return P.closeWallet(); }
    };

    var alive = true;
    return {
      postMessage: function (m) {
        var fn = calls[m.cmd];
        if (!alive || !fn) {
          onmessage({ data: { type: 'error', id: m.id, cmd: m.cmd, message: alive ? 'Unknown: ' + m.cmd : 'Wallet engine stopped' } });
          return;
        }
        Promise.resolve()
          .then(function () { return fn(m); })
          .then(
            function (res) { if (!alive) return; onmessage({ data: { type: 'result', id: m.id, cmd: m.cmd, data: res || { ok: true } } }); },
            function (e)   { if (!alive) return; onmessage({ data: { type: 'error',  id: m.id, cmd: m.cmd, message: (e && e.message) || String(e) } }); }
          );
      },
      // index.html calls terminate() when it drops the engine (delete wallet, or recovery).
      // Close the native wallet (it saves itself); "Delete wallet" additionally wipes the
      // stored data through Android.clearWalletCache().
      terminate: function () {
        alive = false;
        if (sink === onmessage) sink = null;
        try { P.closeWallet(); } catch (e) {}
      }
    };
  }

  // Address check in native code: base58 + network prefix + Keccak checksum (pure Java, no node).
  // Returns a promise of {valid, reason}, or null when the plugin is missing.
  window.__nativeValidateAddress = function (addr) {
    var P = plugin();
    if (!P || typeof P.validateAddress !== 'function') return null;
    return P.validateAddress({ address: String(addr || '') });
  };

  // Node requests (get_info, pings, tx status) go through Android's HTTP stack instead of the
  // WebView's XMLHttpRequest: no CORS, no mixed-content rules, no WebView hangs. index.html's
  // nativePost() calls this first; when it returns nothing (plugin missing) the old XHR path runs.
  window.__nativePost = function (url, body) {
    var P = plugin();
    if (!P || typeof P.httpPost !== 'function') return null;
    return P.httpPost({ url: url, body: JSON.stringify(body), timeoutMs: 12000 }).then(
      function (r) {
        var text = (r && r.body) || '';
        if (!text.trim()) throw new Error('Empty response from node — try a different node');
        try { return JSON.parse(text); }
        catch (e) { throw new Error('Node returned non-JSON: ' + text.slice(0, 80).replace(/\n/g, ' ')); }
      },
      function (e) {
        var m = (e && e.message) || '';
        throw new Error(/timeout/i.test(m) ? 'Node timed out — try a different node'
                                           : 'Network error — check connection or node URL');
      }
    );
  };

  // Wallet keys (create / restore from a seed phrase) and engine readiness: native zephyr-java,
  // replacing the old keys WASM. Each returns a promise, or null when the plugin is missing.
  var _ready = null;
  window.__nativeReady = function () {
    var P = plugin();
    if (!P) return Promise.reject(new Error('wallet plugin not found'));
    if (!_ready) {
      _ready = P.warmUp();
      _ready.catch(function () { _ready = null; });
    }
    return _ready;
  };
  window.__nativeKeys = {
    create: function () {
      var P = plugin();
      return P ? P.createKeys() : null;
    },
    restore: function (phrase) {
      var P = plugin();
      return P ? P.restoreKeys({ phrase: phrase }) : null;
    }
  };

  // Prices: USD per ZPH/ZSD/ZRS/ZYS from the node's oracle pricing record (zephyr-java), no web API.
  // Returns a promise, or null when the plugin is missing.
  window.__nativePrices = function (nodeUrl) {
    var P = plugin();
    if (!P || typeof P.getPrices !== 'function') return null;
    return P.getPrices({ nodeUrl: nodeUrl });
  };

  // index.html's _initWalletWorker() hands over to this (see there). Defined here, not by
  // overwriting index.html's function, so it works no matter which script runs first.
  window.__nativeInitWallet = async function () {
    try {
      if (!plugin()) throw new Error('wallet plugin not found');
      _walletWorker = await makeNativeWorker(_wOnMessage);   // globals from index.html
      await _wCmd('loadWasm', {});                           // -> native warmUp (loads libzephyr-java)
      _useWorker = true;
      console.log('[NATIVE] ZephyrWallet plugin active');
    } catch (e) {
      // Say what is wrong instead of silently falling back to an engine that is no longer shipped.
      console.error('[NATIVE] wallet engine failed to start:', e && e.message);
      try { toast('Wallet engine failed to start: ' + ((e && e.message) || e), 6000); } catch (_) {}
      throw e;
    }
  };
})();
