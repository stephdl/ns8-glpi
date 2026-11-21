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
${SCENARIO}          install
# Boots the GLPI kernel in glpi-app, so the tests use its own classes. Single quotes stay out of the PHP code.
${GLPI_PHP}          podman exec glpi-app php -d display_errors=stderr -r 'require "/var/www/glpi/vendor/autoload.php"; (new Glpi\\Kernel\\Kernel())->boot();
# The rows the update must keep, written as the glpi super-admin through GLPI classes like the UI does
${FILL_DATA}         $u = new User(); $u->getFromDBbyName("glpi"); $_SESSION["glpiID"] = $u->getID(); $_SESSION["glpiname"] = "glpi"; $_SESSION["glpiactive_entity"] = 0; $_SESSION["glpiactiveentities"] = [0]; $_SESSION["glpiactiveentities_string"] = chr(39)."0".chr(39); $_SESSION["glpiactiveprofile"] = ["id" => 4, "interface" => "central"]; $pc = new Computer(); $pcid = $pc->add(["name" => "ci-update-pc", "serial" => "CI-SERIAL-42", "entities_id" => 0]); $t = new Ticket(); $tid = $t->add(["name" => "ci-update-ticket", "content" => "Ticket saved before the update", "entities_id" => 0, "_skip_auto_assign" => true, "items_id" => ["Computer" => [$pcid]]]); $f = new ITILFollowup(); $fid = $f->add(["itemtype" => "Ticket", "items_id" => $tid, "content" => "Followup saved before the update"]); if (!$pcid || !$tid || !$fid) { fwrite(STDERR, "add failed"); exit(1); } echo json_encode(["computer" => $pcid, "ticket" => $tid]);

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

Enable the stephdl forge
    # The module is published there, not in the default NS8 repositories
    ${rc} =    Execute Command
    ...    api-cli run add-repository --data '{"name":"stephdl","url":"https://forge.de-labrusse.fr/ns8/updates/","status":true}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0

GLPI php
    [Arguments]    ${code}
    ${output}  ${rc} =    Execute Command    runagent -m ${module_id} ${GLPI_PHP} ${code}'
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    RETURN    ${output}

Saved data
    [Arguments]    ${pcid}    ${tid}
    ${output} =    GLPI php    $pc = new Computer(); $pc->getFromDB(${pcid}); $t = new Ticket(); $t->getFromDB(${tid}); echo json_encode([$pc->fields["name"], $pc->fields["serial"], $t->fields["name"], strip_tags(html_entity_decode($t->fields["content"])), countElementsInTable("glpi_items_tickets", ["tickets_id" => ${tid}, "itemtype" => "Computer", "items_id" => ${pcid}]), countElementsInTable("glpi_itilfollowups", ["itemtype" => "Ticket", "items_id" => ${tid}])]);
    RETURN    ${output}

Log in to GLPI
    [Arguments]    ${user}    ${password}
    # The first GET sets the session cookie that front/login.php requires
    ${page} =    Execute Command
    ...    jar=$(mktemp); curl -sk -c $jar -b $jar --resolve ${TEST_HOST}:443:127.0.0.1 https://${TEST_HOST}/ -o /dev/null; curl -sk -L -c $jar -b $jar --resolve ${TEST_HOST}:443:127.0.0.1 --data-urlencode 'login_name=${user}' --data-urlencode 'login_password=${password}' https://${TEST_HOST}/front/login.php; rm -f $jar
    RETURN    ${page}

*** Test Cases ***
Check if glpi is installed correctly
    # The update scenario starts from the release published in the stephdl forge,
    # and moves it to the image under test after the first checks
    IF    '${SCENARIO}' == 'update'
        Enable the stephdl forge
        ${image} =    Set Variable    glpi
    ELSE
        ${image} =    Set Variable    ${IMAGE_URL}
    END
    ${output}  ${rc} =    Execute Command    add-module ${image} 1
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    &{output} =    Evaluate    ${output}
    Set Suite Variable    ${module_id}    ${output.module_id}

Check the fresh configuration
    # A fresh instance only: the install scenario covers it
    Skip If    '${SCENARIO}' == 'update'    the update scenario starts from a configured release
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Not Be True    ${config['admin_password_set']}

Check a missing admin password is rejected
    # A fresh instance only: the install scenario covers it
    Skip If    '${SCENARIO}' == 'update'    the update scenario starts from a configured release
    ${output} =    Run task    module/${module_id}/configure-module    {${BASE_CONFIG}}
    ...    decode_json=${FALSE}    rc_expected=2
    Should Contain    ${output}    admin_password_required

