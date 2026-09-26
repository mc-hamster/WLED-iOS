import importlib.util
from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import unittest
from urllib.parse import urljoin, urlsplit


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT.parent / 'WLED/wled00/data'
spec = importlib.util.spec_from_file_location('assets', ROOT / 'scripts/sync_workspace_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class Resources(HTMLParser):
    def __init__(self):
        super().__init__()
        self.urls = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'script' and 'src' in attrs:
            self.urls.append(attrs['src'])
        if tag == 'link' and 'href' in attrs:
            self.urls.append(attrs['href'])


class WorkspaceAssetsTests(unittest.TestCase):
    def transformed(self, relative):
        return assets.transform(relative, (SOURCE / relative).read_bytes()).decode()

    def test_pixel_art_resources_resolve_for_native_and_firmware_routes(self):
        parser = Resources()
        parser.feed(self.transformed('pixart/pixart.htm'))
        self.assertGreaterEqual(len(parser.urls), 6)
        for route in ('/pixart', '/pixart.htm', '/pixart/', '/pixart/pixart.htm'):
            for resource in parser.urls:
                path = urlsplit(urljoin('https://device' + route, resource)).path
                self.assertTrue((SOURCE / path.lstrip('/')).is_file(), (route, resource))

    def test_pixel_art_device_requests_use_selected_connection(self):
        script = self.transformed('pixart/pixart.js')
        self.assertNotIn("fetch('http://", script)
        self.assertEqual(script.count("fetch('/json/state'"), 2)
        self.assertIn('if (!response.ok) throw', script)

    def test_dmx_map_uses_live_config_and_reports_unavailable(self):
        html = self.transformed('dmxmap.htm')
        script = html.split('<script>', 1)[1].split('</script>', 1)[0]
        harness = '''
const vm = require('node:vm');
const assert = require('node:assert/strict');
const map = {innerHTML:'', textContent:''};
let supported = true;
const context = vm.createContext({document:{getElementById:()=>map}, fetch:async(path)=>({ok:true,json:async()=>
 path === '/json/info' ? {leds:{count:2}} : supported ? {dmx:{chan:3,start:1,gap:3,fixmap:[1,2,3]}} : {}})});
vm.runInContext(SCRIPT, context);
(async()=>{
 await context.FM();
 assert.equal((map.innerHTML.match(/class="anytype type[123]"/g)||[]).length, 6);
 assert.equal((map.innerHTML.match(/class="anytype type7"/g)||[]).length, 506);
 supported=false; await context.FM();
 assert.equal(map.textContent,'DMX output is not enabled in this firmware.');
})().catch(error=>{console.error(error);process.exitCode=1;});
'''.replace('SCRIPT', json.dumps(script))
        subprocess.run(['node', '-e', harness], check=True, capture_output=True, text=True)

    def test_opening_controls_never_prompts_or_persists_upgrade_reporting(self):
        def entrypoint(script):
            start = script.index('function checkVersionUpgrade(')
            return script[start:script.index('function showVersionUpgradePrompt(', start)]
        original = entrypoint((SOURCE / 'index.js').read_text())
        bundled = entrypoint(self.transformed('index.js'))
        harness = '''
const vm = require('node:vm');
const assert = require('node:assert/strict');
async function exercise(script, status) {
  const calls = [];
  const context = vm.createContext({versionCheckDone:false,console:{log:()=>{}},getURL:path=>path,
    fetch:async(path)=>{calls.push('read');return {status,ok:false};},
    showVersionUpgradePrompt:()=>calls.push('prompt'),
    updateVersionInfo:()=>calls.push('write')});
  vm.runInContext(script, context);
  context.checkVersionUpgrade({ver:'0.16-test',wifi:{ap:false}});
  await new Promise(resolve=>setImmediate(resolve));
  return calls;
}
(async()=>{
  assert.deepEqual(await exercise(ORIGINAL,404),['read','prompt']);
  assert.deepEqual(await exercise(ORIGINAL,401),['read','write']);
  for (const status of [200,401,404,503]) assert.deepEqual(await exercise(BUNDLED,status),[]);
})().catch(error=>{console.error(error);process.exitCode=1;});
'''.replace('ORIGINAL', json.dumps(original)).replace('BUNDLED', json.dumps(bundled))
        result = subprocess.run(['node', '-e', harness], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
