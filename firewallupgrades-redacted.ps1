
param ([string]$schedulestart=$null,[string]$scheduleend=$null)
$scriptpath = split-path ($MyInvocation.MyCommand.path) -parent
$passfile = "$scriptpath\passfile.txt"
$keyfile = "$scriptpath\AES.key"
$key = get-content $keyfile
$password = (get-content $passfile | ConvertTo-SecureString -Key $key)
$creds = New-Object System.Management.Automation.PSCredential ("username_redacted", $password)
$pkg = $null


#Connect-FMServer and Invoke-FMCommand functions by Justin Grote
#https://gist.github.com/JustinGrote/a1ec4a20d3f3900d5b9f57a96bc41a2e
#Start-FMSession not needed in this script, but left in for posterity :-) Use to create change management sessions in workflow mode

function Connect-FMServer {
    param (
        #The hostname of your Fortimanager
        [Parameter(Mandatory)][Alias("Server","Hostname")][String]$ComputerName,
        #Your username and password. Must be enabled for remote API access
        [Parameter(Mandatory)][PSCredential]$Credential,
        #Disable SSL Checks. THe name on the certificate must still match what you specified for -ComputerName
        [Switch]$Force
    )

    $requestTemplate = @{
        id = 1
        method = "exec"
        session = $null
        verbose = 1
        params = @(@{
            data = @{
                user = $credential.GetNetworkCredential().username
                passwd = $credential.GetNetworkCredential().Password
            }
            url = 'sys/login/user'
        })
    }
    $IRMParams = @{
        URI = "https://$computername/jsonrpc"
        Method = "POST"
        Body = $requestTemplate | ConvertTo-Json -depth 10
    }
    #$requesttemplate | ConvertTo-Json -Depth 10
    if ($Force) {[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $commandResult = Invoke-Restmethod @IRMParams -erroraction stop
    if ($commandresult.result.status.code -eq 0) {
        write-host -fore Green "Successfully connected to $computerName"
        $SCRIPT:FMSessionID = $commandresult.session
        $SCRIPT:FMComputerName = $ComputerName
    } else {
        throw "Error while logging in:" + $commandresult.result.status.message
    }
}
function Invoke-FMCommand {
    param (
        #The command (url) you wish to run
        $command = "/dvmdb/device",
        #Which Method to use. See the fortimanager JSON API reference for details
        [ValidateSet("Get","Set","Add","Update","Delete","Clone","Exec")]$method = "get",
        #Any special Parameters you need to define, such as filter or sort
        [HashTable]$params = @{},
        [bool]$verbose = $true

    )
    if (-not $FMSessionID) {throw "You need to log in with Connect-FMServer first"}
    $params.url = $command

    $requestTemplate = @{
        id = 1
        verbose=[int]$verbose
        method = $method
        session = $FMSessionID
        params = @($params)
    }
    $IRMParams = @{
        URI = "https://$($SCRIPT:FMComputerName)/jsonrpc"
        Method = "POST"
        Body = $requestTemplate | ConvertTo-Json -depth 10
    }
    #$requestTemplate | ConvertTo-Json -Depth 10 | write-host
    if ($Force) {[Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $commandResult = Invoke-Restmethod @IRMParams -erroraction stop
    if ($commandresult.result.status.code -eq 0) {
        $commandResult.result.data
    } else {
        throw "Error while executing command:" + $commandresult.result.status.message
    }
}
function start-fmsession {
    param (
        [parameter(mandatory)][string]$name=$null,
        [parameter(mandatory)][string]$desc=$null
    )
    #get current workflow sessions for client ADOM
    $sessions = invoke-fmcommand "dvmdb/adom/$client/workflow" -method get -params @{'fields'=@("sessionid")}
    #get 'state' of most recent session
    <# 1 - in progress
    2 - submitted, not approved
    3 - approved
    4 - rejected
    5 - repaired #>
    $lastsession = ($sessions.sessionid | measure -Maximum).Maximum
    $state = (invoke-fmcommand "dvmdb/adom/$client/workflow/$lastsession" -method get -params @{'fields'=@("state")}).state
    #if last session is not in progress, create new session
    if ($state -ne 1){
        #lock adom
        Invoke-FMCommand -command "/dvmdb/adom/$Client/workspace/lock" -method exec
        #create new session
        $SCRIPT:CurrentSessionID = (Invoke-FMCommand "/dvmdb/adom/$client/workflow/start" -method exec -params @{'workflow'=@{"name"="$name";'desc'="$desc"}}).sessionid    } else {
        Invoke-FMCommand -command "/dvmdb/adom/$Client/workspace/unlock" -method exec
        Invoke-FMCommand -command 'sys/logout' -method exec
        throw "workflow ID $lastsession currently in progress. Exiting"
        exit
    }
}

######################################################################################################################
###########################################################
# TimeFramePicker.ps1
#
# MeneerB 29/07/2015
###########################################################
Add-Type -AssemblyName System.Windows.Forms
$cancel = $false
# Main Form
$mainForm = New-Object System.Windows.Forms.Form
$font = New-Object System.Drawing.Font("Consolas", 13)
$mainForm.Text = $formTitle
$mainForm.Font = $font
#$mainForm.ForeColor = "White"
#$mainForm.BackColor = "DarkOliveGreen"
$mainForm.Width = 300
$mainForm.Height = 200


# DatePicker Label
$datePickerLabel = New-Object System.Windows.Forms.Label
$datePickerLabel.Text = "date"
$datePickerLabel.Location = "15, 10"
$datePickerLabel.Height = 22
$datePickerLabel.Width = 90
$mainForm.Controls.Add($datePickerLabel)

# MinTimePicker Label
$minTimePickerLabel = New-Object System.Windows.Forms.Label
$minTimePickerLabel.Text = "min-time"
$minTimePickerLabel.Location = "15, 45"
$minTimePickerLabel.Height = 22
$minTimePickerLabel.Width = 90
$mainForm.Controls.Add($minTimePickerLabel)

<# # MaxTimePicker Label
$maxTimePickerLabel = New-Object System.Windows.Forms.Label
$maxTimePickerLabel.Text = "max-time"
$maxTimePickerLabel.Location = "15, 80"
$maxTimePickerLabel.Height = 22
$maxTimePickerLabel.Width = 90
$mainForm.Controls.Add($maxTimePickerLabel) #>

# DatePicker
$datePicker = New-Object System.Windows.Forms.DateTimePicker
$datePicker.Location = "110, 7"
$datePicker.Width = "150"
$datePicker.Format = [windows.forms.datetimepickerFormat]::custom
$datePicker.CustomFormat = "MM/dd/yyyy"
$mainForm.Controls.Add($datePicker)

# MinTimePicker
$minTimePicker = New-Object System.Windows.Forms.DateTimePicker
$minTimePicker.Location = "110, 42"
$minTimePicker.Width = "150"
$minTimePicker.Format = [windows.forms.datetimepickerFormat]::custom
$minTimePicker.CustomFormat = "HH:mm"
$minTimePicker.ShowUpDown = $TRUE
$mainForm.Controls.Add($minTimePicker)

<# # MaxTimePicker
$maxTimePicker = New-Object System.Windows.Forms.DateTimePicker
$maxTimePicker.Location = "110, 77"
$maxTimePicker.Width = "150"
$maxTimePicker.Format = [windows.forms.datetimepickerFormat]::custom
$maxTimePicker.CustomFormat = "HH:mm:ss"
$maxTimePicker.ShowUpDown = $TRUE
$mainForm.Controls.Add($maxTimePicker) #>

# OD Button
$okButton = New-Object System.Windows.Forms.Button
$okButton.Location = "15, 130"
$okButton.ForeColor = "Black"
$okButton.BackColor = "White"
$okButton.Text = "OK"
$okButton.add_Click({$mainForm.close();$script:cancel=$FALSE})
$mainForm.Controls.Add($okButton)

# cancel Button
$CancelButton = New-Object System.Windows.Forms.Button
$CancelButton.Location = "150, 130"
$CancelButton.ForeColor = "Black"
$CancelButton.BackColor = "White"
$CancelButton.Text = "Cancel"
$CancelButton.add_Click({
    $mainForm.close()
    $script:cancel = $TRUE
})
$mainForm.Controls.Add($CancelButton)
$formTitle = "Select Starting Time"
[void] $mainForm.ShowDialog()
if ($cancel -eq $false){
$datetime = ($datepicker.text.tostring() + ' ' + $minTimePicker.text.tostring())
$schedulestart = [datetime]::parseexact(($datepicker.text.tostring() + ' ' + $minTimePicker.text.tostring()),'MM/dd/yyyy HH:mm',$null).tostring('yyyy-MM-dd HH:mm')
} else {
$schedulestart = $null
}

$formTitle = "Select Ending Time"
[void] $mainForm.ShowDialog()
if ($cancel -eq $false) {
$scheduleend = [datetime]::parseexact(($datepicker.text.tostring() + ' ' + $minTimePicker.text.tostring()),'MM/dd/yyyy HH:mm',$null).tostring('yyyy-MM-dd HH:mm')
} else {
$scheduleend = $null
}
if (((($scheduleend -ne $null) -and ($schedulestart -ne $null)) -and ($scheduleend -gt $schedulestart)) -eq $false){
$errorForm = New-Object System.Windows.Forms.Form
$font = New-Object System.Drawing.Font("Consolas", 13)
$errorForm.Text = "Error - end time not after start time. Exiting"
$errorForm.Font = $font
#$mainForm.ForeColor = "White"
#$mainForm.BackColor = "DarkOliveGreen"
$errorForm.Width = 300
$errorForm.Height = 200


[void]$errorform.showDialog()
exit
}

############################################################################################################################################

#Log into FortiManager
Connect-FMServer -ComputerName '<redacted>' -Credential $creds

#Get full list of available firmware and store in memory
$firmwaretable = (Invoke-FMCommand -command 'um/image/version/list').version_list
#sample call for pulling firmware version from the table: 
#($firmwaretable.version_list | where -Property platform -eq 'FortiGate-40F').versions

#get list of all ADOMs
#$adomlist = (Invoke-FMCommand -command "dvmdb/adom" -method get -params @{'fields'=@(@('name'))}).name


#primary ADOM loop
foreach ($Client in $adomlist) {
    #lock the ADOM
    Invoke-FMCommand -command "dvmdb/adom/$client/workspace/lock" -method exec

    #get list of all device models assigned to Client
    $models = @()
    $devices = @()
    $wtpprofilelist = @()
    $enforced_version = @()
    $fwmprof_setting = @{}
    $scope_member = @()
    $templatedata  = @{}
    $clientdevices = $null
    $allGateGroup = (Invoke-FMCommand -command "dvmdb/adom/$client/group" -method get) | where -Property name -eq 'All_FortiGate'
    $scope_member += @{'isGrp'=$true;'name'='Managed FortiGate';'oid'=$allGateGroup.oid}
    $clientdevices = invoke-fmcommand -command "/dvmdb/adom/$client/device" -method get
    if ($clientdevices -eq $null) {continue}
    foreach ($device in $clientdevices) {
        $devicehash = @{}
        $model = $device.platform_str
        $switchmodels = @()
        $wtp = $null
        if ($model -match "^(FortiWifi|FortiGate).*$") { 
            if ($models -notcontains $model){
                $models += @{'platform'=$model;'product'='fgt'}
            }
            $rootoid = ($device.vdom | where name -eq 'root').oid
            $devicehash = @{'name'=$device.name;'oid'=[string]$device.oid;'vdom_oid'=[int]$rootoid;'vdom'='root'}
            $scope_member += $devicehash
        }
        #get all FortiSwitch Models - we don't need the whole device, just the model to add to the upgrade list
        $switches = invoke-fmcommand -command "/pm/config/adom/$client/obj/fsp/managed-switch/" -method get -params @{'scope member'=@(@{'name'=$device.name;'vdom'='root'})}
        foreach ($switchmodel in $switches.platform) {
            if ($models -notcontains $switchmodel) {
                $models += @{'platform'=$switchmodel;'product'='fsw'}
            }
        }
        #get all FortiAP Models - we don't need the whole device, just the model to add to the upgrade list
        #poll each device for wtp-profile
        if ($model -match "^(FortiWifi|FortiGate).*$") {
            $devicename = $device.name
            $wtp = (Invoke-FMCommand -command "pm/config/device/$devicename/vdom/root/wireless-controller/wtp").'wtp-profile'
            if ($wtp -ne $null){
                foreach ($profile in $wtp){
                    if ($wtpprofilelist -notcontains $profile){$wtpprofilelist += $wtp}
                }
                foreach ($profilename in $wtpprofilelist) {
                    $APmodel = (Invoke-FMCommand -command "pm/config/device/$devicename/vdom/root/wireless-controller/wtp-profile/$profilename").platform.type
                    $APmodel = "FortiAP-"+$APmodel
                    if ($models -notcontains $APmodel){
                        $models += @{'platform'=$APmodel;'product'='fap'}
                    }
                }
            }
        }
    }
    #Grab newest version for everything in $models
    foreach ($model in $models){
        $versions = ($firmwaretable | where platform -eq ($model.platform)).versions
        $sortVersionList = @()
        foreach ($version in $versions) {
            #if the version does not have 2 digits in the last place, split on dots and add another 0
            if ($version.version -notmatch "^\d.\d.\d\d.*$") {
                $sortVersion = ($version.version.split('.')[0]+'.'+$version.version.split('.')[1]+'.0'+$version.version.split('.')[2])
            #otherwise, store as-is
            } else {
                $sortVersion = $version.version
            }
            #add the sortable values as a property to sort on
            $version | Add-Member -notepropertyname SortVersion -notepropertyvalue $sortVersion
            $sortVersionList += $version
        }
        $latestversion = ($sortVersionList | where -property version -like "7.0.*" | sort -Property sortversion -Descending)[0].version
        #pad $latestversion to 5 digits after '-b' - add leading zeroes to fill space
        $latestversion = $latestversion.split('-b')[0]+'-b'+$latestversion.Split('-b')[2].padleft(5,'0')
        $versionhash = @{
            #'flags'='0';
            'platform'=$model.platform;
            'product'=$model.product;
            'upgrade-path'='auto';
            'version'=$latestversion
        }
        $enforced_version += $versionhash
    }
    $fwmprof_setting = @{
        'description'=$null;
        'enforced version'=$enforced_version;
        'image-source'='fmg';
        'schedule-day'=0;
        'schedule-end-time'=$scheduleend;
        'schedule-start-time'=$schedulestart;
        'schedule-type'='once';

    }

    $templatename = "$client-FirmwareTemplate"
    $templatedata = @{
        'data'=@{
            'type'='fwmprof';
            'scope member'=$scope_member;
            'name'=$templatename;
            'fwmprof setting'=$fwmprof_setting;
        }
    }
    $templatelist = (Invoke-FMCommand -command "pm/fwmprof/adom/$client/" -method get)
    if ($templatelist -eq $null){
        Invoke-FMCommand -command "pm/fwmprof/adom/$client" -method add -params $templatedata -verbose $false
    } else {
        Invoke-FMCommand -command "pm/fwmprof/adom/$client/$templatename" -method update -params $templatedata -verbose $false
    }
    #unlock the ADOM
    Invoke-FMCommand -command "/dvmdb/adom/$client/workspace/commit" -method exec
    Invoke-FMCommand -command "dvmdb/adom/$client/workspace/unlock" -method exec
}



Invoke-FMCommand -command 'sys/logout' -method exec