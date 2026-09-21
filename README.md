# Fortiglue

#### _Nightly synchronisation between IT Glue and the Fortinet services_

Fortiglue is a container that runs once, does its work and exits. It reads the
configurations held in IT Glue and uses them to keep two Fortinet services in
line with them:

* **FortiCare** — every Fortinet asset gets the description `[device name] - organization`;
* **FortiAnalyzer** — every firewall is renamed after IT Glue, and every
  organization gets its scheduled reports rebuilt and addressed to the contacts
  named in IT Glue.

## Running it

```
docker run --rm --env-file configuration.env xibs/ibs-fortiglue:latest >> last.log 2>&1
```

The container needs no volume and no port. **The log goes to standard error**,
because standard output carries the values the functions pass to each other, so
a scheduler that keeps a log file has to redirect both streams (`2>&1` above).
The exit code tells it how the night went:

| exit code | meaning |
| --------- | ------- |
| `0` | everything done, nothing failed |
| `1` | the run completed, but at least one operation failed |
| `2` | the run could not start: incomplete configuration, or no sign in |

A first run on a new installation is best done twice: once with
`ENVIRONMENT_DRYRUN=1`, which sends no call that writes anything and logs every
change it would make — including every deletion it would perform — and then for
real. `ENVIRONMENT_FORTIANALYZER_ADOM` narrows a first real run to one ADOM.

## What the two stages do

### sync

Every active, non archived IT Glue configuration whose manufacturer is
`Fortinet` is pushed to the two services:

* its serial number receives the description `[name] - organization` on
  FortiCare, unless the configuration carries the asset tag `noasset`;
* if it is a `Firewall` with a primary address, it is looked up on
  FortiAnalyzer by serial number and renamed after IT Glue, unless it carries
  the asset tag `nofaz`.

A device whose serial number is unknown to FortiAnalyzer is reported and
skipped, not treated as a failure: it usually means the firewall has not been
registered on the appliance yet.

### report

For every ADOM holding devices that follow the firewall naming convention, each
organization is served in turn: its own firewalls plus the firewalls of the
organizations below it in the IT Glue hierarchy, so a parent organization gets
one report set covering the whole group.

The recipients come from an IT Glue flexible asset
(`ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID`) holding a language and a list of
contacts. Only the primary address of each named contact is used.

Rebuilding follows one rule: **nothing is deleted before its replacement
exists**. For each organization and language the new output profile, layouts
and schedules are created first — their names carry a fresh identifier, so they
never collide with the previous ones — and only then the previous set is
removed. If anything fails halfway, the partial work is undone and yesterday's
reports are left in place, so a customer never ends up with no report at all.

An organization served in two languages gets both sets, and they replace the
previous ones together: the retirement happens once the last language is in
place, never in between.

These are deliberately left alone, and reported instead:

* organizations that name no recipient, or whose contacts have no primary
  address: their existing reports are kept untouched;
* languages with no report template in the image;
* folders, layouts, schedules and output profiles that do not hang from a
  folder this run has just filled — the work of an engineer, or of another
  instance sharing the appliance.

Inside the folder of an organization that is being rebuilt, on the other hand,
everything left from a previous run is replaced: that folder belongs to the
tool.

## Environment

Required:

| key | value |
| --- | ----- |
| `ENVIRONMENT_ITGLUE` | FQDN of the IT Glue API, for example `api.eu.itglue.com` |
| `ENVIRONMENT_ITGLUE_APIKEY` | API key of the IT Glue tenant |
| `ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE` | Identifier of the active configuration status |
| `ENVIRONMENT_ITGLUE_FLEXIBLE_ASSET_TYPE_ID` | Identifier of the flexible asset type holding the report recipients |
| `ENVIRONMENT_FORTINET_USERNAME` | FortiCare API account user name |
| `ENVIRONMENT_FORTINET_PASSWORD` | FortiCare API account password |
| `ENVIRONMENT_FORTINET_CLIENTID` | FortiCare client identifier, for example `assetmanagement` |
| `ENVIRONMENT_FORTIANALYZER_FQDN` | FQDN of the FortiAnalyzer appliance |
| `ENVIRONMENT_FORTIANALYZER_USERNAME` | FortiAnalyzer account with read and write on the API |
| `ENVIRONMENT_FORTIANALYZER_PASSWORD` | Password of that account |
| `ENVIRONMENT_FORTIANALYZER_FOLDER` | Parent report folder holding one subfolder per organization |
| `ENVIRONMENT_FORTIANALYZER_EMAIL_FROM` | Sender address of the report messages |
| `ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP` | Mail server profile configured on FortiAnalyzer |

