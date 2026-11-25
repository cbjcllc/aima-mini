import { Standard10Session, StandardMessage, encodeStandard, standardAdvertisedMac, AUTH10, CONTROL10, QUERY10, REPORT10 } from '../protocol/Standard10';
import { access, ble, constant } from '@kit.ConnectivityKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { nativeV2Transport, nativeCharacteristicRole } from '../protocol/NativeV2Profile';
import { HarmonyV2Crypto, hexBytes } from '../protocol/HarmonyV2Crypto';
import { LocalClock, CommandResult, manualBody, inductionBody,
  encodeFrame, decodeNotification, parseCommandResult, nextSerial, uppercaseHex, encodeConnection, parseConnectionResult,
  queryBody, parseVehicleStatus } from '../protocol/NativeV2';

export class NearbyVehicle {
  id: string;
  name: string;
  rssi: number;
  vehicleMac: string;
  constructor(id: string, name: string, rssi: number, vehicleMac: string = '') {
    this.id = id; this.name = name; this.rssi = rssi; this.vehicleMac = vehicleMac;
  }
}

export class CommandBinding {
  action: string = '';
  category: number = 1;
  commandId: number = -1;
  parameter: number = 0;
}

// APK AdbVehicleBleCmdSender and AdbVehicleCommand object pool, native plugin path.
export function nativeCommandBindings(): CommandBinding[] {
  return [
    { action: 'lock', category: 1, commandId: 2, parameter: 1 },
    { action: 'unlock', category: 1, commandId: 2, parameter: 0 },
    { action: 'horn', category: 1, commandId: 1, parameter: 1 },
    { action: 'seat', category: 1, commandId: 4, parameter: 1 }
  ];
}

export class VehicleConfig {
  protocolType: number = 2;
  serviceUuid: string = '';
  writeUuid: string = '';
  notifyUuid: string = '';
  userId: string = '';
  bluetoothKey: string = '';
  nativeTransport: boolean = true;
  aesKeyHex: string = '';
  ivHex: string = '';
  hmacKeyHex: string = '';
  bindings: CommandBinding[] = [];
}

export class VehicleSnapshot {
  status: string = '未连接车辆';
  deviceName: string = '';
  scanning: boolean = false;
  connected: boolean = false;
  ready: boolean = false;
  busy: boolean = false;
  devices: NearbyVehicle[] = [];
  characteristics: string[] = [];
  lockState: string = '车辆状态未知';
  hornState: number = -1;
  powerState: number = -1;
  seatState: number = -1;
}

class PendingCommand {
  category: number;
  commandId: number;
  parameter: number;
  action: string;
  resolve: (result: CommandResult) => void;
  reject: (reason: Error) => void;
  timer: number = -1;
  constructor(binding: CommandBinding, resolve: (result: CommandResult) => void, reject: (reason: Error) => void) {
    this.category = binding.category; this.commandId = binding.commandId;
    this.parameter = binding.parameter === 0 ? 0 : 1; this.action = binding.action;
    this.resolve = resolve; this.reject = reject;
  }
}

class StandardPending {
  uuid: string;
  command: number;
  resolve: (message: StandardMessage) => void;
  reject: (error: Error) => void;
  timer: number = -1;
  constructor(uuid: string, command: number, resolve: (message: StandardMessage) => void, reject: (error: Error) => void) {
    this.uuid = uuid; this.command = command; this.resolve = resolve; this.reject = reject;
  }
}

export class VehicleBleService {
  private standard?: Standard10Session;
  private standardCharacteristics: Map<string, ble.BLECharacteristic> = new Map();
  private standardBuffers: Map<string, Uint8Array> = new Map();
  private standardPending?: StandardPending;
  private standardRx: Promise<void> = Promise.resolve();
  private heartbeatTimer: number = -1;
  private authDelayTimer: number = -1;
  private authDelayReject?: (error: Error) => void;
  private state: VehicleSnapshot = new VehicleSnapshot();
  private listener: (state: VehicleSnapshot) => void = () => {};
  private client?: ble.GattClientDevice;
  private config: VehicleConfig = new VehicleConfig();
  private crypto?: HarmonyV2Crypto;
  private writeCharacteristic?: ble.BLECharacteristic;
  private pending?: PendingCommand;
  private serial: number = 1;
  private scanTimer: number = -1;
  private connectTimer: number = -1;
  private prepareTimer: number = -1;
  private generation: number = 0;
  private disposed: boolean = false;
  private requestingPermission: boolean = false;
  private seenNotifications: Set<string> = new Set<string>();
  private credentialsUser: string = '';
  private credentialsKey: string = '';
  private notifyCharacteristic?: ble.BLECharacteristic;
  private targetMac: string = '';
  private autoHandshake: boolean = false;
  private autoHandshakeStarted: boolean = false;
  private handshakeTimer: number = -1;
  private writeType: ble.GattWriteType = ble.GattWriteType.WRITE;

