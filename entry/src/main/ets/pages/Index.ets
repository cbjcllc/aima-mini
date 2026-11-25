import { accountVehicleConfig } from '../services/AccountVehicleProfile';
import { AimaCloudService, CloudVehicle } from '../services/AimaCloudService';
import { common } from '@kit.AbilityKit';
import { VehicleBleService, VehicleSnapshot, NearbyVehicle, VehicleConfig, CommandBinding, nativeCommandBindings } from '../services/VehicleBleService';

@Entry
@Component
struct Index {
  @State selectedTab: number = 0;
  @State vehicle: VehicleSnapshot = new VehicleSnapshot();
  @State showConnection: boolean = false;
  @State serviceUuid: string = '';
  @State writeUuid: string = '';
  @State notifyUuid: string = '';
  @State sessionInput: string = '';
  @State userId: string = '';
  @State bluetoothKey: string = '';
  @State bindingInput: string = JSON.stringify(nativeCommandBindings());
  private bleService: VehicleBleService = new VehicleBleService();
  @State seatOpen: boolean = false;
  @State induction: boolean = false;
  private cloud: AimaCloudService = new AimaCloudService();
  @State acceptedTerms: boolean = false;
  @State cloudReady: boolean = false;
  @State selectedVin: string = '';
  @State selectedProtocol: number = 2;
  @State selectedVehicleName: string = '';
  @State selectedMac: string = '';
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
        if (this.signedIn) { this.userId = this.cloud.userId; this.loadVehicles(); }
      })
      .catch(() => { this.cloudMessage = '无法初始化登录设备信息，请重新打开应用'; });
    this.bleService.observe((state: VehicleSnapshot) => {
      this.vehicle = state;
      if (!state.connected) { this.seatOpen = false; this.induction = false; }
    });
  }

  aboutToDisappear(): void {
    this.selectionGeneration++;
    this.bleService.dispose();
    this.cloud.release();
    if (this.smsTimer !== -1) { clearInterval(this.smsTimer); }
    this.sessionInput = ''; this.userId = ''; this.bluetoothKey = '';
  }

  private async scan(): Promise<void> {
    try {
      await this.bleService.scan(this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch (error) { this.tip((error as Error).message); }
  }

  private connect(device: NearbyVehicle): void {
    try { this.bleService.connect(device); } catch (error) { this.tip((error as Error).message); }
  }

  private saveConfig(): void {
    try {
      const config = this.sessionInput.trim().length > 0 ?
        JSON.parse(this.sessionInput) as VehicleConfig : new VehicleConfig();
      config.protocolType = this.selectedProtocol;
      config.userId = this.userId.trim(); config.bluetoothKey = this.bluetoothKey;
      if (config.nativeTransport === undefined) { config.nativeTransport = true; }
      config.serviceUuid = this.serviceUuid.trim();
      config.writeUuid = this.writeUuid.trim();
      config.notifyUuid = this.notifyUuid.trim();
      config.bindings = JSON.parse(this.bindingInput) as CommandBinding[];
      this.bleService.configure(config);
      this.sessionInput = ''; this.bluetoothKey = '';
      this.tip('配置已应用，连接后请验证车辆');
    } catch (error) { this.tip((error as Error).message); }
  }

  private async control(action: string): Promise<void> {
    try {
      await this.bleService.control(action);
      if (action === 'seat') { this.seatOpen = true; }
      if (action === 'inductionOn') { this.induction = true; }
      if (action === 'inductionOff') { this.induction = false; }
      this.tip('车辆已确认操作');
    } catch (error) { this.tip((error as Error).message); }
  }

  @Builder
  connectionPanel() {
    Column({ space: 14 }) {
      Row() {
        Text('连接我的车辆').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
        Text('收起').fontSize(13).fontColor(this.green).onClick(() => this.showConnection = false)
      }.width('100%')
      if (this.selectedVin) {
        Text('协议 ' + this.selectedProtocol + ' · 已选车辆：' + this.selectedVin + (this.selectedMac ? ' · ' + this.selectedMac : '')).fontSize(12).fontColor(this.green)
        Button('重新自动连接').backgroundColor(this.green).enabled(!this.vehicle.scanning && !this.vehicle.busy)
          .onClick(() => {
            const item = this.cloudVehicles.find((value: CloudVehicle) => value.vinCode === this.selectedVin);
            if (item) { this.selectVehicle(item); }
          })
      }
      Text(this.vehicle.status).fontSize(13).fontColor(this.green).width('100%')
      Row({ space: 12 }) {
        Button(this.vehicle.scanning ? '停止搜索' : '搜索附近车辆').layoutWeight(1).backgroundColor(this.green)
          .onClick(() => {
            if (this.vehicle.scanning) {
              try { this.bleService.stopScan(); } catch (error) { this.tip((error as Error).message); }
            } else { this.scan(); }
          })
        Button('断开').backgroundColor('#E9EFEB').fontColor('#345D49')
          .onClick(() => this.bleService.disconnect())
      }
      Text('仅连接自己的车辆；设备名称不代表车辆身份。').fontSize(11).fontColor('#85968A').width('100%')
      ForEach(this.vehicle.devices, (device: NearbyVehicle) => {
        Row() {
          Column({ space: 4 }) {
            Text(device.name).fontSize(14)
            Text(device.id + ' · ' + device.rssi + ' dBm').fontSize(10).fontColor('#85968A')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Button('连接').fontSize(12).height(32).backgroundColor(this.green)
            .onClick(() => this.connect(device))
        }.width('100%').padding({ top: 6, bottom: 6 })
      }, (device: NearbyVehicle) => device.id)
      Row({ space: 10 }) {
        Button(this.vehicle.ready ? '验证成功' : '验证车辆').backgroundColor(this.green).enabled(!this.vehicle.busy)
          .onClick(() => {
            this.bleService.authenticate().catch((error: Error) => this.tip(error.message));
          })
        Button('刷新状态').backgroundColor('#E9EFEB').fontColor('#345D49').enabled(this.selectedProtocol !== 10 && this.vehicle.ready && !this.vehicle.busy)
          .onClick(() => this.bleService.queryStatus().catch((error: Error) => this.tip(error.message)))
      }
      Text('用户与车辆凭据').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: '车辆授权 UUID（车辆接口返回，非登录用户 ID）', text: this.userId })
        .onChange((value: string) => this.userId = value)
      TextInput({ placeholder: '该车辆的蓝牙密钥（非账号密码）', text: this.bluetoothKey }).type(InputType.Password)
        .onChange((value: string) => this.bluetoothKey = value)
      Text(this.selectedProtocol === 10 ? '协议 10 自动识别鉴权、控车和状态通道，无需填写特征。' : '原生 V2 自动发现 adb1 通知和 adb2 写入特征；下方 UUID 可留空。').fontSize(11).fontColor('#85968A')
      Text('连接设置').fontSize(16).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: '服务 UUID', text: this.serviceUuid }).onChange((value: string) => this.serviceUuid = value)
      TextInput({ placeholder: '写入特征 UUID', text: this.writeUuid }).onChange((value: string) => this.writeUuid = value)
      TextInput({ placeholder: '通知特征 UUID', text: this.notifyUuid }).onChange((value: string) => this.notifyUuid = value)
      Text(this.selectedProtocol === 10 ? '协议 10 已配置上锁、解锁、寻车和座桶。' : '已配置原生 V2 上锁、解锁、寻车和座桶。高级映射仅填写已确认的参数。')
        .fontSize(11).fontColor('#85968A').width('100%')
      TextArea({ placeholder: '高级指令映射 JSON 数组', text: this.bindingInput })
        .height(90).onChange((value: string) => this.bindingInput = value)
      TextInput({ placeholder: '自定义传输参数 JSON（原生 V2 留空）', text: this.sessionInput })
        .type(InputType.Password).onChange((value: string) => this.sessionInput = value)
      Button('应用配置').width('100%').backgroundColor(this.green).onClick(() => this.saveConfig())
      if (this.vehicle.characteristics.length > 0) {
        Text('设备实际服务 / 特征').fontSize(13).width('100%')
        ForEach(this.vehicle.characteristics, (value: string) => {
          Text(value).fontSize(10).fontColor('#6D8476').width('100%').copyOption(CopyOptions.LocalDevice)
        })
      }
    }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(22)
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
    }.layoutWeight(1).onClick(action)
  }

  @Builder
  service(icon: string, title: string, subtitle: string, tint: string) {
    Row({ space: 12 }) {
      Text(icon).fontSize(24).fontColor(this.green).width(42).height(46)
        .textAlign(TextAlign.Center).backgroundColor(tint).borderRadius(14)
      Column({ space: 5 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#233C32')
        Text(subtitle).fontSize(10).fontColor('#96A19C')
      }.alignItems(HorizontalAlign.Start)
    }.layoutWeight(1).onClick(() => this.tip(title + '服务暂未接入'))
  }

  @Builder
  vehiclePage() {
    Column({ space: 20 }) {
      Row() {
        Row({ space: 7 }) {
          Text('AIMA').fontSize(25).fontWeight(FontWeight.Bold).fontStyle(FontStyle.Italic).fontColor('#153F31')
          Text('爱玛出行').fontSize(15).fontWeight(FontWeight.Medium).fontColor('#234D3C')
        }
        Blank()
        Text('＋').fontSize(28).fontColor('#244D3B').onClick(() => this.showConnection = !this.showConnection)
      }.width('100%').padding({ top: 14, bottom: 5 })

      if (this.showConnection) { this.connectionPanel() }

      Column() {
        Row() {
          Column({ space: 7 }) {
            Row({ space: 8 }) {
              Text(this.selectedVehicleName || this.vehicle.deviceName || '我的爱玛').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#193D2E')
              Text('⌄').fontSize(20).fontColor('#587768')
            }
            Text(this.vehicle.connected ? 'AIMA · 蓝牙连接' : '添加车辆，开启智能出行').fontSize(12).fontColor('#739084')
          }.alignItems(HorizontalAlign.Start)
          Blank()
          Text(this.vehicle.connected ? '● 已连接' : '○ 未连接').fontSize(11).fontColor('#42856A')
            .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor('#E3F3E9').borderRadius(20)
        }.width('100%')
        Image($r('app.media.scooter')).width('100%').height(220).objectFit(ImageFit.Contain)
          .margin({ top: 0, bottom: -6 })
        Row({ space: 6 }) {
          Text('●').fontSize(8).fontColor(this.green)
          Text(this.vehicle.lockState).fontSize(12).fontColor('#648174')
        }.margin({ bottom: 23 })
        Row() {
          Column({ space: 6 }) {
            Row({ space: 3 }) {
              Text('--').fontSize(36).fontWeight(FontWeight.Bold).fontColor('#173E2D')
              Text('%').fontSize(14).fontColor('#4D7160').margin({ top: 15 })
              Text('▰').fontSize(20).fontColor(this.green).margin({ left: 5, top: 8 })
            }
            Text('剩余电量').fontSize(11).fontColor('#84988C')
          }.layoutWeight(1)
          Divider().vertical(true).height(34).color('#D5E5DB')
          Column({ space: 6 }) {
            Row({ space: 4 }) {
              Text('--').fontSize(36).fontWeight(FontWeight.Bold).fontColor('#173E2D')
              Text('km').fontSize(13).fontColor('#4D7160').margin({ top: 15 })
            }
            Text('预计续航').fontSize(11).fontColor('#84988C')
          }.layoutWeight(1)
        }.width('100%')
      }.padding(20).width('100%').borderRadius(26)
        .linearGradient({ angle: 150, colors: [['#E2F5E9', 0], ['#F1F8EF', 0.65], ['#F9FBF7', 1]] })

      Column({ space: 22 }) {
        Row() {
          Text('智能控车').fontSize(17).fontWeight(FontWeight.Bold).fontColor('#243B30')
          Blank()
          Text('连接设置  ›').fontSize(11).fontColor('#94A39A').onClick(() => this.showConnection = !this.showConnection)
        }.width('100%')
        Row({ space: 16 }) {
          Button(this.vehicle.busy ? '等待车辆应答…' : this.vehicle.lockState === '车辆已解锁' ? '▢  点击上锁' : '▣  点击解锁')
            .fontSize(18).fontWeight(FontWeight.Medium).fontColor(Color.White)
            .backgroundColor(this.green).borderRadius(18).height(62).layoutWeight(1)
            .enabled(!this.vehicle.busy)
            .onClick(() => this.control(this.vehicle.lockState === '车辆已解锁' ? 'lock' : 'unlock'))
          Column({ space: 5 }) {
            Text(this.vehicle.ready ? '✓' : '○').fontSize(21).fontColor(this.green)
            Text('车辆状态').fontSize(10).fontColor('#6D8476')
          }.width(66)
        }.width('100%')
        Row() {
          this.action('⌁', '寻车鸣笛', false, () => this.control('horn'))
          this.action('▱', this.seatOpen ? '座桶已开' : '打开座桶', this.seatOpen, () => this.control('seat'))
          this.action('◉', '感应解锁', this.induction, () => this.control(this.induction ? 'inductionOff' : 'inductionOn'))
          this.action('⚙', '车辆设置', false, () => this.showConnection = !this.showConnection)
        }.width('100%')
      }.padding(20).width('100%').backgroundColor(Color.White).borderRadius(24)

      Row() {
        this.service('♧', '骑行记录', '记录每一份自由', '#EDF8F1')
        this.service('◇', '售后服务', '贴心守护每一程', '#F0F5FC')
      }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(22)
      Row() {
        Column({ space: 7 }) {
          Text('让每一程，都充满热爱').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#37624D')
          Text('骑上爱玛，发现身边的小美好').fontSize(11).fontColor('#78917E')
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text('GO ↗').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#629B70')
      }.width('100%').padding(20).backgroundColor('#E9F1DD').borderRadius(22)
        .onClick(() => this.tip('一起发现骑行的美好'))
      Text(this.vehicle.status + ' · 电量与续航暂无有效数据').fontSize(10).fontColor('#A3AEA8')
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
      this.signedIn = true; this.accountLabel = this.cloud.accountLabel; this.smsCode = ''; this.userId = this.cloud.userId;
      await this.loadVehicles();
    } catch (error) { this.cloudMessage = (error as Error).message; this.tip(this.cloudMessage); }
    finally { this.cloudBusy = false; }
  }

  private async loadVehicles(): Promise<void> {
    this.cloudBusy = true;
    try {
      this.cloudVehicles = await this.cloud.vehicles();
      this.cloudMessage = this.cloudVehicles.length > 0 ? '选择车辆，配置蓝牙连接' : '账号下暂无车辆';
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
    this.bleService.dispose();
    this.bleService.observe((state: VehicleSnapshot) => { this.vehicle = state; });
    this.cloudVehicles = []; this.userId = ''; this.bluetoothKey = '';
    this.selectedProtocol = 2;
    this.selectedVin = ''; this.selectedVehicleName = ''; this.selectedMac = '';
  }

  private async selectVehicle(item: CloudVehicle): Promise<void> {
    const selection = ++this.selectionGeneration;
    this.bleService.disconnect();
    this.selectedProtocol = Number(item.evcuType);
    this.selectedVin = item.vinCode; this.selectedVehicleName = item.vehicleNick || '我的爱玛';
    this.selectedMac = item.bluetoothMac || '';
    this.userId = ''; this.bluetoothKey = '';
    this.selectedTab = 0; this.showConnection = true;
    try {
      const config = accountVehicleConfig(item);
      this.bleService.configure(config); this.userId = config.userId;
      await this.cloud.rememberVehicle(item.vinCode);
      if (selection !== this.selectionGeneration) { return; }
      await this.bleService.autoConnect(this.getUIContext().getHostContext() as common.UIAbilityContext, item.bluetoothMac || '');
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
      Text('我的爱玛').fontSize(28).fontWeight(FontWeight.Bold).width('100%')
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
        Text('验证码仅在点击获取时发送。登录凭据安全保存在本机，重新打开可恢复登录；失效后需重新登录。')
          .fontSize(12).fontColor('#78917E')
      } else {
        Text('已登录 · ' + this.accountLabel).fontSize(16)
        Button('刷新我的车辆').backgroundColor(this.green).enabled(!this.cloudBusy).onClick(() => this.loadVehicles())
        ForEach(this.cloudVehicles, (item: CloudVehicle) => {
          Column({ space: 8 }) {
            Text(item.vehicleNick || '我的爱玛').fontSize(18)
            Text(item.vinCode).fontSize(12).fontColor('#78917E')
            Button('使用这辆车').backgroundColor(this.green).onClick(() => this.selectVehicle(item))
          }.padding(18).width('100%').backgroundColor(Color.White).borderRadius(18)
        }, (item: CloudVehicle) => item.vinCode)
        Button('退出登录').onClick(() => {
          try { this.cloud.logout(); } catch (error) { this.tip((error as Error).message); }
          this.clearAccountVehicle(); this.signedIn = false; this.accountLabel = '';
          this.cloudVehicles = []; this.userId = ''; this.bluetoothKey = '';
          this.cloudMessage = '已退出登录';
        })
      }
      Text(this.cloudMessage).fontSize(13).fontColor('#78917E')
    }.padding(24).width('100%')
  }

  @Builder
  otherPage(title: string, subtitle: string, icon: string) {
    Column({ space: 20 }) {
      Text(title).fontSize(28).fontWeight(FontWeight.Bold).fontColor('#193D2E').width('100%')
      Text(icon).fontSize(65).fontColor(this.green).margin({ top: 65 })
      Text(subtitle).fontSize(18).fontWeight(FontWeight.Medium).fontColor('#345D49')
      Text(this.selectedTab === 1 ? '骑行记录与沿途风景，将在这里相遇' : '连接你的爱玛，开启便捷出行生活')
        .fontSize(13).fontColor('#8A9E91')
      Button('返回我的车辆').backgroundColor(this.green).margin({ top: 20 })
        .onClick(() => this.selectedTab = 0)
    }.width('100%').padding(24)
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
        } else if (this.selectedTab === 1) {
          this.otherPage('发现', '每一程，都有新发现', '☼')
        } else {
          this.accountPage()
        }
      }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.Top)
      Row() {
        this.tab('▰', '爱车', 0)
        this.tab('◎', '发现', 1)
        this.tab('♙', '我的', 2)
      }.width('100%').backgroundColor(Color.White)
        .border({ width: { top: 0.5 }, color: '#E8EEE9' })
    }.width('100%').height('100%').backgroundColor('#F4F7F4')
  }
}
