import { ProximityBackgroundService } from '../services/ProximityBackgroundService';
import { accountVehicleConfig } from '../services/AccountVehicleProfile';
import { AimaCloudService, CloudVehicle } from '../services/AimaCloudService';
import { common } from '@kit.AbilityKit';
import { VehicleBleService, VehicleSnapshot } from '../services/VehicleBleService';

@Entry
@Component
struct Index {
  @State selectedTab: number = 0;
  @State vehicle: VehicleSnapshot = new VehicleSnapshot();
  @State showConnection: boolean = false;
  @State showDiagnostics: boolean = false;
  private proximity: ProximityBackgroundService = new ProximityBackgroundService();
  @State proximityRunning: boolean = false;
  @State proximityEnabled: boolean = false;
  @State proximityStarting: boolean = false;
  @State proximityMessage: string = '';
  private bleService: VehicleBleService = new VehicleBleService();
  @State seatOpen: boolean = false;
  private cloud: AimaCloudService = new AimaCloudService();
  @State acceptedTerms: boolean = false;
  @State cloudReady: boolean = false;
  @State selectedVin: string = '';
  @State selectedProtocol: number = 2;
  @State selectedVehicleName: string = '';
  @State mobile: string = '';
  @State smsCode: string = '';
  @State cloudBusy: boolean = false;
  @State accountLabel: string = '';
  @State signedIn: boolean = false;
  @State cloudVehicles: CloudVehicle[] = [];
  @State cloudMessage: string = '登录后获取账号下的车辆';
  @State smsSeconds: number = 0;
  private smsTimer: number = -1;
  private selectionGeneration: number = 0;
  private green: string = '#00A879';

  aboutToAppear(): void {
    this.cloud.initialize(this.getUIContext().getHostContext() as common.UIAbilityContext)
      .then(() => {
        this.cloudReady = true; this.signedIn = this.cloud.loggedIn; this.accountLabel = this.cloud.accountLabel;
        if (this.signedIn) { this.loadVehicles(); }
      })
      .catch(() => { this.cloudMessage = '无法初始化登录设备信息，请重新打开应用'; });
    this.bleService.observe((state: VehicleSnapshot) => {
      this.vehicle = state;
      if (!state.connected) { this.seatOpen = false; }
    });
  }

  aboutToDisappear(): void {
    this.selectionGeneration++;
    this.proximity.stop().catch(() => {});
    this.bleService.dispose();
    this.cloud.release();
    if (this.smsTimer !== -1) { clearInterval(this.smsTimer); }
  }

  private async startProximity(item: CloudVehicle, selection: number): Promise<void> {
    this.proximityStarting = true;
    try {
      await this.proximity.start(this.getUIContext().getHostContext() as common.UIAbilityContext, this.bleService,
        item.bluetoothMac || '', accountVehicleConfig(item), (message: string) => {
          if (selection === this.selectionGeneration) { this.proximityMessage = message; this.proximityRunning = this.proximity.isRunning; }
        });
      if (selection === this.selectionGeneration) { this.proximityRunning = this.proximity.isRunning; }
    } finally { if (selection === this.selectionGeneration) { this.proximityStarting = false; } }
  }

  private async toggleProximity(): Promise<void> {
    if (this.proximityStarting) { return; }
    const item = this.cloudVehicles.find((value: CloudVehicle) => value.vinCode === this.selectedVin);
    if (!item || !item.bluetoothMac) { this.tip('请先选择带蓝牙地址的车辆'); return; }
    const selection = this.selectionGeneration;
    try {
      if (this.proximityEnabled) {
        await this.cloud.rememberProximity(item.vinCode, false);
        this.proximityEnabled = false;
        await this.proximity.stop(); this.proximityRunning = false;
        this.proximityMessage = '持续感应已关闭'; return;
      }
      await this.startProximity(item, selection);
      if (selection !== this.selectionGeneration || !this.proximity.isRunning) { return; }
      await this.cloud.rememberProximity(item.vinCode, true);
      if (selection === this.selectionGeneration) { this.proximityEnabled = true; }
    } catch (error) {
      if (!this.proximityEnabled) { await this.proximity.stop().catch(() => {}); this.proximityRunning = false; }
      this.tip((error as Error).message);
    }
  }

