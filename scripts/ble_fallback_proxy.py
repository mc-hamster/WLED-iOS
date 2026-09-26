#!/usr/bin/env python3
"""Read-only HIL endpoint: verify the real fixture at /json/info, reject /ws.

Use its address temporarily in the app to exercise a real Wi-Fi connection
failure followed by BLE fallback. It never forwards control writes. Restore
the app's original address before shutting it down.
"""
import argparse
import http.server
import ipaddress
import json
import urllib.request
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--listen', required=True)
    parser.add_argument('--port', type=int, default=8769)
    parser.add_argument('--upstream', required=True)
    args = parser.parse_args()
    ipaddress.ip_address(args.listen)
    upstream = urlsplit(args.upstream)
    ipaddress.ip_address(upstream.hostname)
    if upstream.scheme != 'http' or upstream.username or upstream.password or upstream.path not in ('', '/') or upstream.query:
        parser.error('upstream must be a literal-IP HTTP origin')

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/json/info':
                self.send_error(503, 'Intentional HIL network failure')
                return
            try:
                with urllib.request.urlopen(args.upstream.rstrip('/') + '/json/info', timeout=3) as response:
                    body = response.read(65536)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception:
                self.send_error(502, 'Fixture unavailable')

        def log_message(self, format, *arguments):
            print(json.dumps({'method': self.command, 'path': self.path.split('?')[0], 'response': arguments[1] if len(arguments) > 1 else None}), flush=True)

    server = http.server.ThreadingHTTPServer((args.listen, args.port), Handler)
    print(json.dumps({'address': f'{args.listen}:{server.server_port}', 'upstream': args.upstream}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
