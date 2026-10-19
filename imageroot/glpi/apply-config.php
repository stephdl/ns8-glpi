<?php

/*
 * Copyright (C) 2026 Nethesis S.r.l.
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Apply the NS8 module settings to the GLPI database.
 * Run inside the glpi-app container, settings come from NS8_* environment variables.
 * Idempotent: every run converges to the same state.
 */

require '/var/www/glpi/vendor/autoload.php';

$kernel = new \Glpi\Kernel\Kernel();
$kernel->boot();

const NS8_LDAP_PREFIX = 'ns8-';
const NS8_ADMIN_RULE_UUID = 'ns8-ldap-admin-group';

function env(string $name, string $default = ''): string
{
    $value = getenv($name);
    return $value === false ? $default : $value;
}

function logmsg(string $message): void
{
    fwrite(STDERR, $message . PHP_EOL);
}

function fail(string $message): never
{
    logmsg('ERROR: ' . $message);
    exit(1);
}

function apply_general_config(): void
{
    $host = env('NS8_HOST');
    $mail_from = env('NS8_MAIL_FROM') ?: 'noreply@' . $host;
    $smtp_enabled = env('NS8_SMTP_ENABLED') === '1';

    $values = [
        'url_base'                 => 'https://' . $host,
        'language'                 => env('NS8_LANGUAGE', 'en_GB'),
        'admin_email'              => $mail_from,
        'from_email'               => $mail_from,
        'admin_email_noreply'      => $mail_from,
        'is_users_auto_add'        => 1,
        'user_deleted_ldap_user'   => AuthLDAP::DELETED_USER_ACTION_USER_DISABLE,
        'user_restored_ldap'       => AuthLDAP::RESTORED_USER_ENABLE,
        'use_notifications'        => $smtp_enabled ? 1 : 0,
        'notifications_mailing'    => $smtp_enabled ? 1 : 0,
    ];

    if ($smtp_enabled) {
        $values += [
            'smtp_mode'              => match (env('NS8_SMTP_ENCRYPTION')) {
                'tls'      => MAIL_SMTPSSL,
                'starttls' => MAIL_SMTPTLS,
                default    => MAIL_SMTP,
            },
            'smtp_host'              => env('NS8_SMTP_HOST'),
            'smtp_port'              => env('NS8_SMTP_PORT', '25'),
            'smtp_username'          => env('NS8_SMTP_USERNAME'),
            'smtp_passwd'            => env('NS8_SMTP_PASSWORD'),
            'smtp_check_certificate' => env('NS8_SMTP_TLSVERIFY') === '1' ? 1 : 0,
        ];
    }

    Config::setConfigurationValues('core', $values);
    logmsg('General and mail settings applied (smtp ' . ($smtp_enabled ? 'enabled' : 'disabled') . ')');
}

/** Return the ns8-* LDAP directories, keyed by id. */
function find_ns8_directories(): array
{
    global $DB;

    $directories = [];
    foreach ($DB->request(['FROM' => AuthLDAP::getTable(), 'WHERE' => ['name' => ['LIKE', NS8_LDAP_PREFIX . '%']]]) as $row) {
        $directories[$row['id']] = $row;
    }
    return $directories;
}

// Keep the directory: GLPI users stay linked to it and work again if the domain comes back
function deactivate_directory(int $id, array $row): void
{
    if ($row['is_active'] || $row['is_default']) {
        (new AuthLDAP())->update(['id' => $id, 'is_active' => 0, 'is_default' => 0]);
        logmsg("Disabled LDAP directory {$row['name']}");
    }
}

function remove_admin_rule(): void
{
    $rule = new RuleRight();
    if ($rule->getFromDBByCrit(['uuid' => NS8_ADMIN_RULE_UUID])) {
        $rule->delete(['id' => $rule->getID()], true);
    }
}

