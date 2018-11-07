<# This script will create a single Azure AD Application in your tenant, apply the appropriate permissions to it and execute a test call against a specified endpoint. Modify the values at the top of this script as required. #>

#https://gcits.com/knowledge-base/automate-api-calls-microsoft-graph-using-powershell-azure-active-directory-applications/

param(
 [Parameter(Mandatory=$True)]
 [string]
 $applicationName,

 [Parameter(Mandatory=$True)]
 [string]
 $appIdUri,

 [bool]
 $createNativeApp = $true,

 [string]
 $nativeAppReplyUri
)

# Modify the homePage, appIdURI and logoutURI values to whatever valid URI you like. They don't need to be actual addresses.
$homePage = $appIdURI
$logoutURI = $appIdURI

# Enter the required permissions below, separated by spaces eg: "Directory.Read.All Reports.Read.All Group.ReadWrite.All Directory.ReadWrite.All"
#$ApplicationPermissions = "Reports.Read.All"
$ApplicationPermissions = $null
  
# Set DelegatePermissions to $null if you only require application permissions. 
$DelegatedPermissions = "user_impersonation"
# Otherwise, include the required delegated permissions below.
# $DelegatedPermissions = "Directory.Read.All Group.ReadWrite.All"
  
  
Function AddResourcePermission($requiredAccess, $exposedPermissions, $requiredAccesses, $permissionType) {
    foreach ($permission in $requiredAccesses.Trim().Split(" ")) {
        $reqPermission = $null
        $reqPermission = $exposedPermissions | Where-Object {$_.Value -contains $permission}
        Write-Verbose "Collected information for $($reqPermission.Value) of type $permissionType"
        $resourceAccess = New-Object Microsoft.Open.AzureAD.Model.ResourceAccess
        $resourceAccess.Type = $permissionType
        $resourceAccess.Id = $reqPermission.Id    
        $requiredAccess.ResourceAccess.Add($resourceAccess)
    }
}
  
Function GetRequiredPermissions($requiredDelegatedPermissions, $requiredApplicationPermissions, $reqsp) {
    $sp = $reqsp
    $appid = $sp.AppId
    $requiredAccess = New-Object Microsoft.Open.AzureAD.Model.RequiredResourceAccess
    $requiredAccess.ResourceAppId = $appid
    $requiredAccess.ResourceAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.ResourceAccess]
    if ($requiredDelegatedPermissions) {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.Oauth2Permissions -requiredAccesses $requiredDelegatedPermissions -permissionType "Scope"
    } 
    if ($requiredApplicationPermissions) {
        AddResourcePermission $requiredAccess -exposedPermissions $sp.AppRoles -requiredAccesses $requiredApplicationPermissions -permissionType "Role"
    }
    return $requiredAccess
}
  
Function GenerateAppKey ($fromDate, $durationInYears, $pw) {
    $endDate = $fromDate.AddYears($durationInYears) 
    $keyId = (New-Guid).ToString();
    $key = New-Object Microsoft.Open.AzureAD.Model.PasswordCredential($null, $endDate, $keyId, $fromDate, $pw)
    return $key
}
  
Function CreateAppKey($fromDate, $durationInYears, $pw) {
  
    $testKey = GenerateAppKey -fromDate $fromDate -durationInYears $durationInYears -pw $pw
  
    while ($testKey.Value -match "\+" -or $testKey.Value -match "/") {
        Write-Verbose "Secret contains + or / and may not authenticate correctly. Regenerating..."
        $pw = ComputePassword
        $testKey = GenerateAppKey -fromDate $fromDate -durationInYears $durationInYears -pw $pw
    }
    Write-Verbose "Secret doesn't contain + or /. Continuing..."
    $key = $testKey
  
    return $key
}
  
Function ComputePassword {
    $aesManaged = New-Object "System.Security.Cryptography.AesManaged"
    $aesManaged.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aesManaged.Padding = [System.Security.Cryptography.PaddingMode]::Zeros
    $aesManaged.BlockSize = 128
    $aesManaged.KeySize = 256
    $aesManaged.GenerateKey()
    return [System.Convert]::ToBase64String($aesManaged.Key)
}
  
function GetOrCreateMicrosoftGraphServicePrincipal {
    $graphsp = Get-AzureADServicePrincipal -Filter "DisplayName eq 'Dynamics CRM Online'"
    $graphsp = $graphsp[0]
    if (!$graphsp) {
        $graphsp = Get-AzureADServicePrincipal -Filter "AppId eq '00000007-0000-0000-c000-000000000000'"
    }
    if (!$graphsp) {
        Login-AzureAccount
        New-AzureRmADServicePrincipal -ApplicationId "00000007-0000-0000-c000-000000000000"
        $graphsp = Get-AzureADServicePrincipal -SearchString "Dynamics CRM Online"
    }
  
    return $graphsp
}

Write-Host "Logging in... Enter credentials for Azure Active Directory linked with CRM"
Connect-AzureAD
Write-Verbose "Tenant: $((Get-AzureADTenantDetail).displayName)"
  
