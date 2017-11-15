function Orchestrate-ArmDeployment {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0)]
        [Alias('s', 'sub')]
        [guid]$subId,
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 1)]
        [Alias('r', 'resGrp')]
        [ValidateScript( {$_ -notmatch '\s+' -and $_ -match '[a-zA-Z0-9]+'})]
        [string]$resourceGroupPrefix = ( -join ((97..122) | Get-Random -Count 4 | ForEach-Object {[char]$_})),
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 2)]
        [Alias('l', 'loc')]
        [ValidateSet("Japan East", "East US 2", "West Europe", "Southeast Asia", "South Central US", "UK South", "West Central US", "North Europe", "Canada Central", "Australia Southeast", "Central India")]
        [string]$location = ( "East US 2", "West Europe", "Southeast Asia", "South Central US", "West Central US" | Get-Random ),
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 3)]
        [Alias('d', 'depPrx')]
        [ValidateSet("dev", "prod")]
        [string]$deploymentPrefix = ( "dev", "prod" | Get-Random ),
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 4)]
        [int[]]$steps = @(7),
        [switch]$complete
    )
    $startTime = Get-Date
    "Azure PCI IaaS deployment routine started: {0}." -f $startTime.ToShortTimeString()
    "To rerun steps use:"
    "Invoke-ArmDeployment -s {0} -r {1} -l '{2}' -d {3} -steps x,x,x -p" -f $subId, $resourceGroupPrefix, $location, $deploymentPrefix
    "To remove deployment completely use:"
    "Remove-ArmDeployment {0} {1} {2}" -f $resourceGroupPrefix, $deploymentPrefix, $subId
    $hash = Get-StringHash (($subId, $resourceGroupPrefix, $deploymentPrefix) -join '-')
    $invoker = @{
        resourceGroupPrefix = $resourceGroupPrefix
        subId               = $subId
        location            = $location
        deploymentPrefix    = $deploymentPrefix
    }

    Invoke-ArmDeployment @invoker -steps 2, 1 -prerequisiteRefresh | Out-Null
    Wait-ArmDeployment $hash 30
    if ( $complete.IsPresent ) {
        Invoke-ArmDeployment @invoker -steps 5, 4, 3, 6, 7 -ErrorAction Stop | Out-Null    
    }
    else {
        "Starting AD and sleeping for 5 minutes afterwards."
        Invoke-ArmDeployment @invoker -steps 5 -ErrorAction Stop | Out-Null
        Start-Sleep 300
        "Starting steps: {0}." -f ($steps -join ", ")
        Invoke-ArmDeployment @invoker -steps $steps -ErrorAction Stop | Out-Null
    }
    Wait-ArmDeployment $hash 120
    $resultTime = (Get-Date) - $startTime
    "All went well, giving back control: {0}. ( total time: {1}:{2}. )" -f (Get-Date -f "HH:mm"), $resultTime.Minutes, $resultTime.Seconds
}
function Invoke-ArmDeployment {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 0)]
        [Alias('s', 'sub')]
        [guid]$subId,
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 1)]
        [Alias('r', 'resGrp')]
        [ValidateScript( {$_ -notmatch '\s+' -and $_ -match '[a-zA-Z0-9]+'})]
        [string]$resourceGroupPrefix,
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 2)]
        [Alias('l', 'loc')]
        [ValidateSet("Japan East", "East US 2", "West Europe", "Southeast Asia", "South Central US", "UK South", "West Central US", "North Europe", "Canada Central", "Australia Southeast", "Central India")] # limited to Azure Automation regions
        [string]$location,
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 3)]
        [Alias('d', 'depPrx')]
        [ValidateSet("dev", "prod")]
        [string]$deploymentPrefix = 'dev',
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true,
            Position = 4)]
        [int[]]$steps,
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 5)]
        [string]$crtPath,
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 6)]
        [string]$crtPwd,
        [Parameter(Mandatory = $false,
            ValueFromPipelineByPropertyName = $true,
            Position = 7)]
        [Alias('p')]
        [switch]$prerequisiteRefresh
    )

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): Login to your Azure account if prompted"
    Try {
        Set-AzureRmContext -SubscriptionId $subId | Out-Null
    }
    Catch [System.Management.Automation.PSInvalidOperationException] {
        Add-AzureRmAccount -SubscriptionId $subId | Out-Null
        Set-AzureRmContext -SubscriptionId $subId | Out-Null
    }
    if ($error[0].Exception.Message -in "Run Login-AzureRmAccount to login.", "Provided subscription $subId does not exist") {
        Write-Error "Login routine failed! Verify your subId"
        return
    }

    try {
        # Main routine block
        $deploymentHash = Get-StringHash (($subId, $resourceGroupPrefix, $deploymentPrefix) -join '-')
        $kvContext = New-DeploymentContextKV $deploymentHash
        if ($prerequisiteRefresh) {
            $components | ForEach-Object { New-AzureRmResourceGroup -Name (($resourceGroupPrefix, $deploymentPrefix, $_) -join '-') -Location $location -Force }
            New-DeploymentContext $deploymentHash "$resourceGroupPrefix-$deploymentPrefix-operations" $location
            # if (!$crtPath -and !$crtPwd) {
            #     $crtPwd = Get-StringHash (($subId, $resourceGroupPrefix, $deploymentPrefix, (Get-Date).ToString()) -join '-')
            #     $cert = New-SelfSignedCertificate -CertStoreLocation 'Cert:\LocalMachine\My' -DnsName ( "{0}.{1}.cloudapp.azure.com" -f 'bla-bla', $location )
            #     Export-PfxCertificate -Cert ( 'Cert:\LocalMachine\My\' + $cert.Thumbprint ) -FilePath ( $solutionRoot + '\cert.txt' ) -Password ( ConvertTo-SecureString -Force -AsPlainText $crtPwd )
            #     $fileContentBytes = Get-Content ( $solutionRoot + '\cert.txt' ) -Encoding Byte
            #     [System.Convert]::ToBase64String($fileContentBytes) | Out-File ( $solutionRoot + '\cert.pfx' )
            # }
        }

        $deploymentData = Get-DeploymentData $deploymentHash $kvContext $resourceGroupPrefix $deploymentPrefix $location
        foreach ($step in $steps) {
            $deploymentScriptblock = {
                param(
                    $rgName,
                    $pathTemplate,
                    $pathParameters,
                    $deploymentName,
                    $subId
                )
                $startTime = Get-Date
                Set-AzureRmContext -SubscriptionId $subId | Out-Null
                New-AzureRmResourceGroupDeployment `
                    -ResourceGroupName $rgName `
                    -TemplateFile $pathTemplate `
                    -TemplateParameterFile $pathParameters `
                    -Name $deploymentName `
                    -ErrorAction Stop | Out-Null
    
                if ($rgName -like "*operations") {
                    do {
                        # hack to wait until kv name resolves
                        $noKey = $noPermissions = $null
                        $user = ( Get-AzureRmSubscription | Where-Object id -eq $subId ).ExtendedProperties.Account
                        if ($user -like '*@*') {
                            Set-AzureRmKeyVaultAccessPolicy -VaultName ( $rgName -replace 'operations', 'kv' ) -ResourceGroupName $rgName -PermissionsToKeys 'Create', 'Get' `
                                -UserPrincipalName $user -ErrorAction SilentlyContinue -ErrorVariable noPermissions | Out-Null
                        }
                        else {
                            Set-AzureRmKeyVaultAccessPolicy -VaultName ( $rgName -replace 'operations', 'kv' ) -ResourceGroupName $rgName -PermissionsToKeys 'Create', 'Get' `
                                -ServicePrincipalName $user -ErrorAction SilentlyContinue -ErrorVariable noPermissions | Out-Null
                        }
                        Add-AzureKeyVaultKey -VaultName ( $rgName -replace 'operations', 'kv' ) -Name ContosoMasterKey -Destination HSM -ErrorAction SilentlyContinue `
                            -ErrorVariable noKey | Out-Null
                    } while (($noPermissions -or $noKey) -and ($startTime.AddMinutes(5) -ge (Get-Date)))
                    if ($noPermissions -or $noKey) { throw "KeyVault post provision failed."}
                }
                $resultTime = (Get-Date) - $startTime
                "{0} took: {1}:{2:D2}" -f $deploymentName, $resultTime.Minutes, $resultTime.Seconds
            }.GetNewClosure()

            Start-job -Name "create-$step-$deploymentHash" -ScriptBlock $deploymentScriptblock -ArgumentList (($resourceGroupPrefix, $deploymentPrefix, ($deployments.$step).rg) -join '-'), `
                "$solutionRoot\templates\resources\$(($deployments.$step).name)\azuredeploy.json", $deploymentData[1], (($deploymentData[0], ($deployments.$step).name) -join '-'), $subId
            Write-Host ("Started Job {0}" -f ($deployments.$step).name) -ForegroundColor Yellow
        }

        $token = Get-Token
        $url = "https://management.azure.com/subscriptions/$subId/providers/microsoft.security/policies/default?api-version=2015-06-01-preview"
        $token, $url, $request | Out-Null
        # $result = $result = Invoke-WebRequest -Uri $url -Method Put -Headers @{ Authorization = "Bearer $token"} -Body $request  -ContentType "application/json" -UseBasicParsing
        # if ($result.StatusCode -ne 200) {
        #     Write-Error "Security Center request failed"
        #     $result.content
        # }
    }
    catch {
        Write-Error $_
        if ($env:destroy) {
            Remove-Item $deploymentData[1]
            Remove-ArmDeployment $resourceGroupPrefix $deploymentPrefix $subId
        }
    }
}

function Remove-ArmDeployment ($rg, $dp, $subId) {
    $hash = Get-StringHash(($subId, $rg, $dp) -join '-')
    Get-AzureRmADApplication -DisplayNameStartWith $hash -ErrorAction Stop | Remove-AzureRmADApplication -Force
    $components | ForEach-Object {
        $deploymentScriptblock = {
            param(
                $rgName,
                $subId,
                $component
            )
            Set-AzureRmContext -SubscriptionId $subId
            if ($component -eq 'networking') {
                Start-Sleep -Seconds 210
            }
            Remove-AzureRmResourceGroup -Name $rgName -Force
        }.GetNewClosure()
        
        Start-job -Name "delete-$_-$hash" -ScriptBlock $deploymentScriptblock -ArgumentList (($rg, $dp, $_) -join '-'), $subId, $_
    }
}
