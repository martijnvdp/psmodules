###########################################################
# EKS/AWS/Terraform Functions for powershell 
# import-module eks
# Requirements aws-sso-util and aws.tools.common
###########################################################
#
# See usage:
# get-help *functionname*
#
# requirements:
# Install-Module -Name AWS.Tools.Installer
# Install-AWSToolsModule AWS.Tools.Common
# pip install aws-sso-util
#
############################################################

function connect-aws {
    <#
.Description
Connect-aws connect to aws using sso profile selection menu.
example: connect-aws
#>
    param(
        [string]$awsProfile = ""
    ) 

    if ($awsProfile -ne "" ) {
        aws-sso-util.exe login --profile $awsProfile
        return $awsProfile
    } 

    $awsProfiles = Get-AWSCredential -ListProfile
    $choice = Initialize-Menu -MenuTitle "select profile" -MenuOptions $awsProfiles -MaximumColumnWidth 30
    $awsProfile = $awsProfiles[$choice]
    Start-Process -Wait -FilePath "aws-sso-util.exe" -ArgumentList "login --profile $awsProfile" -NoNewWindow
    return $awsProfile
}

function connect-eks {
    <#
.Description
Connect-eks connect to aws using sso profile selection menu and select an eks cluster in the account.
example: connect-eks
#>
    param(
        [string]$name,
        [string]$awsProfile = ""
    ) 

    if ($awsProfile -eq "" ) {
        $awsProfile = connect-aws
    }
    
    if ($name -eq "" ) {
        $clusters = (aws eks list-clusters --profile $awsProfile | convertfrom-Json).clusters
        $choice = Initialize-Menu -MenuTitle "select cluster" -MenuOptions $clusters -Columns 1 -MaximumColumnWidth 30
        $name = $clusters[$choice]
    }

    aws eks update-kubeconfig --name $name --profile $awsProfile
}

function ConvertTo-Base64 () {
    <#
    .Description
    Encode Text with Base64
    #>
    param(
        # Input string to encode to base64
        [Parameter(ValueFromPipeline = $true)][string]$inputString
    )
    Write-Host ([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($inputString)))
}

function ConvertFrom-Base64 () {
    <#
    .Description
    Decode Text from Base64
    #>
    param(
        # Input string to decode from base64
        [Parameter(ValueFromPipeline = $true)][string]$inputString
    )
    Write-Host ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($inputString)))
}

function Get-AMI {
    <#
    .Description
    List all ami images, sorted on version
    .Example
    Get-AMI -name "amazon-eks-node" -version "1.21" -awsprofile "test"
    #>
    param(
        # Aws profile
        [string]$awsProfile="",
        # Name
        [string]$name="amazon-eks-node",
        # AMI version
        [string]$version="1.21"
    )
    
    if ($awsProfile -eq "" ) {
        $awsProfile = connect-aws
    }
    
    aws ec2 describe-images --owners amazon --filters "Name=name,Values=$name-$version*"   --query 'Images[?CreationDate] | sort_by(@, &CreationDate)[].Name'  --profile $awsProfile        
}

function Get-Pods {
    <#
    .Description
    Get kubernetes pods with extended info
    #>
    param(
        [string]$name = "",
        [string]$namespace = ""
    )
    
    if ($namespace -eq "") {
        $pods = kubectl get pods --all-namespaces -o json | convertfrom-Json
    }
    else {
        $pods = kubectl get pods --namespace $namespace -o json | convertfrom-Json
    }
    
    $podsArr = [System.Collections.ArrayList]::new()
    try {
        foreach ($pod in $pods.items) {
            [void]$podsArr.Add([pscustomobject]@{ 
                    name      = $pod.metadata.name
                    namespace = $pod.metadata.namespace
                    status    = $pod.status.phase
                    # restartCount = $pod.status.containerStatuses[0].restartCount
                    # image        = $pod.status.containerStatuses[0].image
                    node      = $pod.spec.nodeName 
                })
        }
    }
    
    catch {
        Write-Host $_
    }
    
    if ( $name -ne "") {
        return $podsArr | Where-Object name -like "*$name*"
    }

    return $podsArr  #| Format-Table -AutoSize -Property *   
}
        
