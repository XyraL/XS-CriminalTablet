// Finds client-only natives called from server files.
//
// These do not throw at load. They are simply nil, so the call dies at the
// moment it runs and takes its whole callback or tick with it — the symptom
// is never "bad native", it is "the live map is empty" or "influence stopped
// moving". IsEntityDead cost a full test round exactly that way.
//
//   node tools/check-natives.mjs
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// Client-side only. Each entry names what to use instead, because the
// point of the check is to save the lookup, not just to complain.
const CLIENT_ONLY = {
  IsEntityDead: 'GetEntityHealth(ped) <= 0',
  IsPedDeadOrDying: 'GetEntityHealth(ped) <= 0',
  PlayerPedId: 'GetPlayerPed(src)',
  PlayerId: 'the source that came with the event',
  GetGameTimer: 'os.time() * 1000',
  GetCloudTimeAsInt: 'os.time()',
  IsControlJustPressed: 'client-side only',
  DoesAnimDictExist: 'client-side only',
  RequestModel: 'client-side only',
  IsEntityVisible: 'client-side only',
  GetGroundZFor_3dCoord: 'client-side only',
  StartShapeTestRay: 'client-side only',
  AddBlipForCoord: 'client-side only',
  DrawMarker: 'client-side only',
  SetNuiFocus: 'client-side only',
  IsPedInAnyVehicle: 'GetVehiclePedIsIn(ped) ~= 0',
  GetEntityForwardVector: 'client-side only',
  NetworkGetNetworkIdFromEntity: 'NetworkGetNetworkIdFromEntity exists server-side, but the entity must be networked',
};

// A native named inside a string or a comment is talk, not a call.
function stripNoise(line) {
  return line
    .replace(/--\[\[[\s\S]*?\]\]/g, '')
    .replace(/--.*$/, '')
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

// Names that look like natives and are not. Every one of these has cost
// a test round: they are nil on BOTH sides, so the call dies silently
// wherever it runs.
const NOT_NATIVES = {
  GetOffsetFromCoordInWorldCoords: 'only the entity form exists — do the trig, or use GetOffsetFromEntityInWorldCoords',
  GetEntityCoordsFromCoord: 'not a native',
  SetEntityCoordsNoOffset2: 'not a native',
  GetPedBoneCoords2: 'not a native',
  RequestAnimDictionary: 'RequestAnimDict',
  HasAnimDictionaryLoaded: 'HasAnimDictLoaded',
  DoesAnimationDictExist: 'DoesAnimDictExist',
  GetDistanceBetweenCoords2d: 'GetDistanceBetweenCoords',
  StartParticleFxNonLoopedAtCoords: 'StartParticleFxNonLoopedAtCoord',
  SetNuiFocusKeepInputs: 'SetNuiFocusKeepInput',
};

const files = [];
(function walk(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith('.lua')) files.push(p);
  }
})('server');

// Fake names are checked everywhere, not just on the server.
const allFiles = [];
for (const dir of ['server', 'client', 'bridge', 'shared']) {
  (function walk(d) {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.lua')) allFiles.push(p);
    }
  })(dir);
}

// bridge/*.lua runs on both sides and guards with IsDuplicityVersion(), so
// it is checked by hand rather than here.
let hits = 0;
for (const file of files) {
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((raw, i) => {
    const line = stripNoise(raw);
    for (const [native, instead] of Object.entries(CLIENT_ONLY)) {
      if (new RegExp('\\b' + native + '\\s*\\(').test(line)) {
        hits++;
        console.log(`${file}:${i + 1}  ${native}() — use ${instead}`);
      }
    }
  });
}

let fake = 0;
for (const file of allFiles) {
  const lines = readFileSync(file, 'utf8').split('\n');
  lines.forEach((raw, i) => {
    const line = stripNoise(raw);
    for (const [name, instead] of Object.entries(NOT_NATIVES)) {
      if (new RegExp('\\b' + name + '\\s*\\(').test(line)) {
        fake++;
        console.log(`${file}:${i + 1}  ${name}() is not a native — ${instead}`);
      }
    }
  });
}

console.log(`${files.length} server files scanned, ${hits} client-only native call(s)`);
console.log(`${allFiles.length} lua files scanned, ${fake} call(s) to something that is not a native`);
process.exitCode = (hits || fake) ? 1 : 0;
