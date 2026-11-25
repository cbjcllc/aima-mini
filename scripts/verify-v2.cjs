/* Host regression checks. Uses Node crypto as an independent AES/HMAC reference;
 * the SDK adapter validates our crypto logic but cannot validate Harmony runtime or radio hardware. */
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { test, afterEach } = require('node:test');
const ts = require(process.env.AIMA_TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/plugins/codelinter/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const timers = new Map();
let timerId = 0;
const tick = () => new Promise(resolve => setImmediate(resolve));
const framework = {
  CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
  createRandom: () => ({ generateRandomSync: length => ({ data: new Uint8Array(crypto.randomBytes(length)) }) }),
  createMd: algorithm => {
    const hash = crypto.createHash(algorithm.toLowerCase());
    return { update: async ({ data }) => hash.update(data), digest: async () => ({ data: new Uint8Array(hash.digest()) }) };
  },
  createSymKeyGenerator: () => ({ convertKey: async ({ data }) => Buffer.from(data) }),
  createCipher: name => {
    let key, iv, mode;
    return {
      init: async (m, k, p) => { mode = m; key = k; iv = p ? Buffer.from(p.iv.data) : null; },
      doFinal: async ({ data }) => {
        const fn = mode === 0 ? crypto.createCipheriv : crypto.createDecipheriv;
        const cipher = fn(`aes-${key.length * 8}-${name.includes('|ECB|') ? 'ecb' : 'cbc'}`, key, iv);
        assert.match(name, /\|(CBC|ECB)\|NoPadding$/);
        cipher.setAutoPadding(false);
        return { data: new Uint8Array(Buffer.concat([cipher.update(Buffer.from(data)), cipher.final()])) };
      }
    };
  },
  createMac: name => {
    assert.equal(name, 'SHA256');
    let mac;
    return {
      init: async key => { mac = crypto.createHmac('sha256', key); },
      update: async ({ data }) => { mac.update(Buffer.from(data)); },
      doFinal: async () => ({ data: new Uint8Array(mac.digest()) })
    };
  }
};
let permissions = [0];
let bluetoothOn = true;
let scanCallback;
let scanning = false;
let latestClient;
const serviceUuid = '00000000-0000-0000-0000-000000000001';
const writeUuid = '00000000-0000-0000-0000-000000000002';
const notifyUuid = '00000000-0000-0000-0000-000000000003';
const characteristic = uuid => ({ serviceUuid, characteristicUuid: uuid,
  characteristicValue: new ArrayBuffer(0), descriptors: [], properties: { write: true, notify: true } });
class FakeGatt {
  handlers = new Map(); writes = []; closed = false;
  on(event, fn) { this.handlers.set(event, fn); }
  off(event) { this.handlers.delete(event); }
  connect() {}
  disconnect() {}
  close() { this.closed = true; }
  getServices = async () => [{ serviceUuid, characteristics: [characteristic(writeUuid), characteristic(notifyUuid)] }];
  setCharacteristicChangeNotification = async (_, enabled) => { assert.equal(enabled, true); };
  setBLEMtuSize = mtu => { this.handlers.get('BLEMtuChange')?.(mtu); };
  writeCharacteristicValue = async c => { this.writes.push(Buffer.from(c.characteristicValue)); };
  emit(event, value) { this.handlers.get(event)?.(value); }
}
const ble = {
  on: (_, fn) => { scanCallback = fn; }, off: () => { scanCallback = undefined; },
  startBLEScan: filters => { assert.equal(filters, null, 'unfiltered SDK scan requires null, not []'); scanning = true; }, stopBLEScan: () => { scanning = false; },
  createGattClientDevice: () => (latestClient = new FakeGatt()), GattWriteType: { WRITE: 1, WRITE_NO_RESPONSE: 2 }
};
const mocks = {
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } } } },
  '@kit.CryptoArchitectureKit': { cryptoFramework: framework },
  '@kit.ConnectivityKit': { ble, access: { getState: () => bluetoothOn ? 2 : 0,
    BluetoothState: { STATE_ON: 2 } }, constant: { ProfileConnectionState: { STATE_CONNECTED: 2, STATE_DISCONNECTED: 0 } } },
  '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({ authResults: permissions }) }) } }
};
const cache = new Map();
function load(filename) {
  filename = path.resolve(filename);
  if (cache.has(filename)) return cache.get(filename);
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} }; cache.set(filename, module.exports);
  const requireLocal = id => mocks[id] || load(path.resolve(path.dirname(filename), id + '.ets'));
  vm.runInThisContext(`(function(require,module,exports,setTimeout,clearTimeout){${output}\n})`, { filename })(
    requireLocal, module, module.exports,
    (fn, ms) => { const id = ++timerId; timers.set(id, { fn, ms }); return id; },
    id => timers.delete(id));
  return module.exports;
}
const codec = load(path.join(root, 'protocol/NativeV2.ets'));
const { HarmonyV2Crypto, hexBytes } = load(path.join(root, 'protocol/HarmonyV2Crypto.ets'));
const { VehicleBleService, VehicleConfig, NearbyVehicle } = load(path.join(root, 'services/VehicleBleService.ets'));
const aes = Buffer.from('2b7e151628aed2a6abf7158809cf4f3c', 'hex');
const iv = Buffer.from('000102030405060708090a0b0c0d0e0f', 'hex');
const mac = Buffer.from('test-local-session-key');
const provider = () => new HarmonyV2Crypto(aes, iv, mac);
const device = new NearbyVehicle('test-id', 'Test vehicle', -45);
let service;
afterEach(() => { service?.dispose(); service = undefined; permissions = [0]; bluetoothOn = true; timers.clear(); });
function config() {
  const c = new VehicleConfig();
  Object.assign(c, { serviceUuid, writeUuid, notifyUuid, nativeTransport: false, userId: 'test-user', bluetoothKey: 'test-vehicle-key',
    aesKeyHex: aes.toString('hex'), ivHex: iv.toString('hex'), hmacKeyHex: mac.toString('hex'),
    bindings: [{ action: 'unlock', category: 1, commandId: 1, parameter: 1 }] });
  return c;
}
async function ready() {
  service = new VehicleBleService(); service.configure(config()); service.connect(device);
  latestClient.emit('BLEConnectionStateChange', { state: 2, deviceId: device.id });
  await tick();
  const operation = service.authenticate(); await tick();
  const packet = await rawNotification(Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]));
  latestClient.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await operation; latestClient.writes = []; return latestClient;
}
async function notification(category = 1, id = 1, parameter = 1, success = true) {
  // Decrypted result layout is supplied by the reference, not a guessed telemetry schema.
  const plain = Buffer.alloc(31); plain[9] = 0x40; plain[10] = 0x40; plain[11] = category; plain[12] = success ? 1 : 0;
  plain[29] = id; plain[30] = parameter;
  return rawNotification(plain);
}
async function rawNotification(plain) {
  const cipher = crypto.createCipheriv('aes-128-cbc', aes, iv);
  const data = Buffer.concat([cipher.update(plain), cipher.final()]);
  const tag = crypto.createHmac('sha256', mac).update(data.toString('hex').toUpperCase(), 'ascii').digest();
  return new Uint8Array(Buffer.concat([Buffer.from([0x26, 0x26]), data, tag]));
}