  observe(listener: (state: VehicleSnapshot) => void): void {
    this.disposed = false; this.listener = listener; this.publish();
  }

  private publish(): void {
    const next = new VehicleSnapshot();
    next.status = this.state.status; next.deviceName = this.state.deviceName;
    next.scanning = this.state.scanning; next.connected = this.state.connected;
    next.ready = this.state.ready; next.busy = this.state.busy;
    next.devices = this.state.devices.slice(); next.characteristics = this.state.characteristics.slice();
    next.lockState = this.state.lockState;
    next.hornState = this.state.hornState; next.powerState = this.state.powerState; next.seatState = this.state.seatState;
    this.listener(next);
  }

  private discovered = (results: ble.ScanResult[]): void => {
    if (!this.state.scanning || this.disposed) { return; }
    for (const result of results) {
      if (!result.connectable) { continue; }
      const advertisedMac = this.standard && result.data ? standardAdvertisedMac(new Uint8Array(result.data)) : '';
      const item = new NearbyVehicle(result.deviceId, result.deviceName || '未命名蓝牙设备', result.rssi, advertisedMac);
      const index = this.state.devices.findIndex((device: NearbyVehicle) => device.id === item.id);
      if (index < 0) { this.state.devices.push(item); } else { this.state.devices[index] = item; }
    }
    if (this.targetMac) {
      const target = this.state.devices.find((device: NearbyVehicle) =>
        device.vehicleMac === this.targetMac || device.id.replace(/[:-]/g, '').toUpperCase() === this.targetMac);
      if (target) {
        this.targetMac = '';
        try { this.connect(target, true); }
        catch (error) { this.state.status = (error as Error).message; this.publish(); }
        return;
      }
    }
    this.state.devices.sort((a: NearbyVehicle, b: NearbyVehicle) => b.rssi - a.rssi);
    this.publish();
  };

  async scan(context: common.UIAbilityContext): Promise<void> {
    if (this.state.scanning || this.requestingPermission || this.disposed) { return; }
    const scanGeneration = this.generation;
    this.requestingPermission = true;
    try {
    const permission = await abilityAccessCtrl.createAtManager()
      .requestPermissionsFromUser(context, ['ohos.permission.ACCESS_BLUETOOTH']);
    if (this.disposed || scanGeneration !== this.generation) { return; }
    if (permission.authResults.length === 0 || permission.authResults.some((value: number) => value !== 0)) {
      throw new Error('请在系统设置中允许蓝牙权限');
    }
    if (access.getState() !== access.BluetoothState.STATE_ON) { throw new Error('请先打开手机蓝牙'); }
    this.state.devices = [];
    ble.on('BLEDeviceFind', this.discovered);
    // SDK requires null for an unfiltered scan; an empty filter array is invalid.
    try { ble.startBLEScan(null); } catch (error) {
      ble.off('BLEDeviceFind', this.discovered); throw error as Error;
    }
    this.state.scanning = true; this.state.status = this.targetMac ? '正在寻找已选车辆（10 秒），找到后自动连接' : '正在搜索附近设备'; this.publish();
    this.scanTimer = setTimeout(() => {
      const automatic = this.targetMac.length > 0;
      try { this.stopScan(); if (automatic) { this.state.status = '未找到目标车辆（附近可连接设备 ' + this.state.devices.length + ' 台），请确认车辆未被其他 App 占用后重试'; this.publish(); } } catch (_) { this.state.status = '停止搜索失败，请检查系统蓝牙'; this.publish(); }
    }, this.targetMac ? 10000 : 15000);
    } finally { this.requestingPermission = false; }
  }

  stopScan(): void {
    this.targetMac = '';
    clearTimeout(this.scanTimer);
    if (!this.state.scanning) { return; }
    try { ble.stopBLEScan(); } finally {
      ble.off('BLEDeviceFind', this.discovered);
      this.state.scanning = false;
      this.state.status = this.state.connected ? '车辆已连接' : '搜索结束，请选择车辆';
      this.publish();
    }
  }

  async autoConnect(context: common.UIAbilityContext, mac: string): Promise<void> {
    const normalized = mac.trim().replace(/[:-]/g, '').toUpperCase();
    if (!/^[0-9A-F]{12}$/.test(normalized)) { throw new Error('车辆蓝牙 MAC 缺失或无效，请使用手动连接'); }
    if (!this.standard && (!this.crypto || !this.credentialsUser || !this.credentialsKey)) { throw new Error('车辆缺少蓝牙凭据，无法自动验证'); }
    if (this.requestingPermission) { throw new Error('正在申请蓝牙权限，请稍后重试'); }
    this.disconnect(false);
    this.targetMac = normalized;
    try { await this.scan(context); } catch (error) { this.targetMac = ''; throw error as Error; }
  }

