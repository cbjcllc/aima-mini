import { VehicleConfig } from './VehicleBleService';
import { requestProximityPermissions } from './ProximityPermissions';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import geoLocationManager from '@ohos.geoLocationManager';
import { common, wantAgent } from '@kit.AbilityKit';
import { VehicleBleService, VehicleSnapshot } from './VehicleBleService';

export class ProximityBackgroundService {
  private running: boolean = false;
  private locationActive: boolean = false;
  private context?: common.UIAbilityContext;
  private callback?: (message: string) => void;
  private locationCallback = (): void => {};
  private suspendCallback = (): void => {};
  private activeCallback = (): void => {};
  private cancelCallback = (): void => {};
  private retryTimer: number = -1;
  private retrying: boolean = false;
  private lastScanAt: number = 0;
  private generation: number = 0;
  private inductionConfirmed: boolean = false;
  private bluetoothTask: boolean = false;
  private confirmationBlocked: boolean = false;
  private vehicleService?: VehicleBleService;

  async start(context: common.UIAbilityContext, bleService: VehicleBleService, mac: string, config: VehicleConfig,
    onMessage: (message: string) => void): Promise<void> {
    if (this.running) { return; }
    const generation = ++this.generation;
    this.inductionConfirmed = false; this.confirmationBlocked = false; this.vehicleService = bleService;
    this.context = context; this.callback = onMessage;
    await requestProximityPermissions(context);
    if (generation !== this.generation) { return; }
    if (!geoLocationManager.isLocationEnabled()) { throw new Error('请先打开系统位置服务，再开启持续感应'); }
    const want = await wantAgent.getWantAgent({ wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
      operationType: wantAgent.OperationType.START_ABILITY, requestCode: 17,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    this.bluetoothTask = bleService.authenticated;
    request.backgroundTaskModes = this.bluetoothTask ?
      [backgroundTaskManager.BackgroundTaskMode.MODE_BLUETOOTH_INTERACTION, backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION] :
      [backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION];
    request.backgroundTaskSubmodes = this.bluetoothTask ?
      [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_CAR_KEY_NORMAL_NOTIFICATION, backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION] :
      [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
    request.wantAgent = want;
    await backgroundTaskManager.startBackgroundRunning(context, request);
    this.running = true;
    this.suspendCallback = () => this.message('后台感应暂时暂停，系统等待蓝牙恢复连接');
    this.activeCallback = () => this.message('后台感应已恢复');
    this.cancelCallback = () => {
      this.running = false; this.vehicleService?.cancelInductionSetup(); clearInterval(this.retryTimer);
      if (this.locationActive) { geoLocationManager.off('locationChange', this.locationCallback); this.locationActive = false; }
      this.message('后台感应任务已被系统停止');
    };
    backgroundTaskManager.on('continuousTaskSuspend', this.suspendCallback);
    backgroundTaskManager.on('continuousTaskActive', this.activeCallback);
    backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback);
    this.locationCallback = () => {
      if (!this.running || generation !== this.generation || this.retrying) { return; }
      if (bleService.authenticated && !this.inductionConfirmed) {
        if (this.confirmationBlocked) { return; }
        if (Date.now() - this.lastScanAt < 15000) { return; }
        this.lastScanAt = Date.now();
        this.retrying = true;
        this.message('已连接车辆，正在开启并核对车端感应设置');
        this.confirmInduction(bleService, generation, context).catch((error: Error) => {
          if (generation === this.generation) {
            this.confirmationBlocked = error.message.indexOf('配对') >= 0;
            this.message('感应设置确认失败：' + error.message + (this.confirmationBlocked ? '；请停止后重新开启持续感应重试' : '，将重试'));
          }
        }).finally(() => { if (generation === this.generation) { this.retrying = false; } });
        return;
      }
      if (!bleService.authenticated) { this.inductionConfirmed = false; }
      if (bleService.connectionActive || Date.now() - this.lastScanAt < 15000) { return; }
      this.retrying = true; this.lastScanAt = Date.now();
      try { bleService.configure(config); } catch (_) { this.retrying = false; return; }
      bleService.autoConnect(context, mac, true).then(() => {
        if (generation === this.generation) { this.message('等待车辆靠近，找到后自动连接认证'); }
      }).catch((error: Error) => {
        if (generation === this.generation) { this.message('等待连接：' + error.message); }
      }).finally(() => { if (generation === this.generation) { this.retrying = false; } });
    };
    geoLocationManager.on('locationChange', { priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
      scenario: geoLocationManager.LocationRequestScenario.DAILY_LIFE_SERVICE, timeInterval: 30, distanceInterval: 30 }, this.locationCallback);
    this.locationActive = true;
    this.retryTimer = setInterval(() => this.locationCallback(), 2000);
    this.message('持续感应等待首次连接，靠近车辆后自动认证');
    this.locationCallback();
  }
  private async confirmInduction(bleService: VehicleBleService, generation: number,
    context: common.UIAbilityContext): Promise<void> {
    await bleService.enableInduction();
    if (!this.running || generation !== this.generation) { return; }
    await bleService.queryInduction();
    if (!bleService.inductionEnabled) { throw new Error('车辆感应设置仍为关闭'); }
    if (!this.running || generation !== this.generation) { return; }
    if (!this.bluetoothTask) {
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_BLUETOOTH_INTERACTION,
        backgroundTaskManager.BackgroundTaskMode.MODE_LOCATION];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_CAR_KEY_NORMAL_NOTIFICATION,
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
      request.wantAgent = await wantAgent.getWantAgent({ wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        operationType: wantAgent.OperationType.START_ABILITY, requestCode: 17,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] });
      backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        await backgroundTaskManager.startBackgroundRunning(context, request);
      } finally { backgroundTaskManager.on('continuousTaskCancel', this.cancelCallback); }
      if (!this.running || generation !== this.generation) { return; }
      this.bluetoothTask = true;
    }
    this.inductionConfirmed = true;
    this.message('持续感应运行中，车端设置已确认');
  }
  async stop(): Promise<void> {
    this.vehicleService?.cancelInductionSetup();
    this.generation++; this.retrying = false; this.lastScanAt = 0; this.inductionConfirmed = false;
    clearInterval(this.retryTimer);
    this.running = false;
    if (this.locationActive) { geoLocationManager.off('locationChange', this.locationCallback); this.locationActive = false; }
    if (this.context) { await backgroundTaskManager.stopBackgroundRunning(this.context); }
    backgroundTaskManager.off('continuousTaskSuspend', this.suspendCallback);
    backgroundTaskManager.off('continuousTaskActive', this.activeCallback);
    backgroundTaskManager.off('continuousTaskCancel', this.cancelCallback);
    this.running = false; this.callback = undefined;
  }
  get isRunning(): boolean { return this.running; }
  private message(value: string): void { this.callback?.(value); }
}
