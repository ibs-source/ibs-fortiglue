#!/usr/bin/env python3
"""Acceptance suite for ibs-fortiglue.

Builds the image, then runs it against test/mock.py in a private Docker network
where the real host names (api.eu.itglue.com, support.fortinet.com,
customerapiauth.fortinet.com and the appliance) resolve to the bench. Each
scenario checks what the run did to the services, not just its output.

    python3 test/suite.py                 # every scenario
    python3 test/suite.py nominal dry-run # only those two
    FORTIGLUE_IMAGE=ibs-fortiglue:2.0.0 python3 test/suite.py   # skip the build

Requirements: docker, openssl, python3.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
IMAGE = os.environ.get("FORTIGLUE_IMAGE", "ibs-fortiglue:test")
PYTHON_IMAGE = os.environ.get("FORTIGLUE_TEST_PYTHON_IMAGE", "python:3.12-alpine")
ALIASES = ["api.eu.itglue.com", "support.fortinet.com", "customerapiauth.fortinet.com", "faz.test"]

BASE_ENVIRONMENT = {
    "ENVIRONMENT_ITGLUE": "api.eu.itglue.com",
    "ENVIRONMENT_ITGLUE_APIKEY": "ITG.test-key",
    "ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE": "111",
    "ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID": "222",
    "ENVIRONMENT_FORTINET_USERNAME": "user",
    "ENVIRONMENT_FORTINET_PASSWORD": "secret",
    "ENVIRONMENT_FORTINET_CLIENTID": "assetmanagement",
    "ENVIRONMENT_FORTIANALYZER_FQDN": "faz.test",
    "ENVIRONMENT_FORTIANALYZER_USERNAME": "admin",
    "ENVIRONMENT_FORTIANALYZER_PASSWORD": "secret",
    "ENVIRONMENT_FORTIANALYZER_EMAIL_FROM": "report@ibs.srl",
    "ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP": "smtp.ibs.srl",
    "ENVIRONMENT_FORTIANALYZER_FOLDER": "IBS",
    "ENVIRONMENT_FORTIANALYZER_CACERT": "/ca/ca.crt",
    "CURL_CA_BUNDLE": "/ca/ca.crt",
    "ENVIRONMENT_LOG_LEVEL": "debug",
}


def run(command, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    return subprocess.run(command, **kwargs)


def build_certificates(directory):
    """Certificate authority plus a server certificate naming every service."""
    authority_key = os.path.join(directory, "ca.key")
    authority = os.path.join(directory, "ca.crt")
    key = os.path.join(directory, "server.key")
    request = os.path.join(directory, "server.csr")
    certificate = os.path.join(directory, "server.crt")
    extension = os.path.join(directory, "server.ext")

    run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", authority_key,
         "-out", authority, "-days", "3650", "-subj", "/CN=Fortiglue Test CA"], check=True)
    run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", request,
         "-subj", "/CN=fortiglue-mock"], check=True)
    with open(extension, "w", encoding="utf-8") as handle:
        handle.write("subjectAltName=" + ",".join("DNS:" + name for name in ALIASES) + "\n")
        handle.write("extendedKeyUsage=serverAuth\n")
    run(["openssl", "x509", "-req", "-in", request, "-CA", authority, "-CAkey", authority_key,
         "-CAcreateserial", "-out", certificate, "-days", "3650", "-extfile", extension], check=True)

    return authority, certificate, key


class Bench:
    """One run of the tool against a fresh bench."""

    def __init__(self, workspace, certificates):
        self.workspace = workspace
        self.authority, self.certificate, self.key = certificates

    def execute(self, name, environment=None, faults=None, dataset=None, volumes=None, timeout=600):
        mark = uuid.uuid4().hex[:8]
        network = "fortiglue-%s" % mark
        mock = "fortiglue-mock-%s" % mark
        state = os.path.join(self.workspace, name)
        os.makedirs(state, exist_ok=True)

        shutil.copy(os.path.join(HERE, "mock.py"), os.path.join(state, "mock.py"))
        if faults is not None:
            with open(os.path.join(state, "faults.json"), "w", encoding="utf-8") as handle:
                json.dump(faults, handle)
        if dataset is not None:
            with open(os.path.join(state, "dataset.json"), "w", encoding="utf-8") as handle:
                json.dump(dataset, handle)

        run(["docker", "network", "create", network], check=True)
        try:
            command = ["docker", "run", "-d", "--name", mock, "--network", network]
            for alias in ALIASES:
                command += ["--network-alias", alias]
            command += ["-v", "%s:/mock" % state,
                        "-v", "%s:/tls/server.crt:ro" % self.certificate,
                        "-v", "%s:/tls/server.key:ro" % self.key,
                        "-e", "MOCK_RECORD=/mock/requests.jsonl",
                        "-e", "MOCK_CERT=/tls/server.crt",
                        "-e", "MOCK_KEY=/tls/server.key"]
            if faults is not None:
                command += ["-e", "MOCK_FAULTS=/mock/faults.json"]
            if dataset is not None:
                command += ["-e", "MOCK_DATASET=/mock/dataset.json"]
            command += [PYTHON_IMAGE, "python", "/mock/mock.py", "443"]
            run(command, check=True)

            self.wait(mock)

            command = ["docker", "run", "--rm", "--network", network,
                       "-v", "%s:/ca/ca.crt:ro" % self.authority]
            for source, target in (volumes or []):
                command += ["-v", "%s:%s:ro" % (os.path.join(HERE, source), target)]
            merged = dict(BASE_ENVIRONMENT)
            merged.update(environment or {})
            for variable, value in merged.items():
                if value is None:
                    continue
                command += ["-e", "%s=%s" % (variable, value)]
            command += [IMAGE]

            started = time.time()
            outcome = run(command, timeout=timeout)
            elapsed = time.time() - started

            requests = self.journal(mock, state)
            snapshot = self.snapshot(mock, network)
            return Result(name, outcome.returncode, outcome.stdout, outcome.stderr,
                          requests, snapshot, elapsed)
        finally:
            run(["docker", "rm", "-f", mock])
            run(["docker", "network", "rm", network])

    def wait(self, mock):
        for _ in range(100):
            logs = run(["docker", "logs", mock])
            if "listening on" in (logs.stdout or "") + (logs.stderr or ""):
                return
            time.sleep(0.2)
        raise RuntimeError("the bench did not start: " + run(["docker", "logs", mock]).stdout)

    def journal(self, mock, state):
        run(["docker", "cp", "%s:/mock/requests.jsonl" % mock, os.path.join(state, "requests.jsonl")])
        path = os.path.join(state, "requests.jsonl")
        if not os.path.exists(path):
            return []
        with open(path, "r", encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def snapshot(self, mock, network):
        outcome = run(["docker", "run", "--rm", "--network", network, PYTHON_IMAGE,
                       "python", "-c",
                       "import json,ssl,urllib.request;"
                       "c=ssl.create_default_context();c.check_hostname=False;"
                       "c.verify_mode=ssl.CERT_NONE;"
                       "print(urllib.request.urlopen('https://faz.test/__state',context=c).read().decode())"])
        try:
            return json.loads(outcome.stdout)
        except ValueError:
            return {}


class Result:
    def __init__(self, name, code, stdout, stderr, requests, snapshot, elapsed):
        self.name = name
        self.code = code
        self.stdout = stdout or ""
        self.stderr = stderr or ""
        # The log goes to standard error, the summary to standard output: the
        # checks look at both.
        self.output = self.stdout + self.stderr
        self.requests = requests
        self.snapshot = snapshot
        self.elapsed = elapsed

    # ------------------------------------------------------------- helpers

    def faz(self, method=None, url_contains=None):
        found = []
        for entry in self.requests:
            if entry.get("service") != "faz":
                continue
            body = entry.get("body") or {}
            params = (body.get("params") or [{}])[0]
            if method and body.get("method") != method:
                continue
            if url_contains and url_contains not in params.get("url", ""):
                continue
            found.append((body, params))
        return found

    def forticare(self):
        return [entry["body"] for entry in self.requests
                if entry.get("service") == "forticare"
                and entry.get("path", "").endswith("/products/description")]

    def itglue(self, path=None):
        return [entry for entry in self.requests
                if entry.get("service") == "itglue" and (path is None or entry.get("path") == path)]

    def outputs(self, adom="root"):
        return self.snapshot.get("adom", {}).get(adom, {}).get("outputs", {})

    def layouts(self, adom="root"):
        return self.snapshot.get("adom", {}).get(adom, {}).get("layouts", {})

    def schedules(self, adom="root"):
        return self.snapshot.get("adom", {}).get(adom, {}).get("schedules", {})

    def folders(self, adom="root"):
        return self.snapshot.get("adom", {}).get(adom, {}).get("folders", {})

    def devices(self):
        return {d["sn"]: d for d in self.snapshot.get("faz_devices", [])}

    def assets(self):
        return {a["serialNumber"]: a for a in self.snapshot.get("forticare_assets", [])}

    def recipients(self, prefix, adom="root"):
        """Every address of the output profiles whose name starts with prefix."""
        addresses = []
        for name, profile in self.outputs(adom).items():
            if not name.startswith(prefix):
                continue
            for recipient in profile.get("email-recipients", []) or []:
                addresses.append(recipient.get("address"))
        return addresses

    def malformed(self):
        return [entry for entry in self.requests if entry.get("malformed_json")]

    def writes(self):
        """Every call that changes something on the two services."""
        changing = []
        for entry in self.requests:
            if entry.get("service") == "forticare" and "description" in entry.get("path", ""):
                changing.append(entry)
            if entry.get("service") == "faz":
                body = entry.get("body") or {}
                if body.get("method") in ("add", "set", "delete", "update"):
                    changing.append(entry)
        return changing


# ------------------------------------------------------------------ checks

def expect(condition, message, failures):
    if not condition:
        failures.append(message)


def check_nominal(result, failures):
    expect(result.code == 0, "exit code %d, expected 0" % result.code, failures)
    expect(not result.malformed(), "the appliance received malformed JSON", failures)

    # Names carrying double quotes, backslashes, percent signs or accents must
    # reach the services exactly as IT Glue holds them.
    descriptions = {body.get("serialNumber"): body.get("description") for body in result.forticare()}
    expect(descriptions.get("FG100F0000000002") == '[ROSS-HQ-FW01] - Rossi "Group" S.r.l.',
           "the organization with double quotes never reached FortiCare: %r"
           % descriptions.get("FG100F0000000002"), failures)
    expect(descriptions.get("FG100F0000000003") == "[PERC-HQ-FW01] - Azienda 100% Sicura",
           "the organization with a percent sign never reached FortiCare: %r"
           % descriptions.get("FG100F0000000003"), failures)
    expect(descriptions.get("FG100F0000000009") == "[UNIC-HQ-FW01] - Società Èlite d'Impresa",
           "the accented organization never reached FortiCare: %r"
           % descriptions.get("FG100F0000000009"), failures)
    expect("FG100F0000000004" not in descriptions,
           "the device tagged noasset was written to FortiCare anyway", failures)

    devices = result.devices()
    expect(devices["FG100F0000000001"]["name"] == "ACME-HQ-FW01",
           "the firewall was not renamed on FortiAnalyzer", failures)
    expect(devices["FG100F0000000002"]["name"] == "ROSS-HQ-FW01",
           "the firewall with double quotes was not renamed: %r" % devices["FG100F0000000002"]["name"],
           failures)
    expect(devices["FG100F0000000003"]["name"] == "FGT-OLD-03",
           "the device tagged nofaz was renamed anyway", failures)
    expect(devices["FG100F0000000006"]["name"] == "FGT-OLD-06",
           "the device with no address was renamed anyway", failures)
    expect(devices["FG100F0000000004"]["name"] == "BACK-HQ-FW01",
           "the device whose organization holds a backslash was not renamed: %r"
           % devices["FG100F0000000004"]["name"], failures)

    # No report may be addressed to the contacts of another organization.
    for prefix, allowed in (("ACME-IT", {"mario.rossi@acme.example", "anna.bianchi@acme.example"}),
                            ("GACME-EN", {"referent@group.example"})):
        addresses = set(result.recipients(prefix))
        expect(addresses and addresses.issubset(allowed),
               "the output profile %s is addressed to %s" % (prefix, sorted(addresses)), failures)

    # The organization naming no recipient must be left exactly as it was.
    expect(not [name for name in result.outputs() if name.startswith("ROSS-IT-") and name != "ROSS-IT-OLD"],
           "reports were built for an organization with no recipient: %s"
           % sorted(result.outputs()), failures)
    expect("ROSS-IT-OLD" in result.outputs(),
           "the previous reports of an organization with no recipient were deleted", failures)
    expect("201" in result.schedules(),
           "the schedule of an organization with no recipient was deleted", failures)

    # A profile built by hand does not belong to this tool.
    expect("MANUAL-PROFILE" in result.outputs(),
           "the output profile built by hand was deleted", failures)

    # Another instance of this tool serves a partner from its own parent folder
    # on the same appliance, for the same organization: it must be untouched.
    expect("ACME-IT-PARTNER" in result.outputs(),
           "the output profile of the instance serving the partner was deleted", failures)
    expect("202" in result.schedules(),
           "the schedule of the instance serving the partner was deleted", failures)
    expect(any(layout.get("title") == "ACME-IT-PARTNER-Web" for layout in result.layouts().values()),
           "the layout of the instance serving the partner was deleted", failures)
    expect("104" in result.folders() and "103" in result.folders(),
           "the folders of the instance serving the partner were deleted", failures)

    # The reports of the previous run are replaced, not piled up, and only for
    # the organizations that were actually rebuilt.
    titles = [layout.get("title", "") for layout in result.layouts().values()]
    expect(not [title for title in titles if title.startswith("ACME-IT-OLD")],
           "the layouts of the previous run survived: %s" % titles, failures)
    expect("ROSS-IT-OLD-Web" in titles,
           "the layouts of an organization with no recipient were deleted: %s" % titles, failures)
    inside = [layout.get("title", "") for layout in result.layouts().values()
              if 101 in (layout.get("folders") or [])
              or {"folder-id": 101} in (layout.get("folders") or [])]
    # ACME is served in two languages and both sets live in this one folder:
    # rebuilding the second language must not wipe the first.
    italian = [title for title in inside if title.startswith("ACME-IT-")]
    english = [title for title in inside if title.startswith("ACME-EN-")]
    expect(len(italian) == 4, "expected four Italian reports in the ACME folder, found %s" % inside, failures)
    expect(len(english) == 4, "expected four English reports in the ACME folder, found %s" % inside, failures)
    expect(len(inside) == 8, "the ACME folder holds %d reports, expected eight" % len(inside), failures)
    expect(len(result.recipients("ACME-EN")) == 1,
           "the second language got the wrong recipients: %s" % result.recipients("ACME-EN"), failures)
    expect(len([title for title in titles if title.startswith("GACME-EN-")]) == 4,
           "expected four reports for the parent organization, found %s" % titles, failures)
    # One set per organization and language, not one per child organization.
    marks = set(title.split("-")[2] for title in titles if title.startswith("GACME-EN-"))
    expect(len(marks) == 1, "the parent organization got %d sets of reports" % len(marks), failures)
    expect("ACME-IT-OLD" not in result.outputs(),
           "the output profile of the previous run was not removed", failures)
    expect("200" not in result.schedules(),
           "the schedule of the previous run was not removed", failures)

    # Every schedule points at the profile built for its own organization and
    # language: a report must never be sent through another customer's profile.
    layout_of = {str(layout.get("layout-id")): layout.get("title", "")
                 for layout in result.layouts().values()}
    for name, schedule in result.schedules().items():
        profile = schedule.get("output-profile")
        if not profile or "-" not in str(profile):
            continue
        for reference in schedule.get("report-layout", []) or []:
            title = layout_of.get(str(reference.get("layout-id")), "")
            if not title:
                continue
            expect(title.startswith(str(profile)),
                   "schedule %s sends the report %s through the profile %s" % (name, title, profile),
                   failures)

    # The session must be handed back to the appliance.
    expect(result.snapshot.get("logout_calls", 0) >= 1, "the FortiAnalyzer session was never closed", failures)
    expect(not result.snapshot.get("session_open"), "the FortiAnalyzer session is still open", failures)

    # Neither a language without template nor an organization whose contacts
    # have no address may stop the run, and neither may lose its old reports.
    expect("no report template" in result.output, "the missing template was not reported", failures)
    expect("no usable address" in result.output,
           "the organization whose contacts have no address was not reported", failures)


def check_dry_run(result, failures):
    expect(result.code == 0, "exit code %d, expected 0" % result.code, failures)
    changing = result.writes()
    expect(not changing, "rehearsal mode sent %d calls that change data: %s"
           % (len(changing), [entry.get("path") for entry in changing[:3]]), failures)
    expect(result.itglue(), "rehearsal mode never read IT Glue", failures)
    expect("Rehearsal mode" in result.output, "rehearsal mode was not announced", failures)


def check_session_expiry(result, failures):
    expect(result.code == 0, "exit code %d, expected 0" % result.code, failures)
    logins = [entry for entry in result.faz(method="exec", url_contains="/sys/login/user")]
    expect(len(logins) > 1, "the session was never renewed", failures)
    devices = result.devices()
    expect(devices["FG100F0000000001"]["name"] == "ACME-HQ-FW01",
           "the work did not resume after the session was renewed", failures)


def check_rebuild_failure(result, failures):
    expect(result.code == 1, "exit code %d, expected 1" % result.code, failures)
    # The rollback has to have something to undo, otherwise this scenario would
    # pin down nothing at all.
    created = [params.get("data", {}) for body, params in result.faz(method="add")]
    expect(len(created) >= 2, "the run failed before creating anything: nothing was rolled back", failures)
    deleted = result.faz(method="delete")
    expect(deleted, "nothing was deleted: the partial work was left on the appliance", failures)
    # Whatever happened, yesterday's reports must still be there.
    expect("ACME-IT-OLD" in result.outputs(),
           "the previous output profile was deleted although the rebuild failed: %s"
           % sorted(result.outputs()), failures)
    expect("200" in result.schedules(),
           "the previous schedule was deleted although the rebuild failed", failures)
    expect(any("OLD" in layout.get("title", "") for layout in result.layouts().values()),
           "the previous layouts were deleted although the rebuild failed", failures)
    # Nothing half built may be left behind: a layout of this run carries the
    # unique mark of the run in its title.
    mark = re.compile(r"-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}-")
    fresh = [title for title in (layout.get("title", "") for layout in result.layouts().values())
             if mark.search(title)]
    expect(not fresh, "the failed rebuild left layouts behind: %s" % fresh, failures)
    profiles = [name for name in result.outputs() if mark.search(name + "-")]
    expect(not profiles, "the failed rebuild left output profiles behind: %s" % profiles, failures)


def check_itglue_down(result, failures):
    expect(result.code == 1, "exit code %d, expected 1" % result.code, failures)
    deletions = [entry for entry in result.requests
                 if entry.get("service") == "faz"
                 and (entry.get("body") or {}).get("method") == "delete"]
    expect(not deletions, "reports were deleted while IT Glue was unreachable", failures)
    expect("ACME-IT-OLD" in result.outputs(), "the previous reports did not survive", failures)


def check_environment(result, failures):
    expect(result.code == 2, "exit code %d, expected 2" % result.code, failures)
    expect("ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID" in result.output,
           "the missing variable was not named", failures)
    expect(not result.requests, "calls were made although the configuration is incomplete", failures)


def check_forticare_down(result, failures):
    expect(result.code == 1, "exit code %d, expected 1" % result.code, failures)
    expect("[!!]" in result.output, "the failures were not reported", failures)
    # A broken FortiCare must not stop the FortiAnalyzer work.
    devices = result.devices()
    expect(devices["FG100F0000000001"]["name"] == "ACME-HQ-FW01",
           "FortiAnalyzer was not updated while FortiCare was failing", failures)
    expect(result.outputs(), "the reports were not built while FortiCare was failing", failures)


def check_partner(result, failures):
    """The configuration a partner runs: own parent folder on the shared
    appliance, no FortiCare writes, own mail wording and own cover page."""
    expect(result.code == 0, "exit code %d, expected 0" % result.code, failures)
    expect(not result.forticare(),
           "FortiCare was written although ENVIRONMENT_FORTINET_NOSYNC is set", failures)

    # The reports land in the partner folder, and the IBS ones are untouched.
    partner = [layout.get("title", "") for layout in result.layouts().values()
               if 104 in (layout.get("folders") or [])
               or {"folder-id": 104} in (layout.get("folders") or [])]
    # ACME is served in two languages, so the partner folder holds both sets.
    expect(len([title for title in partner if title.startswith("ACME-IT-")]) == 4
           and len([title for title in partner if title.startswith("ACME-EN-")]) == 4,
           "expected four reports per language in the partner folder, found %s" % partner, failures)
    expect("ACME-IT-PARTNER-Web" not in partner,
           "the previous partner report was not replaced: %s" % partner, failures)
    expect(any(layout.get("title") == "ACME-IT-OLD-Web" for layout in result.layouts().values()),
           "the reports of the other instance were deleted", failures)
    expect("ACME-IT-OLD" in result.outputs() and "200" in result.schedules(),
           "the schedule or profile of the other instance was deleted", failures)
    expect("ACME-IT-PARTNER" not in result.outputs(),
           "the previous profile of the partner was not replaced", failures)

    # The mounted mail template and the overload reached the appliance.
    profiles = [params.get("data", {}) for body, params in result.faz(method="add", url_contains="/config/output")]
    expect(any(data.get("email-subject") == "Partner srl Security Report" for data in profiles),
           "the mounted mail template was not used: %s" % [d.get("email-subject") for d in profiles], failures)
    layouts = [params.get("data", {}) for body, params in result.faz(method="add", url_contains="/config/layout")]
    layouts = [data for data in layouts if "folder-name" not in data]
    expect(layouts and all(data.get("coverpage-background-image") == "{user_img_path}/PartnerCover.png"
                           for data in layouts),
           "the cover page of the overload did not reach every layout", failures)
    expect(layouts and all(data.get("header") == [{"graphic": "{user_img_path}/partner-logo.jpg"}]
                           for data in layouts),
           "the header of the overload did not reach every layout", failures)


SCENARIOS = {
    "partner-instance": {
        "check": check_partner,
        "environment": {
            "ENVIRONMENT_FORTINET_NOSYNC": "true",
            "ENVIRONMENT_FORTIANALYZER_FOLDER": "PartnerReport",
            "ENVIRONMENT_FORTIANALYZER_OVERLOAD":
                '{"coverpage-background-image":"{user_img_path}/PartnerCover.png",'
                '"header":[{"graphic":"{user_img_path}/partner-logo.jpg"}]}',
            # the credentials of the service it does not use are not given
            "ENVIRONMENT_FORTINET_USERNAME": None,
            "ENVIRONMENT_FORTINET_PASSWORD": None,
            "ENVIRONMENT_FORTINET_CLIENTID": None,
        },
        "volumes": [("fixtures/partner-email.it.json", "/library/fortinet/template/it/email.json")],
        "faults": None,
    },
    "nominal": {
        "check": check_nominal,
        "environment": {},
        "faults": None,
    },
    "dry-run": {
        "check": check_dry_run,
        "environment": {"ENVIRONMENT_DRYRUN": "1"},
        "faults": None,
    },
    "session-expiry": {
        "check": check_session_expiry,
        "environment": {},
        "faults": {"endpoints": {}, "faz_session_expire_after": 6},
    },
    "rebuild-failure": {
        "check": check_rebuild_failure,
        "environment": {},
        # The first three creations go through - output profile, first layout,
        # first schedule - and everything after that fails: this is what makes
        # the rollback run for real instead of having nothing to undo.
        "faults": {"endpoints": {"faz_add": {"skip": 3, "times": 99, "status": 500}}},
    },
    "itglue-down": {
        "check": check_itglue_down,
        "environment": {},
        "faults": {"endpoints": {"itglue_configurations": {"times": 99, "status": 500}}},
    },
    "forticare-down": {
        "check": check_forticare_down,
        "environment": {},
        "faults": {"endpoints": {}, "forticare_update_fail": True},
    },
    "incomplete-environment": {
        "check": check_environment,
        "environment": {"ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID": None},
        "faults": None,
    },
}


def main():
    wanted = sys.argv[1:] or sorted(SCENARIOS)
    unknown = [name for name in wanted if name not in SCENARIOS]
    if unknown:
        print("unknown scenarios: %s" % ", ".join(unknown))
        return 2

    if not os.environ.get("FORTIGLUE_IMAGE"):
        print("building %s" % IMAGE, flush=True)
        build = run(["docker", "build", "-t", IMAGE, ROOT])
        if build.returncode != 0:
            print(build.stdout + build.stderr)
            return 1

    workspace = tempfile.mkdtemp(prefix="fortiglue-suite-")
    print("workspace %s" % workspace, flush=True)
    certificates = build_certificates(workspace)
    bench = Bench(workspace, certificates)

    failed = 0
    for name in wanted:
        scenario = SCENARIOS[name]
        print("\n== %s ==" % name, flush=True)
        try:
            result = bench.execute(name, scenario.get("environment"), scenario.get("faults"),
                                   scenario.get("dataset"), scenario.get("volumes"))
        except Exception as error:  # noqa: BLE001 - the suite must report, not crash
            print("   the scenario could not run: %s" % error)
            failed += 1
            continue

        failures = []
        scenario["check"](result, failures)
        directory = os.path.join(workspace, name)
        with open(os.path.join(directory, "stdout.log"), "w", encoding="utf-8") as handle:
            handle.write(result.stdout)
        with open(os.path.join(directory, "stderr.log"), "w", encoding="utf-8") as handle:
            handle.write(result.stderr)
        with open(os.path.join(directory, "state.json"), "w", encoding="utf-8") as handle:
            json.dump(result.snapshot, handle, indent=2, ensure_ascii=False)

        if failures:
            failed += 1
            print("   FAILED in %.1fs (exit %d, %d calls)" % (result.elapsed, result.code, len(result.requests)))
            for failure in failures:
                print("     - %s" % failure)
            print("     journal and logs in %s" % directory)
        else:
            print("   passed in %.1fs (exit %d, %d calls)" % (result.elapsed, result.code, len(result.requests)))

    print("\n%d scenarios, %d failed" % (len(wanted), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