  configure(config: VehicleConfig): void {
    if (this.client) { throw new Error('请先断开车辆再修改连接配置'); }
    const uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
    const hasUuids = config.serviceUuid.length > 0 || config.writeUuid.length > 0 || config.notifyUuid.length > 0;
    if (hasUuids && (!uuid.test(config.serviceUuid) || !uuid.test(config.writeUuid) || !uuid.test(config.notifyUuid))) {
      throw new Error('请填写完整的服务、写入和通知 UUID');
    }
    if (!Array.isArray(config.bindings) || typeof config.nativeTransport !== 'boolean') {
      throw new Error('配置格式无效：bindings 须为数组，nativeTransport 须为布尔值');
    }
    if (config.protocolType !== 2 && config.protocolType !== 10) { throw new Error('不支持该蓝牙协议'); }
    let standard: Standard10Session | undefined = undefined;
    if (config.protocolType === 10) { standard = new Standard10Session(config.bluetoothKey); }
    let provider: HarmonyV2Crypto | undefined = undefined;
    if (typeof config.userId !== 'string' || typeof config.bluetoothKey !== 'string' ||
      config.userId.length > 128 || config.bluetoothKey.length > 256) { throw new Error('用户 ID 或车辆密钥格式不正确'); }
    if (config.protocolType === 2 && (config.userId.length === 0) !== (config.bluetoothKey.length === 0)) { throw new Error('用户 ID 与车辆密钥须同时填写'); }
    if (config.protocolType === 2 && config.userId.length > 0) {
      provider = config.nativeTransport ? nativeV2Transport() :
        new HarmonyV2Crypto(hexBytes(config.aesKeyHex), hexBytes(config.ivHex), hexBytes(config.hmacKeyHex));
    }
    const actions: string[] = [];
    try {
    for (const binding of config.bindings) {
      if (['unlock', 'lock', 'horn', 'seat', 'inductionOn', 'inductionOff'].indexOf(binding.action) < 0 ||
        actions.indexOf(binding.action) >= 0 || [1, 4].indexOf(binding.category) < 0) {
        provider?.clear(); throw new Error('控车映射无效或重复；当前只允许手动和感应指令');
      }
      // Validate command range without transmitting anything.
      const clock = new LocalClock(2026, 1, 1, 0, 0, 0);
      if (binding.category === 1) { manualBody(clock, 1, binding.commandId, binding.parameter); }
      else { inductionBody(clock, 1, binding.commandId, binding.parameter); }
      actions.push(binding.action);
    }
    } catch (error) { provider?.clear(); throw error as Error; }
    this.crypto?.clear(); this.crypto = provider; this.standard?.clear(); this.standard = standard;
    // Do not retain the hex strings, only the in-memory provider and public mapping.
    const clean = new VehicleConfig();
    clean.protocolType = config.protocolType;
    clean.serviceUuid = config.serviceUuid.toLowerCase(); clean.writeUuid = config.writeUuid.toLowerCase();
    clean.notifyUuid = config.notifyUuid.toLowerCase(); clean.bindings = config.bindings;
    this.config = clean;
    this.credentialsUser = config.userId; this.credentialsKey = config.bluetoothKey;
    this.serial = 1;
    this.state.status = provider || standard ? '车辆凭据已配置，等待连接并握手验证' : '已启用原生 V2 特征发现，等待车辆凭据';
    this.publish();
  }

  connect(device: NearbyVehicle, automatic: boolean = false): void {
    this.disconnect(this.client !== undefined);
    this.stopScan();
    this.autoHandshake = automatic; this.autoHandshakeStarted = false;
    const client = ble.createGattClientDevice(device.id);
    this.client = client;
    const generation = this.generation;
    this.state.deviceName = device.name; this.state.characteristics = [];
    this.state.status = '正在连接 ' + device.name;
    client.on('BLEConnectionStateChange', (change: ble.BLEConnectionChangeState) => {
      if (generation !== this.generation) { return; }
      if (change.state === constant.ProfileConnectionState.STATE_CONNECTED) {
        if (this.state.connected) { return; }
        clearTimeout(this.connectTimer);
        this.prepareTimer = setTimeout(() => {
          if (generation !== this.generation) { return; }
          this.disconnect(); this.state.status = '车辆服务发现或订阅超时，请重试连接'; this.publish();
        }, 10000);
        this.state.connected = true; this.state.status = '正在发现车辆服务'; this.publish();
        this.prepare(client, generation).catch((error: Error) => {
          if (generation === this.generation) {
            this.disconnect(); this.state.status = error.message; this.publish();
          }
        });
      } else if (change.state === constant.ProfileConnectionState.STATE_DISCONNECTED) {
        this.disconnect(); this.state.status = '蓝牙连接已断开，请确认原版 App 未占用车辆后重试'; this.publish();
      }
    });
    client.on('BLEMtuChange', (mtu: number) => {
      if (generation === this.generation && mtu >= 23) { this.payloadSize = mtu - 3; this.startAutoHandshake(generation); }
    });
    client.on('BLECharacteristicChange', (characteristic: ble.BLECharacteristic) => {
      if (generation !== this.generation) { return; }
      if (this.standard) {
        const uuid = characteristic.characteristicUuid.toLowerCase();
        const expected = this.standardCharacteristics.get(uuid);
        if (!expected || characteristic.serviceUuid.toLowerCase() !== expected.serviceUuid.toLowerCase()) { return; }
        const bytes = new Uint8Array(characteristic.characteristicValue).slice();
        this.standardRx = this.standardRx.then(() => this.receiveStandard(uuid, bytes, generation)).catch((error: Error) => {
          if (generation === this.generation) { this.state.status = '协议 10 通知校验失败：' + error.message; this.publish(); }
        });
        return;
      }
      if (characteristic.serviceUuid.toLowerCase() !== this.notifyCharacteristic?.serviceUuid.toLowerCase() ||
        characteristic.characteristicUuid.toLowerCase() !== this.notifyCharacteristic?.characteristicUuid.toLowerCase()) { return; }
      this.receive(new Uint8Array(characteristic.characteristicValue), generation).catch((error: Error) => {
        if (generation === this.generation) { this.state.status = '通知校验失败：' + error.message; this.publish(); }
      });
    });
    this.connectTimer = setTimeout(() => {
      if (generation === this.generation) { this.disconnect(); this.state.status = '连接超时，请重试'; this.publish(); }
    }, 15000);
    try { client.connect(); } catch (error) { this.disconnect(); throw error as Error; }
    this.publish();
  }

