function New-BicepMarkdownDocumentation {
    [CmdletBinding(DefaultParameterSetName = 'FromFile')]
    param (
        [Parameter(ParameterSetName = 'FromFile', Position = 0)]
        [string]$File,

        [Parameter(ParameterSetName = 'FromFolder', Position = 0)]
        [string]$Path,

        [Parameter(ParameterSetName = 'FromFolder')]
        [switch]$Recurse,

        [Parameter(ParameterSetName = 'FromFile')]
        [Parameter(ParameterSetName = 'FromFolder')]
        [switch]$Console,

        [Parameter(ParameterSetName = 'FromFile')]
        [Parameter(ParameterSetName = 'FromFolder')]
        [switch]$Force
    )

    function New-MDTableHeader {
        param(
            [string[]]$Headers
        )

        $r = '|'
        foreach ($Head in $Headers) {
            $r += " $Head |"
        }
        
        $r = "$r`n|"
        
        1..($Headers.Count) | ForEach-Object {
            $r += "----|"
        }

        $r = "$r`n"
        
        $r
    }

    switch ($PSCmdLet.ParameterSetName) {
        'FromFile' { 
            $FileCollection = @((Get-Item $File)) 
        }
        'FromFolder' { 
            $FileCollection = Get-ChildItem $Path *.bicep -Recurse:$Recurse
        }
    }

    Write-Verbose -Verbose "Files to process:`n$($FileCollection.Name)"

    $MDHeader = @'
# {{SourceFile}}

[[_TOC_]]

'@

    foreach ($SourceFile in $FileCollection) {
        $FileDocumentationResult = $MDHeader.Replace('{{SourceFile}}', $SourceFile.Name)
        
        $MDMetadata = New-MDTableHeader -Headers 'Name', 'Value'
        $MDProviders = New-MDTableHeader -Headers 'Type', 'Version'
        $MDResources = New-MDTableHeader -Headers 'Name', 'Link', 'Location'
        $MDParameters = New-MDTableHeader -Headers 'Name', 'Type', 'AllowedValues', 'Metadata'
        $MDVariables = New-MDTableHeader -Headers 'Name', 'Value'
        $MDOutputs = New-MDTableHeader -Headers 'Name', 'Type', 'Value'
        $MDModules = New-MDTableHeader -Headers 'Name', 'Path'

        try {
            $BuildObject = (Build-BicepNetFile -Path $SourceFile.FullName -ErrorAction Stop) | ConvertFrom-Json -Depth 100
        }
        catch {
            switch ($ErrorActionPreference) {
                'Stop' {
                    throw
                }
                default {
                    Write-Warning -Message "Failed to build $($SourceFile.Name) - $($_.Exception.Message)"
                    continue
                }
            }
        }

        #region Get used modules in the bicep file

        try {
            $UsedModules = Get-UsedModulesInBicepFile -Path $SourceFile.FullName -ErrorAction Stop 
        }
        catch {
            throw
        }

        #endregion

        #region Add Metadata to MD output

        if ($null -eq $BuildObject.metadata) {
            $MDMetadata = 'n/a'
        }
        else {
            $MetadataNames = ($BuildObject.metadata | Get-Member -MemberType NoteProperty).Name
            
            foreach ($var in $MetadataNames) {
                $Param = $BuildObject.metadata.$var
                if ($Param.GetType().Name -eq 'PSCustomObject') {
                    $tempArr = @()
                    $tempObj = ($Param | Get-Member -MemberType NoteProperty).Name
                    foreach ($item in $tempObj) {
                        $tempArr += $item + ': ' + $Param.$($item) + '<br/>'
                    }
                    $MDMetadata += "| $var | $tempArr |`n"
                }
                else {
                    $MDMetadata += "| $var | $Param |`n"
                }
                
            }

        }
        $MDMetadata = $MDMetadata -replace ', ', '<br/>'

        $FileDocumentationResult += @"
## Metadata

$MDMetadata
"@

        #endregion

        #region Add providers to MD output
        # Check if it's an empty array
        if (-not $BuildObject.resources -or $BuildObject.resources.Count -eq 0) {
            $MDProviders = 'n/a'
        }
        else {
            foreach ($provider in $BuildObject.resources) {
                $MDProviders += "| $($Provider.Type) | $($Provider.apiVersion) |`n"
            }
        }

        $FileDocumentationResult += @"

## Providers

$MDProviders
"@
        #endregion

        #region Add Resources to MD output
        # Check if it's an empty array
        if (-not $BuildObject.resources -or $BuildObject.resources.Count -eq 0) {
            $MDResources = 'n/a'
        }
        else {
            foreach ($Resource in $BuildObject.resources) {
                try {
                    $URI = Get-BicepApiReference -Type "$($Resource.Type)@$($Resource.apiVersion)" -ReturnUri -Force
                }
                catch {
                    # If no uri is found this is the base path for template
                    $URI = 'https://docs.microsoft.com/en-us/azure/templates'
                }
                $MDResources += "| $($Resource.name) | [$($Resource.Type)@$($Resource.apiVersion)]($URI) | $($Resource.location) |`n"
            }
        }

        $FileDocumentationResult += @"

## Resources

$MDResources
"@
        #endregion

        #region Add Parameters to MD output
        if ($null -eq $BuildObject.parameters) {
            $MDParameters = 'n/a'
        }
        else {
            $ParameterNames = ($BuildObject.parameters | Get-Member -MemberType NoteProperty).Name

            foreach ($Parameter in $ParameterNames) {
                $Param = $BuildObject.parameters.$Parameter
                $MDParameters += "| $Parameter | $($Param.type) | $(
                    if ($Param.allowedValues) {
                        forEach ($value in $Param.allowedValues) {
                                                                    "$value <br/>"
                        }
                    } else {
                        "n/a"
                    }
                    ) | $(
                    forEach ($item in $Param.metadata) {
                            $res = $item.PSObject.members | Where-Object { $_.MemberType -eq 'NoteProperty' }
                            
                            if ($null -ne $res) {
                            
                                $res.Name + ': ' + $res.Value + '<br/>'
                            
                            }
                    }) |`n" 
            }
        }

        $FileDocumentationResult += @"

## Parameters

$MDParameters
"@
        #endregion

        #region Add Variables to MD output
        if ($null -eq $BuildObject.variables) {
            $MDVariables = 'n/a'
        }
        else {
            $VariableNames = ($BuildObject.variables | Get-Member -MemberType NoteProperty).Name
            foreach ($var in $VariableNames) {
                $Param = $BuildObject.variables.$var
                $MDVariables += "| $var | $Param |`n"
            }
        }
        $FileDocumentationResult += @"

## Variables

$MDVariables
"@
        #endregion

        #region Add Outputs to MD output
        if ($null -eq $BuildObject.Outputs) {
            $MDOutputs = 'n/a'
        }
        else {
            $OutputNames = ($BuildObject.Outputs | Get-Member -MemberType NoteProperty).Name
            foreach ($OutputName in $OutputNames) {
                $OutputValues = $BuildObject.outputs.$OutputName
                $MDOutputs += "| $OutputName | $($OutputValues.type) | $($OutputValues.value) |`n"
            }
        }

        $FileDocumentationResult += @"

## Outputs

$MDOutputs
"@
        #endregion

        #region Add Modules to MD output
        if (-not $UsedModules -or $UsedModules.Count -eq 0) {
            $MDModules = 'n/a'
        }
        else {
            foreach ($Module in $UsedModules) {
                $MDModules += "| $($Module.Name) | $($Module.Path) |`n"
            }
        }

        $FileDocumentationResult += @"

## Modules

$MDModules
"@

        #endregion

        if ($Console) {
            $FileDocumentationResult
        }
        else {
            $OutFileName = $SourceFile.FullName -replace '\.bicep$', '.md'
            $FileDocumentationResult | Out-File $OutFileName
        }
    }
}