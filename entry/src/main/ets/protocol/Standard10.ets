import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { hexBytes } from './HarmonyV2Crypto';

export function standardUuid(short: string): string { return '0000' + short + '-0000-1000-8000-00805f9b34fb'; }
export const AUTH10: string = standardUuid('7800');
export const CONTROL10: string = standardUuid('7801');
export const QUERY10: string = standardUuid('7802');
export const REPORT10: string = standardUuid('7803');

// APK AimaBusinessAlgorithm.crc16: init 0, polynomial 0xA8B3.
// CommonEncryptAlgorithm stores only the low byte in its checksum slot.
export function standardCrc(data: Uint8Array): number {
  let crc = 0;
  for (let i = 0; i < data.length; i++) {
    crc ^= data[i] << 8;
    for (let bit = 0; bit < 8; bit++) { crc = ((crc << 1) ^ ((crc & 0x8000) ? 0xA8B3 : 0)) & 0xffff; }
  }
  return crc & 0xff;
}
export async function standardHash(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA256'); await md.update({ data: data }); return (await md.digest()).data;
}
export function join10(a: Uint8Array, b: Uint8Array): Uint8Array {
  const result = new Uint8Array(a.length + b.length); result.set(a); result.set(b, a.length); return result;
}
async function ecb(data: Uint8Array, keyBytes: Uint8Array, encrypt: boolean): Promise<Uint8Array> {
  if (keyBytes.length !== 16) { throw new Error('协议 10 AES 密钥长度错误'); }
  const key = await cryptoFramework.createSymKeyGenerator('AES128').convertKey({ data: keyBytes });
  const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
  await cipher.init(encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE, key, null);
  return (await cipher.doFinal({ data: data })).data;
}
export class StandardMessage {
  command: number;
  body: Uint8Array;
  constructor(command: number, body: Uint8Array) { this.command = command; this.body = body; }
}
export async function encodeStandard(command: number, body: Uint8Array, key?: Uint8Array): Promise<Uint8Array> {
  if (body.length > 237 || command < 0 || command > 255) { throw new Error('协议 10 指令长度或命令无效'); }
  const plain = new Uint8Array(body.length + 3); plain[0] = body.length + 2; plain[1] = command; plain.set(body, 3);
  plain[2] = standardCrc(plain);
  let payload = plain.slice(1); let flags = 0;
  if (key) {
    const padding = 16 - payload.length % 16;
    const padded = new Uint8Array(payload.length + padding); padded.set(payload); padded.fill(padding, payload.length);
    payload = await ecb(padded, key, true); flags = 0x80 | (padding & 0x0f);
  }
  const result = new Uint8Array(payload.length + 2); result[0] = flags; result[1] = payload.length; result.set(payload, 2); return result;
}
export async function decodeStandard(packet: Uint8Array, key?: Uint8Array): Promise<StandardMessage> {
  if (packet.length < 4 || packet[1] + 2 !== packet.length || (packet[0] & 0x70) !== 0) { throw new Error('协议 10 应答长度或标志错误'); }
  let plain = packet.slice(2);
  if ((packet[0] & 0x80) !== 0) {
    if (!key || !plain.length || plain.length % 16 !== 0) { throw new Error('协议 10 加密应答无有效密钥或长度错误'); }
    plain = await ecb(plain, key, false);
    const padding = plain[plain.length - 1];
    if (padding < 1 || padding > 16 || (padding & 15) !== (packet[0] & 15)) { throw new Error('协议 10 应答填充错误'); }
    for (let i = plain.length - padding; i < plain.length; i++) {
      if (plain[i] !== padding) { throw new Error('协议 10 应答填充错误'); }
    }
    plain = plain.slice(0, plain.length - padding);
  } else if (packet[0] !== 0) { throw new Error('协议 10 明文标志错误'); }
  if (plain.length < 2) { throw new Error('协议 10 应答不完整'); }
  const check = new Uint8Array(plain.length + 1); check[0] = plain.length; check.set(plain, 1); check[2] = 0;
  if (standardCrc(check) !== plain[1]) { throw new Error('协议 10 应答校验失败'); }
  return new StandardMessage(plain[0], plain.slice(2));
}
export class Standard10Session {
  private longTerm: Uint8Array;
  private session?: Uint8Array;
  private closed: boolean = false;
  constructor(keyHex: string) {
    this.longTerm = hexBytes(keyHex);
    if (this.longTerm.length !== 16) { this.longTerm.fill(0); throw new Error('协议 10 需要车辆接口返回的 16 字节十六进制蓝牙密钥'); }
  }
  async resetPacket(): Promise<Uint8Array> {
    if (this.closed) { throw new Error('车辆会话已清除'); }
    const random = cryptoFramework.createRandom().generateRandomSync(16).data;
    return encodeStandard(5, join10(random, await standardHash(join10(random, this.longTerm))));
  }
  async authPacket(): Promise<Uint8Array> {
    if (this.closed) { throw new Error('车辆会话已清除'); }
    return encodeStandard(3, new Uint8Array([0]), this.longTerm);
  }
  async decode(packet: Uint8Array, authenticating: boolean): Promise<StandardMessage> {
    if (this.closed) { throw new Error('车辆会话已清除'); }
    if ((packet[0] & 0x80) === 0) { throw new Error('车辆认证与控车应答必须加密'); }
    return decodeStandard(packet, authenticating ? this.longTerm : this.session);
  }
  async acceptAuth(response: StandardMessage): Promise<void> {
    if (response.command !== 0x83 || response.body.length < 16) { throw new Error('协议 10 车辆鉴权拒绝或应答不完整'); }
    const derived = await standardHash(join10(this.longTerm, response.body.slice(0, 16)));
    if (this.closed) { derived.fill(0); throw new Error('车辆会话已清除'); }
    this.session = derived.slice(0, 16); derived.fill(0);
  }
  async controlPacket(command: number, body: Uint8Array): Promise<Uint8Array> {
    if (this.closed || !this.session) { throw new Error('请先完成协议 10 车辆鉴权'); }
    return encodeStandard(command, body, this.session);
  }
  clear(): void { this.closed = true; this.longTerm.fill(0); this.session?.fill(0); this.session = undefined; }
}

// APK parses manufacturer id 0x01a8, 24-byte value; bytes 13..18 are the reversed vehicle MAC.
// Harmony may expose a different transport address, so keep the discovered deviceId for GATT.
export function standardAdvertisedMac(advertisement: Uint8Array): string {
  for (let offset = 0; offset < advertisement.length;) {
    const length = advertisement[offset];
    if (length === 0) { break; }
    if (offset + length >= advertisement.length) { return ''; }
    if (advertisement[offset + 1] === 0xff && length === 27 &&
      advertisement[offset + 2] === 0xa8 && advertisement[offset + 3] === 0x01) {
      const value = advertisement.slice(offset + 4, offset + length + 1);
      let mac = '';
      for (let i = 18; i >= 13; i--) { mac += value[i].toString(16).padStart(2, '0').toUpperCase(); }
      return mac;
    }
    offset += length + 1;
  }
  return '';
}
