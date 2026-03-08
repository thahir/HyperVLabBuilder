function Initialize-LabTemplates {
    <#
    .SYNOPSIS
        Validates and prepares template VHDXs from cloud images.
        Converts qcow2 to VHDX if needed, resizes disks.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config
    )

    $templatePath = $Config.TemplatePath
    if (-not (Test-Path $templatePath)) {
        New-Item -ItemType Directory -Path $templatePath -Force | Out-Null
    }

    # === RHEL Cloud Image ===
    $rhelSource = Join-Path $templatePath $Config.RHELCloudImage
    $rhelTemplate = Join-Path $templatePath "rhel10-template.vhdx"

    if (Test-Path $rhelTemplate) {
        Write-Host "[SKIP] RHEL template VHDX already exists: $rhelTemplate" -ForegroundColor Yellow
    }
    elseif (Test-Path $rhelSource) {
        $ext = [System.IO.Path]::GetExtension($rhelSource).ToLower()

        if ($ext -eq ".qcow2") {
            # Convert qcow2 to VHDX using qemu-img
            Write-Host "[IMG ] Converting RHEL cloud image to VHDX..." -ForegroundColor Cyan
            $qemuImg = Find-QemuImg
            if ($qemuImg) {
                & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $rhelSource $rhelTemplate
                if ($LASTEXITCODE -ne 0) {
                    throw "qemu-img conversion failed for RHEL cloud image."
                }
                Write-Host "[OK  ] RHEL VHDX created: $rhelTemplate" -ForegroundColor Green
            }
            else {
                throw @"
qemu-img not found. Install it via one of:
  - winget install qemu
  - choco install qemu
  - Download from https://qemu.weilnetz.de/w64/
Then add it to your PATH and re-run.
"@
            }
        }
        elseif ($ext -in @(".vhd", ".vhdx")) {
            # Direct copy/convert VHD to VHDX
            if ($ext -eq ".vhd") {
                Write-Host "[IMG ] Converting VHD to VHDX..." -ForegroundColor Cyan
                Convert-VHDtoVHDX -SourcePath $rhelSource -DestinationPath $rhelTemplate
            }
            else {
                Write-Host "[IMG ] Copying RHEL VHDX template..." -ForegroundColor Cyan
                Copy-Item $rhelSource $rhelTemplate
            }
            Write-Host "[OK  ] RHEL template ready: $rhelTemplate" -ForegroundColor Green
        }
        else {
            throw "Unsupported RHEL image format: $ext. Use .qcow2, .vhd, or .vhdx"
        }
    }
    else {
        # Check if any RHEL image exists with a different name (auto-download may have used API filename)
        $anyRhel = Get-ChildItem $templatePath -Filter "rhel-*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($anyRhel) {
            $rhelSource = $anyRhel.FullName
            $ext = $anyRhel.Extension.ToLower()
            Write-Host "[IMG ] Found RHEL image with different name: $($anyRhel.Name)" -ForegroundColor Cyan
            if ($ext -eq ".qcow2") {
                $qemuImg = Find-QemuImg
                if ($qemuImg) {
                    Write-Host "[IMG ] Converting RHEL cloud image to VHDX..." -ForegroundColor Cyan
                    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $rhelSource $rhelTemplate
                    if ($LASTEXITCODE -ne 0) { throw "qemu-img conversion failed." }
                    Write-Host "[OK  ] RHEL VHDX created: $rhelTemplate" -ForegroundColor Green
                }
                else {
                    throw "qemu-img not found. Install via: winget install SoftwareFreedomConservancy.QEMU"
                }
            }
            elseif ($ext -eq ".vhd") {
                Write-Host "[IMG ] Converting VHD to VHDX..." -ForegroundColor Cyan
                Convert-VHDtoVHDX -SourcePath $rhelSource -DestinationPath $rhelTemplate
                Write-Host "[OK  ] RHEL template ready: $rhelTemplate" -ForegroundColor Green
            }
            elseif ($ext -eq ".vhdx") {
                Copy-Item $rhelSource $rhelTemplate
                Write-Host "[OK  ] RHEL template ready: $rhelTemplate" -ForegroundColor Green
            }
        }
        else {
            throw @"
RHEL cloud image not found in: $templatePath

Download manually from: https://access.redhat.com/downloads/content/rhel
Place the .qcow2 file in: $templatePath
"@
        }
    }

    # === Windows Server VHD ===
    $winTemplate = Join-Path $templatePath "winserver2022-template.vhdx"

    if (Test-Path $winTemplate) {
        Write-Host "[SKIP] Windows template VHDX already exists: $winTemplate" -ForegroundColor Yellow
    }
    else {
        # Search for any Windows VHD/VHDX in the template directory
        $anyWin = Get-ChildItem $templatePath -Filter "Windows*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".vhd", ".vhdx") } | Select-Object -First 1
        if ($anyWin) {
            $winSource = $anyWin.FullName
            Write-Host "[IMG ] Found Windows image: $($anyWin.Name)" -ForegroundColor Cyan
            if ($anyWin.Extension -eq ".vhd") {
                Write-Host "[IMG ] Converting Windows VHD to VHDX..." -ForegroundColor Cyan
                Convert-VHDtoVHDX -SourcePath $winSource -DestinationPath $winTemplate
            }
            else {
                Copy-Item $winSource $winTemplate
            }
            Write-Host "[OK  ] Windows template ready: $winTemplate" -ForegroundColor Green
        }
        else {
            throw @"
Windows Server VHD not found in: $templatePath

Download manually from: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
Choose VHD format, place in: $templatePath
"@
        }
    }

    return @{
        RHELTemplate    = $rhelTemplate
        WindowsTemplate = $winTemplate
    }
}

