#!/usr/bin/env python3
"""Test bench for ibs-fortiglue.

It impersonates the three services the tool talks to:

  * IT Glue REST            (/configurations, /organizations, /flexible_assets, /contacts)
  * FortiAnalyzer JSON-RPC  (/jsonrpc)
  * FortiCare registration  (/api/v1/oauth/token/, /ES/api/registration/v3/...)

Every request is written to a JSONL file, the FortiAnalyzer objects (folders,
layouts, schedules, output profiles) live in memory so a run can be inspected
afterwards, and failures can be injected through a faults file: HTTP errors,
expired sessions, refused sign in, slow answers.

The data set is deliberately unpleasant: names carrying double quotes,
backslashes, percent signs and accented letters, organizations with no
recipient, contacts with no primary address, languages with no template. Those
are the cases that used to be skipped in silence.

Environment:
  MOCK_RECORD    path of the request journal, default /tmp/mock-requests.jsonl
  MOCK_DATASET   JSON file replacing the built in data set
  MOCK_FAULTS    JSON file describing the failures to inject
  MOCK_CERT      certificate used to serve TLS
  MOCK_KEY       private key of that certificate
"""

import json
import os
import re
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_LOCK = threading.Lock()
RECORD_PATH = os.environ.get("MOCK_RECORD", "/tmp/mock-requests.jsonl")
DATASET_PATH = os.environ.get("MOCK_DATASET", "")
FAULTS_PATH = os.environ.get("MOCK_FAULTS", "")