test('calendar, serial, Java short wrapping and boolean normalization', () => {
  const clock = new codec.LocalClock(2026, 11, 25, 12, 34, 56);
  assert.equal(codec.uppercaseHex(codec.manualBody(clock, 1, 1, -3)), '1A0B190C223800010101');
  assert.equal(codec.nextSerial(32767), 1);
  assert.equal(codec.uppercaseHex(codec.settingBody(clock, 1, 1, 65535)).slice(-4), 'FFFF');
  assert.throws(() => codec.clockBytes(new codec.LocalClock(2026, 2, 29, 0, 0, 0)));
  assert.throws(() => codec.manualBody(clock, 1, 99, 0));
  assert.throws(() => codec.applicationBody(clock, 0, 1, new Uint8Array()));
});
test('wire frame layout, lengths and XOR checksum', () => {
  const body = codec.manualBody(new codec.LocalClock(2026, 11, 25, 12, 34, 56), 1, 1, 1);
  const frame = codec.plaintextFrame(1, body);
  assert.equal(codec.uppercaseHex(frame.slice(0, -1)), '252501000301000010404001FE000A1A0B190C223800010101');
  assert.equal(frame.reduce((a, b) => a ^ b, 0), 0);
});
test('AES agrees with NIST CBC first block and Node PKCS7 output', async () => {
  const plain = hexBytes('6bc1bee22e409f96e93d7e117393172a');
  const encrypted = await provider().encrypt(plain);
  assert.equal(Buffer.from(encrypted.slice(0, 16)).toString('hex'), '7649abac8119b246cee98e9b12e9197d');
  const reference = crypto.createCipheriv('aes-128-cbc', aes, iv);
  assert.deepEqual(Buffer.from(encrypted), Buffer.concat([reference.update(plain), reference.final()]));
  assert.deepEqual(Buffer.from(await provider().decrypt(encrypted)), Buffer.from(plain));
});
test('HMAC authenticates uppercase HEX ASCII and rejects bad keys/padding', async () => {
  const actual = await provider().hmacHexAscii('AB012F');
  assert.equal(Buffer.from(actual).toString('hex'), crypto.createHmac('sha256', mac).update('AB012F', 'ascii').digest('hex'));
  assert.throws(() => hexBytes('abc')); assert.throws(() => hexBytes('zz'));
  assert.throws(() => new HarmonyV2Crypto(new Uint8Array(15), iv, mac));
  const raw = crypto.createCipheriv('aes-128-cbc', aes, iv); raw.setAutoPadding(false);
  await assert.rejects(provider().decrypt(Buffer.concat([raw.update(Buffer.alloc(16)), raw.final()])), /PKCS7/);
});
test('notifications reject altered tags, truncation and invalid markers', async () => {
  const packet = await notification();
  assert.equal(codec.parseCommandResult((await codec.decodeNotification(packet, provider())).slice(9)).success, true);
  packet[packet.length - 1] ^= 1;
  await assert.rejects(codec.decodeNotification(packet, provider()), /authentication failed/);
  packet[0] = 0;
  await assert.rejects(codec.decodeNotification(packet, provider()), /framing/);
  await assert.rejects(codec.decodeNotification(new Uint8Array(10), provider()), /framing/);
  assert.throws(() => codec.parseCommandResult(new Uint8Array(21)));
});
test('real scan API path checks permission and radio, deduplicates results', async () => {
  service = new VehicleBleService(); let snapshot; service.observe(s => snapshot = s);
  permissions = [-1]; await assert.rejects(service.scan({}), /权限/); assert.equal(scanning, false);
  permissions = [0]; bluetoothOn = false; await assert.rejects(service.scan({}), /打开/);
  bluetoothOn = true; await service.scan({});
  scanCallback([{ deviceId: 'one', deviceName: 'A', rssi: -60, connectable: true },
    { deviceId: 'one', deviceName: 'A', rssi: -40, connectable: true }]);
  assert.equal(snapshot.devices.length, 1); assert.equal(snapshot.devices[0].rssi, -40);
  service.stopScan(); assert.equal(scanning, false); assert.equal(scanCallback, undefined);
});
test('control is blocked before configuration and when mapping is missing', async () => {
  service = new VehicleBleService(); await assert.rejects(service.control('unlock'), /会话/);
  await ready(); await assert.rejects(service.control('horn'), /映射/);
  assert.equal(latestClient.writes.length, 0);
});
test('write does not report success until matching authenticated acknowledgement', async () => {
  const client = await ready(); let snapshot; service.observe(s => snapshot = s);
  const operation = service.control('unlock'); await tick();
  assert.equal(client.writes.length, 1); assert.equal(snapshot.lockState, '车辆状态未知');
  assert.equal(snapshot.busy, true);
  await assert.rejects(service.control('unlock'), /等待车辆/);
  const wrong = await notification(1, 2, 1);
  client.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: wrong.buffer });
  await tick(); assert.equal(snapshot.busy, true);
  const packet = await notification();
  client.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  assert.equal((await operation).success, true); assert.equal(snapshot.lockState, '车辆已解锁');
});
test('timeout closes connection and clears session without optimistic lock changes', async () => {
  const client = await ready(); let snapshot; service.observe(s => snapshot = s);
  const operation = service.control('unlock'); const rejection = assert.rejects(operation, /超时/);
  await tick(); const timer = [...timers.values()].find(t => t.ms === 8000); assert.ok(timer); timer.fn();
  await rejection; assert.equal(snapshot.lockState, '车辆状态未知'); assert.equal(snapshot.ready, false);
  assert.equal(client.closed, true);
});
test('negative acknowledgement and disconnect reject pending command', async () => {
  let client = await ready(); let operation = service.control('unlock');
  let rejection = assert.rejects(operation, /拒绝/); await tick();
  const packet = await notification(1, 1, 1, false);
  client.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await rejection;
  operation = service.control('unlock'); rejection = assert.rejects(operation, /断开/);
  await tick(); service.disconnect(); await rejection;
});
test('small MTU prevents unverified fragmentation and transmits no partial packet', async () => {
  service = new VehicleBleService(); service.configure(config()); service.connect(device);
  latestClient.setBLEMtuSize = () => {};
  latestClient.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  await assert.rejects(service.authenticate(), /MTU/);
  assert.equal(latestClient.writes.length, 0);
});

