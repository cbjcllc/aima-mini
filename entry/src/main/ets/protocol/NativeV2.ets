/**
 * Port of the Android native V2 codec only, not the Flutter aima_ble_core codec.
 * References: AdbBleDeviceV2, btInteraction/AdbBle, a/a/a/a, AESUtils.
 * Operates on authenticated local protocol data; contains no cloud credentials.
 */
export class LocalClock {
  year: number;
  month: number;
  day: number;
  hour: number;
  minute: number;
  second: number;

  constructor(year: number, month: number, day: number, hour: number,
    minute: number, second: number) {
    this.year = year; this.month = month; this.day = day;
    this.hour = hour; this.minute = minute; this.second = second;
  }
}

export interface V2Crypto {
  // Provider must reproduce AES/CBC/PKCS7Padding and reject bad padding.
  encrypt(plaintext: Uint8Array): Promise<Uint8Array>;
  decrypt(ciphertext: Uint8Array): Promise<Uint8Array>;
  // Android sha256_HMAC_String authenticates uppercase HEX ASCII, not raw bytes.
  hmacHexAscii(uppercaseHex: string): Promise<Uint8Array>;
}

export class CommandResult {
  category: number;
  commandId: number;
  commandParameter: number;
  success: boolean;

  constructor(category: number, commandId: number, parameter: number,
    success: boolean) {
    this.category = category; this.commandId = commandId;
    this.commandParameter = parameter; this.success = success;
  }
}

export function join(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a); out.set(b, a.length); return out;
}

function integer(value: number, min: number, max: number): void {
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error('Protocol integer outside range');
  }
}

export function signedShortBytes(value: number): Uint8Array {
  integer(value, -32768, 32767);
  return new Uint8Array([(value >> 8) & 255, value & 255]);
}

function u16(value: number): Uint8Array {
  integer(value, 0, 65535);
  return new Uint8Array([(value >> 8) & 255, value & 255]);
}

export function clockBytes(clock: LocalClock): Uint8Array {
  integer(clock.year, 2000, 2255); integer(clock.month, 1, 12);
  const days = new Date(Date.UTC(clock.year, clock.month, 0)).getUTCDate();
  integer(clock.day, 1, days); integer(clock.hour, 0, 23);
  integer(clock.minute, 0, 59); integer(clock.second, 0, 59);
  return new Uint8Array([clock.year - 2000, clock.month, clock.day,
    clock.hour, clock.minute, clock.second]);
}

export function nextSerial(current: number): number {
  integer(current, 1, 32767);
  return current === 32767 ? 1 : current + 1;
}

/** Family: 1=manual control, 2=settings, 4=induction configuration. */
export function applicationBody(clock: LocalClock, serial: number,
  commandId: number, parameter: Uint8Array): Uint8Array {
  integer(serial, 1, 32767); integer(commandId, 0, 255);
  return join(join(join(clockBytes(clock), u16(serial)),
    new Uint8Array([commandId])), parameter);
}

/** V2.command boolean normalization. Does not assign lock/unlock semantics. */
export function manualBody(clock: LocalClock, serial: number,
  commandId: number, parameter: number): Uint8Array {
  if ([1, 2, 3, 4, 16].indexOf(commandId) < 0) {
    throw new Error('Unsupported native V2 command');
  }
  integer(parameter, -2147483648, 2147483647);
  return applicationBody(clock, serial, commandId,
    new Uint8Array([parameter === 0 ? 0 : 1]));
}

/** Directions 1..4 and switch 5; physical direction names remain unverified. */
export function inductionBody(clock: LocalClock, serial: number,
  commandId: number, parameter: number): Uint8Array {
  integer(commandId, 1, 5); integer(parameter, -2147483648, 2147483647);
  return applicationBody(clock, serial, commandId,
    new Uint8Array([parameter === 0 ? 0 : 1]));
}

/** Faithful to V2.autoSeeting, including Java int->short wrapping. */
export function settingBody(clock: LocalClock, serial: number,
  commandId: number, parameter: number): Uint8Array {
  if ([1, 2, 4].indexOf(commandId) < 0) {
    throw new Error('Unresolved setting command');
  }
  integer(parameter, -2147483648, 2147483647);
  let data: Uint8Array;
  if (commandId === 4) {
    data = new Uint8Array([parameter === 0 ? 0 : parameter === 1 ? 1 :
      parameter === 2 ? 2 : 3]);
  } else {
    data = signedShortBytes((parameter << 16) >> 16);
  }
  return applicationBody(clock, serial, commandId, data);
}

export function uppercaseHex(data: Uint8Array): string {
  let result = '';
  for (let i = 0; i < data.length; i++) {
    result += data[i].toString(16).padStart(2, '0').toUpperCase();
  }
  return result;
}

