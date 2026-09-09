// hydrogen: the launch-time rewrites of code-server's minified workbench.js.
//
//   1. editorActions — keep `editor/title` actions in the title bar when NO editor
//      is open. VS Code's EditorGroupView.createEditorActions() builds the
//      editor/title menu only when the group has an active editor pane; an empty
//      group returns nothing, so with workbench.editor.editorActionsLocation=titleBar
//      the agent-bar buttons (docs/features/ui/agent-bar.md) vanish the moment the
//      last tab closes. The empty-group branch is rewritten to build the SAME menu
//      against the group's own scoped context (and still re-fire when an editor
//      opens).
//   2. swStartup — never let startup hang on the PWA service worker. code-server's
//      CodeServerClient.startup() does `await navigator.serviceWorker.register(...)`
//      and only AFTER it returns does web.main create VS Code's BrowserWindow
//      contribution — the object that owns `window resize → layout()` (plus the
//      wheel/contextmenu/drop guards and the multi-window setTimeout shim). In
//      Hydrogen's WKWebView that register() can wedge forever (a /__cs/ registration
//      stuck in `installing`; every later register/unregister for the scope queues
//      behind it, and it survives app restarts) — the workbench then renders and
//      works but never re-lays out: "code-server doesn't resize" on fresh installs
//      (docs/features/workspace/embedded-editor.md, Kyle 2026-09-03). The await is
//      raced against a 3 s timer; the SW (PWA-only, a no-op fetch handler) still
//      registers in the background when it can.
//
// Idempotent (markers) and self-verifying; keeps a .orig of the pristine file.
//
// Cache bust: code-server serves workbench.js under /stable-<commit>/static/
// with max-age=1y and no ETag, so a patched file would never reach a client
// that already loaded the old one (Hydrogen's WKWebView included). The route
// prefix is product.json's `commit`, but the client bakes its own copy of the
// product literal into workbench.js and the websocket handshake refuses a
// client whose commit differs from the server's — so both are rewritten in
// lockstep to sha1(<original commit>:hydrogen:<BUST>). Bump BUST whenever the
// patch output changes; product.json remembers the generation and the pristine
// commit (`hydrogenCacheBust`, `hydrogenOrigCommit`).
//
// usage: node patch-workbench.cjs <workbench.js> [<product.json>]
// prints one line per step (already | CHANGED | NOMATCH) then a summary line:
//   CHANGED   — something was rewritten (restart code-server)
//   already   — nothing to do
//   NOMATCH   — code-server build no longer fits a regex/literal (exit 2; the
//               steps that did match are still written)
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const file = process.argv[2];
const productFile = process.argv[3] || path.resolve(path.dirname(file), '../../../../../product.json');
const MARK = '/*hydrogenEmptyGroupEditorActions*/';
const MARK_SW = '/*hydrogenSwStartupRace*/';
const BUST = 2; // 1 = editorActions; 2 = + swStartup
let src = fs.readFileSync(file, 'utf8');
const orig = src;
let nomatch = false;