test('duplicate authenticated notification cannot acknowledge a subsequent command', async () => {
  const client = await ready();
  const packet = await notification();
  const change = { ...characteristic(notifyUuid), characteristicValue: packet.buffer };
  let operation = service.control('unlock'); await tick();
  client.emit('BLECharacteristicChange', change); await operation;
  operation = service.control('unlock'); const rejection = assert.rejects(operation, /断开/);
  await tick(); let snapshot; service.observe(s => snapshot = s);
  client.emit('BLECharacteristicChange', change); await tick();
  assert.equal(snapshot.busy, true); service.disconnect(); await rejection;
});
test('disconnect clears crypto provider and ignores old connection events', async () => {
  const client = await ready(); const oldHandler = client.handlers.get('BLEConnectionStateChange');
  let snapshot; service.observe(s => snapshot = s); service.disconnect();
  oldHandler({ state: 2 }); await tick(); assert.equal(snapshot.connected, false);
  service.connect(device); latestClient.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  assert.equal(snapshot.ready, false); assert.equal(snapshot.connected, true);
  await assert.rejects(service.control('unlock'), /会话/);
});
test('cleared session provider refuses further AES/HMAC operations', async () => {
  const p = provider(); p.clear();
  await assert.rejects(p.encrypt(new Uint8Array([1])), /清除/);
  await assert.rejects(p.hmacHexAscii('AA'), /清除/);
});

