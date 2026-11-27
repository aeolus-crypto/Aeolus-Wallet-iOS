// Run: JSDOM_DIR=<path to jsdom> node csp_strict_test.js <www/index.html> <strict index.html> <aeolus-handlers.js> <aeolus-app.js>
// Behaviour test for csp_strict.py output: every compiled handler makes the same calls as the
// original inline code, and the run-time dispatcher allows only the four page shapes.
const fs = require('fs');
const { JSDOM } = require(process.env.JSDOM_DIR || 'jsdom');

const orig = fs.readFileSync(process.argv[2], 'utf8');      // pristine index.html
const strict = fs.readFileSync(process.argv[3], 'utf8');    // transformed index.html
const handlersJs = fs.readFileSync(process.argv[4], 'utf8');
const appJs = fs.readFileSync(process.argv[5], 'utf8');

const strip = (h) => h.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '');
let fails = 0, checks = 0;
const ok = (c, m) => { checks++; if (!c) { fails++; console.log('FAIL', m); } };

// app.js is exactly the page's inline script
const inline = orig.match(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/)[1];
ok(inline === appJs, 'aeolus-app.js equals the inline script');

// every global function the handlers call, as a logging stub
function stubWindow(win, log) {
  const names = new Set();
  const codes = [...orig.matchAll(/\son[a-z]+\s*=\s*"([^"]*)"/g)].map(m => m[1]);
  for (const c of codes) for (const m of c.matchAll(/(?<![\w.$])([A-Za-z_$][\w$]*)\s*\(/g)) names.add(m[1]);
  for (const n of ['if', 'function', 'var', 'return']) names.delete(n);
  for (const n of names) if (!(n in win)) win[n] = function () {
    log.push(n + '(' + [...arguments].map(a => a && a.nodeType ? '<' + (a.id || a.tagName) + '>' : (a && a.type ? 'Event' : JSON.stringify(a))).join(',') + ')');
  };
  win.copyTxidFromRow = function (e) { log.push('copyTxidFromRow(Event)'); e.stopPropagation(); };
  win.wipeWallet = function () { log.push('wipeWallet()'); };
}

// A) static handlers: compiled vs original inline code, element by element (same order of elements)
const A = new JSDOM(strip(orig), { runScripts: 'outside-only' });
const B = new JSDOM(strip(strict), { runScripts: 'outside-only' });
const logA = [], logB = [];
stubWindow(A.window, logA); stubWindow(B.window, logB);
B.window.eval(handlersJs);
const elsA = [...A.window.document.querySelectorAll('*')].filter(e => [...e.attributes].some(a => /^on/.test(a.name)));
const elsB = [...B.window.document.querySelectorAll('*')].filter(e => [...e.attributes].some(a => /^data-zh-/.test(a.name)));
ok(elsA.length === elsB.length && elsA.length > 100, `same number of handler elements (${elsA.length} / ${elsB.length})`);
for (let i = 0; i < elsA.length; i++) {
  for (const attr of [...elsA[i].attributes].filter(a => /^on/.test(a.name))) {
    const ev = attr.name.slice(2);
    logA.length = 0; logB.length = 0;
    try { A.window.Function('event', attr.value).call(elsA[i], new A.window.Event(ev)); } catch (e) { logA.push('THROW'); }
    try { elsB[i].dispatchEvent(new B.window.Event(ev, { bubbles: false })); } catch (e) { logB.push('THROW'); }
    const nA = logA.filter(x => x !== "THROW"), nB = logB.filter(x => x !== "THROW");
    ok(JSON.stringify(nA) === JSON.stringify(nB), `handler ${i} on${ev}="${attr.value}": ${JSON.stringify(logA)} vs ${JSON.stringify(logB)}`);
    ok(!elsB[i].hasAttribute('on' + ev), `handler ${i}: inline attribute removed`);
  }
}

// B) run-time markup: the four shapes work; anything else is ignored
const C = new JSDOM('<div id="box"></div>', { runScripts: 'outside-only' });
const logC = [];
stubWindow(C.window, logC);
C.window.eval(handlersJs);
const box = C.window.document.getElementById('box');
box.innerHTML =
  '<button id="f" onclick="selectFiat(\'EUR\')">EUR</button>' +
  '<button id="p" onclick="changeTxPage(-1)">prev</button>' +
  '<div class="tr" id="row" onclick="expandTx(this)"><span id="in">x</span>' +
  '<button id="cp" onclick="copyTxidFromRow(event)">copy</button></div>' +
  '<button id="bad1" onclick="wipeWallet()">x</button>' +
  '<button id="bad2" onclick="selectFiat(document.cookie)">x</button>' +
  '<button id="bad3" onclick="selectFiat(\'a\');wipeWallet()">x</button>';
const click = (id) => { logC.length = 0; C.window.document.getElementById(id).dispatchEvent(new C.window.MouseEvent('click', { bubbles: true })); return logC.join(' '); };
ok(click('f') === 'selectFiat("EUR")', 'selectFiat(\'EUR\')');
ok(click('p') === 'changeTxPage(-1)', 'changeTxPage(-1)');
ok(click('in') === 'expandTx(<row>)', 'click inside a row expands it (this = row): ' + logC.join(' '));
ok(click('cp') === 'copyTxidFromRow(Event)', 'copy button stops the row from toggling: ' + logC.join(' '));
ok(click('bad1') === '', 'a function outside the list is not called');
ok(click('bad2') === '', 'a non-literal argument is refused');
ok(click('bad3') === '', 'a second statement is refused');

console.log(`${checks - fails}/${checks} checks passed`);
process.exit(fails ? 1 : 0);