  private async control(action: string): Promise<void> {
    try {
      if (action === 'inductionOn' && this.selectedProtocol === 10) { await this.bleService.enableInduction(); }
      else { await this.bleService.control(action); }
      if (action === 'seat') { this.seatOpen = true; }
      this.tip('车辆已确认操作');
    } catch (error) { this.tip((error as Error).message); }
  }

  private connectionLabel(): string {
    if (!this.selectedVin) { return this.signedIn ? '请选择车辆' : '登录后连接车辆'; }
    if (this.vehicle.ready) { return '已连接'; }
    if (this.vehicle.connecting || this.vehicle.connected) { return '正在连接…'; }
    if (this.vehicle.scanning) { return '正在寻找车辆…'; }
    return '未连接';
  }

  private proximityLabel(): string {
    if (this.proximityStarting) { return '正在启动…'; }
    if (!this.proximityEnabled) { return '未开启'; }
    if (!this.proximityRunning || this.proximityMessage.indexOf('失败') >= 0 ||
      this.proximityMessage.indexOf('停止') >= 0) { return '需要处理，查看详情'; }
    if (this.proximityMessage.indexOf('暂停') >= 0) { return '暂时暂停'; }
    if (this.vehicle.ready && this.vehicle.inductionState === 1) { return '已就绪'; }
    if (this.proximityMessage.indexOf('配对') >= 0 || this.vehicle.status.indexOf('配对') >= 0) { return '请确认系统配对弹窗'; }
    return this.vehicle.ready ? '正在准备感应解锁…' : '等待靠近车辆';
  }

