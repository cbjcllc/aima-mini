import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export interface CloudVehicle {
  vinCode: string;
  uuid?: string;
  owner?: number;
  evcuType?: string | number;
  vehicleNick?: string;
  bluetoothMac?: string;
  bluetoothKey?: string;
}
interface LoginData { accessToken: string; refreshToken?: string; userId: string; }
interface CachedSession { accessToken: string; refreshToken: string; userId: string; accountLabel: string; }
interface Envelope { code: string | number; message?: string; data: Object; }

// Recovered from AimaNetwork::_sign in the supplied APK. This is a public client salt.
const CLIENT_SALT: string = 'doTVIzldF06eFQf0vBIinsZS3piuFEMJ';
// AimaNetwork.post: path.substring(path.indexOf('/', 1)).
// The AOT immediate 2 is tagged Smi(1), not an index of zero.
export function signaturePath(path: string): string {
  const separator = path.indexOf('/', 1);
  if (!path.startsWith('/') || separator < 0) { throw new Error('接口签名路径格式无效'); }
  return path.substring(separator);
}

export function signingText(body: Record<string, string>): string {
  return CLIENT_SALT + Object.keys(body).sort().map((key: string) => key + body[key]).join('') + CLIENT_SALT;
}
export class AimaCloudService {
  private token: string = '';
  private identity: string = '';
  private label: string = '';
  private deviceCode: string = '';
  private devicePreferences?: preferences.Preferences;
  private generation: number = 0;
  private smsAfter: number = 0;
  private smsBusy: boolean = false;
  private alias(): Uint8Array { return new util.TextEncoder().encodeInto('aima.login.session.v1'); }
  private removeCachedSession(): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias());
    try { asset.removeSync(query); } catch (error) {
      if ((error as BusinessError).code !== asset.ErrorCode.NOT_FOUND) { throw error as Error; }
    }
  }
  private saveSession(session: CachedSession): void {
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, this.alias());
    attributes.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(JSON.stringify(session)));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { asset.addSync(attributes); } catch (_) { throw new Error('无法安全保存登录凭据，请重试'); }
  }
  private restoreSession(): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias()); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let values: asset.AssetMap[];
    try { values = asset.querySync(query); } catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) { return; }
      throw new Error('无法读取安全登录凭据，请解锁设备后重试');
    }
    if (values.length === 0) { return; }
    let session: CachedSession;
    try {
      const secret = values[0].get(asset.Tag.SECRET) as Uint8Array;
      session = JSON.parse(util.TextDecoder.create('utf-8').decodeToString(secret)) as CachedSession;
      if (!session || typeof session.accessToken !== 'string' || !session.accessToken ||
        typeof session.userId !== 'string' || !session.userId || typeof session.accountLabel !== 'string') {
        throw new Error('缓存格式无效');
      }
    } catch (_) { this.removeCachedSession(); return; }
    this.token = session.accessToken; this.identity = session.userId; this.label = session.accountLabel;
  }
  async initialize(context: common.UIAbilityContext): Promise<void> {
    const epoch = this.generation;
    const store = await preferences.getPreferences(context, { name: 'aima_device' });
    this.devicePreferences = store;
    const saved = await store.get('installationId', '');
    this.deviceCode = typeof saved === 'string' && saved.length > 0 ? saved : this.random(32);
    await store.put('installationId', this.deviceCode);
    await store.flush();
    if (epoch === this.generation) { this.restoreSession(); }
  }
  async lastVehicleVin(): Promise<string> {
    if (!this.identity || !this.devicePreferences) { return ''; }
    const value = await this.devicePreferences.get('vehicle.' + this.identity, '');
    return typeof value === 'string' ? value : '';
  }
  async rememberVehicle(vin: string): Promise<void> {
    if (!this.identity || !this.devicePreferences) { return; }
    await this.devicePreferences.put('vehicle.' + this.identity, vin);
    await this.devicePreferences.flush();
  }
  async proximityEnabled(vin: string): Promise<boolean> {
    if (!this.identity || !this.devicePreferences || !vin) { return false; }
    return (await this.devicePreferences.get('proximity.' + this.identity + '.' + vin, false)) === true;
  }
  async rememberProximity(vin: string, enabled: boolean): Promise<void> {
    if (!this.identity || !this.devicePreferences || !vin) { throw new Error('请先恢复账号和车辆信息'); }
    await this.devicePreferences.put('proximity.' + this.identity + '.' + vin, enabled);
    await this.devicePreferences.flush();
  }
  get accountLabel(): string { return this.label; }
  get userId(): string { return this.identity; }
  get loggedIn(): boolean { return this.token.length > 0; }
  private random(length: number): string {
    const alphabet: string = '1234567890qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM';
    const bytes = cryptoFramework.createRandom().generateRandomSync(length).data;
    let result = '';
    for (let i = 0; i < bytes.length; i++) { result += alphabet.charAt(bytes[i] % alphabet.length); }
    return result;
  }
  private async post(path: string, input: Record<string, string>, authenticated: boolean = false,
    loginHeader: boolean = false): Promise<Object> {
    if (authenticated && !this.loggedIn) { throw new Error('请先登录'); }
    if (!this.deviceCode) { this.deviceCode = this.random(32); }
    const epoch = this.generation;
    const body: Record<string, string> = {};
    Object.keys(input).forEach((key: string) => { body[key] = input[key]; });
    body['timestamp'] = Date.now().toString(); body['nonce'] = this.random(20); body['url'] = signaturePath(path);
    const digest = cryptoFramework.createMd('SHA1');
    await digest.update({ data: new util.TextEncoder().encodeInto(signingText(body)) });
    body['sign'] = Array.from((await digest.digest()).data).map((value: number) => value.toString(16).padStart(2, '0')).join('').toUpperCase();
    const headers: Record<string, string> = {
      'Content-Type': 'application/json', 'accept': 'application/json;charset=UTF-8',
      'brandType': '0', 'deviceType': 'ohos', 'platformId': 'ohos', 'UUID': this.deviceCode,
      'currentVersion': '1.0.0'
    };
    if (authenticated) { headers['Authorization'] = 'Bearer ' + this.token; }
    if (loginHeader) { headers['deviceCode'] = this.deviceCode; }
    const client = http.createHttp();
    try {
      const response = await client.request('https://app.aimaiot.cn' + path, {
        method: http.RequestMethod.POST, header: headers, extraData: JSON.stringify(body),
        connectTimeout: 15000, readTimeout: 15000, expectDataType: http.HttpDataType.STRING
      });
      if (epoch !== this.generation) { throw new Error('登录会话已变化，请重试'); }
      if (response.responseCode === 401) { this.logout(); throw new Error('登录已失效，请重新登录'); }
      if (response.responseCode !== 200) { throw new Error('服务请求失败（' + response.responseCode + '）'); }
      const result = JSON.parse(response.result as string) as Envelope;
      if (String(result.code) !== '0') { throw new Error((result.message || '服务未接受请求').substring(0, 160)); }
      return result.data;
    } finally { client.destroy(); }
  }
  async sendSms(mobile: string): Promise<void> {
    if (!/^1\d{10}$/.test(mobile)) { throw new Error('请输入正确的手机号'); }
    if (this.smsBusy || Date.now() < this.smsAfter) { throw new Error('请稍后再获取验证码'); }
    this.smsBusy = true;
    try {
      await this.post('/user/appUser/sendSmsCode', { 'mobile': mobile, 'type': '2' });
      this.smsAfter = Date.now() + 60000;
    } finally { this.smsBusy = false; }
  }
  async login(mobile: string, code: string): Promise<void> {
    if (!/^1\d{10}$/.test(mobile) || !/^\d{4,8}$/.test(code)) { throw new Error('请填写手机号和短信验证码'); }
    const data = await this.post('/user/appUser/ssoLoginBySms', { 'mobile': mobile, 'smsCode': code }, false, true) as LoginData;
    if (!data || typeof data.accessToken !== 'string' || !data.accessToken || !data.userId) {
      throw new Error('登录响应缺少用户凭据');
    }
    const session: CachedSession = { accessToken: data.accessToken,
      refreshToken: typeof data.refreshToken === 'string' ? data.refreshToken : '',
      userId: String(data.userId), accountLabel: mobile.substring(0, 3) + '****' + mobile.substring(7) };
    this.saveSession(session);
    this.token = session.accessToken; this.identity = session.userId; this.label = session.accountLabel;
  }
  async vehicles(): Promise<CloudVehicle[]> {
    const data = await this.post('/veh/userVehicleRelation/myVehicleList', {}, true);
    if (!Array.isArray(data)) { throw new Error('车辆列表格式不匹配，等待核对实际响应'); }
    const list = data as CloudVehicle[];
    return list.filter((item: CloudVehicle) => item !== null && typeof item === 'object' && typeof item.vinCode === 'string' && item.vinCode.length > 0);
  }
  release(): void { this.generation++; this.token = ''; this.identity = ''; this.label = ''; }
  logout(): void {
    this.release();
    try { this.removeCachedSession(); } catch (_) { throw new Error('登录已断开，但本地凭据清除失败，请重试退出登录'); }
  }
}
