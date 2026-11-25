import { CloudVehicle } from './AimaCloudService';
import { VehicleConfig, nativeCommandBindings } from './VehicleBleService';

// VehicleBean.toBleJson passes vehicle.uuid; AdbBleBridgeImpl reads it as "uuid".
// The login account's userId is a different field and must never substitute for it.
export function accountVehicleConfig(vehicle: CloudVehicle): VehicleConfig {
  if (vehicle.evcuType === undefined || vehicle.evcuType === null) {
    throw new Error('车辆未返回蓝牙协议类型，无法自动选择连接协议');
  }
  if (String(vehicle.evcuType) !== '2' && String(vehicle.evcuType) !== '10') {
    throw new Error('车辆蓝牙协议类型为 ' + String(vehicle.evcuType) + '，当前支持类型 2 和 10');
  }
  if (String(vehicle.evcuType) === '2' && (typeof vehicle.uuid !== 'string' || !vehicle.uuid.trim())) {
    throw new Error('车辆未返回蓝牙授权 UUID，不能用登录用户 ID 替代');
  }
  if (typeof vehicle.bluetoothKey !== 'string' || !vehicle.bluetoothKey) {
    throw new Error('车辆未返回蓝牙密钥，无法完成车辆验证');
  }
  if (typeof vehicle.bluetoothMac !== 'string' || !/^[0-9a-fA-F]{12}$/.test(vehicle.bluetoothMac.replace(/[:-]/g, '').trim())) {
    throw new Error('车辆未返回有效蓝牙地址，无法自动寻找车辆');
  }
  const config = new VehicleConfig();
  config.protocolType = Number(vehicle.evcuType);
  config.userId = vehicle.uuid || '';
  config.bluetoothKey = vehicle.bluetoothKey;
  config.bindings = config.protocolType === 10 ? [] : nativeCommandBindings();
  return config;
}