# Check for a Microsoft Graph Service Principal. If it doesn't exist already, create it.
$graphsp = GetOrCreateMicrosoftGraphServicePrincipal

$existingapp = $null
$existingapp = get-azureadapplication -Filter "DisplayName eq '$applicationName'"
if ($existingapp) {
    Write-Verbose "App already exist. Deleting. App: $($existingapp | Out-String)"
    Remove-Azureadapplication -ObjectId $existingApp.objectId
}

$rsps = @()
if ($graphsp) {
    $rsps += $graphsp
    $tenant_id = (Get-AzureADTenantDetail).ObjectId
    $tenantName = (Get-AzureADTenantDetail).DisplayName
    $azureadsp = Get-AzureADServicePrincipal -SearchString "Windows Azure Active Directory"
    $rsps += $azureadsp
  
    # Add Required Resources Access (Microsoft Graph)
    $requiredResourcesAccess = New-Object System.Collections.Generic.List[Microsoft.Open.AzureAD.Model.RequiredResourceAccess]
    $microsoftGraphRequiredPermissions = GetRequiredPermissions -reqsp $graphsp -requiredApplicationPermissions $ApplicationPermissions -requiredDelegatedPermissions $DelegatedPermissions
    $requiredResourcesAccess.Add($microsoftGraphRequiredPermissions)
  
    if ($DelegatedPermissions) {
        Write-Verbose "Delegated Permissions specified, preparing permissions for Azure AD Graph API"
        # Add Required Resources Access (Azure AD Graph)
        #$AzureADGraphRequiredPermissions = GetRequiredPermissions -reqsp $azureadsp -requiredApplicationPermissions "Directory.ReadWrite.All"
        $AzureADGraphRequiredPermissions = GetRequiredPermissions -reqsp $azureadsp -requiredDelegatedPermissions "User.Read"
        $requiredResourcesAccess.Add($AzureADGraphRequiredPermissions)
    }
  
  
    # Get an application key
    $pw = ComputePassword
    $fromDate = [System.DateTime]::Now
    $appKey = CreateAppKey -fromDate $fromDate -durationInYears 2 -pw $pw
  
    Write-Verbose "Creating the AAD application $applicationName"

    $randomGuid = [guid]::newguid()
	$verifiedDomain = ''
	$domains = ((Get-AzureADTenantDetail).VerifiedDomains | where {$_.Capabilities -like '*OrgIdAuthentication*'})
	if($domains.count -gt 0) {
		$verifiedDomain = 'https://' + $domains[0].Name
	}
    if([string]::IsNullOrEmpty($verifiedDomain)) {
        $verifiedDomain = $appIdURI
    }
    $identifierUri = $verifiedDomain + '/' + $randomGuid.toString().Split('-')[0]

    $aadApplication = New-AzureADApplication -DisplayName $applicationName `
        -HomePage $homePage `
        -ReplyUrls $homePage `
        -IdentifierUris $identifierUri `
        -LogoutUrl $logoutURI `
        -RequiredResourceAccess $requiredResourcesAccess `
        -PasswordCredentials $appKey

    Write-Verbose "App Created"
      
    # Creating the Service Principal for the application
    $servicePrincipal = New-AzureADServicePrincipal -AppId $aadApplication.AppId
      
    Write-Verbose "Service Principle Created"

    Write-Verbose "Application ID: $aadApplication.AppId"
    Write-Verbose "Application Secret: $appkey.Value"
    $tenant_id = (Get-AzureADTenantDetail).ObjectId
    Write-Verbose "Tenant ID: $tenant_id"


    if($createNativeApp) {
        $nativeApplicationName = $applicationName + '_native'

        $existingapp = get-azureadapplication -SearchString $nativeApplicationName
        if ($existingapp) {
            Write-Verbose "App already exist. Deleting. App: $($existingapp | Out-String)"
            Remove-Azureadapplication -ObjectId $existingApp.objectId
        }

        Write-Verbose "Creating Native App"
        try 
        {
            $nativceApplication = New-AzureADApplication -DisplayName $nativeApplicationName `
                -ReplyUrls $nativeAppReplyUri `
                -RequiredResourceAccess $requiredResourcesAccess `
                -PublicClient $true

        }
        catch [Exception] {
            Write-Verbose $_.Exception | format-list -force
        }
        $servicePrincipal = New-AzureADServicePrincipal -AppId $nativceApplication.AppId
        Write-Verbose "Native App Created"
    }

	[hashtable]$Return = @{}
	$Return.appId = [string]$aadApplication.AppId
	$Return.appSecret = [string]$appkey.Value
    $Return.nativeAppId = [string]$nativceApplication.AppId
    $Return.nativeReplyUrl = [string]$nativeAppReplyUri
	Return $Return 
}
else {
    Write-Host "Microsoft Graph Service Principal could not be found or created" -ForegroundColor Red
}