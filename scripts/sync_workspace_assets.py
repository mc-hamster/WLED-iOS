#!/usr/bin/env python3
"""Vendor the checked-out firmware interface for offline, versioned iOS use."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def transform(relative: str, contents: bytes) -> bytes:
    """Apply the server's missing build transforms and selected-device routing."""
    if relative == 'index.js':
        text = contents.decode()
        start = text.index('function checkVersionUpgrade(info) {')
        end = text.index('function showVersionUpgradePrompt(', start)
        # Opening device controls must stay read-only. The firmware web UI's
        # upgrade-report prompt writes version-info.json even when reporting
        # is skipped or the initial read fails; it does not belong in the app.
        return (text[:start] + '''function checkVersionUpgrade(_info) {
  // The native workspace does not show upgrade-report prompts or persist telemetry preferences.
}

''' + text[end:]).encode()
    if relative == 'edit.htm':
        text = contents.decode()
        start = text.index("loadFiles('common.js', -1, () => {")
        end = text.index("\n\nvar QueuedRequester", start)
        text = text[:start] + "loadFiles('common.js', -1, () => { loadResources(['style.css'], S); });" + text[end:]
        text = text.replace('leftDiv.appendChild(saveBtn);', """leftDiv.appendChild(saveBtn);
        var openBtn = cE('button'); openBtn.className = 'sml'; openBtn.textContent = 'Open page';
        openBtn.onclick = function() {
          var name = path.value.replace(/^\\/+/, '').replace(/\\.gz$/i, '');
          if (!/\\.html?$/i.test(name) || name.includes('..')) { alert('Choose an HTML page to open.'); return; }
          window.location.href = '/' + name + '?deviceFile=1';
        };
        leftDiv.appendChild(openBtn);""")
        return text.encode()
    if relative == 'pixart/pixart.htm':
        text = contents.decode()
        # Firmware inlines these files. The app preserves them separately, so
        # links must also work at the firmware's canonical /pixart.htm route.
        for name in ('pixart.css', 'favicon-16x16.png', 'statics.js', 'getPixelValues.js', 'boxdraw.js', 'pixart.js'):
            text = text.replace(f'="{name}"', f'="/pixart/{name}"')
        return text.encode()
    if relative == 'pixart/pixart.js':
        text = contents.decode()
        # The host field remains useful for exported CURL/HA snippets. Requests
        # from this embedded workspace always target the selected connection.
        text = text.replace("fetch('http://'+gId('curlUrl').value+'/json/state'", "fetch('/json/state'")
        text = text.replace("fetch('http://'+cv+'/json/state'", "fetch('/json/state'")
        text = text.replace('const data = await response.json();',
                            "if (!response.ok) throw new Error('The device rejected the pixels.');\n      const data = await response.json();")
        return text.encode()
    if relative == 'dmxmap.htm':
        text = contents.decode()
        # The HTTP server injects these variables with dmxProcessor. Populate
        # the same values over the native connection before drawing the map.
        text = text.replace('function FM() {', '''async function FM() {
  let CN, CS, CG, LC, CH;
  try {
    const responses = await Promise.all([fetch('/json/cfg'), fetch('/json/info')]);
    if (responses.some(response => !response.ok)) throw new Error('Unlock settings to read the DMX map.');
    const [config, info] = await Promise.all(responses.map(response => response.json()));
    if (!config.dmx) throw new Error('DMX output is not enabled in this firmware.');
    CN = config.dmx.chan; CS = config.dmx.start; CG = config.dmx.gap;
    LC = info.leds.count; CH = config.dmx.fixmap;
  } catch (error) {
    document.getElementById('map').textContent = error.message;
    return;
  }''')
        return text.replace('line-height:200%%', 'line-height:200%').encode()
    return contents


def main():
    root = Path(__file__).resolve().parents[1]
    firmware = root.parent / 'WLED'
    source = firmware / 'wled00/data'
    target = root / 'wled/Resources/DeviceWorkspace.bundle'
    target.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.name.startswith('.') or 'demo' in str(path.relative_to(source)):
            continue
        relative = path.relative_to(source)
        output = target / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        contents = path.read_bytes()
        bundled = transform(relative.as_posix(), contents)
        output.write_bytes(bundled)
        files.append({'path': str(relative), 'sha256': hashlib.sha256(contents).hexdigest(),
                      'bundled_sha256': hashlib.sha256(bundled).hexdigest()})
    shutil.copyfile(firmware / 'LICENSE', target / 'LICENSE.txt')
    manifest = {'repository': 'mc-hamster/WLED', 'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=firmware, text=True).strip(), 'files': files}
    (target / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Bundled {len(files)} local WLED resources.')


if __name__ == '__main__':
    main()
