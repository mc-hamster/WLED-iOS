import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../../wled/Resources/DeviceWorkspace.bundle/bridge.js', import.meta.url), 'utf8');

function environment(responder, href = 'wled-local://device/settings/leds') {
  const calls = [];
  const listeners = new Map();
  const context = {URL, URLSearchParams, Request, Response, Blob, FormData, TextEncoder, TextDecoder, Uint8Array, ArrayBuffer,
    EventTarget, Event, MessageEvent, CloseEvent: class extends Event { constructor(name, init) { super(name); Object.assign(this,init); } },
    btoa, atob, setTimeout, clearTimeout, console, location: Object.assign(new URL(href), {reload() {}}),
    document: {hidden:true, addEventListener(name, fn) {listeners.set(name,fn)}, documentElement:{classList:{add(){}}}},
    HTMLFormElement: class {}, HTMLAnchorElement: class { click() {} }, fetch: globalThis.fetch};
  context.window = context;
  context.webkit = {messageHandlers:{workspace:{postMessage:async payload => {calls.push(payload); return responder?.(payload) ?? {status:200,type:'application/json',body:btoa('{"success":true}')}; }}}};
  vm.createContext(context);
  vm.runInContext(source, context);
  return {context,calls,listeners};
}

test('JSON fetch preserves method, query and exact UTF-8 bytes', async () => {
  const {context,calls} = environment();
  const response = await context.fetch('/json/state?test=1', {method:'post',body:'{"n":"灯 💡"}'});
  assert.equal(response.status,200);
  assert.equal(calls[0].method,'POST');
  assert.equal(calls[0].path,'/json/state?test=1');
  assert.equal(Buffer.from(calls[0].body,'base64').toString(),' {"n":"灯 💡"}'.trim());
});

test('device bridge rejects other hosts and network protocols', async () => {
  const {context,calls} = environment();
  await assert.rejects(() => context.fetch('http://192.168.1.5/json'));
  await assert.rejects(() => context.fetch('https://example.com/json'));
  await assert.rejects(() => context.fetch('wled-local://another-device/json'));
  assert.equal(calls.length,0);
});

test('controller-file origin keeps fetch, XHR and WebSocket on the selected native device', async () => {
  const {context,calls} = environment(undefined, 'wled-local://files/custom/index.htm?deviceFile=1');
  await context.fetch('palette.json?revision=2');
  assert.equal(calls[0].path, '/custom/palette.json?revision=2');
  const xhr = new context.XMLHttpRequest();
  xhr.open('POST', '/json/state');
  await xhr.send('{"bri":88}');
  assert.equal(xhr.status, 200);
  assert.equal(calls[1].path, '/json/state');
  assert.equal(Buffer.from(calls[1].body, 'base64').toString(), '{"bri":88}');
  const socket = new context.WebSocket('ws://files/ws');
  await new Promise(resolve => socket.onopen = resolve);
  socket.send('{"on":true}');
  await socket.chain;
  socket.close();
  assert.equal(calls[2].path, '/json/state');
  assert.equal(calls[3].path, '/json/si');
  await assert.rejects(() => context.fetch('wled-local://foreign/json'));
  await assert.rejects(() => context.fetch('http://files/json'));
  assert.throws(() => new context.WebSocket('ws://foreign/ws'));
  assert.equal(calls.length, 4);
});

test('zero-byte file uses staged upload instead of losing filename', async () => {
  const {context,calls} = environment();
  const form = new FormData(); form.append('data',new Blob([]),'empty.css');
  await context.fetch('/upload',{method:'POST',body:form});
  assert.equal(calls[0].action,'upload');
  assert.equal(calls[0].path,'/empty.css');
  assert.equal(calls[0].body,'');
});

test('URL encoded forms retain duplicate ordered fields', async () => {
  const {context,calls} = environment();
  const form = new FormData(); form.append('type','bool'); form.append('enabled','on'); form.append('type','int'); form.append('value','10');
  await context.fetch('/settings/um',{method:'POST',body:form});
  assert.equal(Buffer.from(calls[0].body,'base64').toString(),'type=bool&enabled=on&type=int&value=10');
});

test('401 requests native PIN prompt and preserves response status', async () => {
  const {context,calls} = environment(value => value.action === 'request' ? {status:401,type:'text/plain',body:btoa('PIN required')} : {});
  const response = await context.fetch('/json/cfg');
  assert.equal(response.status,401);
  assert.equal(calls[1].action,'unlock');
});

