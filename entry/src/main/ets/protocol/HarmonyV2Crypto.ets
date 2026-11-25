import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { V2Crypto } from './NativeV2';

export function hexBytes(value: string): Uint8Array {
  if (value.length === 0 || value.length % 2 !== 0 || !/^[0-9a-fA-F]+$/.test(value)) {
    throw new Error('密钥必须为完整的十六进制字节');
  }
  const result = new Uint8Array(value.length / 2);
  for (let i = 0; i < result.length; i++) {
    result[i] = parseInt(value.substring(i * 2, i * 2 + 2), 16);
  }
  return result;
}

// Session material is supplied by the authenticated device integration. Never persisted or logged.
export class HarmonyV2Crypto implements V2Crypto {
  private aes: Uint8Array;
  private iv: Uint8Array;
  private macKey: Uint8Array;
  private cleared: boolean = false;

  constructor(aes: Uint8Array, iv: Uint8Array, macKey: Uint8Array) {
    if ([16, 24, 32].indexOf(aes.length) < 0 || iv.length !== 16 || macKey.length === 0) {
      throw new Error('AES 密钥须为 16/24/32 字节，IV 须为 16 字节，HMAC 密钥不可为空');
    }
    this.aes = aes.slice();
    this.iv = iv.slice();
    this.macKey = macKey.slice();
  }

  private async crypt(data: Uint8Array, mode: cryptoFramework.CryptoMode): Promise<Uint8Array> {
    if (this.cleared) { throw new Error('本地会话已清除'); }
    const algorithm = 'AES' + this.aes.length * 8;
    const key = await cryptoFramework.createSymKeyGenerator(algorithm).convertKey({ data: this.aes });
    const cipher = cryptoFramework.createCipher(algorithm + '|CBC|NoPadding');
    const params: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: this.iv } };
    await cipher.init(mode, key, params);
    return (await cipher.doFinal({ data: data })).data;
  }

  async encrypt(plaintext: Uint8Array): Promise<Uint8Array> {
    const padding = 16 - plaintext.length % 16;
    const padded = new Uint8Array(plaintext.length + padding);
    padded.set(plaintext);
    padded.fill(padding, plaintext.length);
    return this.crypt(padded, cryptoFramework.CryptoMode.ENCRYPT_MODE);
  }

  async decrypt(ciphertext: Uint8Array): Promise<Uint8Array> {
    if (ciphertext.length === 0 || ciphertext.length % 16 !== 0) {
      throw new Error('AES 密文长度不合法');
    }
    const data = await this.crypt(ciphertext, cryptoFramework.CryptoMode.DECRYPT_MODE);
    const padding = data[data.length - 1];
    if (padding < 1 || padding > 16) { throw new Error('PKCS7 填充无效'); }
    for (let i = data.length - padding; i < data.length; i++) {
      if (data[i] !== padding) { throw new Error('PKCS7 填充无效'); }
    }
    return data.slice(0, data.length - padding);
  }

  async hmacHexAscii(uppercaseHex: string): Promise<Uint8Array> {
    if (this.cleared) { throw new Error('本地会话已清除'); }
    if (!/^[0-9A-F]+$/.test(uppercaseHex) || uppercaseHex.length % 2 !== 0) {
      throw new Error('HMAC 输入必须为大写十六进制 ASCII');
    }
    const ascii = new Uint8Array(uppercaseHex.length);
    for (let i = 0; i < ascii.length; i++) { ascii[i] = uppercaseHex.charCodeAt(i); }
    const key = await cryptoFramework.createSymKeyGenerator('HMAC').convertKey({ data: this.macKey });
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(key);
    await mac.update({ data: ascii });
    return (await mac.doFinal()).data;
  }

  clear(): void {
    this.cleared = true;
    this.aes.fill(0); this.iv.fill(0); this.macKey.fill(0);
  }
}