  private async prepare(client: ble.GattClientDevice, generation: number): Promise<void> {
    const services = await client.getServices();
    if (generation !== this.generation) { return; }
    if (this.standard) { await this.prepareStandard(client, services, generation); return; }
    let writer: ble.BLECharacteristic | undefined = undefined;
    let notifier: ble.BLECharacteristic | undefined = undefined;
    let writeCandidates: ble.BLECharacteristic[] = [];
    let notifyCandidates: ble.BLECharacteristic[] = [];
    for (const service of services) {
      for (const characteristic of service.characteristics) {
        this.state.characteristics.push(service.serviceUuid + ' / ' + characteristic.characteristicUuid);
        if (this.config.serviceUuid.length === 0) {
          const role = nativeCharacteristicRole(characteristic.characteristicUuid);
          if (role === 'write') { writeCandidates.push(characteristic); }
          if (role === 'notify') { notifyCandidates.push(characteristic); }
          continue;
        }
        if (service.serviceUuid.toLowerCase() !== this.config.serviceUuid) { continue; }
        if (characteristic.characteristicUuid.toLowerCase() === this.config.writeUuid) { writer = characteristic; }
        if (characteristic.characteristicUuid.toLowerCase() === this.config.notifyUuid) { notifier = characteristic; }
      }
    }
    if (this.config.serviceUuid.length === 0) {
      if (writeCandidates.length !== 1 || notifyCandidates.length !== 1) {
        throw new Error('未找到唯一的 adb1/adb2 特征，请手动选择车辆特征');
      }
      writer = writeCandidates[0]; notifier = notifyCandidates[0];
    }
    this.publish();
    if (!writer || !notifier) { throw new Error('已连接，请在连接设置中配置正确的服务与特征 UUID'); }
    if ((!writer.properties?.write && !writer.properties?.writeNoResponse) ||
      (!notifier.properties?.notify && !notifier.properties?.indicate)) {
      throw new Error('特征不支持写入或通知；请确认设备传输方式');
    }
    this.writeType = writer.properties?.write ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE;
    await client.setCharacteristicChangeNotification(notifier, true);
    if (generation !== this.generation) { return; }
    clearTimeout(this.prepareTimer);
    this.writeCharacteristic = writer; this.notifyCharacteristic = notifier;
    this.state.ready = false;
    this.state.status = this.autoHandshake ? '车辆服务已就绪，正在协商蓝牙 MTU' :
      this.crypto ? '蓝牙通道已建立，请点击验证车辆完成握手' : '已发现原生 V2 通道，请配置车辆授权 UUID 与蓝牙密钥';
    this.publish();
    if (this.autoHandshake) {
      this.handshakeTimer = setTimeout(() => {
        if (generation !== this.generation || this.autoHandshakeStarted) { return; }
        this.disconnect();
        this.state.status = '蓝牙 MTU 协商超时，尚未发送握手，请重试连接'; this.publish();
      }, 8000);
    }
    try { client.setBLEMtuSize(511); } catch (_) {
      clearTimeout(this.handshakeTimer);
      throw new Error('蓝牙 MTU 协商启动失败，无法发送完整握手');
    }
    // MTU may have been reported before service discovery completed.
    if (this.payloadSize > 20) { this.startAutoHandshake(generation); }
  }

