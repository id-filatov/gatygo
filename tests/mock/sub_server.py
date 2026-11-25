#!/usr/bin/env python3
"""Mock subscription panel for unit tests and the lab VM (never installed on the router).

Usage: sub_server.py PORT FIXTURE_JSON GEO_DIR PUBLIC_URL

  GET /sub          fixture body + the subscription headers when User-Agent starts with "Happ/"
                    or the path ends in /json, and x-hwid is present; otherwise a text/plain
                    base64 link list (what a real server returns to a name it does not know)
  GET /sub-maxdev   same, plus "x-hwid-max-devices-reached: true"
  GET /sub-norouting  same, without the routing header (no geo file URLs)
  GET /sub-nohwid   same as /sub but the x-hwid header is not required
  GET /sub-broken   HTTP 500
  GET /sub-moved, /sub-move, /sub-movebroken, /sub-move-maxdev, /sub-domain, /sub-badmove,
      /sub-fallback, /sub-msgs
                    same as /sub plus the headers in VARIANTS (a header named there replaces the
                    /sub one): the provider moving the subscription, a spare address, its messages
  GET /sub-closed   no /json (403); the subscription only to "Happ/3.0.0" exactly, base64 to the rest
  GET /sub-own      no /json (403); the subscription only to a User-Agent starting with "gatygo/"
  GET /sub-refuse   no /json (403); 403 to "gatygo/...", base64 to the rest
  GET /sub-never    no /json (403); base64 to everyone
  GET <any of the above>/json  that path asked for Xray JSON
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

# path -> headers added to (or replacing) the /sub ones
VARIANTS = {
    "/sub-moved": [],
    "/sub-move": [("new-url", PUBLIC_URL + "/sub-moved")],
    "/sub-movebroken": [("new-url", PUBLIC_URL + "/sub-broken")],
    "/sub-move-maxdev": [("new-url", PUBLIC_URL + "/sub-moved"), ("x-hwid-max-devices-reached", "true")],
    "/sub-domain": [("new-domain", "localhost")],
    "/sub-badmove": [("new-url", "javascript:alert(1)"), ("new-domain", "evil.example/x")],
    "/sub-fallback": [("fallback-url", PUBLIC_URL + "/sub")],
    "/sub-msgs": [
        ("announce", b64("Maintenance on <b>12 Nov</b> 03:00–04:00 <img src=x onerror=alert(1)>")),
        ("support-url", "https://example.com/support"),
        ("profile-web-page-url", "https://example.com"),
        ("sub-info-text", b64(("Japan and Brazil are in the list now. Press Update now to see them. " * 4)[:200])),
        ("sub-info-color", "red"),
        ("sub-info-button-text", b64("Read more")),
        ("sub-info-button-link", "https://example.com/news"),
        ("sub-expire", "true"),
        ("sub-expire-button-link", "https://example.com/renew"),
        # a far expiry: the fixture's has passed, and an expiry notice would hide sub-info
        ("subscription-userinfo", "upload=1024; download=123456789; total=0; expire=4102444800"),
    ],
}

SUBS = ("/sub", "/sub-maxdev", "/sub-norouting", "/sub-nohwid", "/sub-closed", "/sub-own", "/sub-refuse", "/sub-never")

def answer(path, ua, json_path):
    """True: the subscription; False: the base64 list; a number: that HTTP status"""
    if path in ("/sub-closed", "/sub-own", "/sub-refuse", "/sub-never") and json_path:
        return 403
    if path == "/sub-closed":
        return ua == "Happ/3.0.0"
    if path == "/sub-own":
        return ua.startswith("gatygo/")
    if path == "/sub-refuse":
        return 403 if ua.startswith("gatygo/") else False
    if path == "/sub-never":
        return False
    return json_path or ua.startswith("Happ/")

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
        path = self.path.split("?", 1)[0]
        json_path = path.endswith("/json")
        if json_path:
            path = path[:-len("/json")]
        if path in SUBS or path in VARIANTS:
            a = answer(path, ua, json_path)
            if a is not True and a is not False:
                self._send(a, b"refused", [("Content-Type", "text/plain")])
                return
            if not a or (path != "/sub-nohwid" and not self.headers.get("x-hwid")):
                self._send(200, base64.b64encode(b"vless://00000000-0000-4000-8000-000000000000@relay-1.example.com:443#tile\n"),
                           [("Content-Type", "text/plain; charset=utf-8")])
                return
            hdrs = [("Content-Type", "application/json"),
                    ("profile-title", b64("Example VPN")),
                    ("profile-update-interval", "3"),
                    ("subscription-userinfo", "upload=1024; download=123456789; total=0; expire=1767225600"),
                    ("announce", b64("Planned maintenance — use code 'GO' ✓")),
                    ("manual-block-user-agent", "true")]
            if path != "/sub-norouting":
                hdrs.append(("routing", ROUTING))
            if path == "/sub-maxdev":
                hdrs.append(("x-hwid-max-devices-reached", "true"))
            extra = VARIANTS.get(path, [])
            names = {k.lower() for k, _ in extra}
            hdrs = [h for h in hdrs if h[0].lower() not in names] + extra
            self._send(200, BODY, hdrs)
        elif path == "/sub-broken":
            self._send(500, b"boom", [("Content-Type", "text/plain")])
        elif path == "/redirect":
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
