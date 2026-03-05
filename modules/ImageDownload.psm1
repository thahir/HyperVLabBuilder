function Invoke-LabImageDownload {
    <#
    .SYNOPSIS
        Downloads the Windows Server 2022 evaluation VHD if missing.
        RHEL must be downloaded manually from Red Hat Customer Portal.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Config
    )

    $templatePath = $Config.TemplatePath
    if (-not (Test-Path $templatePath)) {
        New-Item -ItemType Directory -Path $templatePath -Force | Out-Null
    }

    $rhelDest = Join-Path $templatePath $Config.RHELCloudImage
    $winDest  = Join-Path $templatePath $Config.WindowsVHD
    $rhelTemplate = Join-Path $templatePath "rhel10-template.vhdx"
    $winTemplate  = Join-Path $templatePath "winserver2022-template.vhdx"

    # Check RHEL - manual download required
    $rhelPresent = (Test-Path $rhelDest) -or (Test-Path $rhelTemplate)
    $anyRhel = Get-ChildItem $templatePath -Filter "rhel-*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rhelPresent -and -not $anyRhel) {
        Write-Host ""
        Write-Host "[WARN] RHEL 10 KVM Guest Image not found in: $templatePath" -ForegroundColor Yellow
        Write-Host "       Download it manually from: https://access.redhat.com/downloads/content/rhel" -ForegroundColor Yellow
        Write-Host "       Look for: 'Red Hat Enterprise Linux 10.1 KVM Guest Image' (.qcow2)" -ForegroundColor Yellow
        Write-Host "       Place the file in: $templatePath" -ForegroundColor Cyan
        Write-Host ""
        throw "RHEL cloud image required. Download manually and re-run."
    }

    # Check Windows - auto-download
    $needWindows = (-not (Test-Path $winDest)) -and (-not (Test-Path $winTemplate))
    $anyWin = Get-ChildItem $templatePath -Filter "Windows*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".vhd", ".vhdx") } | Select-Object -First 1
    if ($anyWin) { $needWindows = $false }

    if (-not $needWindows) {
        Write-Host "[SKIP] All cloud images already present. No downloads needed." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Windows Server 2022 evaluation VHD (~5 GB) needs to be downloaded." -ForegroundColor Yellow
    $confirm = Read-Host "Continue with download? (Y/N)"
    if ($confirm -notin @("Y", "y", "Yes", "yes")) {
        throw "Download cancelled. Download the VHD manually from: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022"
    }

    Write-Host "[DL  ] Downloading Windows Server 2022 evaluation VHD (~5 GB, may take several minutes)..." -ForegroundColor Cyan

    $winUrl = "https://go.microsoft.com/fwlink/p/?linkid=2195166&clcid=0x409&culture=en-us&country=us"
    $winDownloadPath = Join-Path $templatePath "WindowsServer2022-eval.vhd"

    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($winUrl, $winDownloadPath)
        $wc.Dispose()

        if (Test-Path $winDownloadPath) {
            $sizeMB = [math]::Round((Get-Item $winDownloadPath).Length / 1MB, 1)
            Write-Host "[OK  ] Windows VHD downloaded: $winDownloadPath ($sizeMB MB)" -ForegroundColor Green
            $Config.WindowsVHD = "WindowsServer2022-eval.vhd"
        }
        else {
            throw "Download completed but file not found at: $winDownloadPath"
        }
    }
    catch {
        Write-Host "[FAIL] Windows VHD download failed: $_" -ForegroundColor Red
        Write-Host "       Download manually from: https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022" -ForegroundColor Yellow
        Write-Host "       Choose VHD format, place in: $templatePath" -ForegroundColor Yellow
    }

    # Check for qemu-img (needed if RHEL image is qcow2)
    $rhelFile = Get-ChildItem $templatePath -Filter "rhel-*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rhelFile -and $rhelFile.Extension -eq ".qcow2") {
        $qemuImg = Get-Command "qemu-img.exe" -ErrorAction SilentlyContinue
        if (-not $qemuImg) {
            $found = $false
            foreach ($p in @(
                "$env:ProgramFiles\qemu\qemu-img.exe",
                "${env:ProgramFiles(x86)}\qemu\qemu-img.exe",
                "$env:ProgramFiles\QEMU\qemu-img.exe",
                "C:\qemu\qemu-img.exe"
            )) {
                if (Test-Path $p) { $found = $true; break }
            }

            if (-not $found) {
                Write-Host ""
                Write-Host "[WARN] qemu-img.exe is required to convert .qcow2 to .vhdx" -ForegroundColor Yellow
                Write-Host "       Install it via one of:" -ForegroundColor Yellow
                Write-Host "         winget install SoftwareFreedomConservancy.QEMU" -ForegroundColor Cyan
                Write-Host "         choco install qemu" -ForegroundColor Cyan

                $installChoice = Read-Host "Attempt to install qemu via winget now? (Y/N)"
                if ($installChoice -in @("Y", "y", "Yes", "yes")) {
                    try {
                        Write-Host "[INST] Installing QEMU via winget..." -ForegroundColor Cyan
                        & winget install SoftwareFreedomConservancy.QEMU --accept-source-agreements --accept-package-agreements 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "[OK  ] QEMU installed." -ForegroundColor Green
                            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                        }
                        else {
                            Write-Host "[WARN] winget returned exit code $LASTEXITCODE. Install manually." -ForegroundColor Yellow
                        }
                    }
                    catch {
                        Write-Host "[WARN] Failed to install QEMU: $_" -ForegroundColor Yellow
                    }
                }
            }
        }
    }

    Write-Host ""
    Write-Host "[OK  ] Image download phase complete." -ForegroundColor Green
}

Export-ModuleMember -Function Invoke-LabImageDownload