function Copy-TemplateVHDX {
    <#
    .SYNOPSIS
        Clones a template VHDX for a specific VM and resizes it.
    #>
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][int64]$SizeBytes
    )

    if (Test-Path $DestinationPath) {
        Write-Host "[SKIP] VHDX already exists: $DestinationPath" -ForegroundColor Yellow
        return
    }

    Write-Host "[IMG ] Cloning template VHDX..." -ForegroundColor Cyan
    Copy-Item $TemplatePath $DestinationPath -Force

    # Resize to target size
    $currentSize = (Get-VHD $DestinationPath).Size
    if ($SizeBytes -gt $currentSize) {
        Write-Host "[IMG ] Resizing VHDX to $([math]::Round($SizeBytes / 1GB))GB..." -ForegroundColor Cyan
        Resize-VHD -Path $DestinationPath -SizeBytes $SizeBytes
    }

    Write-Host "[OK  ] VHDX ready: $DestinationPath" -ForegroundColor Green
}

function Find-QemuImg {
    <#
    .SYNOPSIS
        Locates qemu-img.exe on the system.
    #>
    $cmd = Get-Command "qemu-img.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Common install locations
    $paths = @(
        "$env:ProgramFiles\qemu\qemu-img.exe",
        "${env:ProgramFiles(x86)}\qemu\qemu-img.exe",
        "$env:ProgramFiles\QEMU\qemu-img.exe",
        "C:\qemu\qemu-img.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Convert-VHDtoVHDX {
    <#
    .SYNOPSIS
        Converts VHD to VHDX using Convert-VHD (Hyper-V) or qemu-img as fallback.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    # Try Hyper-V Convert-VHD first
    $convertCmd = Get-Command "Convert-VHD" -ErrorAction SilentlyContinue
    if ($convertCmd) {
        Convert-VHD -Path $SourcePath -DestinationPath $DestinationPath -VHDType Dynamic
        return
    }

    # Fallback to qemu-img
    Write-Host "[INFO] Convert-VHD not available, using qemu-img..." -ForegroundColor Yellow
    $qemuImg = Find-QemuImg
    if ($qemuImg) {
        & $qemuImg convert -f vpc -O vhdx -o subformat=dynamic $SourcePath $DestinationPath
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img VHD to VHDX conversion failed."
        }
    }
    else {
        throw @"
Neither Convert-VHD (Hyper-V) nor qemu-img found.
Fix with one of:
  - Enable Hyper-V PowerShell: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell
  - Install qemu: winget install SoftwareFreedomConservancy.QEMU
"@
    }
}

Export-ModuleMember -Function Initialize-LabTemplates, Copy-TemplateVHDX