test('native connection frame matches recovered Java layout and UTF-8 concatenation', () => {
  const plain = codec.connectionPlaintext(Buffer.from('U'), Buffer.from('KEY'), 1);
  assert.equal(codec.uppercaseHex(plain.slice(0, -1)), '25250100010200000B02FE0005000100554B4559');
  assert.equal(plain.reduce((a, b) => a ^ b, 0), 0);
  assert.throws(() => codec.connectionPlaintext(new Uint8Array(), Buffer.from('K'), 1));
  assert.equal(codec.parseConnectionResult(Buffer.from([0,0,0,0,0,0,0,0,0,2,1])), true);
  assert.equal(codec.parseConnectionResult(Buffer.from([0,0,0,0,0,0,0,0,0,2,0])), false);
});
test('transport key alone never makes a connected device ready and failed handshake closes it', async () => {
  service = new VehicleBleService(); service.configure(config()); service.connect(device);
  latestClient.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  let snapshot; service.observe(s => snapshot = s); assert.equal(snapshot.ready, false);
  await assert.rejects(service.control('unlock'), /会话/);
  const operation = service.authenticate(); const rejection = assert.rejects(operation, /握手验证失败/);
  await tick();
  const packet = await rawNotification(Buffer.from([0,0,0,0,0,0,0,0,0,2,0]));
  latestClient.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await rejection; assert.equal(snapshot.ready, false); assert.equal(latestClient.closed, true);
});
test('status query decodes native fields only after its authenticated response', async () => {
  const client = await ready(); let snapshot; service.observe(s => snapshot = s);
  const operation = service.queryStatus(); await tick();
  const plain = Buffer.alloc(34); plain[9] = 0x40; plain[10] = 0x40; plain[11] = 3; plain[12] = 1;
  plain[30] = 1; plain[31] = 0; plain[32] = 1; plain[33] = 1;
  const packet = await rawNotification(plain);
  client.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await operation; assert.equal(snapshot.hornState, 1); assert.equal(snapshot.powerState, 1); assert.equal(snapshot.seatState, 1);
  assert.equal(snapshot.lockState, '车辆状态未知');
});
test('native adb1/adb2 discovery supports different service UUIDs', async () => {
  service = new VehicleBleService(); service.connect(device);
  const writer = { ...characteristic('0000adb2-0000-1000-8000-00805f9b34fb') };
  const notifier = { ...characteristic('0000adb1-0000-1000-8000-00805f9b34fb'), serviceUuid: '00000000-0000-0000-0000-000000000099' };
  latestClient.getServices = async () => [
    { serviceUuid, characteristics: [writer] },
    { serviceUuid: notifier.serviceUuid, characteristics: [notifier] }
  ];
  latestClient.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  let snapshot; service.observe(s => snapshot = s);
  assert.equal(snapshot.connected, true); assert.equal(snapshot.ready, false);
  assert.match(snapshot.status, /原生 V2/);
});