function apply_ldap_directory(string $domain): int
{
    $is_ad = env('NS8_LDAP_SCHEMA') === 'ad';
    $name = NS8_LDAP_PREFIX . $domain;

    $input = [
        'name'               => $name,
        'host'               => env('NS8_LDAP_HOST'),
        'port'               => (int) env('NS8_LDAP_PORT'),
        'basedn'             => env('NS8_LDAP_BASE_DN'),
        'rootdn'             => env('NS8_LDAP_BIND_DN'),
        'rootdn_passwd'      => env('NS8_LDAP_BIND_PASSWORD'),
        'use_bind'           => 1,
        'use_tls'            => 0,
        'is_active'          => 1,
        'is_default'         => 1,
        'email1_field'       => 'mail',
        'phone_field'        => 'telephonenumber',
        'mobile_field'       => 'mobile',
        'comment'            => 'Managed by NethServer 8, changes are overwritten',
        // Group membership is read from the group entries, it works for both schemas
        'group_search_type'  => AuthLDAP::GROUP_SEARCH_GROUP,
        'group_field'        => '',
    ];
    if ($is_ad) {
        $input += [
            'condition'          => '(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2))' . env('NS8_LDAP_USERS_FILTER') . ')',
            'login_field'        => 'samaccountname',
            'sync_field'         => 'objectguid',
            'group_condition'    => '(objectClass=group)',
            'group_member_field' => 'member',
            'use_dn'             => 1,
            'can_support_pagesize' => 1,
            'pagesize'           => 1000,
            'realname_field'     => 'sn',
            'firstname_field'    => 'givenname',
        ];
    } else {
        $input += [
            'condition'          => '(&(objectClass=posixAccount)' . env('NS8_LDAP_USERS_FILTER') . ')',
            'login_field'        => 'uid',
            'sync_field'         => '',
            'group_condition'    => '(objectClass=posixGroup)',
            'group_member_field' => 'memberuid',
            'use_dn'             => 0,
            // NS8 OpenLDAP splits the display name badly into cn and sn, displayName is clean
            'realname_field'     => 'displayname',
            'firstname_field'    => '',
        ];
    }

    $directory = new AuthLDAP();
    $existing = null;
    foreach (find_ns8_directories() as $id => $row) {
        if ($row['name'] === $name) {
            $existing = $id;
        } else {
            deactivate_directory($id, $row);
        }
    }

    if ($existing === null) {
        $existing = $directory->add($input);
        if (!$existing) {
            fail("cannot create LDAP directory $name");
        }
        logmsg("Created LDAP directory $name");
    } else {
        if (!$directory->update(['id' => $existing] + $input)) {
            fail("cannot update LDAP directory $name");
        }
        logmsg("Updated LDAP directory $name");
    }
    return (int) $existing;
}

/** Find the DN of an LDAP group by its name, with the module bind credentials. */
function find_group_dn(string $group): ?string
{
    $is_ad = env('NS8_LDAP_SCHEMA') === 'ad';
    $connection = ldap_connect('ldap://' . env('NS8_LDAP_HOST') . ':' . env('NS8_LDAP_PORT'));
    ldap_set_option($connection, LDAP_OPT_PROTOCOL_VERSION, 3);
    ldap_set_option($connection, LDAP_OPT_REFERRALS, 0);
    if (!@ldap_bind($connection, env('NS8_LDAP_BIND_DN'), env('NS8_LDAP_BIND_PASSWORD'))) {
        fail('LDAP bind failed: ' . ldap_error($connection));
    }

    $name = ldap_escape($group, '', LDAP_ESCAPE_FILTER);
    $filter = $is_ad
        ? "(&(objectClass=group)(|(cn=$name)(sAMAccountName=$name)))"
        : "(&(objectClass=posixGroup)(cn=$name))";
    $result = @ldap_search($connection, env('NS8_LDAP_BASE_DN'), $filter, ['dn']);
    $entries = $result ? ldap_get_entries($connection, $result) : ['count' => 0];
    ldap_unbind($connection);

    return $entries['count'] > 0 ? $entries[0]['dn'] : null;
}

/** Return true when the NS8 admin rule already targets this directory and group. */
function admin_rule_matches(int $directory_id, int $group_id): bool
{
    global $DB;

    $rule = new RuleRight();
    if (!$rule->getFromDBByCrit(['uuid' => NS8_ADMIN_RULE_UUID])) {
        return false;
    }
    $criteria = [];
    foreach ($DB->request(['FROM' => RuleCriteria::getTable(), 'WHERE' => ['rules_id' => $rule->getID()]]) as $row) {
        $criteria[$row['criteria']] = $row['pattern'];
    }
    ksort($criteria);
    return $criteria === ['LDAP_SERVER' => (string) $directory_id, '_groups_id' => (string) $group_id];
}

