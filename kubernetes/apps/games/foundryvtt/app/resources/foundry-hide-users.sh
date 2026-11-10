#!/usr/bin/env bash

# Put this file in CONTAINER_PATCHES (for example, /data/container_patches).
# foundryvtt-docker sources patch scripts after Foundry is installed and before
# it starts. This hides the exact user name "MCP" from the /join screen; it does
# not delete the user, alter the server's join payload, or prevent a direct
# login attempt. Set FOUNDRY_HIDE_USERS to a comma-separated list of exact user
# names to hide (for example, "MCP,Service Bot"); it defaults to "MCP".

foundry_hide_mcp_patch() {
  local app_root
  local candidate
  local join_view=""
  local -a roots=()

  [[ -n "${FOUNDRY_HOME:-}" ]] && roots+=("${FOUNDRY_HOME}")
  roots+=(
    "/home/node"
    "/foundryvtt"
    "/home/foundry/app"
    "${PWD}"
  )

  for app_root in "${roots[@]}"; do
    candidate="${app_root%/}/resources/app/public/scripts/foundry.mjs"
    if [[ -f "${candidate}" ]]; then
      join_view="${candidate}"
      break
    fi
  done

  if [[ -z "${join_view}" ]]; then
    echo "[foundry-hide-mcp] Foundry join view not found; skipping" >&2
    return 0
  fi

  local patch_output
  if patch_output="$(node - "${join_view}" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
if (!path) throw new Error('usage: patcher.js <join.mjs>');

let source = fs.readFileSync(path, 'utf8');
const legacyServerPath = require('path').join(require('path').dirname(path), '../../dist/server/views/join.mjs');
const legacyMarker = '/* foundry-hide-mcp-patch:2026-11-10-r1 */';
if (fs.existsSync(legacyServerPath)) {
  let serverSource = fs.readFileSync(legacyServerPath, 'utf8');
  const legacyMarkers = [...serverSource.matchAll(/\/\* foundry-hide-mcp-patch:[^*]+\*\//g)].map(e => e[0]);
  if (legacyMarkers.includes(legacyMarker)) {
    if (legacyMarkers.length !== 1) throw new Error('duplicate legacy foundry-hide-mcp server markers; restore the core file before applying this revision');
    const legacyFilter = 'users:(await db.User.dump()).filter(e=>e?.name!=="MCP")';
    if (serverSource.split(legacyFilter).length - 1 !== 1) throw new Error('legacy server patch marker found without its expected user filter');
    serverSource = serverSource.replace(legacyFilter, 'users:await db.User.dump()').replace(legacyMarker, '');
    const legacyStat = fs.statSync(legacyServerPath);
    const legacyTemp = `${legacyServerPath}.tmp-${process.pid}.mjs`;
    try {
      fs.writeFileSync(legacyTemp, serverSource, {mode: legacyStat.mode});
      fs.chmodSync(legacyTemp, legacyStat.mode & 0o7777);
      const legacyCheck = require('child_process').spawnSync(process.execPath, ['--check', legacyTemp], {encoding: 'utf8'});
      if (legacyCheck.status !== 0) throw new Error(`restored server join view is invalid: ${(legacyCheck.stderr || legacyCheck.stdout || '').trim()}`);
      fs.renameSync(legacyTemp, legacyServerPath);
    } catch (error) {
      try { fs.unlinkSync(legacyTemp); } catch {}
      throw error;
    }
    console.error('restored legacy server join patch');
  } else if (legacyMarkers.length) {
    throw new Error(`unknown server patch marker ${legacyMarkers[0]}; restore the core file before applying this revision`);
  }
}
const marker = '/* foundry-hide-mcp-patch:2026-11-10-r4 */';
const r3Marker = '/* foundry-hide-mcp-patch:2026-11-10-r3 */';
const r2Marker = '/* foundry-hide-mcp-patch:2026-11-10-r2 */';
const markers = [...source.matchAll(/\/\* foundry-hide-mcp-patch:[^*]+\*\//g)].map(e => e[0]);
const normalizeR2R3 = markers.length === 2 && markers.includes(r2Marker) && markers.includes(r3Marker);
let existingMarker = markers[0];
if (markers.length > 1 && !normalizeR2R3) throw new Error('duplicate foundry-hide-mcp patch markers; restore the core file before applying this revision');
if (existingMarker && existingMarker !== r2Marker && existingMarker !== r3Marker && existingMarker !== marker && !normalizeR2R3) {
  throw new Error(`unknown foundry-hide-mcp patch marker ${existingMarker}; restore the core file before applying this revision`);
}

const hiddenUsers = (process.env.FOUNDRY_HIDE_USERS ?? 'MCP').split(',').map(e => e.trim()).filter(Boolean);
const hiddenLiteral = JSON.stringify(hiddenUsers);
const joinOld = '    // Configure Join view data\n    this.users = new foundry.documents.collections.Users(this.data.users);';
const joinNew = `    // Configure Join view data\n    const users = (this.data.users ?? []).filter(e => !${hiddenLiteral}.includes(e?.name));\n    this.data.users = users;\n    const activeUserIds = new Set(users.map(e => e._id));\n    this.data.activeUsers = (this.data.activeUsers ?? []).filter(e => activeUserIds.has(e));\n    this.users = new foundry.documents.collections.Users(this.data.users);`;
const joinConfiguredNew = joinNew.slice(joinNew.indexOf('    const users'));
const legacyJoin = '    // Configure Join view data\n    const users = (this.data.users ?? []).filter(e => e?.name !== "MCP");\n    this.data.users = users;\n    const activeUserIds = new Set(users.map(e => e._id));\n    this.data.activeUsers = (this.data.activeUsers ?? []).filter(e => activeUserIds.has(e));\n    this.users = new foundry.documents.collections.Users(this.data.users);';
const playersOld = '    for ( const u of game.users ) {\n      const user = {';
const playersNew = `    for ( const u of game.users ) {\n      if ( ${hiddenLiteral}.includes(u.name) ) continue;\n      const user = {`;
const legacyPlayers = '    for ( const u of game.users ) {\n      if ( u.name === "MCP" ) continue;\n      const user = {';
const joinPattern = /    const users = \(this\.data\.users \?\? \[\]\)\.filter\(e => !\[[^\n]*\]\.includes\(e\?\.name\)\);\n    this\.data\.users = users;\n    const activeUserIds = new Set\(users\.map\(e => e\._id\)\);\n    this\.data\.activeUsers = \(this\.data\.activeUsers \?\? \[\]\)\.filter\(e => activeUserIds\.has\(e\)\);\n    this\.users = new foundry\.documents\.collections\.Users\(this\.data\.users\);/;
const playersPattern = /    for \( const u of game\.users \) \{\n      if \( \[[^\n]*\]\.includes\(u\.name\) \) continue;\n      const user = \{/;
let changed = false;
const replaceOne = (text, oldText, newText, label) => {
  const count = text.split(oldText).length - 1;
  if (count !== 1) throw new Error(`${label}: expected one match, found ${count}`);
  const next = text.replace(oldText, () => newText);
  changed ||= next !== text;
  return next;
};
const replaceRegex = (text, regex, newText, label) => {
  const count = [...text.matchAll(new RegExp(regex.source, 'g'))].length;
  if (count !== 1) throw new Error(`${label}: expected one match, found ${count}`);
  const next = text.replace(regex, () => newText);
  changed ||= next !== text;
  return next;
};

if (normalizeR2R3) {
  if (!source.includes(legacyJoin) || !source.includes(legacyPlayers)) throw new Error('r2/r3 migration: expected the existing join and in-game MCP filters');
  source = source.replaceAll(r2Marker, '').replaceAll(r3Marker, '');
  existingMarker = r3Marker;
  changed = true;
}
if (!existingMarker) {
  source = replaceOne(source, joinOld, joinNew, 'join view user list');
  source = replaceOne(source, playersOld, playersNew, 'in-game user list');
} else if (existingMarker === r2Marker) {
  source = replaceOne(source, legacyJoin, joinNew, 'r2 join-view migration');
  source = replaceOne(source, playersOld, playersNew, 'r2 in-game migration');
} else if (existingMarker === r3Marker) {
  source = replaceOne(source, legacyJoin, joinNew, 'r3 join-view migration');
  source = replaceOne(source, legacyPlayers, playersNew, 'r3 in-game migration');
} else if (existingMarker === marker) {
  if (source.match(joinPattern)) source = replaceRegex(source, joinPattern, joinConfiguredNew, 'configured join view user list');
  else throw new Error('r4 migration: configured join-view filter not found');
  if (source.match(playersPattern)) source = replaceRegex(source, playersPattern, playersNew, 'configured in-game user list');
  else throw new Error('r4 migration: configured in-game filter not found');
}

if (!changed) {
  console.log('already patched');
  process.exit(0);
}
const stat = fs.statSync(path);
const temp = `${path}.tmp-${process.pid}.mjs`;
try {
  if (existingMarker) source = source.replaceAll(existingMarker, '');
  fs.writeFileSync(temp, `${source}\n${marker}\n`, {mode: stat.mode});
  fs.chmodSync(temp, stat.mode & 0o7777);
  const check = require('child_process').spawnSync(process.execPath, ['--check', temp], {
    encoding: 'utf8',
  });
  if (check.status !== 0) {
    throw new Error(`patched join view is invalid: ${(check.stderr || check.stdout || '').trim()}`);
  }
  fs.renameSync(temp, path);
} catch (error) {
  try { fs.unlinkSync(temp); } catch {}
  throw error;
}
console.log('patched');
NODE
)"; then
    if [[ "${patch_output}" == "already patched" ]]; then
      echo "[foundry-hide-mcp] already patched ${join_view}" >&2
    else
      echo "[foundry-hide-mcp] patched ${join_view}" >&2
    fi
  else
    echo "[foundry-hide-mcp] patch skipped for ${join_view}; leaving the client bundle unchanged" >&2
    return 0
  fi
}

patch_rc=0
foundry_hide_mcp_patch || patch_rc=$?
unset -f foundry_hide_mcp_patch

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  exit "${patch_rc}"
fi
return "${patch_rc}"
