const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const ts = require('/Applications/DevEco-Studio.app/Contents/plugins/codelinter/node_modules/typescript/lib/typescript.js');
function setup(deny = '', manual = false) {
  const granted = new Set(), calls = [];
  const api = {
    checkAccessToken: async (_, permission) => granted.has(permission) ? 0 : -1,
    requestPermissionsFromUser: async (_, permissions) => {
      calls.push(['runtime', ...permissions]);
      if (manual && permissions.includes('ohos.permission.LOCATION_IN_BACKGROUND')) { throw Object.assign(new Error('unexpected'), { code: 12100014 }); }
      for (const p of permissions) if (p !== deny) granted.add(p);
      return { authResults: permissions.map(p => granted.has(p) ? 0 : -1), dialogShownResults: permissions.map(() => true) };
    },
    requestPermissionOnSetting: async (_, permissions) => {
      calls.push(['retry', ...permissions]);
      for (const p of permissions) if (p !== deny) granted.add(p);
    },
    openPermissionOnSetting: async (_, permission) => {
      calls.push(['settings', permission]); if (permission !== deny) granted.add(permission);
    }
  };
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/ProximityPermissions.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInThisContext(`(function(require,module,exports){${source}\n})`)(() => ({ abilityAccessCtrl: { createAtManager: () => api } }), module, module.exports);
  return { run: () => module.exports.requestProximityPermissions({ applicationInfo: { accessTokenId: 42 } }), calls };
}
test('permissions request Bluetooth and foreground location before separately requesting background location', async () => {
  const f = setup(); await f.run();
  assert.deepEqual(f.calls.map(c => c[0]), ['runtime','runtime','runtime']);
  assert.deepEqual(f.calls[0], ['runtime','ohos.permission.ACCESS_BLUETOOTH']);
  assert.equal(f.calls[2][1], 'ohos.permission.LOCATION_IN_BACKGROUND');
  assert.equal(JSON.stringify(f.calls).includes('KEEP_BACKGROUND_RUNNING'), false);
});
test('denied foreground permission stops before background prompt', async () => {
  const f = setup('ohos.permission.APPROXIMATELY_LOCATION');
  await assert.rejects(f.run(), /位置权限/);
  assert.equal(f.calls.some(c => c[0] === 'settings'), false);
});
test('background permission refusal does not count as permission granted', async () => {
  const f = setup('ohos.permission.LOCATION_IN_BACKGROUND'); await assert.rejects(f.run(), /后台位置/);
});

test('manual settings is used only when runtime explicitly rejects the permission type', async () => {
  const f = setup('', true); await f.run();
  assert.deepEqual(f.calls.at(-1), ['settings', 'ohos.permission.LOCATION_IN_BACKGROUND']);
});