test('ambiguous native characteristics require explicit selection', async () => {
  service = new VehicleBleService(); service.connect(device);
  latestClient.getServices = async () => [{ serviceUuid, characteristics: [
    characteristic('0000adb1-0000-1000-8000-00805f9b34fb'),
    characteristic('0000adb2-0000-1000-8000-00805f9b34fb'),
    characteristic('1111adb2-0000-1000-8000-00805f9b34fb')
  ] }];
  latestClient.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  let snapshot; service.observe(s => snapshot = s);
  assert.equal(snapshot.ready, false); assert.match(snapshot.status, /唯一/);
  assert.equal(latestClient.writes.length, 0);
});
test('query parser rejects truncated or wrong categories and does not invent battery values', () => {
  assert.throws(() => codec.parseVehicleStatus(new Uint8Array(24)));
  assert.throws(() => codec.parseVehicleStatus(new Uint8Array(25)));
  const body = codec.queryBody(new codec.LocalClock(2026, 11, 25, 12, 34, 56), 1);
  assert.equal(codec.uppercaseHex(body), '1A0B190C22380001');
  assert.equal(codec.plaintextFrame(3, body)[11], 3);
});

 test('APK native defaults map each action to verified command and polarity', async () => {
  const { nativeCommandBindings } = load(path.join(root, 'services/VehicleBleService.ets'));
  assert.deepEqual(nativeCommandBindings().map(b => [b.action, b.category, b.commandId, b.parameter]), [
    ['lock', 1, 2, 1], ['unlock', 1, 2, 0], ['horn', 1, 1, 1], ['seat', 1, 4, 1]
  ]);
  await ready();
  for (const [action, id, parameter] of [['lock', 2, 1], ['unlock', 2, 0], ['horn', 1, 1], ['seat', 4, 1]]) {
    service.disconnect(); const c = config(); c.bindings = nativeCommandBindings(); service.configure(c); service.connect(device);
    latestClient.emit('BLEConnectionStateChange', { state: 2, deviceId: device.id }); await tick();
    const auth = service.authenticate(); await tick();
    const authPacket = await rawNotification(Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]));
    latestClient.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: authPacket.buffer }); await auth;
    const pending = service.control(action); await tick();
    const packet = await notification(1, id, parameter);
    latestClient.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer }); await pending;

  }
});

test('auto-connect matches only the selected MAC then authenticates without manual action', async () => {
  service = new VehicleBleService(); service.configure(config()); let state;
  service.observe(value => state = value);
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  assert.equal(state.scanning, true);
  const callback = scanCallback;
  callback([{ deviceId: '11:22:33:44:55:66', deviceName: 'Same name', rssi: -10, connectable: true }]);
  assert.equal(state.connected, false); assert.equal(state.scanning, true);
  callback([{ deviceId: 'aa:bb:cc:dd:ee:ff', deviceName: 'Owned vehicle', rssi: -70, connectable: true }]);
  assert.equal(state.scanning, false); assert.equal(state.deviceName, 'Owned vehicle');
  latestClient.emit('BLEConnectionStateChange', { state: 2, deviceId: 'aa:bb:cc:dd:ee:ff' });
  await tick(); await tick();
  assert.equal(latestClient.writes.length, 1); assert.equal(state.ready, false);
  const packet = await rawNotification(Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]));
  latestClient.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await tick(); assert.equal(state.ready, true);
});

test('auto search timeout and cancellation do not connect a late target', async () => {
  service = new VehicleBleService(); service.configure(config()); let state;
  service.observe(value => state = value);
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  const timeout = [...timers.values()].find(t => t.ms === 10000); assert.ok(timeout); timeout.fn();
  assert.equal(state.scanning, false); assert.match(state.status, /未找到目标车辆/);
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  const late = scanCallback; service.disconnect();
  late([{ deviceId: 'AA:BB:CC:DD:EE:FF', deviceName: 'Late', rssi: -30, connectable: true }]);
  assert.equal(state.connected, false); assert.equal(state.scanning, false);
});

test('auto-connect rejects missing credentials and malformed addresses', async () => {
  service = new VehicleBleService();
  await assert.rejects(service.autoConnect({}, 'AA:BB:CC:DD:EE:FF'), /凭据/);
  service.configure(config()); await assert.rejects(service.autoConnect({}, 'wrong'), /MAC/);
});

test('account vehicle profile uses vehicle UUID and rejects unsupported protocol before connecting', () => {
  const { accountVehicleConfig } = load(path.join(root, 'services/AccountVehicleProfile.ets'));
  const vehicle = { vinCode: 'test-vin', uuid: 'vehicle-authorized-uuid', evcuType: 2,
    bluetoothMac: 'AA:BB:CC:DD:EE:FF', bluetoothKey: 'test-key' };
  assert.equal(accountVehicleConfig(vehicle).userId, 'vehicle-authorized-uuid');
  assert.equal(accountVehicleConfig(vehicle).bluetoothKey, 'test-key');
  assert.throws(() => accountVehicleConfig({ ...vehicle, uuid: undefined, userId: 'login-user-id' }), /UUID/);
  for (const evcuType of [1, 3, 11, 30]) {
    assert.throws(() => accountVehicleConfig({ ...vehicle, evcuType }), /协议类型/);
  }
  assert.throws(() => accountVehicleConfig({ ...vehicle, evcuType: undefined }), /协议类型/);
});

