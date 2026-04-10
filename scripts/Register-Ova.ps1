<#
.SYNOPSIS
Imports a local OVA file to a specified VMware Cloud Director catalog within a specific Organization.
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$CIServer,

    [Parameter(Mandatory=$true)]
    [string]$OrgName,

    [Parameter(Mandatory=$true)]
    [string]$CatalogName,

    [Parameter(Mandatory=$true)]
    [string]$OvaPath,

    [Parameter(Mandatory=$true)]
    [string]$TemplateName
)

# Set error handling preference
$ErrorActionPreference = "Stop"

# Connect to VMware Cloud Director
Connect-CIServer -Server $CIServer

try {
    # Retrieve the target Organization
    Write-Host "Retrieving Organization '$OrgName'..."
    $targetOrg = Get-Org -Name $OrgName

    # Retrieve the target Catalog within the Organization
    Write-Host "Retrieving Catalog '$CatalogName' within Organization '$OrgName'..."
    $targetCatalog = Get-Catalog -Name $CatalogName -Org $targetOrg

    # Import the OVA file as a vApp Template
    Write-Host "Importing OVA file '$OvaPath' as '$TemplateName'..."
    Import-CIVAppTemplate -SourcePath $OvaPath -Name $TemplateName -Catalog $targetCatalog
    
    Write-Host "Import completed successfully."

} catch {
    Write-Error "An error occurred during the import process: $_"
} finally {
    # Disconnect from the server
    Write-Host "Disconnecting from VMware Cloud Director..."
    Disconnect-CIServer -Server $CIServer -Confirm:$false
}