The three `ENVIRONMENT_FORTINET_*` credentials are not needed when
`ENVIRONMENT_FORTINET_NOSYNC` is set.

Optional:

| key | value |
| --- | ----- |
| `ENVIRONMENT_DRYRUN` | When set to `1`, no call that writes is ever sent: the run only logs what it would do |
| `ENVIRONMENT_FORTINET_NOSYNC` | When set, the FortiCare descriptions are not written |
| `ENVIRONMENT_FORTIANALYZER_NOREPORT` | When set, the report stage is not executed |
| `ENVIRONMENT_FORTIANALYZER_NORENAME` | When set, devices are not renamed on this appliance |
| `ENVIRONMENT_FORTIANALYZER_ADOM` | Comma separated list of ADOMs to work on, default every ADOM |
| `ENVIRONMENT_FORTIANALYZER_OVERLOAD` | JSON object merged into every report layout, for installation specific settings |
| `ENVIRONMENT_FORTIANALYZER_DEVICE_PATTERN` | Regular expression picking the firewalls that get a report, default `[A-Z0-9]{4}-[A-Z0-9]{2}-FW[0-9]{2}` |
| `ENVIRONMENT_FORTIANALYZER_CACERT` | Path of a certificate authority bundle: giving it turns on TLS verification of the appliance |
| `ENVIRONMENT_LOG_LEVEL` | `debug`, `info`, `warning` or `error`, default `info` |
| `ENVIRONMENT_HTTP_RETRY` | Attempts per HTTP call, default `4` |
| `ENVIRONMENT_HTTP_TIMEOUT` | Deadline in seconds of a single call, default `120` |
| `ENVIRONMENT_HTTP_CONNECT_TIMEOUT` | Deadline in seconds to open a connection, default `15` |
| `ENVIRONMENT_HTTP_BACKOFF` | Base of the growing pause between two attempts, default `2` |
| `ENVIRONMENT_ITGLUE_RATE` | Minimum seconds between two IT Glue calls, default `0.15` |
| `ENVIRONMENT_ITGLUE_PAGE_SIZE` | Page size of the IT Glue listings, default `600` |
| `ENVIRONMENT_ITGLUE_PAGE_LIMIT` | Highest number of pages read from one listing, default `500` |
| `ENVIRONMENT_ITGLUE_NAME_CHUNK` | Device names asked for in a single request, default `50` |
| `ENVIRONMENT_FORTINET_RATE` | Minimum seconds between two FortiCare calls, default `0.2` |
| `ENVIRONMENT_FORTIANALYZER_RATE` | Minimum seconds between two FortiAnalyzer calls, default `0` |
| `ENVIRONMENT_FORTICARE_ENDPOINT` | Base address of the FortiCare API, default `https://support.fortinet.com` |
| `ENVIRONMENT_FORTICARE_AUTH_ENDPOINT` | Base address of the token service, default `https://customerapiauth.fortinet.com` |

An incomplete configuration is reported in full at startup — every missing
variable at once — and the run stops with exit code `2` before touching
anything.

`example.env` holds a template to copy.

## Several instances on one appliance

More than one instance of this tool can serve the same FortiAnalyzer, each one
with its own parent folder — for example one folder per partner, or one
instance for the asset descriptions and one per appliance for the reports.
Nothing is ever selected by name for deletion: an old report is removed only
when it hangs from the folder the running instance owns, and an output profile
only when the schedules being replaced were the ones using it. Two instances
serving the same organization from two different folders do not disturb each
other.

