#!/usr/bin/env bash

# Put this file in CONTAINER_PATCHES (for example, /data/container_patches).
# foundryvtt-docker sources patch scripts after Foundry and its modules are
# installed and before Foundry is started.
# A matching module with changed semantic bundle anchors fails closed so it
# cannot run while silently missing the S3/WebM behavior.

tokenizer_2_s3_webm_patch() {
  local data_dir="${FOUNDRY_DATA_PATH:-/data}"
  local module_dir=""
  local candidate

  for candidate in \
    "${data_dir}/modules/tokenizer-2" \
    "/data/Data/modules/tokenizer-2" \
    "/data/modules/tokenizer-2"
  do
    if [[ -f "${candidate}/module.json" && -f "${candidate}/dist/main.js" ]]; then
      module_dir="${candidate}"
      break
    fi
  done

  if [[ -z "${module_dir}" ]]; then
    echo "[tokenizer-2-s3-webm] tokenizer-2 is not installed; skipping" >&2
    return 0
  fi

  local version
  if ! version="$(node -e 'const fs=require("fs"); const p=process.argv[1]; process.stdout.write(String(JSON.parse(fs.readFileSync(p,"utf8")).version??""));' "${module_dir}/module.json")"; then
    echo "[tokenizer-2-s3-webm] could not read ${module_dir}/module.json; skipping" >&2
    return 0
  fi
  if ! node -e 'const v=process.argv[1]??""; const m=/^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/.exec(v); process.exit(m && Number(m[1]) >= 3 ? 0 : 1);' "${version}"; then
    echo "[tokenizer-2-s3-webm] unsupported tokenizer-2 version ${version}; expected >= 3.0.0, skipping" >&2
    return 0
  fi

  # The embedded transformer discovers module boundaries and exported helpers
  # from stable symbols rather than relying on minified IDs or import aliases.
  local main_js="${module_dir}/dist/main.js"
  local patch_output
  if patch_output="$(node - "${main_js}" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
if (!path) throw new Error('usage: patcher.js <main.js>');
let source = fs.readFileSync(path, 'utf8');
const marker = '/* tokenizer-2-s3-webm-patch:>=3.0.0 */';
if (/\/\* tokenizer-2-s3-webm-patch:[^*]+\*\//.test(source)) { console.log('already patched'); process.exit(0); }
let changes = 0;

function moduleList() {
  const re = /},([A-Za-z_$][\w$]*|\d+)\([A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*,[A-Za-z_$][\w$]*\)\{/g;
  const starts = [];
  let match;
  while ((match = re.exec(source))) starts.push({ key: match[1], start: match.index, bodyStart: re.lastIndex });
  return starts.map((item, index) => ({ ...item, bodyEnd: index + 1 < starts.length ? starts[index + 1].start : source.length }));
}
function moduleBy(label, anchor) {
  const found = moduleList().filter(({bodyStart, bodyEnd}) => source.slice(bodyStart, bodyEnd).includes(anchor));
  if (found.length !== 1) throw new Error(`${label}: expected one module containing ${anchor}, found ${found.length}`);
  return found[0];
}
function mutateModule(label, anchor, mutate) {
  const item = moduleBy(label, anchor);
  const body = source.slice(item.bodyStart, item.bodyEnd);
  const next = mutate(body);
  if (next === body) throw new Error(`${label}: made no change`);
  source = source.slice(0, item.bodyStart) + next + source.slice(item.bodyEnd);
  changes++;
  return next;
}
function replaceOnce(text, label, old, replacement) {
  const count = text.split(old).length - 1;
  if (count !== 1) throw new Error(`${label}: expected one match, found ${count}`);
  return text.replace(old, () => replacement);
}
function regexOnce(text, label, re, replacement) {
  const flags = re.flags.includes('g') ? re.flags : `${re.flags}g`;
  const global = new RegExp(re.source, flags);
  const matches = [...text.matchAll(global)];
  if (matches.length !== 1) throw new Error(`${label}: expected one match, found ${matches.length}`);
  return text.replace(re, (...args) => typeof replacement === 'function' ? replacement(...args) : replacement);
}
function moduleKeyLiteral(key) { return /^\d+$/.test(key) ? key : JSON.stringify(key); }
const dependencyAliases = new Map();
let dependencyNumber = 0;
function exportMember(body, symbol, label) {
  const declarations = [...body.matchAll(/m\.d\(l,\{([\s\S]*?)\}\);/g)];
  for (const declaration of declarations) {
    const entries = [...declaration[1].matchAll(/([A-Za-z_$][\w$]*):\(\)=>\s*([A-Za-z_$][\w$]*)/g)];
    const exact = entries.find(([, key, target]) => target === symbol);
    if (exact) return exact[1];
    const named = entries.find(([, key]) => key === symbol);
    if (named) return named[1];
    if (symbol === 'PluginRegistry') {
      const variable = body.match(new RegExp(`(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*new class ${symbol}\\b`))?.[1];
      const byVariable = entries.find(([, key, target]) => target === variable);
      if (byVariable) return byVariable[1];
    }
  }
  throw new Error(`${label}: could not discover export for ${symbol}`);
}
function dependency(targetAnchor, depAnchor, symbol, label) {
  const target = moduleBy(`${label} target`, targetAnchor);
  const dep = moduleBy(`${label} dependency`, depAnchor);
  const cacheKey = `${target.key}|${dep.key}|${symbol}`;
  const existing = dependencyAliases.get(cacheKey);
  const member = exportMember(source.slice(dep.bodyStart, dep.bodyEnd), symbol, label);
  if (existing) return `${existing}.${member}`;
  let alias;
  do alias = `__t2d${dependencyNumber++}`; while (source.slice(target.bodyStart, target.bodyEnd).includes(alias));
  const body = source.slice(target.bodyStart, target.bodyEnd);
  source = source.slice(0, target.bodyStart) + `var ${alias}=m(${moduleKeyLiteral(dep.key)});` + body + source.slice(target.bodyEnd);
  dependencyAliases.set(cacheKey, alias);
  changes++;
  return `${alias}.${member}`;
}
function dep(target, anchor, symbol, label) {
  return dependency(target, anchor, symbol, label);
}
function call(ref, args) { return `(0,${ref})(${args})`; }

// Stable module boundaries and export names are discovered from semantic symbols.
const storageFor = (target, label='storage') => dep(target, 'class StorageHelper', 'StorageHelper', label);
// StorageHelper: accept Foundry's bracket notation and canonical S3 URLs, and expose
// document/storage conversions used by the rest of the bundle.
mutateModule('storage parse', 'class StorageHelper', body => regexOnce(body, 'storage parse', /static parse\(n=""\)\{.*?\}static format/s,
  `static parse(n=""){const l=String(n).trim(),m=l.match(/^\\[([^\\]]+)\\]\\s*(.*)/);if(m){const[,n,l]=m,[p,g]=n.split(":");return{activeSource:p,bucket:g??null,current:StorageHelper.decodePath(l.trim())}}if(/^https?:\\/\\//i.test(l))try{const n=new URL(l),p=game.data?.files?.s3?.endpoint?.hostname??"s3.amazonaws.com",g=p?"."+p:"";if(g&&n.hostname.endsWith(g))return{activeSource:"s3",bucket:n.hostname.slice(0,-g.length),current:StorageHelper.decodePath(n.pathname.replace(/^\\/+/,""))};if(p&&n.hostname===p){const l=n.pathname.replace(/^\\/+/,""),[m,g]=l.split(/\\/(.*)/s);if(m&&g)return{activeSource:"s3",bucket:m,current:StorageHelper.decodePath(g)}}}catch{}return{activeSource:"data",bucket:null,current:StorageHelper.decodePath(l)}}static format`));
mutateModule('storage upload return', 'class StorageHelper', body => replaceOnce(body, 'storage upload return',
  'if("string"!=typeof y?.path)throw new Error(`upload to ${m.current} failed`);return y.path',
  'if("string"!=typeof y?.path)throw new Error(`upload to ${m.current} failed`);const b=y.path;return"data"!==m.activeSource&&!/^\\[[^\\]]+\\]\\s*/.test(b)&&!/^[a-z][a-z0-9+.-]*:\\/\\//i.test(b)?StorageHelper.format({...m,path:b.replace(/^\\/+/,"")}):b'));
mutateModule('storage helper methods', 'class StorageHelper', body => replaceOnce(body, 'storage helper methods',
  'return encodeURI(g)}}',
  'return encodeURI(g)}static toDocumentPath(n){const l=String(n??"");if(/^[a-z][a-z0-9+.-]*:\\/\\//i.test(l))return l;const m=StorageHelper.parse(l);if("data"===m.activeSource||"public"===m.activeSource)return m.current;if("s3"===m.activeSource&&m.bucket){const n=game.data?.files?.s3?.endpoint?.hostname??"s3.amazonaws.com";return encodeURI("https://"+m.bucket+"."+n+"/"+m.current)}if("forgevtt"===m.activeSource&&"undefined"!=typeof ForgeVTT&&ForgeVTT?.usingTheForge){const n=ForgeAPI.lastStatus?.user;if(n)return encodeURI("https://assets.forge-vtt.com/"+n+"/"+m.current)}return l}static toStoragePath(n){const l=String(n??"");if(/^https?:\\/\\//i.test(l)){const m=StorageHelper.parse(l);return"data"===m.activeSource?l:StorageHelper.format(m)}const m=StorageHelper.parse(l);return"data"===m.activeSource?m.current:StorageHelper.format(m)}}'));

// New-set defaults are rebuilt from the stable function boundary, while all imports
// are discovered by exported semantics rather than bundle IDs or local aliases.
const nsStorage = storageFor('function newSetDefaults', 'new-set storage');
const nsActor = dep('function newSetDefaults', 'function prototypeActorOf', 'prototypeActorOf', 'new-set actor');
const nsSettings = dep('function newSetDefaults', 'function getSetting', 'getSetting', 'new-set settings');
const nsFormat = dep('function newSetDefaults', 'function resolveSaveTarget', 'resolveSaveTarget', 'new-set format');
const nsVideo = dep('function newSetDefaults', 'function isVideoSource', 'isVideoSource', 'new-set video');
const nsAnimated = dep('function newSetDefaults', 'function hasAnimatedContent', 'hasAnimatedContent', 'new-set animated');
const nsEncoder = dependency('function newSetDefaults', 'class PluginRegistry', 'PluginRegistry', 'new-set encoder');
const nsWild = dep('function newSetDefaults', 'function wildcardWhere', 'wildcardWhere', 'new-set wildcard');
const nsMayChange = dep('function newSetDefaults', 'function mayChangeWildcard', 'mayChangeWildcard', 'new-set random');
const nsFlags = dep('function newSetDefaults', 'const p="tokenizer-2"', 'Do', 'new-set flags');
const nsFlagObject = dep('function newSetDefaults', 'const p="tokenizer-2"', 'Wg', 'new-set flag object');
const nsSafe = dep('function newSetDefaults', 'function sanitizeFilename', 'sanitizeFilename', 'new-set filename');
const nsVariants = {
  Rb: dep('function newSetDefaults', 'function readSetList', 'readSetList', 'new-set set list'),
};
const nsKeep = dep('function newSetDefaults', 'function keepableTokenImage', 'keepableTokenImage', 'new-set keepable');
const nsSources = dep('function newSetDefaults', 'function setSources', 'setSources', 'new-set sources');
const nsPC = dep('function newSetDefaults', 'function isPCActor', 'isPCActor', 'new-set actor type');
mutateModule('newSetDefaults', 'function newSetDefaults', body => regexOnce(body, 'newSetDefaults', /async function newSetDefaults\(n\)\{.*?\}async function browseSetFolder/s,
`async function newSetDefaults(n){const{actor:l,token:m}=n,M=${call(nsActor, 'm,l')}??l,E=${nsEncoder}.getEncoder(${call(nsSettings, '"animation-encoder"')})??${nsEncoder}.getEncoder("webm"),F=m?.texture?.src??m?.document?.texture?.src??"",C=(n.layerManager?${call(nsAnimated,'n.layerManager.layers??[]')}:n.layers?${call(nsAnimated,'n.layers')}:${call(nsVideo,'F') }&&!/\\.gif$/i.test(String(F).split(/[?#]/)[0]))?E&&E.isAvailable&&!E.isAvailable()?${call(nsSettings,'"export-format"')}:E?.extension??${call(nsSettings,'"export-format"')}:${call(nsSettings,'"export-format"')},I=${call(nsMayChange,'m??null')},P=await${call(nsFormat,'{kind:"token",actor:l,extension:C}')},D=${call(nsSafe,'l?.name')}.toLowerCase()||"token",pathOf=n=>{const l=${nsStorage}.parse(n??"");return l.activeSource+":"+(l.bucket??"")+":"+l.current.replace(/\\/+$/,"")},z=new Set(${call(nsVariants.Rb,`${call(nsActor,'M') }?.getFlag?.(${nsFlags},${nsFlagObject}.WILDCARD_SETS)`)}.map(n=>pathOf(n.folder)));for(const l of[${call(nsWild,'M')},n.imageSet,n.wildcard?.where])l&&z.add(pathOf(l.folder));const B=${call(nsKeep,'M,m')},${'__t2set'}=${call(nsSettings,'"wildcard-set-location"')};const{activeSource:sourceName,bucket:bucketName,current:q}=${nsStorage}.parse(${ '__t2set'}??""),H=q.trim().replace(/\\/+$/,"");const O=H?"data"===sourceName?H+"/"+(${call(nsPC,'l')}?"pc":"npc"):${nsStorage}.format({activeSource:sourceName,bucket:bucketName,path:H+"/"+(${call(nsPC,'l')}?"pc":"npc")}):P.folder;let setNumber=1,setFolder=O+"/"+D;for(;z.has(pathOf(setFolder));)setNumber+=1,setFolder=O+"/"+D+"-"+setNumber;return{name:setNumber>1?game.i18n.format("TOKENIZER-2.Wildcard.SecondSetName",{name:l?.name??"",number:setNumber}):l?.name??"",folder:setFolder,pattern:D+"-*"+"."+C,canKeep:!!B,keepSrc:B,unsaved:!!n.unsaved,canRandom:I,random:I&&(!!n.isWildcard||!n.imageSet&&!${call(nsPC,'l')}),ext:C,sources:${call(nsSources,'M')}.flatMap(({actor:n,sets:l})=>l.map(l=>({actor:n,where:l.where,name:l.name,own:n===M})))}}async function browseSetFolder`));

// Set manager: browse the current storage path, normalize document URLs, and pass
// the FilePicker source metadata to set-image insertion.
const smStorage = storageFor('class SetManagerApp', 'set-manager storage');
const smVariants = {
  LQ: dep('class SetManagerApp', 'function variantRows', 'variantRows', 'set-manager rows'),
  SF: dep('class SetManagerApp', 'function findVariantFiles', 'findVariantFiles', 'set-manager files'),
  jG: dep('class SetManagerApp', 'function setProblems', 'setProblems', 'set-manager problems'),
  uJ: dep('class SetManagerApp', 'function joinPath', 'joinPath', 'set-manager join'),
  zu: dep('class SetManagerApp', 'function shownImage', 'shownImage', 'set-manager shown'),
  uz: dep('class SetManagerApp', 'function copyIntoSet', 'copyIntoSet', 'set-manager copy'),
};
mutateModule('set-manager rows', 'class SetManagerApp', body => regexOnce(body, 'set-manager rows', /this\._rows=\(0,[A-Za-z_$][\w$]*\.LQ\)\(y\.set,await\(0,[A-Za-z_$][\w$]*\.SF\)\(y\.where,y\.set\),y\.where\);let [A-Za-z_$][\w$]*=null;try\{.*?\}catch\{[A-Za-z_$][\w$]*=null\}/s,
`const P=await${call(smVariants.SF,'y.where,y.set')};this._rows=${call(smVariants.LQ,'y.set,P,y.where')};let A=null;try{const{current:F}=${smStorage}.parse(C);A=(await${smStorage}.browse(C,${call(smVariants.uJ,'F,"*"')},{wildcard:!0}))?.files??null}catch{A=null}`));
mutateModule('set-manager problems files', 'class SetManagerApp', body => regexOnce(body, 'set-manager problems files', /const D=\(0,[A-Za-z_$][\w$]*\.jG\)\(y\.set,P,I\),/, `const D=${call(smVariants.jG,'y.set,A,I')},`));
mutateModule('set-manager document comparisons', 'class SetManagerApp', body => regexOnce(body, 'set-manager document comparisons', /isPortrait:n\.path===z,isDefault:n\.path===\$\,onScene:\(l=n\.path,B\.filter\(n=>\(0,[A-Za-z_$][\w$]*\.zu\)\(n\)===l\)\.length\)/,
`isPortrait:${smStorage}.toDocumentPath(n.path)===z,isDefault:${smStorage}.toDocumentPath(n.path)===$,onScene:(l=${smStorage}.toDocumentPath(n.path),B.filter(n=>${call(smVariants.zu,'n')}===l).length)`));
mutateModule('set-manager add image callback', 'class SetManagerApp', body => regexOnce(body, 'set-manager add image callback', /callback:async [A-Za-z_$][\w$]*=>\{try\{const [A-Za-z_$][\w$]*=await\(0,[A-Za-z_$][\w$]*\.uz\)\(n,[A-Za-z_$][\w$]*,this\.holder\);/, `callback:async(l,m)=>{try{const p=m?.activeSource??"data",g="data"===p?l:${smStorage}.format({activeSource:p,bucket:"s3"===p?m.sources?.s3?.bucket??null:null,path:l}),y=await${call(smVariants.uz,'n,g,this.holder')};`));

// Variant batch: video files are valid sources and video layers remain video layers.
const vbVideo = dep('class VariantBatchApp', 'function isVideoSource', 'isVideoSource', 'variant-batch video');
mutateModule('variant batch extension list', 'class VariantBatchApp', body => regexOnce(body, 'variant batch extension list', /const ([A-Za-z_$][\w$]*)=\/\\\.\(webp\|png\|jpe\?g\|avif\|gif\|bmp\|svg\)\$\/i;/, (_, name) => `const ${name}=/\\.(webp|png|jpe?g|avif|gif|bmp|svg|webm|mp4|m4v|mov|ogv)$/i;`));
mutateModule('variant batch video filter', 'class VariantBatchApp', body => replaceOnce(body, 'variant batch video filter', '||n.isVideo||n.isFrame', '||n.isFrame'));
mutateModule('variant batch design video flag', 'class VariantBatchApp', body => replaceOnce(body, 'variant batch design video flag', 'g.src=m,g.isVideo=!1,g.paintMask', `g.src=m,g.isVideo=${call(vbVideo,'m')},g.paintMask`));

// Thumbnail URLs, variant metadata, and wildcard storage access.
const thumbAnchor = 'function variantSrc(n){return n.savedAt?';
const thumbStorage = storageFor(thumbAnchor, 'thumbnail storage');
mutateModule('thumbnail source', thumbAnchor, body => replaceOnce(body, 'thumbnail source', 'function variantSrc(n){return n.savedAt?`${n.path}?v=${n.savedAt}`:n.path}', `function variantSrc(n){return ${thumbStorage}.toDocumentPath(n.savedAt?\`\${n.path}?v=\${n.savedAt}\`:n.path)}`));
mutateModule('variant rows', 'function variantRows', body => regexOnce(body, 'variant rows', /function variantRows\(n,l,\{folder:m,pattern:p\}\)\{.*?\}function variantLabel/s,
`function variantRows(n,l,{folder:m,pattern:p}){const w=anyFormatPattern(p),_=w.replace(/\\.\*$/, ""),g=l?l.map(baseName).filter(n=>matchesPattern(n,w)):Object.keys(n?.variants??{});return[...new Set(g)].map(l=>{const g=n?.variants?.[l];return{file:l,path:joinPath(m,l),number:variantNumber(l,_),label:g?.label??"",hasDesign:!!g?.design,savedAt:g?.savedAt??0,transition:g?.transition??null}}).sort((n,l)=>(n.number??1/0)-(l.number??1/0)||n.file.localeCompare(l.file))}function variantLabel`));

const wcStorage = storageFor('function wildcardWhere', 'wildcard storage');
const wcVariants = {
  an: dep('function wildcardWhere', 'function variantRows', 'splitWildcardPath', 'wildcard split'),
  c1: dep('function wildcardWhere', 'function variantRows', 'anyFormatPattern', 'wildcard pattern'),
  Rb: dep('function wildcardWhere', 'function readSetList', 'readSetList', 'wildcard set list'),
  MT: dep('function wildcardWhere', 'function matchesPattern', 'matchesPattern', 'wildcard matches'),
  Fl: dep('function wildcardWhere', 'function baseName', 'baseName', 'wildcard basename'),
  uJ: dep('function wildcardWhere', 'function joinPath', 'joinPath', 'wildcard join'),
  Lo: dep('function wildcardWhere', 'variantNumber', 'variantNumber', 'wildcard number'),
  Xe: dep('function wildcardWhere', 'function variantFilename', 'variantFilename', 'wildcard filename'),
};
const wcSettings = dep('function wildcardWhere', 'function getSetting', 'getSetting', 'wildcard settings');
const wcFlags = dep('function wildcardWhere', 'const p="tokenizer-2"', 'Do', 'wildcard flags');
const wcFlagObject = dep('function wildcardWhere', 'const p="tokenizer-2"', 'Wg', 'wildcard flag object');
const wcPC = dep('function wildcardWhere', 'function isPCActor', 'isPCActor', 'wildcard actor type');
mutateModule('wildcard import and helpers', 'function wildcardWhere', body => regexOnce(body, 'wildcard helpers', /function mayChangeWildcard\(n=null\)\{return!n\|\|!!n\.actorLink\}/,
  `function mayChangeWildcard(n=null){return!n||!!n.actorLink}function storageCurrent(n){return ${wcStorage}.parse(n??"").current.replace(/\\/+$/,"")}function storageTarget(n,l=""){const m=storageCurrent(n);return m?l?m+"/"+l:m:l}function storagePath(n,l=""){const m=${wcStorage}.parse(n??""),p=storageTarget(n,l);return"data"===m.activeSource?p:${wcStorage}.format({...m,path:p})}async function storageURL(n){return/^[a-z][a-z0-9+.-]*:\\/\\//i.test(String(n??""))?n:await ${wcStorage}.getFileUrl(n)}`));
mutateModule('wildcard where storage path', 'function wildcardWhere', body => regexOnce(body, 'wildcard where storage path', /const l=\(0,[A-Za-z_$][\w$]*\.an\)\(n\.prototypeToken\.texture\?\.src\);/, `const l=${call(wcVariants.an,`${wcStorage}.toStoragePath(n.prototypeToken.texture?.src)`) };`));
mutateModule('wildcard set image source', 'function setOfImage', body => regexOnce(body, 'wildcard set image source', /const\{folder:[A-Za-z_$][\w$]*\}=\(0,[A-Za-z_$][\w$]*\.an\)\(l\),[A-Za-z_$][\w$]*=\(0,[A-Za-z_$][\w$]*\.Rb\)\(n\?\.getFlag\?\.\([^)]*\)\)\.find\(n=>n\.pattern&&n\.folder===[A-Za-z_$][\w$]*&&\(0,[A-Za-z_$][\w$]*\.MT\)\(l,\(0,[A-Za-z_$][\w$]*\.c1\)\(n\.pattern\)\)\);/,
`const M=${wcStorage}.toStoragePath(l),{folder:m}=${call(wcVariants.an,'M')},g=${call(wcVariants.Rb,`n?.getFlag?.(${wcFlags},${wcFlagObject}.WILDCARD_SETS)`)}.find(n=>n.pattern&&n.folder===m&&${call(wcVariants.MT,`M,${call(wcVariants.c1,'n.pattern')}`)});`));
mutateModule('set image design source', 'function setImageDesign', body => replaceOnce(body, 'set image design source', 'const m=String(l??"").split("?")[0];', `const m=${wcStorage}.toStoragePath(String(l??"")).split("?")[0];`));
mutateModule('browse files path', 'function browseFiles', body => regexOnce(body, 'browse files path', /const [A-Za-z_$][\w$]*=await [A-Za-z_$][\w$]*\.StorageHelper\.browse\(n,\(0,[A-Za-z_$][\w$]*\.uJ\)\(n,l\),\{wildcard:!0\}\);/, `const m=await${wcStorage}.browse(n,storageTarget(n,l),{wildcard:!0});`));
mutateModule('read set file fetch', 'function readSetFile', body => regexOnce(body, 'read set file fetch', /async function readSetFile\(n\)\{try\{const [A-Za-z_$][\w$]*=await fetch\(`\$\{n\}\$\{n\.includes\("\?"\)\?"&":"\?"\}t=\$\{Date\.now\(\)\}`,\{cache:"no-store"\}\);/, 'async function readSetFile(n){try{const __t2Url=await storageURL(n),__t2RequestUrl=`${__t2Url}${__t2Url.includes("?")?"&":"?"}t=${Date.now()}`,l=await fetch(__t2RequestUrl,{cache:"no-store"});'));
mutateModule('set folder for', 'function setFolderFor', body => regexOnce(body, 'set folder for', /function setFolderFor\(n\)\{.*?\}async function folderMissing/s,
`function setFolderFor(n){const l=${wcSettings}("wildcard-set-location"),m=storageCurrent(l);return m?storagePath(l,${call(wcPC,'n')}?"pc":"npc"):${wcSettings}("wildcard-set-location")}async function folderMissing`));
mutateModule('folder missing', 'function folderMissing', body => regexOnce(body, 'folder missing', /async function folderMissing\(n\)\{.*?\}async function listSetFiles/s,
`async function folderMissing(n){const l=storageCurrent(n);if(!l||!l.includes("/"))return!1;const m=l.slice(0,l.lastIndexOf("/")),p=l.slice(l.lastIndexOf("/")+1);try{const g=await${wcStorage}.browse(n,m),y=Array.isArray(g?.dirs)?g.dirs.map(${wcVariants.Fl}):null;return!!y&&!y.includes(p)}catch{const g=${wcStorage}.parse(n);return folderMissing("data"===g.activeSource?m:${wcStorage}.format({...g,path:m}))}}async function listSetFiles`));
mutateModule('wildcard extensions', 'function fileExists', body => regexOnce(body, 'wildcard extensions', /const [A-Za-z_$][\w$]*=\["webp","png","webm","jpg","jpeg","gif","svg"\];/, 'const C=["webp","png","webm","jpg","jpeg","gif","svg","avif","bmp","mp4","m4v","mov","ogv"];'));
mutateModule('file exists fetch', 'function fileExists', body => regexOnce(body, 'file exists fetch', /async function fileExists\(n\)\{try\{return\(await fetch\(`\$\{n\}\?t=\$\{Date\.now\(\)\}`,\{method:"HEAD",cache:"no-store"\}\)\)\.ok\}catch\{return!1\}\}/,
`async function fileExists(n){try{const l=await storageURL(n);return(await fetch(\`${'${l}'}${'${l.includes("?")?"&":"?"}'}t=\${Date.now()}\`,{method:"HEAD",cache:"no-store"})).ok}catch{return!1}}`));
mutateModule('variant browse pattern', 'function findVariantFiles', body => replaceOnce(body, 'variant browse pattern', 'return browseFiles(n,l)}(n);', `return browseFiles(n,${call(wcVariants.c1,'l')})}(n);`));
mutateModule('wildcard patch path', 'function wildcardOnPatch', body => regexOnce(body, 'wildcard patch path', /function wildcardOnPatch\(n,l\)\{const [A-Za-z_$][\w$]*=\{"prototypeToken\.texture\.src":\(0,[A-Za-z_$][\w$]*\.uJ\)\(l\.folder,l\.pattern\),"prototypeToken\.randomImg":!0\};/, `function wildcardOnPatch(n,l){const m={"prototypeToken.texture.src":${wcStorage}.toDocumentPath(${call(wcVariants.uJ,'l.folder,l.pattern')}),"prototypeToken.randomImg":!0};`));
mutateModule('retarget image patch', 'function retargetImagePatch', body => regexOnce(body, 'retarget image patch', /return n\?Object\.fromEntries\(imageFields\(n,l\)\.map\(n=>\[`\$\{p\}\$\{n\}`,m\]\)\):\{\}/,
`return n?Object.fromEntries(imageFields(n,${wcStorage}.toDocumentPath(l)).map(n=>[\`${'${p}'}${'${n}'}\`,${wcStorage}.toDocumentPath(m)])):{}`));
mutateModule('refresh variant path', 'function refreshPlacedVariant', body => regexOnce(body, 'refresh variant path', /const p=String\(l\)\.split\("\?"\)\[0\],y=`\$\{p\}\?v=\$\{m\}`;let b=0;for\(const m of tokensShowing\(n,l\)\)\{/,
`const p=String(${wcStorage}.toDocumentPath(l)).split("?")[0],y=\`${'${p}'}?v=\${m}\`;let b=0;for(const m of tokensShowing(n,p)){`));
mutateModule('copy variant fetch', 'function copyIntoSet', body => replaceOnce(body, 'copy variant fetch', 'const y=await fetch(l,{cache:"no-store"});', 'const y=await fetch(await storageURL(l),{cache:"no-store"});'));
mutateModule('variant source path', 'function variantSrcOf', body => replaceOnce(body, 'variant source path', 'function variantSrcOf(n){return n.savedAt?`${n.path}?v=${n.savedAt}`:n.path}', `function variantSrcOf(n){return ${wcStorage}.toDocumentPath(n.savedAt?\`\${n.path}?v=\${n.savedAt}\`:n.path)}`));

// New-set validation accepts the same sources as StorageHelper.
const setStorage = storageFor('function readNewSet', 'new-set validation storage');
const setKey = dep('function readNewSet', 'function setKey', 'setKey', 'new-set key');
mutateModule('new-set validation', 'function readNewSet', body => regexOnce(body, 'new-set validation', /function readNewSet\(\{name:n,folder:l,pattern:m,keepCurrent:p=!1,portrait:b=!1,random:w=!0,copyFrom:[A-Za-z_$][\w$]*=null\}=\{\}\)\{.*?\}function keepableTokenImage/s,
`function readNewSet({name:n,folder:l,pattern:m,keepCurrent:p=!1,portrait:b=!1,random:w=!0,copyFrom:copyFrom=null}={}){const v=${setStorage}.parse(String(l??""));if(!new Set(["data","s3","forgevtt"]).has(v.activeSource))return{error:"a wildcard set must use a supported Foundry file source"};const M=v.current.trim().replace(/\\/+$/, ""),S=String(m??"").trim(),x="data"===v.activeSource?M:${setStorage}.format({...v,path:M});if(!M)return{error:"a set needs a folder"};if(!S||1!==(S.match(/\\*/g)??[]).length)return{error:"the name pattern needs one * where the number goes"};if(/[/\\\\?<>:"|]/.test(S))return{error:'the name pattern cannot hold a folder or any of / \\ ? < > : " |'};const C=copyFrom?.where?{actor:copyFrom.actor??null,name:String(copyFrom.name??""),where:{folder:copyFrom.where.folder,pattern:copyFrom.where.pattern}}:null;return C&&${call(setKey,'C.where')}===${call(setKey,'({folder:x,pattern:S})')}?{error:"the new set needs a folder or name pattern of its own, not those of the set it copies"}:{set:{name:String(n??"").trim(),folder:x,pattern:S,keepCurrent:!!p,portrait:!!b,random:!!w,...C?{copyFrom:C}:{}}}}function keepableTokenImage`));

// Token-save writes and avatar/prototype URLs must use canonical document URLs.
const saveStorage = storageFor('function tokenSaveUpdates', 'token-save storage');
mutateModule('token save upload storage', 'function tokenSaveUpdates', body => regexOnce(body, 'token save upload storage', /[A-Za-z_$][\w$]*\.StorageHelper\.upload\(/, `${saveStorage}.upload(`));
mutateModule('token save document URLs', 'function tokenSaveUpdates', body => replaceOnce(body, 'token save document URLs',
  ',Y=`${p}?v=${y}`,Q={isDynamicRing:j,oversizedScale:V,oversizedRingFill:W,ringColor:U,ringBgColor:Z,textureSrc:g?`${g}?v=${y}`:void 0}',
  `,Y=\`\${${saveStorage}.toDocumentPath(p)}?v=\${y}\`,Q={isDynamicRing:j,oversizedScale:V,oversizedRingFill:W,ringColor:U,ringBgColor:Z,textureSrc:g?\`\${${saveStorage}.toDocumentPath(g)}?v=\${y}\`:void 0}`));
mutateModule('token save wildcard URL', 'function tokenSaveUpdates', body => replaceOnce(body, 'token save wildcard URL',
  'wildcardPath:W?.random?J:null,', `wildcardPath:W?.random?${saveStorage}.toDocumentPath(J):null,`));
mutateModule('avatar save URL', 'function avatarSaveUpdates', body => regexOnce(body, 'avatar save URL', /const y=\{\[\(0,[A-Za-z_$][\w$]*\.getAvatarKey\)\(game\.system\.id,game\.system\.version\)\]:`\$\{l\}\?v=\$\{m\}`\},b=\{\.\.\.y\};/,
  `const S=${saveStorage}.toDocumentPath(l),y={[(0,w.getAvatarKey)(game.system.id,game.system.version)]:\`${'${S}'}?v=\${m}\`},b={...y};`));

// Animated exports are allowed for wildcard variants as well.
const animatedRef = dep('function encodeTokenSave', 'function hasAnimatedContent', 'hasAnimatedContent', 'animated export');
mutateModule('animated export options', 'function encodeTokenSave', body => regexOnce(body, 'animated export options', /function animatedExport\(n,l,\{isWildcard:[^}]+\}=\{\}\)\{const [A-Za-z_$][\w$]*=\{animated:null,warning:null\};if\(!\(0,[A-Za-z_$][\w$]*\.Ty\)\(n\)\)return [A-Za-z_$][\w$]*;if\([A-Za-z_$][\w$]*\)return [A-Za-z_$][\w$]*\.default\.warn\("Tokenizer 2: wildcard tokens save as static images; skipping animated export\."\),[A-Za-z_$][\w$]*;/,
  `function animatedExport(n,l){const w={animated:null,warning:null};if(!${call(animatedRef,'n')})return w;`));
mutateModule('animated export call', 'function encodeTokenSave', body => regexOnce(body, 'animated export call', /\}\(l,n,\{isWildcard:[A-Za-z_$][\w$]*\}\);/, '}(l,n);'));

// Preserve animation layers in GM requests.
mutateModule('GM request layers', 'function applyTokenRequest', body => {
  const payload = body.match(/function applyTokenRequest\([^)]*\)\{const ([A-Za-z_$][\w$]*)=\w+\.payload/)?.[1];
  if (!payload) throw new Error('GM request layers: could not discover request payload alias');
  return regexOnce(body, 'GM request layers', /imageSet:[A-Za-z_$][\w$]*\}\);/, match => match.replace(/\}\);$/, `,layers:${payload}.layers});`));
});

// Save dialog choices must not force animated output back to still images.
mutateModule('save dialog animation choice', 'startSetInTab:', body => replaceOnce(body, 'save dialog animation choice',
  'w=b&&!savesToSet(l)', 'w=b'));
mutateModule('save dialog set choice', 'startSetInTab:', body => replaceOnce(body, 'save dialog set choice',
  'M=w?null:await this._startSetChoice()', 'M=await this._startSetChoice()'));
mutateModule('save dialog set tab', 'startSetInTab:', body => replaceOnce(body, 'save dialog set tab',
  'startSetInTab:!(M||w||savesToSet(l)||!l.wildcard?.canChangeSets)', 'startSetInTab:!(M||savesToSet(l)||!l.wildcard?.canChangeSets)'));
mutateModule('save dialog still in set', 'startSetInTab:', body => replaceOnce(body, 'save dialog still in set',
  'stillInSet:b&&savesToSet(l)', 'stillInSet:!1'));
mutateModule('save dialog token extension', '_tokenExtension(){', body => replaceOnce(body, 'save dialog token extension',
  '||savesToSet(n)||', '||'));
mutateModule('save dialog encoder availability', '_tokenExtension(){', body => replaceOnce(body, 'save dialog encoder availability',
  'return m?.extension??l}', 'return m&&m.isAvailable&&!m.isAvailable()?l:m?.extension??l}'));

if (source.includes(marker)) throw new Error('marker collision');
try { new Function(source); } catch (error) { throw new Error(`patched bundle is invalid: ${error.message}`); }
source += `\n${marker}\n`;
const stat = fs.statSync(path);
const temp = `${path}.tmp-${process.pid}`;
try {
  fs.writeFileSync(temp, source, {mode: stat.mode});
  fs.chmodSync(temp, stat.mode & 0o7777);
  fs.renameSync(temp, path);
} catch (error) {
  try { fs.unlinkSync(temp); } catch {}
  throw error;
}
console.log(`patched (${changes} changes)`);
NODE
)"; then
    if [[ "${patch_output}" == "already patched" ]]; then
      echo "[tokenizer-2-s3-webm] tokenizer-2 ${version} is already patched in ${main_js}" >&2
    else
      echo "[tokenizer-2-s3-webm] ${patch_output}; tokenizer-2 ${version} is patched in ${main_js}" >&2
    fi
  else
    echo "[tokenizer-2-s3-webm] failed to patch ${main_js}" >&2
    return 1
  fi
}

patch_rc=0
tokenizer_2_s3_webm_patch || patch_rc=$?
unset -f tokenizer_2_s3_webm_patch

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exit "${patch_rc}"
fi
return "${patch_rc}"