// --- 1. empty-group editor actions -------------------------------------------
// createEditorActions(e){let t={primary:[],secondary:[]},s;const n=this.activeEditorPane;
//   if(n instanceof fd){const r=n.scopedContextKeyService??this.scopedContextKeyService,
//     o=e.add(this.Y.createMenu(x.EditorTitle,r,{emitEventsForSubmenuChanges:!0,eventDebounceDelay:0}));
//     s=o.onDidChange;const a=(l,c)=>c==="navigation"&&l.actions.length<=1;
//     t=kc(o.getActions({arg:this.D.get(),shouldForwardArgs:!0}),"navigation",a)}
//   else{const r=e.add(new E);s=r.event,e.add(this.onDidActiveEditorChange(()=>r.fire()))}
//   return{actions:t,onDidChange:s}}
// Every identifier is captured from the same match so a re-minified build still fits.
if (src.includes(MARK)) {
  console.log('editorActions: already');
} else {
  // ID = a minified identifier char (VS Code mangles some names to `$s`, `D`, …).
  const ID = '[\\w$]';
  // VS Code >= 1.135 (code-server >= 4.101): createEditorActions gained a
  // defaulted menu-id param (`(e,t=A.EditorTitle)`), a `let` (not `const`) body,
  // an inline reopen-with block, and readable member names (menuService,
  // resourceContext). Named groups so the two builds don't fight over positions.
  const re135 = new RegExp(
    'createEditorActions\\((?<e>\\w+),(?<menuId>\\w+)=(?<menuConst>\\w+\\.EditorTitle)\\)\\{' +
    'let (?<acts>\\w+)=\\{primary:\\[\\],secondary:\\[\\]\\},(?<sig>\\w+),(?<pane>\\w+)=this\\.activeEditorPane;' +
    'if\\(\\k<pane> instanceof ' + ID + '+\\)\\{' +
    'let (?<svc>\\w+)=\\k<pane>\\.scopedContextKeyService\\?\\?this\\.scopedContextKeyService,' +
    '(?<menuVar>\\w+)=\\k<e>\\.add\\(this\\.(?<menuSvc>\\w+)\\.createMenu\\(\\k<menuId>,\\k<svc>,(?<opts>\\{[^}]*\\})\\)\\);' +
    '\\k<sig>=\\k<menuVar>\\.onDidChange;let (?<pred>\\w+)=(?<predExpr>\\([^)]*\\)=>[^;]+);' +
    'if\\(\\k<acts>=(?<fill>\\w+)\\(\\k<menuVar>\\.getActions\\((?<getOpts>\\{[^}]*\\})\\),"navigation",\\k<pred>\\),\\k<menuId>===\\k<menuConst>\\)\\{' +
    '.*?\\}\\}' +
    'else\\{let (?<ev>\\w+)=\\k<e>\\.add\\(new (?<emitter>' + ID + '+)\\);\\k<sig>=\\k<ev>\\.event,' +
    '\\k<e>\\.add\\(this\\.onDidActiveEditorChange\\(\\(\\)=>\\k<ev>\\.fire\\(\\)\\)\\)\\}'
  );
  // VS Code 1.100 (code-server 4.100.x): the original shape.
  const re100 = new RegExp(
    'createEditorActions\\((\\w+)\\)\\{let (\\w+)=\\{primary:\\[\\],secondary:\\[\\]\\},(\\w+);' +
    'const (\\w+)=this\\.activeEditorPane;if\\(\\4 instanceof \\w+\\)\\{' +
    'const (\\w+)=\\4\\.scopedContextKeyService\\?\\?this\\.scopedContextKeyService,' +
    '(\\w+)=\\1\\.add\\(this\\.(\\w+)\\.createMenu\\((\\w+)\\.EditorTitle,\\5,(\\{[^}]*\\})\\)\\);' +
    '\\3=\\6\\.onDidChange;const (\\w+)=(\\([^)]*\\)=>[^;]+);' +
    '\\2=(\\w+)\\(\\6\\.getActions\\(\\{arg:this\\.\\w+\\.get\\(\\),shouldForwardArgs:!0\\}\\),"navigation",\\10\\)\\}' +
    'else\\{const (\\w+)=\\1\\.add\\(new (\\w+)\\);\\3=\\13\\.event,\\1\\.add\\(this\\.onDidActiveEditorChange\\(\\(\\)=>\\13\\.fire\\(\\)\\)\\)\\}'
  );
  const m135 = src.match(re135);
  if (m135) {
    const g = m135.groups;
    // Rebuild the empty-group ELSE so it constructs the SAME EditorTitle menu
    // against the workbench's scoped context, re-firing on menu + editor change.
    const elseNew =
      `else{${MARK}let ${g.ev}=${g.e}.add(new ${g.emitter});${g.sig}=${g.ev}.event;` +
      `let o=${g.e}.add(this.${g.menuSvc}.createMenu(${g.menuId},this.scopedContextKeyService,${g.opts}));` +
      `${g.e}.add(o.onDidChange(()=>${g.ev}.fire()));${g.e}.add(this.onDidActiveEditorChange(()=>${g.ev}.fire()));` +
      `${g.acts}=${g.fill}(o.getActions({shouldForwardArgs:!0,renderShortTitle:!0}),"navigation",${g.pred})}`;
    const whole = m135[0];
    const elseOld = whole.slice(whole.indexOf('else{'));
    src = src.replace(whole, whole.replace(elseOld, elseNew));
    console.log('editorActions: CHANGED (v1.135)');
  } else {
    const m = src.match(re100);
    if (!m) {
      console.log('editorActions: NOMATCH'); nomatch = true;
    } else {
      const [whole, e, t, s, , , , svc, menuId, opts, , pred, fill, r, emitter] = m;
      const elseNew =
        `else{${MARK}const ${r}=${e}.add(new ${emitter});${s}=${r}.event;` +
        `const o=${e}.add(this.${svc}.createMenu(${menuId}.EditorTitle,this.scopedContextKeyService,${opts}));` +
        `${e}.add(o.onDidChange(()=>${r}.fire()));${e}.add(this.onDidActiveEditorChange(()=>${r}.fire()));` +
        `${t}=${fill}(o.getActions({shouldForwardArgs:!0}),"navigation",${pred})}`;
      const elseOld = whole.slice(whole.indexOf('else{'));
      src = src.replace(whole, whole.replace(elseOld, elseNew));
      console.log('editorActions: CHANGED (v1.100)');
    }
  }
}

