#!/usr/bin/env python3
"""Mock subscription panel for unit tests and the lab VM (never installed on the router).

Usage: sub_server.py PORT FIXTURE_JSON GEO_DIR PUBLIC_URL

  GET /sub          fixture body + the subscription headers when User-Agent starts with "gatygo/"
                    and x-hwid is present; otherwise a text/plain base64 link list (what the
                    real panel returns to unknown clients)
  GET /sub-maxdev   same, plus "x-hwid-max-devices-reached: true"
  GET /sub-broken   HTTP 500
  GET /redirect     302 to /sub
  GET /geo/<file>   file from GEO_DIR with Last-Modified; 304 when If-Modified-Since matches
  GET /log          JSON list of received requests [{"path":..., "headers":{...}}]
"""
import base64, json, os, sys, time
from email.utils import formatdate, parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, FIXTURE, GEO_DIR, PUBLIC_URL = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4].rstrip("/")
BODY = open(FIXTURE, "rb").read()
LOG = []

def b64(s):
    return "base64:" + base64.b64encode(s.encode()).decode()

ROUTING = "app://routing/add/" + base64.b64encode(json.dumps({
    "Geositeurl": PUBLIC_URL + "/geo/geosite.dat",
    "Geoipurl": PUBLIC_URL + "/geo/geoip.dat",
    "RemoteDNSType": "DoH", "DomainStrategy": "IPIfNonMatch"}).encode()).decode()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep test output quiet
        pass

    def _send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        LOG.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}})
        ua = self.headers.get("User-Agent", "")
        if self.path in ("/sub", "/sub-maxdev"):
            if not (ua.startswith("gatygo/") and self.headers.get("x-hwid")):
                self._send(200, base64.b64encode(b"vless://00000000-0000-4000-8000-000000000000@relay-1.example.com:443#tile\n"),
                           [("Content-Type", "text/plain; charset=utf-8")])
                return
            hdrs = [("Content-Type", "application/json"),
                    ("profile-title", b64("Example VPN")),
                    ("profile-update-interval", "3"),
                    ("subscription-userinfo", "upload=1024; download=123456789; total=0; expire=1767225600"),
                    ("announce", b64("Planned maintenance — use code 'GO' ✓")),
                    ("routing", ROUTING),
                    ("manual-block-user-agent", "true")]
            if self.path == "/sub-maxdev":
                hdrs.append(("x-hwid-max-devices-reached", "true"))
            self._send(200, BODY, hdrs)
        elif self.path == "/sub-broken":
            self._send(500, b"boom", [("Content-Type", "text/plain")])
        elif self.path == "/redirect":
            self._send(302, b"", [("Location", "/sub")])
        elif self.path.startswith("/geo/"):
            p = os.path.join(GEO_DIR, os.path.basename(self.path))
            if not os.path.isfile(p):
                self._send(404); return
            mtime = int(os.stat(p).st_mtime)
            ims = self.headers.get("If-Modified-Since")
            if ims:
                try:
                    if int(parsedate_to_datetime(ims).timestamp()) >= mtime:
                        self._send(304); return
                except (TypeError, ValueError):
                    pass
            self._send(200, open(p, "rb").read(),
                       [("Content-Type", "application/octet-stream"), ("Last-Modified", formatdate(mtime, usegmt=True))])
        elif self.path == "/log":
            self._send(200, json.dumps(LOG).encode(), [("Content-Type", "application/json")])
        else:
            self._send(404)

HTTPServer(("0.0.0.0", PORT), H).serve_forever()