test('XHR retains response text and load/ready-state event ordering', async () => {
  const {context} = environment(() => ({status:200,type:'application/json',body:btoa('[1,2]')}));
  const events=[];
  const xhr = new context.XMLHttpRequest();
  xhr.onreadystatechange=()=>events.push(xhr.readyState);
  xhr.onload=()=>events.push('load');
  xhr.open('GET','/json/effects');
  await xhr.send();
  assert.deepEqual(events,[1,2,4,'load']);
  assert.equal(xhr.responseText,'[1,2]');
  assert.equal(xhr.getResponseHeader('Content-Type'),'application/json');
});

test('pixel packets preserve the binary WebSocket DDP prefix', async () => {
  const {context,calls} = environment();
  const socket = new context.WebSocket('ws://device/ws');
  await new Promise(resolve=>socket.onopen=resolve);
  const bytes=new Uint8Array([2,0x41,0,0x0b,1,0,0,0,0,0,3,255,0,80]);
  socket.send(bytes.buffer);
  await socket.chain;
  socket.close();
  const request=calls.find(value=>value.path==='/ble/ddp');
  const body=JSON.parse(Buffer.from(request.body,'base64').toString());
  assert.deepEqual(Buffer.from(body.data,'base64'),Buffer.from(bytes));
});


test('detached export anchors reach the native share sheet exactly once', async () => {
  const {context,calls} = environment();
  const link = new context.HTMLAnchorElement();
  link.href = URL.createObjectURL(new Blob(['{"palette":[1,2,3]}']));
  link.download = 'palette.json';
  link.hasAttribute = name => name === 'download';
  link.click();
  for (let attempt = 0; attempt < 20 && !calls.some(call => call.action === 'download'); attempt++) await new Promise(resolve => setTimeout(resolve, 5));
  const downloads = calls.filter(call => call.action === 'download');
  assert.equal(downloads.length,1);
  assert.equal(downloads[0].name,'palette.json');
  assert.equal(Buffer.from(downloads[0].body,'base64').toString(),'{"palette":[1,2,3]}');
  URL.revokeObjectURL(link.href);
});

for (const [name, receipt, shouldReload, error, action = '/settings/ui', reset = false] of [
  ['confirmed settings', {success:true,saved:true}, true, false],
  ['restarting controller', {success:true,saved:true,reboot:true}, false, false],
  ['disabled Bluetooth', {success:true,saved:true,reconnect:true,bluetoothEnabled:false}, false, false],
  ['unconfirmed save', {success:true}, false, true],
  ['confirmed factory reset', {success:true,saved:false,reboot:true}, false, false, '/settings/sec', true],
  ['reboot without a saved receipt', {success:true,saved:false,reboot:true}, false, true],
  ['reset on the wrong settings page', {success:true,saved:false,reboot:true}, false, true, '/settings/ui', true],
  ['failed factory reset', {success:false,saved:false,reboot:true}, false, true, '/settings/sec', true]
]) {
  test(`form submission handles ${name} without a false saved state`, async () => {
    const {context,calls,listeners} = environment(value => value.action === 'request' ?
      {status:200,type:'application/json',body:btoa(JSON.stringify(receipt))} : {});
    context.FormData = class extends FormData { constructor() {super(); this.append('name','WLED'); if (reset) this.append('RS','on');} };
    let reloaded = false;
    context.location.reload = () => {reloaded=true};
    const button = {disabled:false};
    const form = {dataset:{}, reportValidity:()=>true, querySelectorAll:()=>[button], action,method:'post'};
    listeners.get('submit')({preventDefault(){},target:form});
    for (let attempt=0;attempt<20&&!calls.some(call=>call.action==='notice');attempt++) await new Promise(resolve=>setTimeout(resolve,5));
    await new Promise(resolve=>setTimeout(resolve,0));
    const notice = calls.find(call=>call.action==='notice');
    assert.ok(notice);
    assert.equal(!!notice.error,error);
    assert.equal(reloaded,shouldReload);
    assert.equal(button.disabled,false);
    if (receipt.bluetoothEnabled===false) assert.match(notice.message,/Bluetooth is now off/);
    if (reset && !error) assert.match(notice.message,/Factory reset completed/);
  });
}