def default_dataset():
    return {
        "configurations": [
            # plain firewall
            {"id": "1001", "name": "ACME-HQ-FW01", "serial": "FG100F0000000001",
             "organization": "Acme S.p.A.", "oid": 11, "short": "ACME", "ip": "10.0.0.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": "backup"},
            # double quotes in the organization name: used to break printf built JSON
            {"id": "1002", "name": "ROSS-HQ-FW01", "serial": "FG100F0000000002",
             "organization": 'Rossi "Group" S.r.l.', "oid": 12, "short": "ROSS", "ip": "10.0.1.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": None},
            # percent sign: used to break printf used as a format string
            {"id": "1003", "name": "PERC-HQ-FW01", "serial": "FG100F0000000003",
             "organization": "Azienda 100% Sicura", "oid": 13, "short": "PERC", "ip": "10.0.2.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": "nofaz"},
            # backslash in the name
            {"id": "1004", "name": "BACK-HQ-FW01", "serial": "FG100F0000000004",
             "organization": "C:\\Data S.r.l.", "oid": 14, "short": "BACK", "ip": "10.0.3.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": "noasset"},
            # Fortinet switch: description yes, rename no
            {"id": "1005", "name": "ACME-HQ-SW01", "serial": "S248DF0000000005",
             "organization": "Acme S.p.A.", "oid": 11, "short": "ACME", "ip": "10.0.0.2",
             "type": "Switch", "manufacturer": "Fortinet", "tag": None},
            # firewall with no address: skipped on FortiAnalyzer
            {"id": "1006", "name": "NOIP-HQ-FW01", "serial": "FG100F0000000006",
             "organization": "No Address S.r.l.", "oid": 15, "short": "NOIP", "ip": None,
             "type": "Firewall", "manufacturer": "Fortinet", "tag": None},
            # serial number FortiAnalyzer does not know
            {"id": "1007", "name": "GHOS-HQ-FW01", "serial": "FG100F0000000099",
             "organization": "Ghost S.r.l.", "oid": 16, "short": "GHOS", "ip": "10.0.5.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": None},
            # not Fortinet: ignored
            {"id": "1008", "name": "ACME-HQ-RT01", "serial": "CSCO000000000008",
             "organization": "Acme S.p.A.", "oid": 11, "short": "ACME", "ip": "10.0.0.3",
             "type": "Router", "manufacturer": "Cisco", "tag": None},
            # accented letters and an apostrophe
            {"id": "1009", "name": "UNIC-HQ-FW01", "serial": "FG100F0000000009",
             "organization": "Società Èlite d'Impresa", "oid": 17, "short": "UNIC", "ip": "10.0.6.1",
             "type": "Firewall", "manufacturer": "Fortinet", "tag": None},
        ],
        "organizations": [
            {"oid": 11, "name": "Acme S.p.A.", "short": "ACME", "parent": 20},
            {"oid": 12, "name": 'Rossi "Group" S.r.l.', "short": "ROSS", "parent": None},
            {"oid": 13, "name": "Azienda 100% Sicura", "short": "PERC", "parent": None},
            {"oid": 14, "name": "C:\\Data S.r.l.", "short": "BACK", "parent": None},
            {"oid": 15, "name": "No Address S.r.l.", "short": "NOIP", "parent": None},
            {"oid": 16, "name": "Ghost S.r.l.", "short": "GHOS", "parent": None},
            {"oid": 17, "name": "Società Èlite d'Impresa", "short": "UNIC", "parent": None},
            {"oid": 20, "name": "Acme Group", "short": "GACME", "parent": None},
        ],
        # flexible assets: report recipients, per organization
        "flexible_assets": [
            {"id": 501, "oid": 11, "traits": {"language": "IT",
                                              "contacts": {"values": [{"id": 9001}, {"id": 9002}]}}},
            {"id": 502, "oid": 20, "traits": {"language": "EN",
                                              "contacts": {"values": [{"id": 9003}]}}},
            # the same organization in two languages: both report sets have to
            # survive the run, they live in the same folder
            {"id": 506, "oid": 11, "traits": {"language": "EN",
                                              "contacts": {"values": [{"id": 9002}]}}},
            # no recipient at all: the organization must be left alone
            {"id": 503, "oid": 12, "traits": {"language": "IT", "contacts": {"values": []}}},
            # language with no template on disk
            {"id": 504, "oid": 17, "traits": {"language": "DE", "contacts": {"values": [{"id": 9004}]}}},
            # every named contact lacks a primary address
            {"id": 505, "oid": 16, "traits": {"language": "IT", "contacts": {"values": [{"id": 9005}]}}},
        ],
        "contacts": [
            {"id": 9001, "oid": 11, "first": "Mario", "last": "Rossi",
             "emails": [{"primary": True, "value": "mario.rossi@acme.example"},
                        {"primary": False, "value": "old@acme.example"}]},
            {"id": 9002, "oid": 11, "first": "Anna", "last": "Bianchi",
             "emails": [{"primary": True, "value": "anna.bianchi@acme.example"}]},
            {"id": 9003, "oid": 20, "first": "Group", "last": "Referent",
             "emails": [{"primary": True, "value": "referent@group.example"}]},
            {"id": 9004, "oid": 17, "first": "Unic", "last": "Referent",
             "emails": [{"primary": True, "value": "referent@unic.example"}]},
            # no primary address at all
            {"id": 9005, "oid": 16, "first": "No", "last": "Primary",
             "emails": [{"primary": False, "value": "secondary@ghost.example"}]},
        ],
        # devices known to FortiAnalyzer, by serial number
        "faz_devices": [
            {"sn": "FG100F0000000001", "name": "FGT-OLD-01", "desc": ""},
            {"sn": "FG100F0000000002", "name": "FGT-OLD-02", "desc": ""},
            {"sn": "FG100F0000000003", "name": "FGT-OLD-03", "desc": ""},
            {"sn": "FG100F0000000004", "name": "FGT-OLD-04", "desc": ""},
            {"sn": "FG100F0000000006", "name": "FGT-OLD-06", "desc": ""},
            {"sn": "FG100F0000000009", "name": "FGT-OLD-09", "desc": ""},
        ],
        "adoms": ["root", "customers", "Unmanaged_Devices", "rootp"],
        # ADOMs whose report API answers with a code instead of a listing: a
        # real appliance has several of them and they are not failures
        "faz_reports_unsupported": {"Unmanaged_Devices": -3, "rootp": -6},
        "adom_devices": {
            "root": ["ACME-HQ-FW01", "ROSS-HQ-FW01", "GHOS-HQ-FW01", "device-out-of-convention"],
            "customers": ["UNIC-HQ-FW01"],
        },
        "forticare_assets": [
            {"serialNumber": "FG100F0000000001", "description": ""},
            {"serialNumber": "FG100F0000000002", "description": ""},
            {"serialNumber": "FG100F0000000003", "description": ""},
            {"serialNumber": "FG100F0000000004", "description": ""},
            {"serialNumber": "S248DF0000000005", "description": ""},
            {"serialNumber": "FG100F0000000006", "description": ""},
            {"serialNumber": "FG100F0000000009", "description": ""},
            {"serialNumber": "FG100F0000000099", "description": ""},
        ],
        # reports already on the appliance: this is what a run has to replace
        "faz_reports": {
            "root": {
                # 103 and 104 belong to another instance of this same tool,
                # serving a partner from its own parent folder on the very same
                # appliance, for the very same organization. Nothing of it may
                # be touched by a run working on the IBS folder.
                "folders": {99: {"folder-name": "Reports", "parent-id": 0},
                            100: {"folder-name": "IBS", "parent-id": 99},
                            101: {"folder-name": "ACME", "parent-id": 100},
                            102: {"folder-name": "ROSS", "parent-id": 100},
                            103: {"folder-name": "PartnerReport", "parent-id": 0},
                            104: {"folder-name": "ACME", "parent-id": 103}},
                "layouts": {200: {"layout-id": 200, "title": "ACME-IT-OLD-Web",
                                  "folders": [{"folder-id": 101}]},
                            201: {"layout-id": 201, "title": "ROSS-IT-OLD-Web",
                                  "folders": [{"folder-id": 102}]},
                            202: {"layout-id": 202, "title": "ACME-IT-PARTNER-Web",
                                  "folders": [{"folder-id": 104}]}},
                "schedules": {"200": {"name": "200", "output-profile": "ACME-IT-OLD",
                                      "report-layout": [{"layout-id": 200}]},
                              "201": {"name": "201", "output-profile": "ROSS-IT-OLD",
                                      "report-layout": [{"layout-id": 201}]},
                              "202": {"name": "202", "output-profile": "ACME-IT-PARTNER",
                                      "report-layout": [{"layout-id": 202}]}},
                "outputs": {"ACME-IT-OLD": {"name": "ACME-IT-OLD"},
                            "ROSS-IT-OLD": {"name": "ROSS-IT-OLD"},
                            "ACME-IT-PARTNER": {"name": "ACME-IT-PARTNER"},
                            # built by hand by an engineer: it must survive the run
                            "MANUAL-PROFILE": {"name": "MANUAL-PROFILE"}},
            },
            "customers": {
                "folders": {110: {"folder-name": "IBS", "parent-id": 0}},
                "layouts": {}, "schedules": {}, "outputs": {},
            },
        },
    }


