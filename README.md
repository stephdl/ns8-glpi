# ns8-glpi

[GLPI](https://glpi-project.org/) IT service management for [NethServer 8](https://github.com/NethServer/ns8-core).

The module runs the official `glpi/glpi` image (Apache, PHP, built-in cron worker) with a MariaDB LTS database in the same rootless pod.
Traefik publishes it on a dedicated host name and always redirects HTTP to HTTPS.

Features:

- the local `glpi` Super-Admin password is set from NS8, the demo accounts `tech`, `normal` and `post-only` are disabled
- login with GLPI local accounts and with the users of one NS8 user domain (OpenLDAP or Active Directory)
- domain users are created at their first login with the Self-Service profile
- members of an optional domain group get the Super-Admin profile
- optional daily synchronization of domain users (names, emails, removed users get disabled)
- email notifications through the cluster smarthost, when it is configured
- default GLPI language chosen at configuration time
- backup, restore, clone and move

## Install

Instantiate the module with:

    add-module ghcr.io/stephdl/glpi:latest 1

The output of the command will return the instance name.
Output example:

    {"module_id": "glpi1", "image_name": "glpi", "image_url": "ghcr.io/stephdl/glpi:latest"}

## Configure

Let's assume that the instance is named `glpi1`.

Launch `configure-module` with the following parameters:

- `host`: fully qualified domain name of the application
- `lets_encrypt`: request a Let's Encrypt certificate (true/false)
- `language`: default GLPI language, one of `en_GB`, `en_US`, `fr_FR`, `it_IT`, `es_ES`, `de_DE`, `pt_PT`, `pt_BR`, `nl_NL`
- `user_domain`: NS8 user domain for LDAP login, empty for local accounts only
- `admin_group`: group of the user domain whose members get the Super-Admin profile, empty for none
- `ldap_sync`: synchronize domain users every day (true/false)
- `mail_from`: sender of GLPI notifications, empty for `noreply@<host>`
- `admin_password`: password of the GLPI local `glpi` account, at least 8 characters with lowercase and uppercase letters, a number and a symbol. Required at the first configuration, optional later

Example:

```
api-cli run configure-module --agent module/glpi1 --data - <<EOF
{
  "host": "glpi.domain.com",
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
The internal `glpi-system` account is kept: GLPI uses it for automatic actions and nobody can log in with it.

The module writes its settings into GLPI at every configuration, module update, smarthost change and user domain change.
If the user domain is unreachable, the LDAP settings and the admin rule are kept as they are.
If the user domain is removed from the cluster, the LDAP directory is disabled but not deleted, and GLPI local accounts still work.
The same applies after a restore or a clone on a cluster without that domain.
The LDAP directory is named `ns8-<domain>` and the admin rule `NS8 administrators group`: changes made to them from the GLPI interface are overwritten.

Get the current configuration with:

    api-cli run get-configuration --agent module/glpi1

## Backup, restore, clone

The backup contains a dump of the database, the database credentials and the `glpi-data` volume (GLPI configuration, encryption key, documents, marketplace plugins).
The `glpi-data` volume can be placed on an additional disk at install time.

A cloned instance keeps the host name of its source and gets no Traefik route.
Set a new host name from the Settings page to make it reachable.
A moved instance keeps its host name.

## Users and groups

Domain users are created in GLPI at their first login with the Self-Service profile.
Members of `admin_group` get the Super-Admin profile on the root entity.
With `ldap_sync`, the `glpi-ldap-sync.timer` user unit runs `ldap:synchronize_users` once a day: names and emails are updated and users removed from the domain are disabled.

## Email

GLPI uses the cluster smarthost settings. Notifications are enabled only when the smarthost is enabled.
The container host name is the GLPI host name, so the SMTP EHLO uses the FQDN.

## Upgrade

The GLPI image updates the database schema at startup when its version changes.
Back up the instance before an upgrade to a new major version, and check that installed plugins support it.
Renovate opens the image update PRs. MariaDB stays on the 12.3 LTS branch, and GLPI major upgrades are not merged automatically.
The About page shows the GLPI version next to the module version.

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

    ./test-module.sh <NODE_ADDR> ghcr.io/stephdl/glpi:latest

The tests are made using [Robot Framework](https://robotframework.org/).

## UI translation

Translated with [Weblate](https://hosted.weblate.org/projects/ns8/).
Edit only `ui/public/i18n/en/translation.json`, the other languages are managed by Weblate.
