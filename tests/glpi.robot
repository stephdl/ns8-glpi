*** Settings ***
Library    SSHLibrary
Resource    api.resource

*** Variables ***
${ADMIN_USER}        admin
${ADMIN_PASSWORD}    Nethesis,1234
# Any resolvable-looking name: the schema demands a dot, nothing resolves it.
${TEST_HOST}         glpi.ns8-ci.test
${GLPI_PASSWORD}     Ns8,Glpi-Test1
${BASE_CONFIG}       "host":"${TEST_HOST}","lets_encrypt":false,"user_domain":"","admin_group":"","ldap_sync":false,"mail_from":"","language":"en_GB"

*** Keywords ***
Login to cluster-admin
    New Page    https://${NODE_ADDR}/cluster-admin/
    Fill Text    text="Username"    ${ADMIN_USER}
    Click    button >> text="Continue"
    Fill Text    text="Password"    ${ADMIN_PASSWORD}
    Click    button >> text="Log in"
    Wait For Elements State    css=#main-content    visible    timeout=10s

HTTP code
    [Arguments]    ${url}    ${options}=${EMPTY}
    ${code} =    Execute Command    curl -sk ${options} -o /dev/null -w "\%{http_code}" -H "Host: ${TEST_HOST}" ${url}
    RETURN    ${code}

GLPI answers
    ${code} =    HTTP code    https://127.0.0.1/    -L
    Should Be Equal    ${code}    200

Log in to GLPI
    [Arguments]    ${user}    ${password}
    # The first GET sets the session cookie that front/login.php requires
    ${page} =    Execute Command
    ...    jar=$(mktemp); curl -sk -c $jar -b $jar --resolve ${TEST_HOST}:443:127.0.0.1 https://${TEST_HOST}/ -o /dev/null; curl -sk -L -c $jar -b $jar --resolve ${TEST_HOST}:443:127.0.0.1 --data-urlencode 'login_name=${user}' --data-urlencode 'login_password=${password}' https://${TEST_HOST}/front/login.php; rm -f $jar
    RETURN    ${page}

*** Test Cases ***
Check if glpi is installed correctly
    ${output}  ${rc} =    Execute Command    add-module ${IMAGE_URL} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check the fresh configuration
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Not Be True    ${config['admin_password_set']}

Check a missing admin password is rejected
    ${output} =    Run task    module/${module_id}/configure-module    {${BASE_CONFIG}}
    ...    decode_json=${FALSE}    rc_expected=2
    Should Contain    ${output}    admin_password_required

Check a weak admin password is rejected
    ${output} =    Run task    module/${module_id}/configure-module    {${BASE_CONFIG},"admin_password":"abcdefgh"}
    ...    decode_json=${FALSE}    rc_expected=2
    Should Contain    ${output}    admin_password_too_weak

Check if glpi can be configured
    Run task    module/${module_id}/configure-module    {${BASE_CONFIG},"admin_password":"${GLPI_PASSWORD}"}
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Be Equal    ${config['host']}    ${TEST_HOST}
    Should Be True    ${config['admin_password_set']}
    Should Be True    ${config['route_configured']}

Check services are running
    ${status} =    Run task    module/${module_id}/get-status    null
    FOR    ${service}    IN    @{status['services']}
        # A oneshot unit started by its timer is inactive between runs
        IF    $service['name'] == 'glpi-ldap-sync'    CONTINUE
        Should Be True    ${service['active']}    ${service['name']} is not active
    END

Check if glpi works as expected
    # The first start installs the database, so give it more time than a warm start
    Wait Until Keyword Succeeds    30 times    10 seconds    GLPI answers
    # HTTP to HTTPS redirection is always on
    ${code} =    HTTP code    http://127.0.0.1/
    Should Match Regexp    ${code}    ^30[178]$

Check if the default glpi password is replaced
    ${output}  ${rc} =    Execute Command    runagent -m ${module_id} podman exec glpi-app php -r 'require "/var/www/glpi/vendor/autoload.php"; (new Glpi\\Kernel\\Kernel())->boot(); $u = new User(); $u->getFromDBbyName("glpi"); echo Auth::checkPassword("glpi", $u->fields["password"]) ? "default" : "changed";'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Be Equal    ${output}    changed

Check the admin can log in
    ${page} =    Log in to GLPI    glpi    ${GLPI_PASSWORD}
    # The logout icon is only in the menu of a logged in user
    Should Contain    ${page}    ti-logout

Check the default password cannot log in
    ${page} =    Log in to GLPI    glpi    glpi
    Should Not Contain    ${page}    ti-logout
    Should Contain    ${page}    Incorrect username or password

Check a reconfigure without password is accepted
    Run task    module/${module_id}/configure-module    {${BASE_CONFIG}}
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Be True    ${config['admin_password_set']}

Take screenshots
    [Tags]    ui
    Import Library    Browser
    New Browser    chromium    headless=True
    New Context    ignoreHTTPSErrors=True
    Login to cluster-admin
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}
    Wait For Elements State    iframe >>> h2 >> text="Status"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/1._Status.png
    Go To    https://${NODE_ADDR}/cluster-admin/#/apps/${module_id}?page=settings
    Wait For Elements State    iframe >>> h2 >> text="Settings"    visible    timeout=10s
    Sleep    5s
    Take Screenshot    filename=${OUTPUT DIR}/browser/screenshot/2._Settings.png
    Close Browser

Check if glpi is removed correctly
    ${rc} =    Execute Command    remove-module --no-preserve ${module_id}
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