def default_faults():
    return {
        # per endpoint: {"times": 2, "status": 500} or {"body_invalid": true}
        "endpoints": {},
        # FortiAnalyzer session expires after this many calls, 0 means never
        "faz_session_expire_after": 0,
        # artificial delay on every answer, in seconds
        "delay": 0.0,
        "faz_login_fail": False,
        "forticare_login_fail": False,
        "forticare_update_fail": False,
    }


def load_json(path, fallback):
    if not path:
        return fallback()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return fallback()


DATA = load_json(DATASET_PATH, default_dataset)
FAULTS = load_json(FAULTS_PATH, default_faults)

FAZ = {
    "session": None,
    "session_calls": 0,
    "logout": 0,
    "adom": {},
    "next_folder": 900,
    "next_layout": 950,
}
COUNTERS = {}


def adom_state(adom):
    """Report objects of one ADOM, seeded from the data set on first use."""
    with STATE_LOCK:
        if adom not in FAZ["adom"]:
            seed = DATA.get("faz_reports", {}).get(adom, {})
            FAZ["adom"][adom] = {
                "folders": {int(k): dict(v) for k, v in (seed.get("folders") or {}).items()},
                "layouts": {int(k): dict(v) for k, v in (seed.get("layouts") or {}).items()},
                "schedules": {str(k): dict(v) for k, v in (seed.get("schedules") or {}).items()},
                "outputs": {str(k): dict(v) for k, v in (seed.get("outputs") or {}).items()},
            }
        return FAZ["adom"][adom]