  private startAutoHandshake(generation: number): void {
    if (generation !== this.generation || !this.autoHandshake || this.autoHandshakeStarted || !this.writeCharacteristic) { return; }
    this.autoHandshakeStarted = true; clearTimeout(this.handshakeTimer);
    this.authenticate().catch((error: Error) => {
      // authenticate may close the session itself on rejection or timeout.
      if (generation === this.generation) { this.state.status = '自动验证失败：' + error.message; this.publish(); }
    });
  }

  private async prepareStandard(client: ble.GattClientDevice, services: ble.GattService[], generation: number): Promise<void> {
    const required = [AUTH10, CONTROL10, QUERY10, REPORT10];
    for (const service of services) {
      for (const characteristic of service.characteristics) {
        this.state.characteristics.push(service.serviceUuid + ' / ' + characteristic.characteristicUuid);
        const uuid = characteristic.characteristicUuid.toLowerCase();
        if (required.indexOf(uuid) < 0) { continue; }
        if (this.standardCharacteristics.has(uuid)) { throw new Error('协议 10 车辆特征重复，无法确定正确通道'); }
        this.standardCharacteristics.set(uuid, characteristic);
      }
    }
    for (const uuid of required) {
      const characteristic = this.standardCharacteristics.get(uuid);
      if (!characteristic || (!characteristic.properties?.notify && !characteristic.properties?.indicate)) {
        throw new Error('未找到协议 10 的 ' + uuid.substring(4, 8) + ' 通知特征');
      }
      if (uuid !== REPORT10 && !characteristic.properties?.write && !characteristic.properties?.writeNoResponse) {
        throw new Error('协议 10 特征不支持写入');
      }
      if (uuid === AUTH10) {
        await client.setCharacteristicChangeNotification(characteristic, true);
        if (generation !== this.generation) { return; }
      }
    }
    clearTimeout(this.prepareTimer);
    this.writeCharacteristic = this.standardCharacteristics.get(AUTH10);
    this.state.status = '协议 10 服务已就绪，正在协商 MTU'; this.publish();
    if (this.autoHandshake) {
      this.handshakeTimer = setTimeout(() => {
        if (generation !== this.generation || this.autoHandshakeStarted) { return; }
        this.disconnect(); this.state.status = '协议 10 MTU 协商超时，请重试'; this.publish();
      }, 8000);
    }
    client.setBLEMtuSize(511);
    if (this.payloadSize > 20) { this.startAutoHandshake(generation); }
  }

  private async writeStandard(uuid: string, packet: Uint8Array, generation: number): Promise<void> {
    const characteristic = this.standardCharacteristics.get(uuid); const client = this.client;
    if (generation !== this.generation || !characteristic || !client) { throw new Error('车辆连接已变化'); }
    if (packet.length > this.payloadSize) { throw new Error('MTU 无法容纳协议 10 数据包，请重新连接协商'); }
    const value: ble.BLECharacteristic = { serviceUuid: characteristic.serviceUuid,
      characteristicUuid: characteristic.characteristicUuid, characteristicValue: packet.buffer as ArrayBuffer,
      descriptors: characteristic.descriptors };
    await client.writeCharacteristicValue(value, characteristic.properties?.write ? ble.GattWriteType.WRITE : ble.GattWriteType.WRITE_NO_RESPONSE);
  }

  private async exchangeStandard(uuid: string, command: number, packet: Uint8Array, generation: number): Promise<StandardMessage> {
    if (this.standardPending) { throw new Error('正在等待协议 10 车辆应答'); }
    return new Promise<StandardMessage>((resolve, reject) => {
      const pending = new StandardPending(uuid, command, resolve, reject); this.standardPending = pending;
      pending.timer = setTimeout(() => {
        if (this.standardPending !== pending) { return; }
        this.standardPending = undefined; this.disconnect();
        this.state.status = '协议 10 车辆应答超时，请确认原版 App 已断开'; this.publish(); reject(new Error(this.state.status));
      }, 8000);
      this.writeStandard(uuid, packet, generation).catch((error: Error) => {
        if (this.standardPending !== pending) { return; }
        clearTimeout(pending.timer); this.standardPending = undefined; reject(error);
      });
    });
  }

  private async receiveStandard(uuid: string, bytes: Uint8Array, generation: number): Promise<void> {
    if (generation !== this.generation || !this.standard) { return; }
    const old = this.standardBuffers.get(uuid) || new Uint8Array(0);
    if (old.length + bytes.length > 1024) { this.standardBuffers.delete(uuid); throw new Error('通知缓冲超长'); }
    const buffer = new Uint8Array(old.length + bytes.length); buffer.set(old); buffer.set(bytes, old.length);
    let offset = 0;
    while (buffer.length - offset >= 2) {
      const length = buffer[offset + 1] + 2;
      if (length < 4) { this.standardBuffers.delete(uuid); throw new Error('应答包头错误'); }
      if (buffer.length - offset < length) { break; }
      const packet = buffer.slice(offset, offset + length); offset += length;
      const pending = this.standardPending;
      if (!pending || pending.uuid !== uuid) { continue; }
      const session = this.standard;
      const message = await session.decode(packet, pending.command === 0x83 && uuid === AUTH10);
      if (generation !== this.generation || this.standardPending !== pending) { return; }
      if (message.command !== pending.command) { continue; }
      clearTimeout(pending.timer); this.standardPending = undefined; pending.resolve(message);
    }
    if (generation === this.generation) { this.standardBuffers.set(uuid, buffer.slice(offset)); }
  }

