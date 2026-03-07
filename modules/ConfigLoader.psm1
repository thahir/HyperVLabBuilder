function Convert-SizeToBytes {
    <#
    .SYNOPSIS
        Converts PowerShell-style size strings to bytes.
        "8GB" -> 8589934592, "512MB" -> 536870912, "4TB" -> 4398046511104
    #>
    param([Parameter(Mandatory)][string]$SizeString)

    if ($SizeString -match '^(\d+(?:\.\d+)?)\s*(TB|GB|MB|KB)$') {
        $value = [double]$Matches[1]
        switch ($Matches[2]) {
            'TB' { return [int64]($value * 1TB) }
            'GB' { return [int64]($value * 1GB) }
            'MB' { return [int64]($value * 1MB) }
            'KB' { return [int64]($value * 1KB) }
        }
    }

    # Fallback: already numeric (bytes)
    if ($SizeString -match '^\d+$') {
        return [int64]$SizeString
    }

    throw "Cannot parse size: '$SizeString'. Use format like '8GB', '512MB', etc."
}

function Import-LabConfig {
    <#
    .SYNOPSIS
        Loads config.yaml and returns a hashtable. Converts RAM strings
        to bytes and synthesizes DiskGB from Disks array.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Ensure powershell-yaml is available
    if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
        throw "Required module 'powershell-yaml' is not installed.`nInstall it with: Install-Module -Name powershell-yaml -Scope CurrentUser -Force"
    }
    Import-Module powershell-yaml -ErrorAction Stop

    if (-not (Test-Path $Path)) {
        throw "Config file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw
    $config = ConvertFrom-Yaml $raw

    # Post-process VM definitions
    foreach ($vm in $config.VMs) {
        # Convert RAM string to bytes (e.g., "8GB" -> 8589934592)
        if ($vm.RAM -is [string]) {
            $vm.RAM = Convert-SizeToBytes $vm.RAM
        }

        # Synthesize DiskGB from Disks array (backward compat for modules using $VMDef.DiskGB)
        if ($vm.Disks -and $vm.Disks.Count -gt 0) {
            $osDisk = $vm.Disks | Where-Object { $_.Purpose -eq 'OS' } | Select-Object -First 1
            if ($osDisk) {
                $vm['DiskGB'] = [int]$osDisk.Size
            }
            else {
                $vm['DiskGB'] = [int]$vm.Disks[0].Size
            }
        }
    }

    return $config
}

Export-ModuleMember -Function Import-LabConfig
