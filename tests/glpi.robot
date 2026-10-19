*** Settings ***
Library    SSHLibrary

*** Variables ***
# Any resolvable-looking name: the schema demands a dot, nothing resolves it.
${TEST_HOST}    glpi.ns8-ci.test
${ADMIN_PASSWORD}    Ns8,Glpi-Test1

*** Test Cases ***
Check if glpi is installed correctly
    ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check if glpi refuses a first configuration without admin password
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${TEST_HOST}","lets_encrypt":false,"user_domain":"","admin_group":"","ldap_sync":false,"mail_from":"","language":"en_GB"}'
    ...    return_rc=True  return_stdout=False
    Should Not Be Equal As Integers    ${rc}  0

Check if glpi can be configured
    ${rc} =    Execute Command
    ...    api-cli run module/${module_id}/configure-module --data '{"host":"${TEST_HOST}","lets_encrypt":false,"user_domain":"","admin_group":"","ldap_sync":false,"mail_from":"","language":"en_GB","admin_password":"${ADMIN_PASSWORD}"}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

Check if glpi login page is served
    ${output}  ${rc} =    Execute Command    curl -sk -o /dev/null -w '%{http_code}' --resolve ${TEST_HOST}:443:127.0.0.1 https://${TEST_HOST}/
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Be Equal    ${output}    200

Check if the default glpi password is replaced
    ${output}  ${rc} =    Execute Command    runagent -m ${module_id} podman exec glpi-app php -r 'require "/var/www/glpi/vendor/autoload.php"; (new Glpi\Kernel\Kernel())->boot(); $u = new User(); $u->getFromDBbyName("glpi"); echo Auth::checkPassword("glpi", $u->fields["password"]) ? "default" : "changed";'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Be Equal    ${output}    changed

Check if glpi configuration reads back
    ${output}  ${rc} =    Execute Command    api-cli run module/${module_id}/get-configuration --data '{}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    ${config} =    Evaluate    json.loads('''${output}''')    modules=json
    Should Be Equal    ${config}[host]    ${TEST_HOST}
    Should Be True    ${config}[admin_password_set]

Check if glpi is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
