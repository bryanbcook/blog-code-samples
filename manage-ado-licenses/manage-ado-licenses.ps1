param(
    [Parameter(Mandatory=$true, HelpMessage="Azure AD User Group for licensed users")]
    [string]$AADLicensedUsers
)

function Get-AzureDevOpsUsers() {

    param(
        [Parameter()]
        [int]$BatchSize = 100
    )

    $query = "items[].{license:accessLevel.licenseDisplayName, email:user.principalName, dateCreated:dateCreated, lastAccessedDate:lastAccessedDate }"
    
    $users = @()

    Write-Host "Determining number of ADO users."
    $totalCount = az devops user list --query "totalCount"
    Write-Host "Fetching $totalCount users" -NoNewline

    $intervals = [math]::Ceiling($totalCount / $BatchSize)

    for($i = 0; $i -lt $intervals; $i++) {

        Write-Host -NoNewline "."

        $skip = $i * $BatchSize;
        $results = az devops user list --query "$query" --top $BatchSize --skip $skip | ConvertFrom-Json

        $users = $users + $results
    }

    Write-Host

    return $users
}

function Where-License()
{
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline)]
        $Users,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Basic', 'Stakeholder')]
        [string]$license
    )

    BEGIN{}
    PROCESS
    {
        $Users | Where-Object -FilterScript { $_.license -eq $license }
    }
    END{}
}

function Where-LicenseAccessed()
{
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline)]
        $Users,

        [Parameter()]
        [int]$WithinDays = 1,

        [Parameter()]
        [switch]$NotUsed = $false
    )
    BEGIN
    {
        $today = Get-Date
    }
    PROCESS
    {
        $Users | Where-Object -FilterScript {

            $lastAccess = (@( $_.lastAccessedDate, $_.dateCreated) | 
                            ForEach-Object { [datetime]$_ } |
                            Measure-Object -Maximum | Select-Object Maximum).Maximum

            $timespan = New-TimeSpan -Start $lastAccess -End $today

            if (($NotUsed -and $timespan.Days -gt $WithinDays) -or (($NotUsed -eq $false) -and $timespan.Days -le $WithinDays))
            {
                Write-Host ("User {0} last accessed within {1} days." -f $_.email, $timespan.Days)
                return $true
            }

            return $false
        }
    }
    END {}
}

function Set-AzureDevOpsLicense()
{
    param(
        [Parameter(Mandatory=$true)]
        $User,

        [Parameter(Mandatory=$true)]
        [ValidateSet('express','stakeholder')]
        [string]$license
    )
    Write-Host ("Setting User {0} license to {1}" -f $_.email, $license)
    az devops user update --user $user.email --license-type $license | ConvertFrom-Json
}

Write-Host "Fetching list of licensed users from Azure AD"
$licensedUsers = az ad group member list -g $AADLicensedUsers --query "[].otherMails[0]" | ConvertFrom-Json

$users = Get-AzureDevOpsUsers
$reactivatedUsers = @() + ($users | Where-License -license Stakeholder | 
                             Where-LicenseAccessed -WithinDays 3 | 
                             Where-Object -FilterScript { $licensedUsers.Contains($_.email) } | 
                             ForEach-Object { Set-AzureDevOpsLicense -User $_ -license express })

$deactivatedUsers = @() + ($users | Where-License -license Basic | 
                             Where-LicenseAccessed -NotUsed -WithinDays 21 | 
                             ForEach-Object { Set-AzureDevOpsLicense -User $_ -license stakeholder })

Write-Host
Write-Host ("Reviewed {0} users" -f $users.Length)
Write-Host ("Deactivated {0} licenses." -f $deactivatedUsers.length)
Write-Host ("Reactivated {0} licenses." -f $reactivatedUsers.length)

