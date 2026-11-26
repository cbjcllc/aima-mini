import { connection } from '@kit.ConnectivityKit';

// pairDevice starts pairing; only BONDED state confirms its completion.
export class VehiclePairing {
  private cancelWait?: (error: Error) => void;
  cancel(): void { this.cancelWait?.(new Error('车辆配对等待已取消')); }

  async ensure(deviceId: string): Promise<void> {
    if (connection.getPairState(deviceId) === connection.BondState.BOND_STATE_BONDED) { return; }
    if (this.cancelWait) { throw new Error('正在等待车辆配对'); }
    await new Promise<void>((resolve, reject) => {
      let finished = false;
      let timer: number = -1;
      const finish = (error?: Error): void => {
        if (finished) { return; }
        finished = true; clearTimeout(timer); this.cancelWait = undefined;
        try { connection.off('bondStateChange', changed); } catch (_) {}
        if (error) { reject(error); } else { resolve(); }
      };
      const changed = (event: connection.BondStateParam): void => {
        if (event.deviceId.toUpperCase() !== deviceId.toUpperCase()) { return; }
        if (event.state === connection.BondState.BOND_STATE_BONDED) { finish(); }
        else if (event.state === connection.BondState.BOND_STATE_INVALID) {
          finish(new Error('车辆系统蓝牙配对被取消或失败，请重新开启持续感应并确认系统配对弹窗'));
        }
      };
      this.cancelWait = (error: Error): void => finish(error);
      try {
        connection.on('bondStateChange', changed);
        timer = setTimeout(() => finish(new Error('车辆系统蓝牙配对超时，请保持应用前台并确认系统配对弹窗')), 30000);
        // Recheck after subscribing so a peripheral-initiated bond cannot be missed.
        const state = connection.getPairState(deviceId);
        if (state === connection.BondState.BOND_STATE_BONDED) { finish(); return; }
        if (state !== connection.BondState.BOND_STATE_BONDING) {
          connection.pairDevice(deviceId).then(() => {
            if (!finished && connection.getPairState(deviceId) === connection.BondState.BOND_STATE_BONDED) { finish(); }
          }).catch((error: Error) => finish(new Error('无法完成车辆系统蓝牙配对：' + error.message)));
        }
      } catch (error) { finish(new Error('无法检查或发起车辆系统蓝牙配对：' + (error as Error).message)); }
    });
  }
}
