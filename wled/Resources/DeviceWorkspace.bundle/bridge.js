/* Offline WLED workspace. Device traffic is handled by the selected native connection. */
(() => {
  'use strict';
  const originalFetch = window.fetch.bind(window);
  const origin = location.protocol === 'wled-local:' && location.hostname === 'files' ? 'wled-local://files' : 'wled-local://device';
  const bridge = window.webkit.messageHandlers.workspace;
  const encode = bytes => { let s = ''; for (const b of bytes) s += String.fromCharCode(b); return btoa(s); };
  const decode = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
  const utf8 = text => new TextEncoder().encode(text);
  const localPath = input => {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    if (!['wled-local:', 'ws:', 'wss:'].includes(url.protocol) || !['device', 'files'].includes(url.hostname)) throw new TypeError('This link needs an external network connection.');
    return url.pathname + url.search;
  };
  const call = value => bridge.postMessage(value);
  async function request(input, options = {}) {
    const destination = new URL(typeof input === 'string' ? input : input.url, location.href);
    // Optional public catalogs/fonts remain available through the phone's internet
    // connection. Device operations never fall back to an HTTP host.
    const publicResources = new Set(['wled.github.io', 'dedehai.github.io', 'pixelmagictool.vercel.app']);
    if (['blob:', 'data:'].includes(destination.protocol) ||
        destination.protocol === 'https:' && publicResources.has(destination.hostname)) return originalFetch(input, options);
    const path = localPath(input);
    const method = (options.method || input.method || 'GET').toUpperCase();
    let body = options.body;
    if (body === undefined && input instanceof Request && !['GET', 'HEAD'].includes(method)) body = await input.arrayBuffer();
    let result;
    if (body instanceof FormData) {
      const files = [...body.entries()].filter(([, value]) => value instanceof Blob && (value.name || value.size > 0));
      if (files.length) {
        if (new URL(path, origin).pathname !== '/upload') throw new TypeError('This firmware uses USB for updates.');
        for (const [, file] of files) result = await call({action: 'upload', path: '/' + file.name.replace(/^\/+/, ''), body: encode(new Uint8Array(await file.arrayBuffer()))});
      } else body = new URLSearchParams([...body.entries()].filter(([, value]) => typeof value === 'string')).toString();
    }
    if (!result) {
      if (body instanceof Blob) body = await body.arrayBuffer();
      const bytes = body == null ? new Uint8Array() : typeof body === 'string' || body instanceof URLSearchParams ? utf8(String(body)) : new Uint8Array(body);
      result = await call({action: 'request', method, path, body: encode(bytes)});
    }
    const response = new Response(decode(result.body), {status: result.status, headers: {'Content-Type': result.type}});
    if (result.status === 401) await call({action: 'unlock'});
    return response;
  }
  window.fetch = request;
  class LocalXHR extends EventTarget {
    constructor() { super(); this.readyState = 0; this.status = 0; this.responseType = ''; this.responseText = ''; this.response = null; this.upload = new EventTarget(); this.aborted = false; }
    open(method, url, async = true) { if (!async) throw new TypeError('Use asynchronous device requests.'); this.method = method; this.url = url; this.readyState = 1; this.emit('readystatechange'); }
    setRequestHeader() {}
    getResponseHeader(name) { return this.headers?.get(name) ?? null; }
    getAllResponseHeaders() { return [...(this.headers ?? [])].map(([k,v]) => `${k}: ${v}\r\n`).join(''); }
    overrideMimeType() {}
    abort() { this.aborted = true; this.emit('abort'); this.emit('loadend'); }
    emit(name) { const event = new Event(name); this.dispatchEvent(event); this['on' + name]?.(event); }
    async send(body = null) {
      try {
        const response = await request(this.url, {method: this.method, body});
        if (this.aborted) return;
        this.status = response.status; this.headers = response.headers; this.readyState = 2; this.emit('readystatechange');
        const bytes = await response.arrayBuffer();
        this.responseText = new TextDecoder().decode(bytes);
        this.response = this.responseType === 'arraybuffer' ? bytes : this.responseType === 'blob' ? new Blob([bytes], {type: this.headers.get('Content-Type')}) : this.responseType === 'json' ? JSON.parse(this.responseText) : this.responseText;
        this.readyState = 4; this.emit('readystatechange'); this.emit('load'); this.emit('loadend');
      } catch (error) { if (!this.aborted) { this.readyState = 4; this.status = 0; this.emit('readystatechange'); this.emit('error'); this.emit('loadend'); } }
    }
  }
  window.XMLHttpRequest = LocalXHR;
  class LocalSocket extends EventTarget {
    static CONNECTING = 0; static OPEN = 1; static CLOSING = 2; static CLOSED = 3;
    constructor(url) {
      super(); localPath(url); this.readyState = 0; this.bufferedAmount = 0; this.binaryType = 'arraybuffer'; this.live = false; this.lastStateAt = 0; this.chain = Promise.resolve();
      setTimeout(() => { if (this.readyState !== 0) return; this.readyState = 1; this.emit('open', new Event('open')); this.poll(); }, 0);
    }
    emit(name, event) { this.dispatchEvent(event); this['on' + name]?.(event); }
    async poll() {
      if (this.readyState !== 1 || document.hidden) { if (this.readyState === 1) this.timer = setTimeout(() => this.poll(), 1000); return; }
      try {
        if (this.live && Date.now() - this.lastStateAt > 2000) {
          const state = await request('/json/si');
          if (state.ok && this.readyState === 1) this.emit('message', new MessageEvent('message', {data: await state.text()}));
          this.lastStateAt = Date.now();
        }
        const response = await request(this.live ? '/json/live' : '/json/si');
        if (!response.ok) throw new Error('Device disconnected.');
        const text = await response.text();
        if (this.readyState !== 1) return;
        if (this.live) {
          const data = JSON.parse(text), matrix = data.w && data.h;
          const head = matrix ? [76, 2, data.w, data.h] : [76, 1];
          const rgb = data.leds.flatMap(value => { const color = value.length > 6 ? value.substring(2) : value; return [parseInt(color.slice(0,2),16), parseInt(color.slice(2,4),16), parseInt(color.slice(4,6),16)]; });
          this.emit('message', new MessageEvent('message', {data: new Uint8Array([...head, ...rgb]).buffer}));
        } else this.emit('message', new MessageEvent('message', {data: text}));
      } catch (error) { this.emit('error', new Event('error')); this.close(); return; }
      this.timer = setTimeout(() => this.poll(), this.live ? 350 : 1800);
    }
    send(data) {
      if (this.readyState !== 1) throw new Error('Device connection is closed.');
      if (typeof data === 'string') {
        const value = JSON.parse(data);
        if ('lv' in value) { this.live = !!value.lv; return; }
      }
      const size = typeof data === 'string' ? utf8(data).length : data.byteLength;
      if (this.bufferedAmount + size > 32768) throw new Error('Bluetooth is busy. Slow down the pixel stream.');
      this.bufferedAmount += size;
      this.chain = this.chain.then(async () => {
        if (this.readyState !== 1) return;
        const response = typeof data === 'string' ? await request('/json/state', {method: 'POST', body: data}) : await request('/ble/ddp', {method: 'POST', body: JSON.stringify({data: encode(new Uint8Array(data))})});
        if (!response.ok) throw new Error('Device rejected the command.');
        if (typeof data === 'string') {
          const state = await request('/json/si');
          if (state.ok && this.readyState === 1) this.emit('message', new MessageEvent('message', {data: await state.text()}));
        }
      }).catch(() => { this.emit('error', new Event('error')); this.close(); }).finally(() => { this.bufferedAmount -= size; });
    }
    close() { if (this.readyState === 3) return; this.readyState = 3; clearTimeout(this.timer); this.emit('close', new CloseEvent('close', {code: 1000})); }
  }
  window.WebSocket = LocalSocket;
  async function submit(form) {
    if (form.dataset.sending || !form.reportValidity()) return;
    form.dataset.sending = 'true';
    const buttons = [...form.querySelectorAll('button[type="submit"],input[type="submit"]')];
    buttons.forEach(button => button.disabled = true);
    try {
      const fields = new FormData(form);
      const resetting = new URL(form.action || location.href, location.href).pathname === '/settings/sec' && fields.has('RS');
      const result = await request(form.action || location.href, {method: form.method || 'POST', body: fields});
      if (!result.ok) throw new Error(result.status === 401 ? 'Unlock settings, then save again.' : await result.text());
      const receipt = await result.json();
      const resetConfirmed = resetting && receipt.success === true && receipt.saved === false && receipt.reboot === true;
      if (receipt.saved !== true && !resetConfirmed) throw new Error('WLED has not confirmed that these settings were saved. Refresh before trying again.');
      const message = resetConfirmed ? 'Factory reset completed. WLED is restarting with default settings.' :
        receipt.bluetoothEnabled === false ? 'Settings saved. Bluetooth is now off. Enable it through Wi-Fi or USB to connect again.' :
        receipt.reboot ? 'Settings saved. WLED is restarting. Your workspace will return when it reconnects.' :
        receipt.reconnect ? 'Settings saved. Bluetooth is reconnecting. If the pairing code changed, pair again with the new code.' : 'Settings saved on WLED.';
      await call({action: 'notice', message});
      if (!receipt.reboot && !receipt.reconnect) location.reload();
    } catch (error) { await call({action: 'notice', message: error.message, error: true}); }
    finally { delete form.dataset.sending; buttons.forEach(button => button.disabled = false); }
  }
  HTMLFormElement.prototype.submit = function() { void submit(this); };
  document.addEventListener('submit', event => { event.preventDefault(); void submit(event.target); });
  const isDownload = link => link && (link.href.startsWith('blob:') || link.hasAttribute('download'));
  async function downloadLink(link) {
    try {
      let bytes;
      if (link.href.startsWith('blob:')) bytes = await (await originalFetch(link.href)).arrayBuffer();
      else {
        const response = await request(link.href);
        if (!response.ok) throw new Error('The backup could not be read. Unlock settings and try again.');
        bytes = await response.arrayBuffer();
      }
      await call({action:'download', name: link.download || new URL(link.href).pathname.split('/').pop(), body: encode(new Uint8Array(bytes))});
    } catch (error) { await call({action:'notice', message:error.message, error:true}); }
  }
  const originalAnchorClick = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function() {
    if (isDownload(this)) { void downloadLink(this); return; }
    originalAnchorClick.call(this);
  };
  document.addEventListener('click', event => {
    const link = event.target.closest?.('a');
    if (isDownload(link)) { event.preventDefault(); void downloadLink(link); }
  });
  document.addEventListener('DOMContentLoaded', () => {
    document.documentElement.classList.add('native-workspace');
    const style = document.createElement('link'); style.rel = 'stylesheet'; style.href = origin + '/native.css'; document.head.appendChild(style);
    const meta = document.querySelector('meta[name="viewport"]'); if (meta) meta.content = 'width=device-width, initial-scale=1, viewport-fit=cover';
    // The firmware assumes a one-line banner. Native fonts and narrow screens
    // can wrap it, so keep fixed controls clear of its actual rendered height.
    const header = document.querySelector('#top.wrapper');
    if (header) {
      const banner = document.getElementById('devBanner'), footer = document.getElementById('bot');
      const size = () => {
        for (const [name, element] of [['banner', banner], ['header', header], ['footer', footer]]) {
          document.documentElement.style.setProperty('--native-' + name + '-height', Math.ceil(element?.getBoundingClientRect().height || 0) + 'px');
        }
      };
      const observer = new ResizeObserver(size);
      for (const element of [banner, header, footer]) if (element) observer.observe(element);
      style.addEventListener('load', size);
      size();
    }
  });
})();