Check if glpi can be configured
    Run task    module/${module_id}/configure-module    {${BASE_CONFIG},"admin_password":"${GLPI_PASSWORD}"}
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Should Be Equal    ${config['host']}    ${TEST_HOST}
    Should Be True    ${config['admin_password_set']}
    Should Be True    ${config['route_configured']}

Check if glpi works as expected
    # The first start installs the database, so give it more time than a warm start
    Wait Until Keyword Succeeds    30 times    10 seconds    GLPI answers
    # HTTP to HTTPS redirection is always on
    ${code} =    HTTP code    http://127.0.0.1/
    Should Match Regexp    ${code}    ^30[178]$

Fill glpi with data before the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${output} =    GLPI php    ${FILL_DATA}
    &{ids} =    Evaluate    json.loads($output)    modules=json
    Set Suite Variable    ${pcid}    ${ids.computer}
    Set Suite Variable    ${tid}    ${ids.ticket}
    ${data} =    Saved data    ${pcid}    ${tid}
    Set Suite Variable    ${data_before}    ${data}
    ${rc} =    Execute Command    runagent -m ${module_id} podman exec glpi-app sh -c 'echo saved-before-update > /var/glpi/files/ci-update.txt'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    Set Suite Variable    ${config_before}    ${config}
    ${image} =    Execute Command    runagent -m ${module_id} printenv GLPI_IMAGE
    Set Suite Variable    ${glpi_image_before}    ${image}

Update glpi to the image under test
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${rc} =    Execute Command
    ...    api-cli run update-module --data '{"force":true,"module_url":"${IMAGE_URL}","instances":["${module_id}"]}'
    ...    return_rc=True  return_stdout=False
    Should Be Equal As Integers    ${rc}  0
    ${image} =    Execute Command    runagent -m ${module_id} printenv IMAGE_URL
    Should Be Equal    ${image}    ${IMAGE_URL}
    # A newer release in the forge than the image under test would downgrade the database schema
    ${glpi_image} =    Execute Command    runagent -m ${module_id} printenv GLPI_IMAGE
    ${newer} =    Evaluate    [int(x) for x in $glpi_image.rsplit(":", 1)[1].split(".")] >= [int(x) for x in $glpi_image_before.rsplit(":", 1)[1].split(".")]
    Should Be True    ${newer}    the stable release runs ${glpi_image_before}, newer than ${glpi_image}
    # The entrypoint migrates the database schema before Apache answers
    Wait Until Keyword Succeeds    30 times    10 seconds    GLPI answers

Check the settings survive the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${config} =    Run task    module/${module_id}/get-configuration    {}
    # Only the keys the stable release had: a new release may add settings
    ${changed} =    Evaluate    [k for k, v in $config_before.items() if $config.get(k) != v]
    Should Be Empty    ${changed}

Check the data survives the update
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${data} =    Saved data    ${pcid}    ${tid}
    Should Be Equal    ${data}    ${data_before}
    Should Be Equal    ${data}    ["ci-update-pc","CI-SERIAL-42","ci-update-ticket","Ticket saved before the update",1,1]
    ${output}  ${rc} =    Execute Command    runagent -m ${module_id} podman exec glpi-app cat /var/glpi/files/ci-update.txt
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Be Equal    ${output}    saved-before-update

Check the database schema matches the new release
    Skip If    '${SCENARIO}' != 'update'    scenario is ${SCENARIO}, nothing to update
    ${output}  ${rc} =    Execute Command    runagent -m ${module_id} podman exec glpi-app php /var/www/glpi/bin/console db:is_up_to_date
    ...    return_rc=True
    Should Be Equal As Integers    ${rc}  0
    Should Contain    ${output}    The database is up to date

Check a weak admin password is rejected
    ${output} =    Run task    module/${module_id}/configure-module    {${BASE_CONFIG},"admin_password":"abcdefgh"}
    ...    decode_json=${FALSE}    rc_expected=2
    Should Contain    ${output}    admin_password_too_weak

Check services are running
    ${status} =    Run task    module/${module_id}/get-status    null
    FOR    ${service}    IN    @{status['services']}
        # A oneshot unit started by its timer is inactive between runs
        IF    $service['name'] == 'glpi-ldap-sync'    CONTINUE
        Should Be True    ${service['active']}    ${service['name']} is not active
    END

Check if the default glpi password is replaced
    ${output} =    GLPI php    $u = new User(); $u->getFromDBbyName("glpi"); echo Auth::checkPassword("glpi", $u->fields["password"]) ? "default" : "changed";
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
