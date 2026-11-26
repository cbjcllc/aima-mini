const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const ts = require('/Applications/DevEco-Studio.app/Contents/plugins/codelinter/node_modules/typescript/lib/typescript.js');
const tick = () => new Promise(r => setImmediate(r));
function fixture() {
  const timers = new Map(), events = new Map(), tasks = [], messages = []; let id=0;
  const bg = { ContinuousTaskRequest: class {},
    BackgroundTaskMode: { MODE_BLUETOOTH_INTERACTION:5, MODE_LOCATION:4 },
    BackgroundTaskSubmode: { SUBMODE_CAR_KEY_NORMAL_NOTIFICATION:1, SUBMODE_NORMAL_NOTIFICATION:2 },
    startBackgroundRunning: async (_, request) => tasks.push(request.backgroundTaskModes),
    stopBackgroundRunning: async () => {}, on: (type, fn) => events.set(type, fn), off: type => events.delete(type) };
  const geo = { isLocationEnabled: () => true, on: () => {}, off: () => {},
    LocationRequestPriority: { LOW_POWER:0 }, LocationRequestScenario: { DAILY_LIFE_SERVICE:0 } };
  const mocks = {
    './ProximityPermissions': { requestProximityPermissions: async () => {} },
    './VehicleBleService': {}, '@ohos.resourceschedule.backgroundTaskManager': { default:bg },
    '@ohos.geoLocationManager': { default:geo },
    '@kit.AbilityKit': { wantAgent: { getWantAgent:async()=>({}), OperationType:{START_ABILITY:0},WantAgentFlags:{UPDATE_PRESENT_FLAG:0} } }
  };
  const module={exports:{}};
  const source=ts.transpileModule(fs.readFileSync('entry/src/main/ets/services/ProximityBackgroundService.ets','utf8'),{
    compilerOptions:{target:ts.ScriptTarget.ES2021,module:ts.ModuleKind.CommonJS}}).outputText;
  vm.runInThisContext(`(function(require,module,exports,setInterval,clearInterval){${source}\n})`)(
    name=>mocks[name],module,module.exports,(fn)=>{timers.set(++id,fn);return id;},key=>timers.delete(key));
  const service=new module.exports.ProximityBackgroundService();
  const ble={authenticated:false,connectionActive:false,inductionEnabled:false,scans:0,controls:0,
    configure:()=>{},autoConnect:async()=>{ble.scans++;},
    enableInduction:async()=>{ble.controls++;ble.inductionEnabled=true;},cancelInductionSetup:()=>{}, queryInduction:async()=>{ble.inductionEnabled=true;} };
  return {service,ble,tasks,messages,timers,events,start:()=>service.start({abilityInfo:{bundleName:'test',name:'EntryAbility'}},ble,'AA',{},m=>messages.push(m))};
}
test('continuous proximity can start disconnected and schedules first connection without manual authentication',async()=>{
  const f=fixture();await f.start();await tick();
  assert.equal(f.service.isRunning,true);assert.equal(f.ble.scans,1);assert.deepEqual(f.tasks,[[4]]);
  assert.equal(f.ble.controls,0);assert.ok(f.messages.some(m=>m.includes('首次连接')));
  await f.service.stop();assert.equal(f.timers.size,0);
});
test('already connected vehicle confirms induction before reporting running',async()=>{
  const f=fixture();f.ble.authenticated=true;f.ble.connectionActive=true;await f.start();await tick();await tick();
  assert.equal(f.ble.controls,1);assert.equal(f.ble.scans,0);assert.ok(f.messages.includes('持续感应运行中，车端设置已确认'));
  await f.service.stop();
});
test('failed vehicle confirmation never reports induction running',async()=>{
  const f=fixture();f.ble.authenticated=true;f.ble.enableInduction=async()=>{};f.ble.queryInduction=async()=>{};
  await f.start();await tick();await tick();assert.equal(f.messages.includes('持续感应运行中，车端设置已确认'),false);
  assert.ok(f.messages.some(m=>m.includes('仍为关闭')));await f.service.stop();
});

test('cancelled system pairing stops automatic prompts until the user restarts proximity',async()=>{
  const f=fixture();f.ble.authenticated=true;f.ble.connectionActive=true;
  f.ble.enableInduction=async()=>{f.ble.controls++;throw new Error('车辆系统蓝牙配对被取消');};
  await f.start();await tick();await tick();assert.equal(f.ble.controls,1);
  for(const timer of f.timers.values())timer();await tick();await tick();
  assert.equal(f.ble.controls,1);assert.ok(f.messages.some(m=>m.includes('停止后重新开启')));
  assert.equal(f.messages.includes('持续感应运行中，车端设置已确认'),false);await f.service.stop();
});