  private async authenticateStandard(): Promise<void> {
    const session = this.standard; const generation = this.generation;
    if (!session || !this.client || !this.standardCharacteristics.has(AUTH10)) { throw new Error('请先连接协议 10 车辆'); }
    if (this.state.ready) { return; }
    if (this.state.busy) { throw new Error('正在等待车辆应答'); }
    this.state.busy = true; this.state.status = '正在执行协议 10 挑战鉴权'; this.publish();
    try {
      await this.writeStandard(AUTH10, await session.resetPacket(), generation);
      await new Promise<void>((resolve, reject) => {
        this.authDelayReject = reject;
        this.authDelayTimer = setTimeout(() => { this.authDelayReject = undefined; resolve(); }, 200);
      });
      if (generation !== this.generation) { throw new Error('车辆连接已变化'); }
      const response = await this.exchangeStandard(AUTH10, 0x83, await session.authPacket(), generation);
      await session.acceptAuth(response);
      if (generation !== this.generation || !this.client) { return; }
      for (const uuid of [CONTROL10, QUERY10, REPORT10]) {
        const characteristic = this.standardCharacteristics.get(uuid);
        if (!characteristic) { throw new Error('协议 10 特征已失效'); }
        await this.client.setCharacteristicChangeNotification(characteristic, true);
        if (generation !== this.generation || !this.client) { return; }
      }
      this.state.ready = true; this.state.status = '协议 10 车辆鉴权成功'; this.publish();
      this.scheduleStandardHeartbeat(generation);
    } catch (error) {
      if (generation === this.generation) { this.disconnect(); this.state.status = '协议 10 鉴权失败：' + (error as Error).message; this.publish(); }
      throw error as Error;
    } finally { if (generation === this.generation) { this.state.busy = false; this.publish(); } }
  }

  private scheduleStandardHeartbeat(generation: number): void {
    this.heartbeatTimer = setTimeout(async () => {
      if (generation !== this.generation || !this.standard || !this.state.ready) { return; }
      try {
        if (!this.state.busy) {
          // APK's normal heartbeat is unencrypted bind command 0x11; 0xff is its default user marker.
          const packet = await this.standardHeartbeatPacket();
          await this.writeStandard(AUTH10, packet, generation);
        }
      } catch (_) {
        if (generation === this.generation) { this.disconnect(); this.state.status = '协议 10 心跳发送失败，请重新连接'; this.publish(); }
        return;
      }
      if (generation === this.generation) { this.scheduleStandardHeartbeat(generation); }
    }, 5000);
  }

  private async standardHeartbeatPacket(): Promise<Uint8Array> {
    return encodeStandard(0x11, new Uint8Array([255]));
  }

  private async controlStandard(action: string): Promise<CommandResult> {
    const session = this.standard; const generation = this.generation;
    if (!session || !this.state.ready) { throw new Error('请先完成协议 10 车辆鉴权'); }
    if (this.state.busy) { throw new Error('正在等待车辆应答'); }
    let command = 0; let body = new Uint8Array(0);
    if (action === 'lock' || action === 'unlock') { command = 1; body = new Uint8Array([action === 'lock' ? 1 : 0]); }
    else if (action === 'horn') { command = 4; body = new Uint8Array([1, 3]); }
    else if (action === 'seat') { command = 11; body = new Uint8Array([1]); }
    else { throw new Error('协议 10 尚未接入该功能'); }
    this.state.busy = true; this.publish();
    try {
      const packet = await session.controlPacket(command, body);
      const response = await this.exchangeStandard(CONTROL10, command | 0x80, packet, generation);
      if (response.body.length === 0 || response.body[0] !== 0) { throw new Error('车辆未确认操作成功（返回 ' + (response.body.length ? response.body[0] : '空') + '）'); }
      if (action === 'lock') { this.state.lockState = '车辆已上锁'; }
      if (action === 'unlock') { this.state.lockState = '车辆已解锁'; }
      this.state.status = '协议 10 车辆已确认操作'; this.publish();
      return new CommandResult(1, command, body[0], true);
    } finally { if (generation === this.generation) { this.state.busy = false; this.publish(); } }
  }

