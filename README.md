# Fortiglue
#### _Sync tool for ITGlue&Fortinet_

## Getting Started

With these instructions you will be able to setting up your system to run a container on your server. See deployment's notes to deploy the project on a live system.

### Installing

I recommend using [Docker](https://www.docker.com/) to run the script as the container is updated according to the machine versions.
The container do not require any specified configuration because the software works like an automatic tool.

## Docker cli

```
docker run --name fortiglue --env-file configuration.env ubyte/ibs-fortiglue:latest
```

## Features

- Sync all name of Fortinet product from ITGlue and FortiManager using Serial Number.
- Sync all name of Fortigate from ITGlue and FortiAnalyzer using Serial Number.
- Generate report in FortiAnalyzer based on Flezible Field in ITGlue.

## Environment

| key | value |
| ------ | ------ |
| ENVIRONMENT_ITGLUE | The FQDN of ITGlue API. Example: api.eu.itglue.com |
| ENVIRONMENT_ITGLUE_APIKEY | Your APIKEY to autenticate in your tenant |
| ENVIRONMENT_ITGLUE_CONFIGURATION_STATUS_ACTIVE | The ID of status active menù in all configuration |
| ENVIRONMENT_FORTINET_USERNAME | Username of API account in FortiManager |
| ENVIRONMENT_FORTINET_PASSWORD | Password of API account in FortiManager |
| ENVIRONMENT_FORTINET_CLIENTID | The Client string ID information |
| ENVIRONMENT_FORTIANALYZER_FQDN | The FQDN of FortiAnalyzer |
| ENVIRONMENT_FORTIANALYZER_USERNAME | Username of FortiAnalyzer must have the property read/write in API |
| ENVIRONMENT_FORTIANALYZER_PASSWORD | Password of FortiAnalyzer account |
| ENVIRONMENT_FORTIANALYZER_EMAIL_FROM | Recipient e-mail to recive the report in PDF |
| ENVIRONMENT_FORTIANALYZER_EMAIL_SMTP | SMTP used of FortiAnalyzer to send report to recipient e-mail |
| ENVIRONMENT_FORTIANALYZER_FOLDER | Specify the master forlder to contain the sub-directory of report |


## Built With

* [Docker](https://www.docker.com/) - Get Started with Docker
* [Alpine Linux](https://alpinelinux.org/) - Alpine Linux
* [JQ](https://stedolan.github.io/jq/) - JQ
* [cURL](https://curl.se/) - cURL

## Contributing

Please read [CONTRIBUTING.md](https://github.com/ubyte-source/ibs-fortiglue/blob/main/CONTRIBUTING.md) for details on our code of conduct, and the process for submitting us pull requests.

## Versioning

We use [SemVer](https://semver.org/) for versioning. For the versions available, see the [tags on this repository](https://github.com/ubyte-source/ibs-fortiglue/tags). 

## Authors

* **Paolo Fabris** - *Initial work* - [ibs.srl](https://ibs.srl/)

See also the list of [contributors](https://github.com/ubyte-source/ibs-fortiglue/blob/main/CONTRIBUTORS.md) who participated in this project.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details