`ENVIRONMENT_FORTINET_NOSYNC` is what keeps the FortiCare descriptions from
being written several times: one instance writes them, the others only rename
devices and rebuild reports. `ENVIRONMENT_FORTIANALYZER_NORENAME` does the same
for the renaming, when two instances share an appliance and only one of them
should be touching device names.

Two instances must not share the same parent folder, and the same instance must
not be started twice at once: both runs would consider the other's fresh
reports as leftovers of a previous night. Giving the container a fixed name is
enough of a lock, since Docker refuses to start a second one:

```
docker run --rm --name fortiglue-customers-faz02 --env-file configuration.env \
  xibs/ibs-fortiglue:latest >> last.log 2>&1
```

The mail templates can be replaced from outside the image, which is how a
partner gets its own wording without a private build:

```
docker run --rm --env-file configuration.env \
  -v /opt/fortiglue/partner/email.it.json:/library/fortinet/template/it/email.json:ro \
  -v /opt/fortiglue/partner/email.en.json:/library/fortinet/template/en/email.json:ro \
  -e ENVIRONMENT_FORTIANALYZER_OVERLOAD='{"coverpage-background-image":"{user_img_path}/cover.png"}' \
  xibs/ibs-fortiglue:latest >> last.log 2>&1
```

The mounted files have to be readable by the unprivileged user inside the
container, so world readable permissions on the host (`chmod 644`).

`ENVIRONMENT_FORTIANALYZER_OVERLOAD` is merged into every layout before the
fields this tool owns, so it can change images, colours and headers but never
move a report into another folder or rename it. It is checked at startup: if it
is not a JSON object the run stops before anything is touched.

## Security notes

* Credentials never appear in process arguments: request bodies and
  authentication headers are passed to `curl` through files with restricted
  permissions, so `ps` shows nothing useful.
* The appliance usually carries a self signed certificate, so its certificate
  is not verified by default. Point `ENVIRONMENT_FORTIANALYZER_CACERT` at a
  bundle to turn verification on; IT Glue and FortiCare are always verified.
* The container runs as an unprivileged user and writes only to `/tmp`.
* Keep the API key out of the repository: `*.env` is ignored by git and the
  build context excludes everything but the program itself.

## Tests

The acceptance suite runs the real image against a bench that impersonates
IT Glue, FortiAnalyzer and FortiCare on a private Docker network, with the real
host names resolving to it:

```
python3 test/suite.py                  # every scenario
python3 test/suite.py nominal dry-run  # only those two
```

Each scenario checks what the run did to the services, not only what it
printed: the descriptions written, the devices renamed, which reports were
replaced and which were left alone, whether the session was closed. The data
set on purpose holds names with double quotes, backslashes, percent signs and
accented letters, organizations with no recipient, contacts with no primary
address, languages with no template, and the objects of a second instance
serving a partner from its own folder on the same appliance.

| scenario | what it pins down |
| -------- | ----------------- |
| `nominal` | descriptions, renames, reports replaced, everything else left alone, session closed |
| `partner-instance` | a partner run: own folder, no FortiCare writes, mounted mail template, overload on every layout |
| `dry-run` | not a single call that writes leaves the container |
| `session-expiry` | the session is renewed in the middle of the work and the work finishes |
| `rebuild-failure` | a rebuild failing halfway leaves yesterday's reports in place and nothing half built |
| `itglue-down` | with IT Glue unreachable nothing at all is deleted |
| `forticare-down` | a broken FortiCare does not stop the FortiAnalyzer work |
| `incomplete-environment` | a missing variable stops the run before the first call |

The same suite, ShellCheck and a JSON check of every report template run in CI
on each push and pull request.

## Built with

* [Docker](https://www.docker.com/)
* [Alpine Linux](https://alpinelinux.org/)
* [jq](https://jqlang.github.io/jq/)
* [cURL](https://curl.se/)

## Versioning

We use [SemVer](https://semver.org/). For the versions available, see the
[tags on this repository](https://github.com/ibs-source/ibs-fortiglue/tags).
Pushing a tag builds and publishes the image; `latest` follows the highest
version only.

## Authors

* **Paolo Fabris** - _Initial work_ - [ibs.srl](https://ibs.srl/)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE)
file for details.