function Remove-Pods {
    <#
    .Description
    Delete pods matching a search patern from all namespaces
    #>
    param(
        [string]$name = ""
    )
        
    if ($name -eq "") {
        return
    }
    else {
        $pods = get-pods | Where-Object name -like "*$name*"
        $pods | Format-Table -AutoSize
        if ($pods.Count -gt 0) {
            $confirmation = Read-Host "Are you sure you want to delete these pods (y/n)"
            if ($confirmation -eq 'y') {
                $pods |  ForEach-Object { kubectl delete pod $_.name -n $_.namespace }
            }
        }
    }
}

function Get-Nodes {
    <#
    .Description
    Get kubernetes nodes with extended info
    #>
    $nodes = kubectl get nodes -o json | convertfrom-Json
    $nodesArr = [System.Collections.ArrayList]::new()
    try {
        foreach ($node in $nodes.items) {
            [void]$nodesArr.Add([pscustomobject]@{ 
                    name             = $node.metadata.name
                    created          = $node.metadata.creationTimestamp
                    type             = $node.metadata.labels.'beta.kubernetes.io/instance-type'                
                    os               = $node.metadata.labels.'beta.kubernetes.io/os'
                    nodegroup        = $node.metadata.labels.'eks.amazonaws.com/nodegroup'
                    ami              = $node.metadata.labels.'eks.amazonaws.com/nodegroup-image'
                    launchTemplateId = $node.metadata.labels.'eks.amazonaws.com/sourceLaunchTemplateId'
                    hostname         = $node.metadata.labels.'kubernetes.io/hostname'
                })
        }
    }
        
    catch {
        Write-Host $_
    }
        
    return $nodesArr  #| Format-Table -AutoSize -Property *           
}

function Disable-Nodes {
    <#
    .Description
    Drain and cordon kubernetes nodes matchin a name or nodegroup
    #>
    param(
        [string]$name = "",    
        [string]$nodegroup = ""
    )
        
    if ($nodegroup -ne "") {  
        $nodes = get-nodes | Where-Object nodegroup -like "*$nodegroup*"
    } 

    if ($name -ne "") {  
        $nodes = get-nodes | Where-Object name -like "*$name*"
    }

    if ($nodes.Count -gt 0 ) {
        $nodes | Format-Table -AutoSize
        $confirmation = Read-Host "Are you sure you want to cordon and drain these nodes (y/n)"
        if ($confirmation -eq 'y') {
            $nodes |  ForEach-Object { kubectl drain $_.name --ignore-daemonsets --delete-emptydir-data }
        }
    }
}

