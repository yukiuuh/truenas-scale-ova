<#
.SYNOPSIS
Imports a local OVF file to a VMware Cloud Director catalog within a specific organization.

.DESCRIPTION
VMware Cloud Director PowerCLI imports a vApp template from an OVF package path.
Use the .ovf descriptor file, not the packed .ova archive.

.PARAMETER OvfPath
Path to the .ovf descriptor file to import.

.PARAMETER Force
Deletes an existing vApp template with the same name from the target catalog before importing.
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$CIServer,

    [Parameter(Mandatory=$true)]
    [string]$OrgName,

    [Parameter(Mandatory=$true)]
    [string]$CatalogName,

    [Parameter(Mandatory=$true)]
    [string]$OvfPath,

    [Parameter(Mandatory=$true)]
    [string]$TemplateName,

    [switch]$Force
)

# Set error handling preference
$ErrorActionPreference = "Stop"

# Connect to VMware Cloud Director
$ciConnection = Connect-CIServer -Server $CIServer -Org $OrgName

try {
    if (-not (Test-Path -LiteralPath $OvfPath -PathType Leaf)) {
        throw "OVF file does not exist: $OvfPath"
    }

    if ([System.IO.Path]::GetExtension($OvfPath) -ine ".ovf") {
        throw "OvfPath must point to an .ovf descriptor file, not an .ova archive: $OvfPath"
    }

    # Retrieve the target Organization
    Write-Host "Retrieving Organization '$OrgName'..."
    $targetOrg = Get-Org -Name $OrgName

    # Retrieve the target Catalog within the Organization
    Write-Host "Retrieving Catalog '$CatalogName' within Organization '$OrgName'..."
    $targetCatalog = Get-Catalog -Name $CatalogName -Org $targetOrg

    $existingTemplates = @(
        Get-CIVAppTemplate -Name $TemplateName -Catalog $targetCatalog -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $TemplateName }
    )

    if ($existingTemplates.Count -gt 0) {
        if (-not $Force) {
            throw "vApp template '$TemplateName' already exists in catalog '$CatalogName'. Re-run with -Force to delete and recreate it."
        }

        foreach ($existingTemplate in $existingTemplates) {
            Write-Host "Removing existing vApp template '$($existingTemplate.Name)' from catalog '$CatalogName'..."
            $previousConfirmPreference = $ConfirmPreference
            try {
                $ConfirmPreference = "None"
                $existingTemplate | Remove-CIVAppTemplate
            } finally {
                $ConfirmPreference = $previousConfirmPreference
            }
        }
    }

    # Import the OVF file as a vApp Template
    Write-Host "Importing OVF file '$OvfPath' as '$TemplateName'..."
    Import-CIVAppTemplate -SourcePath $OvfPath -Name $TemplateName -Catalog $targetCatalog

    Write-Host "Import completed successfully."

} catch {
    Write-Error "An error occurred during the import process: $_"
} finally {
    # Disconnect from the server
    Write-Host "Disconnecting from VMware Cloud Director..."
    Disconnect-CIServer -Server $ciConnection -Confirm:$false
}