function apply_admin_rule(int $directory_id, string $group): void
{
    if ($group === '') {
        remove_admin_rule();
        return;
    }

    // Resolve the group before touching the rule: a bind failure exits and keeps the current rule
    $group_dn = find_group_dn($group);
    if ($group_dn === null) {
        remove_admin_rule();
        logmsg("WARNING: LDAP group $group not found, admin rule removed");
        return;
    }

    $glpi_group = new Group();
    if (!$glpi_group->getFromDBByCrit(['ldap_group_dn' => $group_dn])) {
        $group_id = $glpi_group->add([
            'name'          => $group,
            'entities_id'   => 0,
            'is_recursive'  => 1,
            'ldap_group_dn' => $group_dn,
            'comment'       => 'Managed by NethServer 8',
        ]);
        if (!$group_id) {
            fail("cannot create GLPI group for $group_dn");
        }
    }

    if (admin_rule_matches($directory_id, $glpi_group->getID())) {
        logmsg("Admin rule unchanged for LDAP group $group_dn");
        return;
    }
    remove_admin_rule();

    $profile = new Profile();
    if (!$profile->getFromDBByCrit(['name' => 'Super-Admin'])) {
        fail('Super-Admin profile not found');
    }

    $rule = new RuleRight();
    $rule_id = $rule->add([
        'name'         => 'NS8 administrators group',
        'description'  => "Members of $group get the Super-Admin profile. Managed by NethServer 8.",
        'sub_type'     => RuleRight::class,
        'uuid'         => NS8_ADMIN_RULE_UUID,
        'match'        => 'AND',
        'is_active'    => 1,
        'entities_id'  => 0,
        'is_recursive' => 1,
        'condition'    => 0,
    ]);
    if (!$rule_id) {
        fail('cannot create admin rule');
    }

    $criteria = new RuleCriteria();
    $criteria->add(['rules_id' => $rule_id, 'criteria' => 'LDAP_SERVER', 'condition' => Rule::PATTERN_IS, 'pattern' => $directory_id]);
    $criteria->add(['rules_id' => $rule_id, 'criteria' => '_groups_id', 'condition' => Rule::PATTERN_IS, 'pattern' => $glpi_group->getID()]);

    $action = new RuleAction();
    $action->add(['rules_id' => $rule_id, 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => $profile->getID()]);
    // The default Root rule also gives Self-Service, open the session on Super-Admin
    $action->add(['rules_id' => $rule_id, 'action_type' => 'assign', 'field' => '_profiles_id_default', 'value' => $profile->getID()]);
    $action->add(['rules_id' => $rule_id, 'action_type' => 'assign', 'field' => 'entities_id', 'value' => 0]);
    $action->add(['rules_id' => $rule_id, 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => 1]);

    logmsg("Admin rule created for LDAP group $group_dn");
}

function apply_ldap(): void
{
    $domain = env('NS8_LDAP_DOMAIN');
    if ($domain === '') {
        remove_admin_rule();
        foreach (find_ns8_directories() as $id => $row) {
            deactivate_directory($id, $row);
        }
        return;
    }

    $directory_id = apply_ldap_directory($domain);
    apply_admin_rule($directory_id, env('NS8_ADMIN_GROUP'));
}

function apply_local_accounts(): void
{
    $password = env('NS8_ADMIN_PASSWORD');
    if ($password !== '') {
        $user = new User();
        if (!$user->getFromDBbyName('glpi')) {
            fail('local glpi user not found');
        }
        // GLPI refuses to reuse the current password: an unchanged password is already applied
        if (Auth::checkPassword($password, $user->fields['password'])) {
            logmsg('Password of the glpi user unchanged');
        } elseif (!$user->update(['id' => $user->getID(), 'password' => $password, 'password2' => $password])) {
            fail('cannot set the glpi user password');
        } else {
            logmsg('Password of the glpi user changed');
        }
        // Read by glpi-apply-config, even when a later LDAP step fails
        echo "NS8_ADMIN_PASSWORD_APPLIED\n";
    }

    if (env('NS8_DISABLE_DEMO_USERS') === '1') {
        foreach (['tech', 'normal', 'post-only'] as $name) {
            $user = new User();
            if ($user->getFromDBbyName($name) && $user->fields['is_active']) {
                $user->update(['id' => $user->getID(), 'is_active' => 0]);
                logmsg("Demo user $name disabled");
            }
        }
    }
}

\Session::callAsSystem(function () {
    apply_general_config();
    // Before LDAP: an LDAP failure must not leave glpi/glpi and the demo accounts open
    apply_local_accounts();
    apply_ldap();
});