// --- 2. service-worker startup race -------------------------------------------
// code-server's CodeServerClient.startup() ends with
//   this.c.serviceWorker&&await this.j(this.c.serviceWorker)
// (`j` = navigator.serviceWorker.register wrapped in try/catch). Both member
// names are captured; the config member must be the same on both sides.
if (src.includes(MARK_SW)) {
  console.log('swStartup: already');
} else {
  const re = /this\.(\w+)\.serviceWorker&&await this\.(\w+)\(this\.\1\.serviceWorker\)/g;
  const hits = src.match(re) || [];
  if (hits.length !== 1) {
    console.log(`swStartup: NOMATCH (${hits.length} sites)`); nomatch = true;
  } else {
    src = src.replace(re, (whole, cfg, fn) =>
      `${MARK_SW}this.${cfg}.serviceWorker&&await Promise.race([this.${fn}(this.${cfg}.serviceWorker),new Promise(r=>setTimeout(r,3e3))])`);
    console.log('swStartup: CHANGED');
  }
}

// --- 3. cache bust (product.json + baked client literal, in lockstep) ---------
const product = JSON.parse(fs.readFileSync(productFile, 'utf8'));
if (product.hydrogenCacheBust === BUST) {
  console.log('cacheBust: already');
} else if (!/^[0-9a-f]{40}$/.test(product.commit || '')) {
  console.log('cacheBust: NOMATCH'); nomatch = true;
} else {
  const cur = product.commit;
  const origCommit = product.hydrogenOrigCommit || cur;
  const next = crypto.createHash('sha1').update(`${origCommit}:hydrogen:${BUST}`).digest('hex');
  const lit = `commit:"${cur}"`;
  if (src.split(lit).length !== 2) {
    console.log('cacheBust: NOMATCH'); nomatch = true;
  } else {
    src = src.replace(lit, `commit:"${next}"`);
    product.commit = next;
    product.hydrogenOrigCommit = origCommit;
    product.hydrogenCacheBust = BUST;
    fs.writeFileSync(productFile, JSON.stringify(product, null, 2) + '\n');
    console.log(`cacheBust: CHANGED (${cur.slice(0, 8)} -> ${next.slice(0, 8)})`);
  }
}

if (src !== orig) {
  if (!fs.existsSync(file + '.orig')) fs.copyFileSync(file, file + '.orig');
  fs.writeFileSync(file, src);
}
// Summary line LAST so callers can key on it; NOMATCH (exit 2) still reports
// CHANGED when another step wrote (the caller must restart code-server then too).
if (nomatch) console.log('NOMATCH');
console.log(src === orig ? 'already' : 'CHANGED');
process.exit(nomatch ? 2 : 0);
