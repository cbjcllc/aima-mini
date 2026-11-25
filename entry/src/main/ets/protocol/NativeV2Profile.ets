import { HarmonyV2Crypto, hexBytes } from './HarmonyV2Crypto';

// Protocol-wide transport constants recovered from the user-provided APK:
// classes7.dex Constant / classes.dex a.a.a.b. NOT vehicle authorization.
// Vehicle access still requires the current user's ID and per-vehicle bluetooth key.
export function nativeV2Transport(): HarmonyV2Crypto {
  return new HarmonyV2Crypto(
    hexBytes('FBBEC2E10221F96FB56E625AB71D91B2'),
    hexBytes('E3177768FB213BAE066632E3676575F8'),
    hexBytes('3031323334353637383930313233343536373839303132333435363738393132'));
}

// AdbBleManager.getUUID scans characteristics dynamically, not a hardcoded service UUID.
export function nativeCharacteristicRole(uuid: string): string {
  const value = uuid.toLowerCase();
  if (value.indexOf('adb1') >= 0) { return 'notify'; }
  if (value.indexOf('adb2') >= 0) { return 'write'; }
  return '';
}
