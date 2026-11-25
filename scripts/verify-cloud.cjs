const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const ts = require('/Applications/DevEco-Studio.app/Contents/plugins/codelinter/node_modules/typescript/lib/typescript.js');
function fixture(storage = { secret: undefined, fail: false }) {
  const calls = []; let response = { responseCode: 200, result: JSON.stringify({ code: '0', data: {} }) };
  let destroyed = 0;
  const framework = {
    createRandom: () => ({ generateRandomSync: n => ({ data: crypto.randomBytes(n) }) }),
    createMd: algorithm => {
      assert.equal(algorithm, 'SHA1'); const hash = crypto.createHash('sha1');
      return { update: async b => hash.update(b.data), digest: async () => ({ data: hash.digest() }) };
    }
  };
  const asset = {
    Tag: { ALIAS: 1, SECRET: 2, ACCESSIBILITY: 3, CONFLICT_RESOLUTION: 4, RETURN_TYPE: 5 },
    Accessibility: { DEVICE_UNLOCKED: 2 }, ConflictResolution: { OVERWRITE: 0 }, ReturnType: { ALL: 0 },
    ErrorCode: { NOT_FOUND: 24000002 },
    addSync: values => {
      if (storage.fail) throw new Error('storage failed');
      assert.equal(values.get(3), 2); assert.equal(values.get(4), 0);
      storage.secret = Buffer.from(values.get(2));
    },
    querySync: () => storage.secret ? [new Map([[2, storage.secret]])] : [],
    removeSync: () => { storage.secret = undefined; }
  };
  const preferencesData = new Map();
  const mocks = {
    '@kit.AssetStoreKit': { asset }, '@kit.BasicServicesKit': {},
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      get: async (key, fallback) => preferencesData.get(key) ?? fallback,
      put: async (key, value) => preferencesData.set(key, value), flush: async () => {}
    }) } },
    '@kit.NetworkKit': { http: { RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' },
      createHttp: () => ({ request: async (url, options) => { calls.push({ url, ...options }); return typeof response === 'function' ? response() : response; },
        destroy: () => destroyed++ }) } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: framework },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(s) { return Buffer.from(s); } }, TextDecoder: { create: () => ({ decodeToString: bytes => Buffer.from(bytes).toString('utf8') }) } } }
  };
  const module = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/AimaCloudService.ets', 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInThisContext(`(function(require,module,exports){${source}\n})`)(id => mocks[id], module, module.exports);
  return { storage, service: new module.exports.AimaCloudService(), signaturePath: module.exports.signaturePath, signingText: module.exports.signingText, calls, set: value => response = value, destroyed: () => destroyed };
}
const ok = data => ({ responseCode: 200, result: JSON.stringify({ code: '0', data }) });
test('SMS request uses signed official contract, enforces validation and cooldown', async () => {
  const f = fixture(); await assert.rejects(f.service.sendSms('123')); assert.equal(f.calls.length, 0);
  await f.service.sendSms('13800000000');
  const call = f.calls[0], body = JSON.parse(call.extraData);
  assert.equal(call.url, 'https://app.aimaiot.cn/user/appUser/sendSmsCode');
  assert.equal(body.url, '/appUser/sendSmsCode');
  assert.equal(body.type, '2'); assert.equal(body.mobile, '13800000000');
  assert.match(body.nonce, /^[a-zA-Z0-9]{20}$/); assert.match(body.timestamp, /^\d{13}$/);
  const sign = body.sign; delete body.sign;
  const salt = 'doTVIzldF06eFQf0vBIinsZS3piuFEMJ';
  const text = salt + ['mobile', 'nonce', 'timestamp', 'type', 'url'].map(k => k + body[k]).join('') + salt;
  assert.equal(sign, crypto.createHash('sha1').update(text).digest('hex').toUpperCase());
  assert.equal(call.header.Authorization, undefined); assert.equal(call.header.platformId, 'ohos');
  await assert.rejects(f.service.sendSms('13800000000'), /稍后/); assert.equal(f.calls.length, 1);
  assert.equal(f.destroyed(), 1);
});
test('login validates tokens, vehicle request uses bearer and logout removes access', async () => {
  const f = fixture(); await assert.rejects(f.service.vehicles(), /登录/);
  f.set(ok({ userId: 'test-user', accessToken: 'test-token' }));
  await f.service.login('13800000000', '123456');
  assert.equal(f.service.userId, 'test-user'); assert.equal(f.service.loggedIn, true);
  const login = f.calls[0]; assert.equal(login.header.deviceCode, login.header.UUID);
  assert.equal(JSON.parse(login.extraData).smsCode, '123456');
  assert.equal(JSON.parse(login.extraData).url, '/appUser/ssoLoginBySms');
  f.set(ok([{ vinCode: 'test-vin', bluetoothKey: 'test-key' }]));
  assert.equal((await f.service.vehicles())[0].vinCode, 'test-vin');
  assert.equal(f.calls[1].header.Authorization, 'Bearer test-token');
  assert.equal(f.calls[1].url, 'https://app.aimaiot.cn/veh/userVehicleRelation/myVehicleList');
  assert.equal(JSON.parse(f.calls[1].extraData).url, '/userVehicleRelation/myVehicleList');
  f.service.logout(); assert.equal(f.service.userId, ''); await assert.rejects(f.service.vehicles(), /登录/);
});
test('failed login, HTTP expiry, malformed responses and network exceptions never become success', async () => {
  const f = fixture(); f.set(ok({})); await assert.rejects(f.service.login('13800000000', '123456'), /凭据/);
  assert.equal(f.service.loggedIn, false);
  f.set(ok({ userId: 'id', accessToken: 'test' })); await f.service.login('13800000000', '123456');
  f.set({ responseCode: 401 }); await assert.rejects(f.service.vehicles(), /失效/); assert.equal(f.service.loggedIn, false);
  f.set({ responseCode: 200, result: '{' }); await assert.rejects(f.service.sendSms('13800000000'));
  f.set(() => { throw new Error('offline'); }); await assert.rejects(f.service.sendSms('13800000000'), /offline/);
  assert.equal(f.destroyed(), 5);
});
test('logout during request prevents a stale login from restoring the session', async () => {
  const f = fixture(); let resolve;
  f.set(() => new Promise(r => resolve = r));
  const pending = f.service.login('13800000000', '123456');
  while (!resolve) { await new Promise(r => setImmediate(r)); }
  f.service.logout(); resolve(ok({ userId: 'id', accessToken: 'test' }));
  await assert.rejects(pending, /会话已变化/); assert.equal(f.service.loggedIn, false);
});