def record(entry):
    with STATE_LOCK:
        with open(RECORD_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def fault_for(key):
    """Failure to inject on this call, if any.

    "skip" lets the first calls through, which is how a failure can be made to
    land in the middle of a rebuild instead of on its first step.
    """
    spec = FAULTS.get("endpoints", {}).get(key)
    if not spec:
        return None
    with STATE_LOCK:
        seen = COUNTERS.get(key, 0) + 1
        COUNTERS[key] = seen
    skip = spec.get("skip", 0)
    if seen <= skip or seen > skip + spec.get("times", 1):
        return None
    return spec


def paginate(items, page_number, page_size):
    start = (page_number - 1) * page_size
    chunk = items[start:start + page_size]
    has_next = start + page_size < len(items)
    return chunk, (page_number + 1 if has_next else None)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fortiglue-mock/2.0"

    def log_message(self, *args):  # the journal is the JSONL file
        pass

    def respond(self, status, payload, raw=False):
        delay = FAULTS.get("delay", 0)
        if delay:
            time.sleep(delay)
        body = payload if raw else json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    # ------------------------------------------------------------- IT Glue

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

        if parsed.path == "/__state":
            return self.respond(200, {
                "adom": {a: {"folders": {str(k): v for k, v in st["folders"].items()},
                             "layouts": {str(k): v for k, v in st["layouts"].items()},
                             "schedules": st["schedules"], "outputs": st["outputs"]}
                         for a, st in FAZ["adom"].items()},
                "faz_devices": DATA["faz_devices"],
                "forticare_assets": DATA["forticare_assets"],
                "session_open": FAZ["session"] is not None,
                "logout_calls": FAZ["logout"],
            })

        record({"service": "itglue", "method": "GET", "path": parsed.path,
                "query": {k: v[0] for k, v in query.items()},
                "apikey": self.headers.get("x-api-key"), "ts": time.time()})

        fault = fault_for("itglue_" + parsed.path.strip("/").replace("/", "_"))
        if fault:
            if fault.get("body_invalid"):
                return self.respond(fault.get("status", 200), b"<html>error</html>", raw=True)
            return self.respond(fault.get("status", 500), {"errors": [{"title": "injected failure"}]})

        page_number = int(query.get("page[number]", ["1"])[0] or 1)
        page_size = int(query.get("page[size]", ["50"])[0] or 50)
        # forced down so pagination is exercised even with a handful of rows
        page_size = min(page_size, 4)

        if parsed.path == "/configurations":
            return self.itglue_configurations(query, page_number, page_size)
        if parsed.path == "/organizations":
            return self.itglue_organizations(query, page_number, page_size)
        if parsed.path == "/flexible_assets":
            return self.itglue_flexible(query, page_number, page_size)
        if parsed.path == "/contacts":
            return self.itglue_contacts(query, page_number, page_size)
        return self.respond(404, {"errors": [{"title": "not found"}]})

    def itglue_pack(self, rows, next_page, kind):
        return {"data": rows,
                "meta": {"current-page": 1, "next-page": next_page, "total-count": len(rows)},
                "links": {}, "type": kind}

    def itglue_configurations(self, query, page_number, page_size):
        items = DATA["configurations"]
        names = query.get("filter[name]", [None])[0]
        if names is not None:
            wanted = set(n.strip() for n in names.split(",") if n.strip())
            items = [c for c in items if c["name"] in wanted]
        rows, nxt = paginate(items, page_number, page_size)
        data = [{"id": c["id"], "type": "configurations",
                 "attributes": {"name": c["name"], "serial-number": c["serial"],
                                "primary-ip": c["ip"], "asset-tag": c["tag"],
                                "configuration-type-name": c["type"],
                                "manufacturer-name": c["manufacturer"],
                                "organization-name": c["organization"],
                                "organization-id": c["oid"],
                                "organization-short-name": c["short"]}} for c in rows]
        self.respond(200, self.itglue_pack(data, nxt, "configurations"))

    def itglue_organizations(self, query, page_number, page_size):
        items = DATA["organizations"]
        wanted = query.get("filter[id]", [None])[0]
        if wanted is not None:
            ids = set(x.strip() for x in wanted.split(",") if x.strip())
            items = [o for o in items if str(o["oid"]) in ids]
        rows, nxt = paginate(items, page_number, page_size)
        data = [{"id": str(o["oid"]), "type": "organizations",
                 "attributes": {"name": o["name"], "short-name": o["short"],
                                "parent-id": o["parent"]}} for o in rows]
        self.respond(200, self.itglue_pack(data, nxt, "organizations"))

    def itglue_flexible(self, query, page_number, page_size):
        items = DATA["flexible_assets"]
        oid = query.get("filter[organization-id]", [None])[0]
        if oid is not None:
            items = [f for f in items if str(f["oid"]) == str(oid).strip()]
        rows, nxt = paginate(items, page_number, page_size)
        data = [{"id": str(f["id"]), "type": "flexible-assets",
                 "attributes": {"name": "Report", "traits": f["traits"],
                                "organization-id": f["oid"]}} for f in rows]
        self.respond(200, self.itglue_pack(data, nxt, "flexible-assets"))

    def itglue_contacts(self, query, page_number, page_size):
        items = DATA["contacts"]
        wanted = query.get("filter[id]", [None])[0]
        if wanted is not None:
            ids = set(x.strip() for x in wanted.split(",") if x.strip())
            # an empty filter is what the old code used to send: the real API
            # answers with every contact of the tenant, and so does this bench
            if ids:
                items = [c for c in items if str(c["id"]) in ids]
        rows, nxt = paginate(items, page_number, page_size)
        data = [{"id": str(c["id"]), "type": "contacts",
                 "attributes": {"first-name": c["first"], "last-name": c["last"],
                                "organization-id": c["oid"],
                                "contact-emails": [{"primary": e["primary"], "value": e["value"]}
                                                   for e in c["emails"]]}} for c in rows]
        self.respond(200, self.itglue_pack(data, nxt, "contacts"))

    # --------------------------------------------- FortiAnalyzer, FortiCare

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        raw = self.read_body()
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
            malformed = False
        except (ValueError, UnicodeDecodeError) as exc:
            body = {"_raw": raw.decode("utf-8", "replace"), "_error": str(exc)}
            malformed = True

        record({"service": "faz" if parsed.path == "/jsonrpc" else "forticare",
                "method": "POST", "path": parsed.path, "body": body,
                "malformed_json": malformed, "ts": time.time()})

        if malformed:
            # exactly what a real appliance does with broken JSON
            return self.respond(400, {"error": "invalid json"})

        if parsed.path == "/jsonrpc":
            return self.jsonrpc(body)
        if parsed.path == "/api/v1/oauth/token/":
            if FAULTS.get("forticare_login_fail"):
                return self.respond(400, {"error": "invalid_grant",
                                          "error_description": "wrong credentials"})
            return self.respond(200, {"access_token": "test-token", "expires_in": 3600,
                                      "token_type": "Bearer", "scope": "read write"})
        if parsed.path == "/ES/api/registration/v3/products/description":
            return self.forticare_description(body)
        return self.respond(404, {"error": "not found"})

    def forticare_description(self, body):
        fault = fault_for("forticare_description")
        if fault:
            return self.respond(fault.get("status", 500), {"status": 1, "message": "injected failure"})
        serial = body.get("serialNumber")
        known = [a for a in DATA["forticare_assets"] if a["serialNumber"] == serial]
        if FAULTS.get("forticare_update_fail") or not known:
            return self.respond(200, {"status": -1, "message": "invalid serial number"})
        known[0]["description"] = body.get("description", "")
        return self.respond(200, {"status": 0, "message": "ok"})

    def jsonrpc(self, body):
        params = (body.get("params") or [{}])[0]
        url = params.get("url", "")
        method = body.get("method", "")
        session = body.get("session")
        rid = body.get("id", 1)

        if url == "/sys/login/user":
            if FAULTS.get("faz_login_fail"):
                return self.respond(200, {"id": rid, "result": [
                    {"status": {"code": -22, "message": "Login fail"}, "url": url}]})
            FAZ["session"] = "test-session"
            FAZ["session_calls"] = 0
            return self.respond(200, {"id": rid, "session": FAZ["session"], "result": [
                {"status": {"code": 0, "message": "OK"}, "url": url}]})

        if url == "/sys/logout":
            FAZ["session"] = None
            FAZ["logout"] += 1
            return self.respond(200, {"id": rid, "result": [
                {"status": {"code": 0, "message": "OK"}, "url": url}]})

        expire_after = FAULTS.get("faz_session_expire_after", 0)
        FAZ["session_calls"] += 1
        expired = expire_after and FAZ["session_calls"] > expire_after
        if session != FAZ["session"] or expired:
            if expired:
                FAZ["session"] = None
            return self.respond(200, {"id": rid, "result": [
                {"status": {"code": -11, "message": "No permission for the resource"}, "url": url}]})

        fault = fault_for("faz_" + method)
        if fault:
            return self.respond(fault.get("status", 500), {"error": "injected failure"})

        if url == "/dvmdb/adom":
            return self.respond(200, {"id": rid, "result": [
                {"data": [{"name": a} for a in DATA["adoms"]],
                 "status": {"code": 0, "message": "OK"}, "url": url}]})

        match = re.match(r"^/dvmdb/adom/([^/]+)/device$", url)
        if match:
            adom = urllib.parse.unquote(match.group(1))
            names = DATA["adom_devices"].get(adom, [])
            return self.respond(200, {"id": rid, "result": [
                {"data": [{"name": n} for n in names],
                 "status": {"code": 0, "message": "OK"}, "url": url}]})

        if url == "/dvmdb/device" and method == "get":
            wanted = None
            for item in params.get("filter", []) or []:
                if isinstance(item, list) and len(item) == 3 and item[0] == "sn":
                    wanted = item[2]
            found = [d for d in DATA["faz_devices"] if d["sn"] == wanted]
            return self.respond(200, {"id": rid, "result": [
                {"data": [{"name": d["name"], "sn": d["sn"]} for d in found],
                 "status": {"code": 0, "message": "OK"}, "url": url}]})

        match = re.match(r"^/dvmdb/device/(.+)$", url)
        if match and method == "set":
            target = urllib.parse.unquote(match.group(1))
            data = params.get("data", {})
            for device in DATA["faz_devices"]:
                if device["name"] == target:
                    device["name"] = data.get("name", device["name"])
                    device["desc"] = data.get("desc", device["desc"])
                    return self.respond(200, {"id": rid, "result": [
                        {"status": {"code": 0, "message": "OK"}, "url": url}]})
            return self.respond(200, {"id": rid, "result": [
                {"status": {"code": -3, "message": "Object does not exist"}, "url": url}]})

        return self.report_api(rid, method, url, params)

    def report_api(self, rid, method, url, params):
        unsupported = DATA.get("faz_reports_unsupported", {})
        for adom, code in unsupported.items():
            if url.startswith("/report/adom/%s/" % adom):
                return self.respond(200, {"id": rid, "result": {
                    "status": {"code": code,
                               "message": "Object does not exist" if code == -3 else "Invalid url"},
                    "url": url}})

        def ok(data):
            return self.respond(200, {"id": rid, "result": {
                "data": data, "status": {"code": 0, "message": "OK"}, "url": url}})

        def ko(code, message):
            return self.respond(200, {"id": rid, "result": {
                "status": {"code": code, "message": message}, "url": url}})

        folder = re.match(r"^/report/adom/([^/]+)/config/layout-folder(?:/(\d+))?$", url)
        layout = re.match(r"^/report/adom/([^/]+)/config/layout(?:/(\d+))?$", url)
        schedule = re.match(r"^/report/adom/([^/]+)/config/schedule(?:/(.+))?$", url)
        output = re.match(r"^/report/adom/([^/]+)/config/output(?:/(.+))?$", url)

        if folder:
            state = adom_state(urllib.parse.unquote(folder.group(1)))
            fid = folder.group(2)
            if method == "get":
                rows = [dict(v, **{"folder-id": k}) for k, v in state["folders"].items()]
                condition = params.get("filter")
                if condition:
                    parent = int(condition[0][2])
                    rows = [r for r in rows if int(r.get("parent-id") or 0) == parent]
                return ok(rows)
            if method == "add":
                data = params.get("data", {})
                pair = (data.get("folder-name"), data.get("parent-id"))
                if pair in [(v.get("folder-name"), v.get("parent-id")) for v in state["folders"].values()]:
                    return ko(-2, "Object already exists")
                with STATE_LOCK:
                    new = FAZ["next_folder"]
                    FAZ["next_folder"] += 1
                state["folders"][new] = {"folder-name": data.get("folder-name"),
                                         "parent-id": data.get("parent-id", 0)}
                return ok({"folder-id": new})
            if method == "delete":
                if fid is None or int(fid) not in state["folders"]:
                    return ko(-3, "Object does not exist")
                state["folders"].pop(int(fid), None)
                return ok({"folder-id": int(fid)})

        if layout:
            state = adom_state(urllib.parse.unquote(layout.group(1)))
            lid = layout.group(2)
            if method == "get":
                return ok(list(state["layouts"].values()))
            if method == "add":
                data = params.get("data", {})
                if data.get("title") in [l.get("title") for l in state["layouts"].values()]:
                    return ko(-2, "Object already exists")
                with STATE_LOCK:
                    new = FAZ["next_layout"]
                    FAZ["next_layout"] += 1
                data["layout-id"] = new
                state["layouts"][new] = data
                return ok({"layout-id": new})
            if method == "delete":
                if lid is None or int(lid) not in state["layouts"]:
                    return ko(-3, "Object does not exist")
                state["layouts"].pop(int(lid), None)
                return ok({"layout-id": int(lid)})

        if schedule:
            state = adom_state(urllib.parse.unquote(schedule.group(1)))
            sid = schedule.group(2)
            if method == "get":
                return ok(list(state["schedules"].values()))
            if method == "add":
                data = params.get("data", {})
                name = str(data.get("name"))
                if name in state["schedules"]:
                    return ko(-2, "Object already exists")
                state["schedules"][name] = data
                return ok({"name": name})
            if method == "delete":
                key = urllib.parse.unquote(sid or "")
                if key not in state["schedules"]:
                    return ko(-3, "Object does not exist")
                state["schedules"].pop(key, None)
                return ok({"name": key})

        if output:
            state = adom_state(urllib.parse.unquote(output.group(1)))
            oid = output.group(2)
            if method == "get":
                return ok(list(state["outputs"].values()))
            if method == "add":
                data = params.get("data", {})
                name = str(data.get("name"))
                if name in state["outputs"]:
                    return ko(-2, "Object already exists")
                state["outputs"][name] = data
                return ok({"name": name})
            if method == "delete":
                key = urllib.parse.unquote(oid or "")
                if key not in state["outputs"]:
                    return ko(-3, "Object does not exist")
                state["outputs"].pop(key, None)
                return ok({"name": key})

        return ko(-6, "Invalid url")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8099
    open(RECORD_PATH, "w", encoding="utf-8").close()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    certificate = os.environ.get("MOCK_CERT")
    key = os.environ.get("MOCK_KEY")
    if certificate and key:
        import ssl
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    print("listening on %d (tls=%s, journal: %s)" % (port, bool(certificate), RECORD_PATH), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