async function foundAutomaticVehicle() {
  service = new VehicleBleService(); service.configure(config());
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  scanCallback([{ deviceId: 'AA:BB:CC:DD:EE:FF', deviceName: 'Owned vehicle', rssi: -45, connectable: true }]);
  return latestClient;
}

test('automatic handshake waits for a delayed MTU event and requests APK MTU 511', async () => {
  const client = await foundAutomaticVehicle(); let state; service.observe(value => state = value);
  client.setBLEMtuSize = mtu => { assert.equal(mtu, 511); };
  client.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  assert.equal(client.writes.length, 0);
  assert.ok([...timers.values()].find(t => t.ms === 8000));
  client.emit('BLEMtuChange', 511); await tick(); assert.equal(client.writes.length, 1);
  client.emit('BLEMtuChange', 511); await tick(); assert.equal(client.writes.length, 1);
  const packet = await rawNotification(Buffer.from([0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1]));
  client.emit('BLECharacteristicChange', { ...characteristic(notifyUuid), characteristicValue: packet.buffer });
  await tick(); assert.equal(state.ready, true);
});

test('MTU timeout closes the channel without sending an undersized handshake', async () => {
  const client = await foundAutomaticVehicle(); let state; service.observe(value => state = value);
  client.setBLEMtuSize = () => {};
  client.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  [...timers.values()].find(t => t.ms === 8000).fn();
  assert.equal(client.closed, true); assert.equal(client.writes.length, 0);
  assert.equal(state.ready, false); assert.match(state.status, /MTU.*超时/);
});

test('service discovery failures close the channel and keep the failure visible', async () => {
  const client = await foundAutomaticVehicle(); let state; service.observe(value => state = value);
  client.getServices = async () => { throw new Error('service discovery failed'); };
  client.emit('BLEConnectionStateChange', { state: 2 }); await tick();
  assert.equal(client.closed, true); assert.match(state.status, /service discovery failed/);
  assert.equal(client.writes.length, 0);
});

