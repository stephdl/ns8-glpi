# ns8-glpi

[GLPI](https://glpi-project.org/) IT service management for [NethServer 8](https://github.com/NethServer/ns8-core).

The module runs the official `glpi/glpi` image (Apache, PHP, built-in cron worker) with a MariaDB database in the same pod.
Traefik publishes it on a dedicated host name.

Features:

- login with GLPI local accounts and with the users of one NS8 user domain (OpenLDAP or Active Directory)
- domain users are created at their first login with the Self-Service profile
- members of an optional domain group get the Super-Admin profile
- optional daily synchronization of domain users (names, emails, removed users get disabled)
- email notifications through the cluster smarthost, when it is configured
- backup, restore, clone and move

## Install

Instantiate the module with:

    add-module ghcr.io/nethserver/glpi:latest 1

The output of the command will return the instance name.
Output example:

    {"module_id": "glpi1", "image_name": "glpi", "image_url": "ghcr.io/nethserver/glpi:latest"}

## Configure

Let's assume that the instance is named `glpi1`.

Launch `configure-module` with the following parameters:

- `host`: fully qualified domain name of the application
- `http2https`: redirect HTTP to HTTPS (true/false)
- `lets_encrypt`: request a Let's Encrypt certificate (true/false)
- `language`: default GLPI language, for example `en_GB`, `fr_FR`, `it_IT`
- `user_domain`: NS8 user domain for LDAP login, empty for local accounts only
- `admin_group`: group of the user domain whose members get the Super-Admin profile, empty for none
- `ldap_sync`: synchronize domain users every day (true/false)
- `mail_from`: sender of GLPI notifications, empty for `noreply@<host>`
- `admin_password`: password of the GLPI local `glpi` account. Required at the first configuration, optional later

Example:

```
api-cli run configure-module --agent module/glpi1 --data - <<EOF
{
  "host": "glpi.domain.com",
  "http2https": true,
  "lets_encrypt": false,
  "language": "en_GB",
  "user_domain": "ad.domain.com",
  "admin_group": "Domain Admins",
  "ldap_sync": true,
  "mail_from": "",
  "admin_password": "Choose,a-strong1"
}
EOF
```

The first start installs the GLPI database, it takes about one minute.
The demo accounts `tech`, `normal` and `post-only` are disabled.

The module writes its settings into GLPI at every configuration, smarthost change and user domain change.
The LDAP directory is named `ns8-<domain>` and the admin rule `NS8 administrators group`: changes made to them from the GLPI interface are overwritten.

Get the current configuration with:

    api-cli run get-configuration --agent module/glpi1

## Backup, restore, clone

The backup contains a dump of the database, the database credentials and the `glpi-data` volume (GLPI configuration, encryption key, documents, marketplace plugins).
The `glpi-data` volume can be placed on an additional disk at install time.

A cloned instance keeps the host name of its source and gets no Traefik route.
Set a new host name from the Settings page to make it reachable.
A moved instance keeps its host name.

## Upgrade

The GLPI image updates the database schema at startup when its version changes.
Back up the instance before an upgrade to a new major version, and check that installed plugins support it.

## Debug

Show the module environment:

    runagent -m glpi1 env

Run the GLPI console:

    runagent -m glpi1 podman exec -ti glpi-app php /var/www/glpi/bin/console list

Apply the module settings to GLPI again:

    runagent -m glpi1 glpi-apply-config

## Uninstall

To uninstall the instance:

    remove-module --no-preserve glpi1

## Testing

Test the module using the `test-module.sh` script:

    ./test-module.sh <NODE_ADDR> ghcr.io/nethserver/glpi:latest

The tests are made using [Robot Framework](https://robotframework.org/).

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).