  async control(action: string): Promise<CommandResult> {
    if (this.standard) { return this.controlStandard(action); }
    if (!this.state.ready || !this.crypto || !this.client || !this.writeCharacteristic) {
      throw new Error('请先连接车辆并配置已认证的本地会话');
    }
    if (this.state.busy) { throw new Error('正在等待车辆应答'); }
    const binding = this.config.bindings.find((item: CommandBinding) => item.action === action);
    if (!binding) { throw new Error('尚未配置该功能的已验证指令映射'); }
    this.state.busy = true; this.publish();
    const generation = this.generation;
    try {
      const now = new Date();
      const clock = new LocalClock(now.getFullYear(), now.getMonth() + 1, now.getDate(),
        now.getHours(), now.getMinutes(), now.getSeconds());
      const body = binding.category === 1 ? manualBody(clock, this.serial, binding.commandId, binding.parameter) :
        inductionBody(clock, this.serial, binding.commandId, binding.parameter);
      this.serial = nextSerial(this.serial);
      const packet = await encodeFrame(binding.category, body, this.crypto);
      if (generation !== this.generation || !this.client || !this.writeCharacteristic) { throw new Error('车辆已断开'); }
      // No unverified fragmentation scheme: require a complete frame to fit one ATT write.
      // Default ATT payload is 20 bytes; raise MTU only after its change event confirms negotiation.
      if (packet.length > this.payloadSize) { throw new Error('当前蓝牙 MTU 无法容纳完整指令，需确认车辆分包协议或协商更大 MTU'); }
      return await this.sendPacket(packet, binding);
    } finally {
      if (generation === this.generation) { this.state.busy = false; this.publish(); }
    }
  }

  private async sendPacket(packet: Uint8Array, binding: CommandBinding): Promise<CommandResult> {
    if (packet.length > this.payloadSize) { throw new Error('当前蓝牙 MTU 无法容纳完整指令，请等待协商或重新连接'); }
      const client = this.client;
      if (!client || !this.writeCharacteristic) { throw new Error('车辆已断开'); }
      const characteristic: ble.BLECharacteristic = {
        serviceUuid: this.writeCharacteristic.serviceUuid,
        characteristicUuid: this.writeCharacteristic.characteristicUuid,
        characteristicValue: packet.buffer as ArrayBuffer,
        descriptors: this.writeCharacteristic.descriptors
      };
      return await new Promise<CommandResult>((resolve, reject) => {
        const pending = new PendingCommand(binding, resolve, reject);
        this.pending = pending;
        pending.timer = setTimeout(() => {
          if (this.pending === pending) {
            this.pending = undefined; this.disconnect();
            this.state.status = '车辆应答超时，连接已关闭；操作结果未知'; this.publish();
            reject(new Error('车辆应答超时，操作结果未知；请检查车辆后再操作'));
          }
        }, 8000);
        client.writeCharacteristicValue(characteristic, this.writeType).catch((error: Error) => {
          if (this.pending === pending) {
            clearTimeout(pending.timer); this.pending = undefined; this.disconnect(); reject(error);
          }
        });
      });
  }

  async authenticate(): Promise<void> {
    if (this.standard) { await this.authenticateStandard(); return; }
    if (!this.crypto || !this.client || !this.writeCharacteristic || !this.credentialsUser || !this.credentialsKey) {
      throw new Error('请先配置用户 ID 与车辆蓝牙密钥并连接车辆');
    }
    if (this.state.busy) { throw new Error('正在等待车辆应答'); }
    if (this.state.ready) { return; }
    const generation = this.generation;
    this.state.busy = true; this.state.status = '正在验证车辆'; this.publish();
    try {
      const encoder = new util.TextEncoder();
      const packet = await encodeConnection(encoder.encodeInto(this.credentialsUser),
        encoder.encodeInto(this.credentialsKey), this.serial, this.crypto);
      this.serial = nextSerial(this.serial);
      if (generation !== this.generation) { throw new Error('车辆连接已变化'); }
      const binding = new CommandBinding(); binding.action = 'authenticate'; binding.category = 0;
      await this.sendPacket(packet, binding);
    } finally {
      if (generation === this.generation) { this.state.busy = false; this.publish(); }
    }
  }

  async queryStatus(): Promise<void> {
    if (this.standard) { throw new Error('协议 10 连接和基础控车已接入，完整状态查询仍待核对'); }
    if (!this.state.ready || !this.crypto) { throw new Error('请先完成车辆握手验证'); }
    if (this.state.busy) { throw new Error('正在等待车辆应答'); }
    const generation = this.generation;
    this.state.busy = true; this.publish();
    try {
      const now = new Date();
      const clock = new LocalClock(now.getFullYear(), now.getMonth() + 1, now.getDate(),
        now.getHours(), now.getMinutes(), now.getSeconds());
      const packet = await encodeFrame(3, queryBody(clock, this.serial), this.crypto);
      this.serial = nextSerial(this.serial);
      if (generation !== this.generation) { throw new Error('车辆连接已变化'); }
      const binding = new CommandBinding(); binding.action = 'query'; binding.category = 3;
      await this.sendPacket(packet, binding);
    } finally {
      if (generation === this.generation) { this.state.busy = false; this.publish(); }
    }
  }

  private payloadSize: number = 20;