const standard10 = load(path.join(root, 'protocol/Standard10.ets'));
const standardKey = Buffer.from('00112233445566778899aabbccddeeff', 'hex');
// Independent table implementation of the polynomial recovered from AOT.
const crc10Table = Array.from({ length: 256 }, (_, value) => {
  let x = value * 256;
  for (let bit = 0; bit < 8; bit++) x = x >= 32768 ? ((x * 2) ^ 43187) & 65535 : x * 2 & 65535;
  return x;
});
function referenceCrc10(bytes) {
  let crc = 0;
  for (const b of bytes) crc = ((crc << 8) ^ crc10Table[(crc >> 8) ^ b]) & 65535;
  return crc & 255;
}
function reference10(command, body, key) {
  const plain = Buffer.from([body.length + 2, command, 0, ...body]);
  plain[2] = referenceCrc10(plain);
  let payload = plain.subarray(1), flags = 0;
  if (key) {
    flags = 128 | ((16 - payload.length % 16) & 15);
    const cipher = crypto.createCipheriv('aes-128-ecb', key, null);
    payload = Buffer.concat([cipher.update(payload), cipher.final()]);
  }
  return Buffer.from([flags, payload.length, ...payload]);
}
function decodeReference10(packet, key) {
  let plain = packet.subarray(2);
  if (packet[0] & 128) {
    const cipher = crypto.createDecipheriv('aes-128-ecb', key, null);
    plain = Buffer.concat([cipher.update(plain), cipher.final()]);
  }
  const check = Buffer.from([plain.length, ...plain]); check[2] = 0;
  assert.equal(referenceCrc10(check), plain[1]);
  return { command: plain[0], body: plain.subarray(2) };
}
test('standard 10 frame agrees with independent CRC and Node ECB PKCS7 across padding boundaries', async () => {
  for (const length of [0, 1, 14, 15, 16, 17, 48, 100]) {
    const body = Buffer.alloc(length, 0x41);
    for (const key of [undefined, standardKey]) {
      const actual = Buffer.from(await standard10.encodeStandard(3, body, key));
      assert.deepEqual(actual, reference10(3, body, key));
      const decoded = await standard10.decodeStandard(actual, key);
      assert.equal(decoded.command, 3); assert.deepEqual(Buffer.from(decoded.body), body);
    }
  }
  await assert.rejects(standard10.decodeStandard(Buffer.from([0, 2, 3, 0])), /校验/);
  await assert.rejects(standard10.decodeStandard(Buffer.from([0, 5, 3, 0])), /长度/);
  const good = reference10(0x83, Buffer.alloc(16), standardKey); good[0] ^= 1;
  await assert.rejects(standard10.decodeStandard(good, standardKey), /填充/);
});
test('standard 10 random challenge and session derivation use the authorized vehicle key', async () => {
  const session = new standard10.Standard10Session(standardKey.toString('hex'));
  const reset = decodeReference10(Buffer.from(await session.resetPacket()));
  assert.equal(reset.command, 5); assert.equal(reset.body.length, 48);
  assert.deepEqual(reset.body.subarray(16), crypto.createHash('sha256').update(reset.body.subarray(0, 16)).update(standardKey).digest());
  const auth = decodeReference10(Buffer.from(await session.authPacket()), standardKey);
  assert.equal(auth.command, 3); assert.deepEqual(auth.body, Buffer.from([0]));
  await assert.rejects(session.controlPacket(1, Buffer.from([1])), /鉴权/);
  const challenge = Buffer.from('ffeeddccbbaa99887766554433221100', 'hex');
  const response = await session.decode(reference10(0x83, challenge, standardKey), true); await session.acceptAuth(response);
  const sk = crypto.createHash('sha256').update(standardKey).update(challenge).digest().subarray(0, 16);
  const control = decodeReference10(Buffer.from(await session.controlPacket(1, Buffer.from([1]))), sk);
  assert.equal(control.command, 1); assert.equal(control.body[0], 1);
  session.clear(); await assert.rejects(session.authPacket(), /清除/);
  assert.throws(() => new standard10.Standard10Session('abcd'), /密钥/);
});
function standardCharacteristics() {
  return [standard10.AUTH10, standard10.CONTROL10, standard10.QUERY10, standard10.REPORT10]
    .map(uuid => ({ ...characteristic(uuid), properties: { write: uuid !== standard10.REPORT10, notify: true } }));
}
function emit10(client, uuid, packet) {
  client.emit('BLECharacteristicChange', { ...characteristic(uuid), characteristicValue: Uint8Array.from(packet).buffer });
}
async function connect10() {
  service = new VehicleBleService();
  const c = new VehicleConfig(); c.protocolType = 10; c.bluetoothKey = standardKey.toString('hex');
  service.configure(c); let state; service.observe(s => state = s);
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  scanCallback([{ deviceId: 'AA:BB:CC:DD:EE:FF', deviceName: 'Standard vehicle', rssi: -40, connectable: true }]);
  const client = latestClient; const subscriptions = [];
  client.getServices = async () => [{ serviceUuid, characteristics: standardCharacteristics() }];
  client.setCharacteristicChangeNotification = async c => { subscriptions.push(c.characteristicUuid); };
  client.emit('BLEConnectionStateChange', { state: 2 }); await tick(); await tick();
  assert.deepEqual(subscriptions, [standard10.AUTH10]);
  assert.equal(client.writes.length, 1); assert.equal(decodeReference10(client.writes[0]).command, 5);
  [...timers.values()].find(t => t.ms === 200).fn(); await tick(); await tick();
  assert.equal(client.writes.length, 2); assert.equal(decodeReference10(client.writes[1], standardKey).command, 3);
  return { client, state: () => state, subscriptions };
}
async function ready10() {
  const f = await connect10(); const challenge = Buffer.alloc(16, 0x53);
  const response = reference10(0x83, challenge, standardKey);
  emit10(f.client, standard10.AUTH10, response.subarray(0, 7)); await tick(); assert.equal(f.state().ready, false);
  emit10(f.client, standard10.AUTH10, response.subarray(7)); await tick(); await tick();
  assert.equal(f.state().ready, true); assert.equal(f.subscriptions.length, 4);
  f.sk = crypto.createHash('sha256').update(standardKey).update(challenge).digest().subarray(0, 16);
  return f;
}
test('standard 10 uses its own characteristic authentication then confirms all four controls', async () => {
  const f = await ready10();
  for (const [action, command, body] of [['lock', 1, [1]], ['unlock', 1, [0]], ['horn', 4, [1, 3]], ['seat', 11, [1]]]) {
    const operation = service.control(action); await tick();
    const sent = decodeReference10(f.client.writes.at(-1), f.sk);
    assert.equal(sent.command, command); assert.deepEqual(sent.body, Buffer.from(body));
    assert.equal(f.state().busy, true);
    emit10(f.client, standard10.CONTROL10, reference10(command | 128, [0], f.sk));
    await operation; assert.equal(f.state().busy, false);
  }
  await assert.rejects(service.control('inductionOn'), /尚未接入/);
});
test('standard 10 rejects short, plaintext, and invalid-key authentication without opening controls', async () => {
  const f = await connect10();
  emit10(f.client, standard10.AUTH10, reference10(0x83, Buffer.alloc(16)));
  await tick(); assert.equal(f.state().ready, false);
  emit10(f.client, standard10.AUTH10, reference10(0x83, Buffer.alloc(16), Buffer.alloc(16, 0xa5)));
  await tick(); assert.equal(f.state().ready, false);
  emit10(f.client, standard10.AUTH10, reference10(0x83, [1], standardKey));
  await tick(); await tick(); assert.equal(f.state().ready, false); assert.equal(f.client.closed, true);
  await assert.rejects(service.control('unlock'), /先连接|先完成/);
});
test('standard 10 negative acknowledgments, wrong channel, heartbeat, and disconnect are handled', async () => {
  const f = await ready10();
  const operation = service.control('lock'); await tick();
  emit10(f.client, standard10.QUERY10, reference10(0x81, [0], f.sk)); await tick(); assert.equal(f.state().busy, true);
  emit10(f.client, standard10.CONTROL10, reference10(0x81, [1], f.sk));
  await assert.rejects(operation, /未确认/); assert.equal(f.state().lockState, '车辆状态未知');
  [...timers.values()].find(t => t.ms === 5000).fn(); await tick();
  const heartbeat = decodeReference10(f.client.writes.at(-1)); assert.equal(heartbeat.command, 0x11);
  assert.equal(heartbeat.body[0], 255);
  const pending = service.control('unlock'); await tick(); service.disconnect(); await assert.rejects(pending, /断开/);
  emit10(f.client, standard10.AUTH10, reference10(0x83, Buffer.alloc(16), standardKey));
  await tick(); assert.equal(f.state().ready, false);
});

