[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation
try {
    Import-VstsLocStrings "$PSScriptRoot\task.json"

    # TODO MOVE ASSERT-VSTSAGENT TO THE TASK LIB AND LOC
    function Assert-VstsAgent {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)]
            [version]$Minimum)

        if ($Minimum -lt ([version]'2.104.1')) {
            Write-Error "Assert-Agent requires the parameter to be 2.104.1 or higher"
            return
        }

        $agent = Get-VstsTaskVariable -Name 'agent.version'
        if (!$agent -or (([version]$agent) -lt $Minimum)) {
            Write-Error "Agent version $Minimum or higher is required."
        }
    }

    # Get inputs.
    $input_failOnStderr = Get-VstsInput -Name 'failOnStderr' -AsBool
    $input_script = Get-VstsInput -Name 'script'
    $input_workingDirectory = Get-VstsInput -Name 'workingDirectory' -Require
    Assert-VstsPath -LiteralPath $input_workingDirectory -PathType 'Container'

    # Generate the script contents.
    #TODO: CONVERT NEWLINES?
    $contents = "$input_script"

    # Write the script to disk.
    Assert-VstsAgent -Minimum '2.115.0'
    $tempDirectory = Get-VstsTaskVariable -Name 'agent.tempDirectory' -Require
    Assert-VstsPath -LiteralPath $tempDirectory -PathType 'Container'
    $filePath = [System.IO.Path]::Combine($tempDirectory, "$([System.Guid]::NewGuid()).cmd")
    $null = [System.IO.File]::WriteAllText(
        $filePath,
        $contents.ToString(),
        ([System.Console]::OutputEncoding))

    # Prepare the external command values.
    $cmdPath = $env:ComSpec
    Assert-VstsPath -LiteralPath $cmdPath -PathType Leaf
    # Command line switches:
    # /Q     Turns echo off.
    # /D     Disable execution of AutoRun commands from registry.
    # /E:ON  Enable command extensions. Note, command extensions are enabled
    #        by default, unless disabled via registry.
    # /V:OFF Disable delayed environment expansion. Note, delayed environment
    #        expansion is disabled by default, unless enabled via registry.
    # /S     Will cause first and last quote after /C to be stripped.
    #
    # TODO: ADD EXPLANATION WHY "CALL" IS REQUIRED
    $arguments = "/Q /D /E:ON /V:OFF /S /C `"CALL `"$filePath`"`""
    $splat = @{
        'FileName' = $cmdPath
        'Arguments' = $arguments
        'WorkingDirectory' = $input_workingDirectory
    }

    # Switch to "Continue".
    $global:ErrorActionPreference = 'Continue'
    $failed = $false

    # Run the script.
    if (!$input_failOnStderr) {
        Invoke-VstsTool @splat
    } else {
        $inError = $false
        $errorLines = New-Object System.Text.StringBuilder
        Invoke-VstsTool @splat 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    # Buffer the error lines.
                    $failed = $true
                    $inError = $true
                    $null = $errorLines.AppendLine("$($_.Exception.Message)")

                    # Write to verbose to mitigate if the process hangs.
                    Write-Verbose "STDERR: $($_.Exception.Message)"
                } else {
                    # Flush the error buffer.
                    if ($inError) {
                        $inError = $false
                        $message = $errorLines.ToString().Trim()
                        $null = $errorLines.Clear()
                        if ($message) {
                            Write-VstsTaskError -Message $message
                        }
                    }

                    Write-Host "$_"
                }
            }

        # Flush the error buffer one last time.
        if ($inError) {
            $inError = $false
            $message = $errorLines.ToString().Trim()
            $null = $errorLines.Clear()
            if ($message) {
                Write-VstsTaskError -Message $message
            }
        }
    }

    # Fail on $LASTEXITCODE
    if (!(Test-Path -LiteralPath 'variable:\LASTEXITCODE')) {
        $failed = $true
        Write-Verbose "Unable to determine exit code"
        Write-VstsTaskError -Message (Get-VstsLocString -Key 'PS_UnableToDetermineExitCode')
    } else {
        if ($LASTEXITCODE -ne 0) {
            $failed = $true
            Write-VstsTaskError -Message (Get-VstsLocString -Key 'PS_ExitCode' -ArgumentList $LASTEXITCODE)
        }
    }

    # Fail if any errors.
    if ($failed) {
        Write-VstsSetResult -Result 'Failed' -Message "Error detected" -DoNotThrow
    }
} finally {
    Trace-VstsLeavingInvocation $MyInvocation
}