Function Initialize-Menu () {
    <#
    .Description
    Generate a interactive menu
    #>
    Param(
        [Parameter(Mandatory = $True)][String]$MenuTitle,
        [Parameter(Mandatory = $True)][array]$MenuOptions,
        [Parameter(Mandatory = $False)][String]$Columns = "Auto",
        [Parameter(Mandatory = $False)][int]$MaximumColumnWidth = 20,
        [Parameter(Mandatory = $False)][bool]$ShowCurrentSelection = $False
    )
    $MaxValue = $MenuOptions.count - 1
    $Selection = 0
    $EnterPressed = $False

    If ($Columns -eq "Auto") {
        $WindowWidth = (Get-Host).UI.RawUI.MaxWindowSize.Width
        $Columns = [Math]::Floor($WindowWidth / ($MaximumColumnWidth + 2))
    }

    If ([int]$Columns -gt $MenuOptions.count) {
        $Columns = $MenuOptions.count
    }
    $RowQty = ([Math]::Ceiling(($MaxValue + 1) / $Columns))       
    $MenuListing = @()

    For ($i = 0; $i -lt $Columns; $i++) {    
        $ScratchArray = @()

        For ($j = ($RowQty * $i); $j -lt ($RowQty * ($i + 1)); $j++) {
            $ScratchArray += $MenuOptions[$j]
        }
        $ColWidth = ($ScratchArray | Measure-Object -Maximum -Property length).Maximum
        
        If ($ColWidth -gt $MaximumColumnWidth) {
            $ColWidth = $MaximumColumnWidth - 1
        }

        For ($j = 0; $j -lt $ScratchArray.count; $j++) {    
            If (($ScratchArray[$j]).length -gt $($MaximumColumnWidth - 2)) {
                $ScratchArray[$j] = $($ScratchArray[$j]).Substring(0, $($MaximumColumnWidth - 4))
                $ScratchArray[$j] = "$($ScratchArray[$j])..."
            }
            Else {
                For ($k = $ScratchArray[$j].length; $k -lt $ColWidth; $k++) {
                    $ScratchArray[$j] = "$($ScratchArray[$j]) "
                }
            }
            $ScratchArray[$j] = " $($ScratchArray[$j]) "
        }
        $MenuListing += $ScratchArray
    }
    Clear-Host

    While ($EnterPressed -eq $False) {   
        Write-Host "$MenuTitle"
        If ($ShowCurrentSelection -eq $True) {
            $Host.UI.RawUI.WindowTitle = "CURRENT SELECTION: $($MenuOptions[$Selection])"
        }

        For ($i = 0; $i -lt $RowQty; $i++) {
            For ($j = 0; $j -le (($Columns - 1) * $RowQty); $j += $RowQty) {
                If ($j -eq (($Columns - 1) * $RowQty)) {
                    If (($i + $j) -eq $Selection) {
                        Write-Host -BackgroundColor cyan -ForegroundColor Black "$($MenuListing[$i+$j])"
                    }
                    Else {
                        Write-Host "$($MenuListing[$i+$j])"
                    }
                }
                Else {
                    If (($i + $j) -eq $Selection) {
                        Write-Host -BackgroundColor Cyan -ForegroundColor Black "$($MenuListing[$i+$j])" -NoNewline
                    }
                    Else {
                        Write-Host "$($MenuListing[$i+$j])" -NoNewline
                    }
                }
                
            }
        }
        $KeyInput = $host.ui.rawui.readkey("NoEcho,IncludeKeyDown").virtualkeycode

        Switch ($KeyInput) {
            13 {
                $EnterPressed = $True
                Return $Selection
                Clear-Host
                break
            }
            37 {
                #Left
                If ($Selection -ge $RowQty) {
                    $Selection -= $RowQty
                }
                Else {
                    $Selection += ($Columns - 1) * $RowQty
                }
                Clear-Host
                break
            }
            38 {
                #Up
                If ((($Selection + $RowQty) % $RowQty) -eq 0) {
                    $Selection += $RowQty - 1
                }
                Else {
                    $Selection -= 1
                }
                Clear-Host
                break
            }
            39 {
                #Right
                If ([Math]::Ceiling($Selection / $RowQty) -eq $Columns -or ($Selection / $RowQty) + 1 -eq $Columns) {
                    $Selection -= ($Columns - 1) * $RowQty
                }
                Else {
                    $Selection += $RowQty
                }
                Clear-Host
                break
            }
            40 {
                #Down
                If ((($Selection + 1) % $RowQty) -eq 0 -or $Selection -eq $MaxValue) {
                    $Selection = ([Math]::Floor(($Selection) / $RowQty)) * $RowQty
                    
                }
                Else {
                    $Selection += 1
                }
                Clear-Host
                break
            }
            Default {
                Clear-Host
            }
        }
    }
}

function Set-taint () {
    <#
.Description
Set-taint terraform taint on all resources matching the resource parameter.
example: set-taint argocd
#>
    param(
        # Input string to match terraform resources in the state
        [Parameter(ValueFromPipeline = $true)][string]$resource
    )
    try {
        $resources = terraform state list | findstr $resource
    }
    catch {
        Write-Host $_
    }
    if ($resources -ne "" -and $resources -notlike "*No state*") {
        $resources |  ForEach-Object { write-host "- $_" }
        $confirmation = Read-Host "Are you sure you want to taint these resources (y/n)"
        if ($confirmation -eq 'y') {
            $resources |  ForEach-Object { $_.replace("`"", "\`"") } |  ForEach-Object { terraform taint "$_" }
        }
    }
}