test('account profile selects standard 10 without substituting login identity or native bindings', () => {
  const { accountVehicleConfig } = load(path.join(root, 'services/AccountVehicleProfile.ets'));
  const config10 = accountVehicleConfig({ vinCode: 'vin', evcuType: 10, bluetoothMac: 'AA:BB:CC:DD:EE:FF', bluetoothKey: standardKey.toString('hex') });
  assert.equal(config10.protocolType, 10); assert.equal(config10.userId, '');
});

test('standard 10 matches the manufacturer MAC while connecting the real transport address', async () => {
  const manufacturer = Buffer.alloc(24); Buffer.from('ffeeddccbbaa', 'hex').copy(manufacturer, 13);
  const adv = Buffer.from([27, 255, 168, 1, ...manufacturer]);
  assert.equal(standard10.standardAdvertisedMac(adv), 'AABBCCDDEEFF');
  const wrongVendor = Buffer.from(adv); wrongVendor[2] = 1;
  assert.equal(standard10.standardAdvertisedMac(wrongVendor), '');
  assert.equal(standard10.standardAdvertisedMac(adv.subarray(0, 10)), '');
  service = new VehicleBleService(); const c = new VehicleConfig(); c.protocolType = 10; c.bluetoothKey = standardKey.toString('hex');
  service.configure(c); let state; service.observe(s => state = s);
  await service.autoConnect({}, 'AA:BB:CC:DD:EE:FF');
  scanCallback([{ deviceId: '11:22:33:44:55:66', deviceName: 'Vehicle', rssi: -40, connectable: true,
    data: Uint8Array.from(adv).buffer }]);
  assert.equal(state.scanning, false); assert.match(state.status, /正在连接/);
  assert.equal(state.devices[0].id, '11:22:33:44:55:66');
});

test('standard 10 control timeout closes the session and leaves the vehicle state unknown', async () => {
  const f = await ready10(); const operation = service.control('unlock'); await tick();
  [...timers.values()].find(t => t.ms === 8000).fn();
  await assert.rejects(operation, /应答超时/);
  assert.equal(f.client.closed, true); assert.equal(f.state().ready, false); assert.equal(f.state().lockState, '车辆状态未知');
});
test('standard 10 notification subscription failure after auth never marks the vehicle ready', async () => {
  const f = await connect10(); f.client.setCharacteristicChangeNotification = async () => { throw new Error('subscribe failed'); };
  emit10(f.client, standard10.AUTH10, reference10(0x83, Buffer.alloc(16), standardKey));
  await tick(); await tick(); assert.equal(f.state().ready, false); assert.equal(f.client.closed, true);
  assert.match(f.state().status, /subscribe failed/);
});