/** sencommandSprite/blueSeeting/inductionLock, before transport encryption. */
export function plaintextFrame(category: number, body: Uint8Array): Uint8Array {
  if ([1, 2, 3, 4].indexOf(category) < 0) {
    throw new Error('Unsupported native V2 category');
  }
  const inner = join(join(new Uint8Array([0x40, 0x40, category, 0xfe]),
    u16(body.length)), body);
  const header = join(new Uint8Array([0x25, 0x25, 1, 0, 3, category, 0]),
    u16(inner.length));
  const message = join(header, inner);
  let checksum = 0;
  for (let i = 0; i < message.length; i++) { checksum ^= message[i]; }
  return join(message, new Uint8Array([checksum]));
}

export async function encodeFrame(category: number, body: Uint8Array,
  crypto: V2Crypto): Promise<Uint8Array> {
  const cipher = await crypto.encrypt(plaintextFrame(category, body));
  if (cipher.length === 0 || cipher.length % 16 !== 0) {
    throw new Error('Invalid AES ciphertext size');
  }
  const tag = await crypto.hmacHexAscii(uppercaseHex(cipher));
  if (tag.length !== 32) { throw new Error('Invalid HMAC size'); }
  return join(cipher, tag);
}

/** Android V2 notifications start with 0x2626 before ciphertext and HMAC. */
export async function decodeNotification(packet: Uint8Array,
  crypto: V2Crypto): Promise<Uint8Array> {
  if (packet.length < 50 || packet[0] !== 0x26 || packet[1] !== 0x26 ||
    (packet.length - 34) % 16 !== 0) {
    throw new Error('Invalid V2 notification framing');
  }
  const cipher = packet.slice(2, packet.length - 32);
  const receivedTag = packet.slice(packet.length - 32);
  const expectedTag = await crypto.hmacHexAscii(uppercaseHex(cipher));
  if (expectedTag.length !== 32) { throw new Error('Invalid HMAC size'); }
  let difference = 0;
  for (let i = 0; i < 32; i++) { difference |= receivedTag[i] ^ expectedTag[i]; }
  if (difference !== 0) { throw new Error('Notification authentication failed'); }
  return crypto.decrypt(cipher);
}

/** Input is the already authenticated/decrypted frame sliced at offset 9. */
export function parseCommandResult(data: Uint8Array): CommandResult {
  if (data.length < 22 || (data[2] !== 1 && data[2] !== 4)) {
    throw new Error('Truncated or unsupported result');
  }
  return new CommandResult(data[2], data[20], data[21], data[3] === 1);
}

/** Recovered from AdbBle.carQuery: category 3 has a clock + serial body, no command byte. */
export function queryBody(clock: LocalClock, serial: number): Uint8Array {
  integer(serial, 1, 32767);
  return join(clockBytes(clock), u16(serial));
}

/** Recovered bleConnectData / AdbBleProtocol.a(byte, String, String).
 * UTF-8 encoding is supplied by the platform adapter, never hex-decoded user data.
 */
export function connectionPlaintext(userId: Uint8Array, bluetoothKey: Uint8Array, serial: number): Uint8Array {
  integer(serial, 1, 32767);
  if (userId.length === 0 || bluetoothKey.length === 0) { throw new Error('缺少用户 ID 或车辆蓝牙密钥'); }
  const body = join(join(new Uint8Array([0]), userId), bluetoothKey);
  const inner = join(join(new Uint8Array([2, 0xfe]), u16(body.length)), join(u16(serial), body));
  const message = join(join(new Uint8Array([0x25, 0x25, 1, 0, 1, 2, 0]), u16(inner.length)), inner);
  let checksum = 0;
  for (let i = 0; i < message.length; i++) { checksum ^= message[i]; }
  return join(message, new Uint8Array([checksum]));
}

export class VehicleStatusResult {
  success: boolean;
  horn: number;
  lock: number;
  power: number;
  seat: number;
  constructor(success: boolean, horn: number, lock: number, power: number, seat: number) {
    this.success = success; this.horn = horn; this.lock = lock; this.power = power; this.seat = seat;
  }
}

/** Authenticated/decrypted application frame at offset 9; AdbBle.getQueryResult. */
export function parseVehicleStatus(data: Uint8Array): VehicleStatusResult {
  if (data.length < 25 || data[0] !== 0x40 || data[1] !== 0x40 || data[2] !== 3) {
    throw new Error('车辆状态应答不完整或类别不符');
  }
  return new VehicleStatusResult(data[3] === 1, data[21], data[22], data[23], data[24]);
}

export function parseConnectionResult(plaintext: Uint8Array): boolean {
  if (plaintext.length < 11 || plaintext[9] !== 2) { throw new Error('连接握手应答无效'); }
  return plaintext[10] === 1;
}

/** Encrypt a non-application (connection) frame with the same native transport wrapper. */
export async function encodeConnection(userId: Uint8Array, bluetoothKey: Uint8Array, serial: number,
  crypto: V2Crypto): Promise<Uint8Array> {
  const cipher = await crypto.encrypt(connectionPlaintext(userId, bluetoothKey, serial));
  if (cipher.length === 0 || cipher.length % 16 !== 0) { throw new Error('Invalid AES ciphertext size'); }
  const tag = await crypto.hmacHexAscii(uppercaseHex(cipher));
  if (tag.length !== 32) { throw new Error('Invalid HMAC size'); }
  return join(cipher, tag);
}