  private async receive(packet: Uint8Array, generation: number): Promise<void> {
    if (!this.crypto) { return; }
    const observedPending = this.pending;
    {
      const plaintext = await decodeNotification(packet, this.crypto);
      if (generation !== this.generation) { return; }
      const fingerprint = uppercaseHex(packet);
      if (this.seenNotifications.has(fingerprint)) { return; }
      if (this.seenNotifications.size >= 256) {
        this.disconnect(); throw new Error('请重新建立本地会话');
      }
      this.seenNotifications.add(fingerprint);
      if (observedPending && this.pending === observedPending && observedPending.action === 'authenticate') {
        if (plaintext.length < 11 || plaintext[9] !== 2) { return; }
        const success = parseConnectionResult(plaintext);
        clearTimeout(observedPending.timer); this.pending = undefined;
        if (!success) {
          this.disconnect(); this.state.status = '车辆拒绝握手，请检查车辆授权 UUID、密钥和协议类型'; this.publish();
          observedPending.reject(new Error('车辆握手验证失败')); return;
        }
        this.state.ready = true; this.state.status = '车辆握手验证成功'; this.publish();
        observedPending.resolve(new CommandResult(0, 0, 0, true)); return;
      }
      if (!this.state.ready) { return; }
      if (plaintext.length > 11 && plaintext[9] === 0x40 && plaintext[11] === 3) {
        if (!observedPending || observedPending.action !== 'query' || this.pending !== observedPending) { return; }
        const status = parseVehicleStatus(plaintext.slice(9));
        clearTimeout(observedPending.timer); this.pending = undefined;
        if (!status.success) { observedPending.reject(new Error('车辆状态查询失败')); return; }
        this.state.hornState = status.horn; this.state.powerState = status.power; this.state.seatState = status.seat;
        // The native parser gives raw values but does not establish lock polarity here.
        this.state.status = '车辆状态已更新（锁状态原始值 ' + status.lock + '）'; this.publish();
        observedPending.resolve(new CommandResult(3, 0, 0, true)); return;
      }
      if (plaintext.length < 12 || plaintext[9] !== 0x40 || plaintext[10] !== 0x40) { return; }
      const result = parseCommandResult(plaintext.slice(9));
      const pending = this.pending;
      if (!pending || pending !== observedPending || pending.category !== result.category || pending.commandId !== result.commandId ||
        pending.parameter !== result.commandParameter) { return; }
      clearTimeout(pending.timer); this.pending = undefined;
      if (!result.success) { pending.reject(new Error('车辆拒绝了该指令')); return; }
      if (pending.action === 'lock') { this.state.lockState = '车辆已上锁'; }
      if (pending.action === 'unlock') { this.state.lockState = '车辆已解锁'; }
      this.state.status = '车辆已确认操作'; this.publish(); pending.resolve(result);
    }
  }

  disconnect(clearSession: boolean = true): void {
    this.generation++; clearTimeout(this.heartbeatTimer); clearTimeout(this.authDelayTimer);
    this.authDelayReject?.(new Error('车辆连接已取消')); this.authDelayReject = undefined;
    if (this.standardPending) {
      clearTimeout(this.standardPending.timer); this.standardPending.reject(new Error('车辆连接已断开，操作结果未知'));
      this.standardPending = undefined;
    }
    this.standardCharacteristics.clear(); this.standardBuffers.clear(); this.standardRx = Promise.resolve();
    if (clearSession) { this.standard?.clear(); this.standard = undefined; }
    clearTimeout(this.connectTimer); clearTimeout(this.prepareTimer); clearTimeout(this.handshakeTimer);
    this.autoHandshake = false; this.autoHandshakeStarted = false; this.targetMac = '';
    try { this.stopScan(); } catch (_) { /* Continue clearing the connection and credentials. */ }
    const client = this.client; this.client = undefined;
    if (client) {
      try { client.off('BLEConnectionStateChange'); client.off('BLECharacteristicChange'); client.off('BLEMtuChange'); }
      catch (_) {}
      try { client.disconnect(); } catch (_) {}
      try { client.close(); } catch (_) {}
    }
    if (this.pending) {
      clearTimeout(this.pending.timer); this.pending.reject(new Error('车辆连接已断开，操作结果未知'));
      this.pending = undefined;
    }
    if (clearSession) {
      this.crypto?.clear(); this.crypto = undefined; this.credentialsUser = ''; this.credentialsKey = '';
    }
    this.payloadSize = 20; this.writeCharacteristic = undefined; this.notifyCharacteristic = undefined; this.seenNotifications.clear();
    this.state.connected = false; this.state.ready = false; this.state.busy = false;
    this.state.hornState = -1; this.state.powerState = -1; this.state.seatState = -1;
    this.state.lockState = '车辆状态未知'; this.state.status = '未连接车辆'; this.publish();
  }

  dispose(): void {
    this.disposed = true;
    try { this.stopScan(); } finally { this.disconnect(); this.listener = () => {}; }
  }
}
