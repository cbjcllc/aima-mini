import { BusinessError } from '@kit.BasicServicesKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';

export async function requestProximityPermissions(context: common.UIAbilityContext): Promise<void> {
  const manager = abilityAccessCtrl.createAtManager();
  const token = context.applicationInfo.accessTokenId;
  // System-grant KEEP_BACKGROUND_RUNNING is declared in the manifest, not a runtime dialog.
  const bluetooth: Permissions[] = ['ohos.permission.ACCESS_BLUETOOTH'];
  await manager.requestPermissionsFromUser(context, bluetooth);
  if (await manager.checkAccessToken(token, bluetooth[0]) !== 0) {
    await manager.requestPermissionOnSetting(context, bluetooth);
    if (await manager.checkAccessToken(token, bluetooth[0]) !== 0) { throw new Error('请允许蓝牙权限后再开启持续感应'); }
  }
  // Foreground location must be granted before requesting the separate background permission.
  await manager.requestPermissionsFromUser(context, ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION']);
  if (await manager.checkAccessToken(token, 'ohos.permission.APPROXIMATELY_LOCATION') !== 0) {
    await manager.requestPermissionOnSetting(context, ['ohos.permission.APPROXIMATELY_LOCATION', 'ohos.permission.LOCATION']);
    if (await manager.checkAccessToken(token, 'ohos.permission.APPROXIMATELY_LOCATION') !== 0) {
      throw new Error('请先允许位置权限，位置变化仅用于重新寻找车辆');
    }
  }
  if (await manager.checkAccessToken(token, 'ohos.permission.LOCATION_IN_BACKGROUND') !== 0) {
    // Request separately after foreground location. Do not assume this is manual_settings.
    const background: Permissions[] = ['ohos.permission.LOCATION_IN_BACKGROUND'];
    try {
      const result = await manager.requestPermissionsFromUser(context, background);
      if (await manager.checkAccessToken(token, background[0]) !== 0 && result.dialogShownResults?.[0] !== true) {
        await manager.requestPermissionOnSetting(context, background);
      }
    } catch (error) {
      if ((error as BusinessError).code !== 12100014) { throw error as Error; }
      // Only a runtime API's explicit type mismatch permits the manual-settings path.
      await manager.openPermissionOnSetting(context, background[0]);
    }
    if (await manager.checkAccessToken(token, 'ohos.permission.LOCATION_IN_BACKGROUND') !== 0) {
      throw new Error('尚未允许后台位置，请在位置权限中选择始终允许后重试');
    }
  }
}