  @Builder
  connectionPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('连接详情').fontSize(17).fontWeight(FontWeight.Bold)
        Blank()
        Text('收起').fontSize(13).fontColor(this.green).onClick(() => this.showConnection = false)
      }.width('100%')
      Text(this.connectionLabel()).fontSize(14).fontColor(this.green).width('100%')
      if (this.selectedVin) {
        Button('重新连接').width('100%').backgroundColor(this.green)
          .enabled(!this.vehicle.scanning && !this.vehicle.busy && !this.proximityStarting)
          .onClick(() => {
            const item = this.cloudVehicles.find((value: CloudVehicle) => value.vinCode === this.selectedVin);
            if (item) { this.selectVehicle(item); }
          })
      }
      Text(this.showDiagnostics ? '收起故障详情' : '查看故障详情').fontSize(12).fontColor('#78917E')
        .onClick(() => this.showDiagnostics = !this.showDiagnostics)
      if (this.showDiagnostics) {
        Text(this.vehicle.status).fontSize(12).fontColor('#6D8476').width('100%').copyOption(CopyOptions.LocalDevice)
        if (this.proximityMessage) {
          Text(this.proximityMessage).fontSize(12).fontColor('#6D8476').width('100%').copyOption(CopyOptions.LocalDevice)
        }
      }
    }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(22)
  }

  @Builder
  proximityCard() {
    Column({ space: 14 }) {
      Row() {
        Column({ space: 6 }) {
          Text('持续感应').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#243B30')
          Text(this.proximityLabel()).fontSize(13).fontColor(this.green)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.proximityEnabled ? '关闭' : '开启').fontSize(14)
          .backgroundColor(this.proximityEnabled ? '#E9EFEB' : this.green)
          .fontColor(this.proximityEnabled ? '#345D49' : Color.White)
          .enabled(!this.proximityStarting).onClick(() => this.toggleProximity())
      }.width('100%')
      Text('开启后自动连接车辆，下次打开应用也会恢复。首次使用请确认系统蓝牙配对。')
        .fontSize(12).fontColor('#78917E').width('100%')
      if (this.proximityEnabled && (!this.proximityRunning || this.proximityMessage.indexOf('失败') >= 0 ||
        this.proximityMessage.indexOf('停止') >= 0)) {
        Text('查看原因  ›').fontSize(12).fontColor(this.green)
          .onClick(() => { this.showConnection = true; this.showDiagnostics = true; })
      }
    }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(24)
  }

  private tip(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
  }

  @Builder
  action(icon: string, title: string, active: boolean, action: () => void) {
    Column({ space: 10 }) {
      Text(icon).fontSize(25).fontColor(active ? this.green : '#263D36')
        .width(56).height(56).textAlign(TextAlign.Center)
        .backgroundColor(active ? '#E5F8EF' : '#F4F7F6').borderRadius(20)
      Text(title).fontSize(12).fontColor('#53635D')
    }.layoutWeight(1).enabled(this.vehicle.ready && !this.vehicle.busy).onClick(action)
  }

  @Builder
  vehiclePage() {
    Column({ space: 20 }) {
      Row() {
        Row({ space: 7 }) {
          Text('近骑').fontSize(25).fontWeight(FontWeight.Bold).fontStyle(FontStyle.Italic).fontColor('#153F31')
          Text('随身车钥匙').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#234D3C')
        }
        Blank()
        Text(this.signedIn ? '切换车辆' : '登录').fontSize(14).fontColor(this.green).onClick(() => this.selectedTab = 1)
      }.width('100%').padding({ top: 14, bottom: 5 })

      if (this.showConnection) { this.connectionPanel() }

      Column() {
        Row({ space: 12 }) {
          Column({ space: 7 }) {
            Text(this.selectedVehicleName || '我的车辆').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#193D2E')
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.selectedVin ? '随时准备出发' : '选择车辆，开启便捷出行').fontSize(12).fontColor('#739084')
              .width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Text(this.connectionLabel()).fontSize(11).fontColor('#42856A').maxLines(1).flexShrink(0)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor('#E3F3E9').borderRadius(20)
        }.width('100%')
        Image($r('app.media.scooter')).width('100%').height(190).objectFit(ImageFit.Contain)
          .margin({ top: 0, bottom: -6 })
        if (this.vehicle.ready && this.vehicle.lockState !== '车辆状态未知') {
          Text(this.vehicle.lockState).fontSize(13).fontColor('#648174').margin({ bottom: 12 })
        }
        if (!this.selectedVin) {
          Button(this.signedIn ? '选择我的车辆' : '登录并添加车辆').backgroundColor(this.green)
            .onClick(() => this.selectedTab = 1)
        }
      }.padding(20).width('100%').borderRadius(26)
        .linearGradient({ angle: 150, colors: [['#E2F5E9', 0], ['#F1F8EF', 0.65], ['#F9FBF7', 1]] })

      if (this.selectedVin && this.selectedProtocol === 10) { this.proximityCard() }

      if (this.selectedVin) {
        Column({ space: 22 }) {
          Row() {
            Text('智能控车').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#243B30')
            Blank()
            Text('连接详情  ›').fontSize(11).fontColor('#94A39A').onClick(() => this.showConnection = !this.showConnection)
          }.width('100%')
          Row({ space: 16 }) {
            Button(this.vehicle.busy ? '等待车辆应答…' : this.vehicle.lockState === '车辆已解锁' ? '▢  点击设防' : '▣  点击撤防')
              .fontSize(18).fontWeight(FontWeight.Medium).fontColor(Color.White)
              .backgroundColor(this.green).borderRadius(18).height(62).layoutWeight(1)
              .enabled(this.vehicle.ready && !this.vehicle.busy)
              .onClick(() => this.control(this.vehicle.lockState === '车辆已解锁' ? 'lock' : 'unlock'))
          }.width('100%')
          Row() {
            this.action('⌁', '寻车鸣笛', false, () => this.control('horn'))
            this.action('▱', this.seatOpen ? '座桶已开' : '打开座桶', this.seatOpen, () => this.control('seat'))
          }.width('100%')
          if (this.selectedProtocol === 10) {
            Row({ space: 12 }) {
              Button('车辆上电').layoutWeight(1).backgroundColor(this.green).enabled(this.vehicle.ready && !this.vehicle.busy)
                .onClick(() => this.control('powerOn'))
              Button('车辆断电').layoutWeight(1).backgroundColor('#E9EFEB').fontColor('#345D49').enabled(this.vehicle.ready && !this.vehicle.busy)
                .onClick(() => this.control('powerOff'))
            }.width('100%')
          }
        }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(24)

      }
    }.width('100%').padding({ left: 20, right: 20, bottom: 22 })
  }

  private async sendSms(): Promise<void> {
    if (!this.acceptedTerms) { this.tip('请先阅读并同意用户协议与隐私政策'); return; }
    this.cloudBusy = true;
    try {
      await this.cloud.sendSms(this.mobile.trim());
      this.smsSeconds = 60;
      this.smsTimer = setInterval(() => {
        this.smsSeconds--;
        if (this.smsSeconds <= 0) { clearInterval(this.smsTimer); this.smsTimer = -1; }
      }, 1000);
      this.tip('验证码已发送');
    } catch (error) { this.tip((error as Error).message); }
    finally { this.cloudBusy = false; }
  }

  private async login(): Promise<void> {
    if (!this.acceptedTerms) { this.tip('请先阅读并同意用户协议与隐私政策'); return; }
    this.cloudBusy = true;
    try {
      await this.cloud.login(this.mobile.trim(), this.smsCode.trim());
      this.signedIn = true; this.accountLabel = this.cloud.accountLabel; this.smsCode = '';
      await this.loadVehicles();
    } catch (error) { this.cloudMessage = (error as Error).message; this.tip(this.cloudMessage); }
    finally { this.cloudBusy = false; }
  }

  private async loadVehicles(): Promise<void> {
    this.cloudBusy = true;
    try {
      this.cloudVehicles = await this.cloud.vehicles();
      this.cloudMessage = this.cloudVehicles.length > 0 ? '选择您要使用的车辆' : '账号下暂无车辆';
      if (!this.selectedVin) {
        const previous = await this.cloud.lastVehicleVin();
        const candidate = this.cloudVehicles.find((item: CloudVehicle) => item.vinCode === previous);
        if (this.selectedVin) { return; }
        if (candidate) { await this.selectVehicle(candidate); }
        else if (this.cloudVehicles.length === 1) { await this.selectVehicle(this.cloudVehicles[0]); }
      }
    } catch (error) {
      this.signedIn = this.cloud.loggedIn;
      if (!this.signedIn) { this.clearAccountVehicle(); }
      this.cloudMessage = (error as Error).message;
    } finally { this.cloudBusy = false; }
  }

  private clearAccountVehicle(): void {
    this.selectionGeneration++;
    this.proximityEnabled = false; this.proximityRunning = false; this.proximityStarting = false; this.proximityMessage = '';
    this.proximity.stop().catch(() => {});
    this.bleService.dispose();
    this.bleService.observe((state: VehicleSnapshot) => { this.vehicle = state; });
    this.cloudVehicles = [];
    this.selectedProtocol = 2;
    this.selectedVin = ''; this.selectedVehicleName = '';
  }

  private async selectVehicle(item: CloudVehicle): Promise<void> {
    const selection = ++this.selectionGeneration;
    this.proximityEnabled = false; this.proximityStarting = false; this.proximityMessage = '';
    await this.proximity.stop();
    if (selection !== this.selectionGeneration) { return; } this.proximityRunning = false;
    this.bleService.disconnect();
    this.selectedProtocol = Number(item.evcuType);
    this.selectedVin = item.vinCode; this.selectedVehicleName = item.vehicleNick || '我的爱玛';
    this.selectedTab = 0; this.showConnection = false; this.showDiagnostics = false;
    try {
      const config = accountVehicleConfig(item);
      this.bleService.configure(config);
      await this.cloud.rememberVehicle(item.vinCode);
      if (selection !== this.selectionGeneration) { return; }
      const enabled = await this.cloud.proximityEnabled(item.vinCode);
      if (selection !== this.selectionGeneration) { return; }
      this.proximityEnabled = enabled;
      if (enabled) {
        this.proximityMessage = '正在恢复持续感应，等待重新连接并核对车端设置';
        try { await this.startProximity(item, selection); }
        catch (error) {
          if (selection === this.selectionGeneration) {
            await this.proximity.stop().catch(() => {}); this.proximityRunning = false;
            this.proximityMessage = '持续感应已保存，恢复失败：' + (error as Error).message + '；排除原因后重新连接车辆可重试';
          }
        }
      } else {
        await this.bleService.autoConnect(this.getUIContext().getHostContext() as common.UIAbilityContext, item.bluetoothMac || '');
      }
    } catch (error) { this.cloudMessage = (error as Error).message; this.tip(this.cloudMessage); }
  }

  private openTerms(privacy: boolean): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.startAbility({ action: 'ohos.want.action.viewData',
      uri: privacy ? 'https://amapp.aimaiot.cn/web/newPrivacy.html' : 'https://amapp.aimaiot.cn/web/newTerms.html'
    }).catch(() => this.tip('无法打开协议，请检查浏览器设置'));
  }

  @Builder
  accountPage() {
    Column({ space: 18 }) {
      Text('我的').fontSize(28).fontWeight(FontWeight.Bold).width('100%')
      if (!this.signedIn) {
        Text('手机号登录').fontSize(20).margin({ top: 36 })
        TextInput({ placeholder: '手机号', text: this.mobile }).type(InputType.PhoneNumber)
          .maxLength(11).onChange((value: string) => this.mobile = value)
        Row({ space: 10 }) {
          TextInput({ placeholder: '短信验证码', text: this.smsCode }).type(InputType.Number)
            .maxLength(8).layoutWeight(1).onChange((value: string) => this.smsCode = value)
          Button(this.smsSeconds > 0 ? this.smsSeconds + '秒后重试' : '获取验证码')
            .backgroundColor(this.green).enabled(this.cloudReady && !this.cloudBusy && this.smsSeconds === 0)
            .onClick(() => this.sendSms())
        }
        Button(this.cloudBusy ? '处理中…' : '登录').width('100%').backgroundColor(this.green)
          .enabled(this.cloudReady && !this.cloudBusy).onClick(() => this.login())
        Row({ space: 4 }) {
          Checkbox({ name: 'terms' }).select(this.acceptedTerms).selectedColor(this.green)
            .onChange((value: boolean) => this.acceptedTerms = value)
          Text('已阅读并同意').fontSize(11)
          Text('用户协议').fontSize(11).fontColor(this.green).onClick(() => this.openTerms(false))
          Text('及隐私政策').fontSize(11).fontColor(this.green).onClick(() => this.openTerms(true))
        }.width('100%')
        Text('使用爱玛账号登录，登录状态会安全保存在本机。')
          .fontSize(12).fontColor('#78917E')
      } else {
        Text('已登录 · ' + this.accountLabel).fontSize(16)
        Button('刷新我的车辆').backgroundColor(this.green).enabled(!this.cloudBusy).onClick(() => this.loadVehicles())
        ForEach(this.cloudVehicles, (item: CloudVehicle) => {
          Column({ space: 8 }) {
            Text(item.vehicleNick || '我的爱玛').fontSize(18)
            if (this.cloudVehicles.length > 1) {
              Text('车辆尾号 ' + item.vinCode.slice(-6)).fontSize(12).fontColor('#78917E')
            }
            Button(this.selectedVin === item.vinCode ? '当前车辆' : '使用这辆车').enabled(!this.cloudBusy && !this.proximityStarting).backgroundColor(this.green).onClick(() => this.selectVehicle(item))
          }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(18)
        }, (item: CloudVehicle) => item.vinCode)
        Button('退出登录').onClick(() => {
          try { this.cloud.logout(); } catch (error) { this.tip((error as Error).message); }
          this.clearAccountVehicle(); this.signedIn = false; this.accountLabel = '';
          this.cloudVehicles = [];
          this.cloudMessage = '已退出登录';
        })
      }
      Text(this.cloudMessage).fontSize(13).fontColor('#78917E')
    }.padding(24).width('100%')
  }

  @Builder
  tab(icon: string, label: string, index: number) {
    Column({ space: 5 }) {
      Text(icon).fontSize(23).fontWeight(FontWeight.Medium)
        .fontColor(this.selectedTab === index ? this.green : '#99A79F')
      Text(label).fontSize(10).fontWeight(this.selectedTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.selectedTab === index ? this.green : '#99A79F')
    }
      .layoutWeight(1).padding({ top: 13, bottom: 12 }).onClick(() => this.selectedTab = index)
  }

  build() {
    Column({ space: 0 }) {
      Scroll() {
        if (this.selectedTab === 0) {
          this.vehiclePage()

        } else {
          this.accountPage()
        }
      }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      Row() {
        this.tab('▰', '爱车', 0)
        this.tab('♙', '我的', 1)
      }.width('100%').backgroundColor(Color.White)
        .border({ width: { top: 0.5 }, color: '#E8EEE9' })
    }.width('100%').height('100%').backgroundColor('#F4F7F4')
  }
}
