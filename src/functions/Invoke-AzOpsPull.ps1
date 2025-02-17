﻿function Invoke-AzOpsPull {

    <#
        .SYNOPSIS
            Setup a repository for the AzOps workflow, based off templates and an existing Azure deployment.
        .DESCRIPTION
            Setup a repository for the AzOps workflow, based off templates and an existing Azure deployment.
        .PARAMETER SkipPolicy
            Skip discovery of policies for better performance.
        .PARAMETER SkipRole
            Skip discovery of role.
        .PARAMETER SkipResourceGroup
            Skip discovery of resource groups
        .PARAMETER SkipResource
            Skip discovery of resources inside resource groups.
        .PARAMETER InvalidateCache
            Invalidate cached subscriptions and Management Groups and do a full discovery.
        .PARAMETER ExportRawTemplate
            Export generic templates without embedding them in the parameter block.
        .PARAMETER Rebuild
            Delete all AutoGeneratedTemplateFolderPath folders inside AzOpsState directory.
        .PARAMETER Force
            Delete $script:AzOpsState directory.
        .PARAMETER PartialMgDiscoveryRoot
            The subset of management groups in the entire hierarchy with which to work.
            Needed when lacking root access.
        .PARAMETER StatePath
            The root folder under which to write the resource json.
        .EXAMPLE
            > Invoke-AzOpsPull
            Setup a repository for the AzOps workflow, based off templates and an existing Azure deployment.
    #>

    [CmdletBinding()]
    [Alias("Initialize-AzOpsRepository")]
    param (
        [switch]
        $SkipPolicy = (Get-PSFConfigValue -FullName 'AzOps.Core.SkipPolicy'),

        [switch]
        $SkipRole = (Get-PSFConfigValue -FullName 'AzOps.Core.SkipRole'),

        [switch]
        $SkipResourceGroup = (Get-PSFConfigValue -FullName 'AzOps.Core.SkipResourceGroup'),

        [switch]
        $SkipResource = (Get-PSFConfigValue -FullName 'AzOps.Core.SkipResource'),

        [switch]
        $InvalidateCache = (Get-PSFConfigValue -FullName 'AzOps.Core.InvalidateCache'),

        [switch]
        $ExportRawTemplate = (Get-PSFConfigValue -FullName 'AzOps.Core.ExportRawTemplate'),

        [switch]
        $Rebuild,

        [switch]
        $Force,

        [string[]]
        $PartialMgDiscoveryRoot = (Get-PSFConfigValue -FullName 'AzOps.Core.PartialMgDiscoveryRoot'),

        [string]
        $StatePath = (Get-PSFConfigValue -FullName 'AzOps.Core.State'),

        [string]
        $TemplateParameterFileSuffix = (Get-PSFConfigValue -FullName 'AzOps.Core.TemplateParameterFileSuffix')
    )

    begin {
        #region Initialize & Prepare
        Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Initialization.Starting'
        if (-not $SkipRole) {
            try {
                Write-PSFMessage -Level Verbose -String 'Invoke-AzOpsPull.Validating.UserRole'
                $null = Get-AzADUser -First 1 -ErrorAction Stop
                Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Validating.UserRole.Success'
            }
            catch {
                Write-PSFMessage -Level Warning -String 'Invoke-AzOpsPull.Validating.UserRole.Failed'
                $SkipRole = $true
            }
        }

        $parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Inherit -Include InvalidateCache, PartialMgDiscovery, PartialMgDiscoveryRoot
        Initialize-AzOpsEnvironment @parameters

        Assert-AzOpsInitialization -Cmdlet $PSCmdlet -StatePath $StatePath

        $tenantId = (Get-AzContext).Tenant.Id
        Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Tenant' -StringValues $tenantId
        Write-PSFMessage -Level Verbose -String 'Invoke-AzOpsPull.TemplateParameterFileSuffix' -StringValues (Get-PSFConfigValue -FullName 'AzOps.Core.TemplateParameterFileSuffix')

        Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Initialization.Completed'
        $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
        #endregion Initialize & Prepare
    }

    process {
        #region Existing Content
        if (Test-Path $StatePath) {
            $migrationRequired = (Get-ChildItem -Recurse -Force -Path $StatePath -File | Where-Object {
                    $_.Name -like $("Microsoft.Management_managementGroups-" + $tenantId + $TemplateParameterFileSuffix)
                } | Select-Object -ExpandProperty FullName -First 1) -notmatch '\((.*)\)'
            if ($migrationRequired) {
                Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Migration.Required'
            }

            if ($Force -or $migrationRequired) {
                Invoke-PSFProtectedCommand -ActionString 'Invoke-AzOpsPull.Deleting.State' -ActionStringValues $StatePath -Target $StatePath -ScriptBlock {
                    Remove-Item -Path $StatePath -Recurse -Force -Confirm:$false -ErrorAction Stop
                } -EnableException $true -PSCmdlet $PSCmdlet
            }
            if ($Rebuild) {
                Invoke-PSFProtectedCommand -ActionString 'Invoke-AzOpsPull.Rebuilding.State' -ActionStringValues $StatePath -Target $StatePath -ScriptBlock {
                    Get-ChildItem -Path $StatePath  -File -Recurse -Force -Filter 'Microsoft.*_*.json' | Remove-Item -Force -Recurse -Confirm:$false -ErrorAction Stop
                } -EnableException $true -PSCmdlet $PSCmdlet
            }
        }
        #endregion Existing Content

        #region Root Scopes
        $rootScope = '/providers/Microsoft.Management/managementGroups/{0}' -f $tenantId
        if ($script:AzOpsPartialRoot.id) {
            $rootScope = $script:AzOpsPartialRoot.id | Sort-Object -Unique
        }

        if ($rootScope -and $script:AzOpsAzManagementGroup) {
            foreach ($root in $rootScope) {
                # Create AzOpsState Structure recursively
                Save-AzOpsManagementGroupChildren -Scope $root -StatePath $StatePath

                # Discover Resource at scope recursively
                $parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Inherit -Include SkipPolicy, SkipRole, SkipResourceGroup, SkipResource, ExportRawTemplate, StatePath
                Get-AzOpsResourceDefinition -Scope $root @parameters
            }
        }
        else {
            # If no management groups are found, iterate through each subscription
            foreach ($subscription in $script:AzOpsSubscriptions) {
                $parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Inherit -Include SkipPolicy, SkipRole, SkipResourceGroup, SkipResource, ExportRawTemplate, StatePath
                Get-AzOpsResourceDefinition -Scope $subscription.id @parameters
            }

        }
        #endregion Root Scopes
    }

    end {
        $stopWatch.Stop()
        Write-PSFMessage -Level Important -String 'Invoke-AzOpsPull.Duration' -StringValues $stopWatch.Elapsed -Data @{ Elapsed = $stopWatch.Elapsed }
    }

}