test('APK indexOf start=1 strips the gateway segment only from the signed URL', () => {
  const f = fixture();
  assert.equal(f.signaturePath('/user/appUser/sendSmsCode'), '/appUser/sendSmsCode');
  assert.equal(f.signaturePath('/user/appUser/ssoLoginBySms'), '/appUser/ssoLoginBySms');
  assert.equal(f.signaturePath('/veh/userVehicleRelation/myVehicleList'), '/userVehicleRelation/myVehicleList');
  assert.throws(() => f.signaturePath('/user'));
  assert.throws(() => f.signaturePath('https://app.aimaiot.cn/user/appUser/sendSmsCode'));
  const body = { mobile: '13800000000', type: '2', timestamp: '1795615200000',
    nonce: '1234567890abcdefghij', url: f.signaturePath('/user/appUser/sendSmsCode') };
  const text = f.signingText(body);
  assert.equal(text, 'doTVIzldF06eFQf0vBIinsZS3piuFEMJmobile13800000000nonce1234567890abcdefghijtimestamp1795615200000type2url/appUser/sendSmsCodedoTVIzldF06eFQf0vBIinsZS3piuFEMJ');
  assert.notEqual(crypto.createHash('sha1').update(text).digest('hex'),
    crypto.createHash('sha1').update(f.signingText({ ...body, url: '/user/appUser/sendSmsCode' })).digest('hex'));
});

test('secure login cache survives a new instance, while release keeps it and logout removes it', async () => {
  const f = fixture(); f.set(ok({ userId: 'cache-user', accessToken: 'cached-token', refreshToken: 'refresh' }));
  await f.service.login('13800000000', '123456');
  assert.ok(f.storage.secret); assert.equal(JSON.parse(f.storage.secret).refreshToken, 'refresh');
  assert.equal(JSON.parse(f.storage.secret).accountLabel, '138****0000');
  assert.equal(f.storage.secret.toString().includes('13800000000'), false);
  f.service.release(); assert.equal(f.service.loggedIn, false); assert.ok(f.storage.secret);
  const next = fixture(f.storage); await next.service.initialize({});
  assert.equal(next.service.loggedIn, true); assert.equal(next.service.userId, 'cache-user');
  assert.equal(next.service.accountLabel, '138****0000');
  next.set(ok([])); await next.service.vehicles();
  assert.equal(next.calls[0].header.Authorization, 'Bearer cached-token');
  next.service.logout(); assert.equal(next.storage.secret, undefined);
  const after = fixture(next.storage); await after.service.initialize({}); assert.equal(after.service.loggedIn, false);
});
test('HTTP 401 deletes cached token, network failure retains it, malformed cache is discarded', async () => {
  const f = fixture(); f.set(ok({ userId: 'id', accessToken: 'token' })); await f.service.login('13800000000', '123456');
  f.set(() => { throw new Error('offline'); }); await assert.rejects(f.service.vehicles()); assert.ok(f.storage.secret);
  f.set({ responseCode: 401 }); await assert.rejects(f.service.vehicles(), /失效/); assert.equal(f.storage.secret, undefined);
  const bad = fixture({ secret: Buffer.from('{broken') }); await bad.service.initialize({});
  assert.equal(bad.service.loggedIn, false); assert.equal(bad.storage.secret, undefined);
});
test('secure storage failure does not falsely report a cached login', async () => {
  const f = fixture({ fail: true }); f.set(ok({ userId: 'id', accessToken: 'token' }));
  await assert.rejects(f.service.login('13800000000', '123456'), /保存/); assert.equal(f.service.loggedIn, false);
});

test('last selected vehicle is scoped to the restored account', async () => {
  const f = fixture(); await f.service.initialize({});
  f.set(ok({ userId: 'account-a', accessToken: 'token-a' }));
  await f.service.login('13800000000', '123456'); await f.service.rememberVehicle('vin-a');
  f.service.release(); await f.service.initialize({});
  assert.equal(await f.service.lastVehicleVin(), 'vin-a');
  f.service.logout(); f.set(ok({ userId: 'account-b', accessToken: 'token-b' }));
  await f.service.login('13800000000', '123456');
  assert.equal(await f.service.lastVehicleVin(), '');
});
