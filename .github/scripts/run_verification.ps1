. "$PSScriptRoot\ai_orchestration_common.ps1"

$tempRoot = Get-TempRoot
$verificationResultPath = Join-Path $tempRoot 'ai-orchestrator-verification-result.json'

$reviewContextPath = [string]$env:REVIEW_CONTEXT_PATH
if ([string]::IsNullOrWhiteSpace($reviewContextPath) -or -not (Test-Path -LiteralPath $reviewContextPath)) {
    throw 'REVIEW_CONTEXT_PATH environment variable is required and must point to an existing file.'
}

function New-VerificationResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$Summary,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Checks,
        [string]$Reason = '',
        [bool]$SkipIsSafe = $false
    )

    return [pscustomobject]@{
        verification_status = $Status
        summary             = $Summary
        checks              = $Checks
        verification_reason = $Reason
        skip_is_safe        = $SkipIsSafe
    }
}

function Write-VerificationResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    Write-JsonUtf8 -Path $verificationResultPath -Value $Result
    Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
    Set-WorkflowOutput -Name 'verification_status' -Value ([string]$Result.verification_status)
}

function Get-LogExcerpt {
    param(
        [AllowNull()]
        [object[]]$OutputLines,
        [int]$MaxLines = 20,
        [int]$MaxChars = 1200
    )

    if ($null -eq $OutputLines) {
        return ''
    }

    $lines = @(
        $OutputLines |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($lines.Count -eq 0) {
        return ''
    }

    $excerpt = ($lines | Select-Object -Last $MaxLines) -join "`n"
    if ($excerpt.Length -gt $MaxChars) {
        $excerpt = $excerpt.Substring($excerpt.Length - $MaxChars)
    }

    return $excerpt
}

function Invoke-BuildCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SolutionPath,
        [Parameter(Mandatory = $true)]
        [string]$Configuration,
        [Parameter(Mandatory = $true)]
        [string]$Platform
    )

    $arguments = @(
        $SolutionPath
        '/t:Build'
        "/p:Configuration=$Configuration"
        "/p:Platform=$Platform"
        '/m'
    )

    $buildOutput = & msbuild @arguments 2>&1
    $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 1 }
    $logExcerpt = Get-LogExcerpt -OutputLines $buildOutput

    return [pscustomobject]@{
        name        = "$Configuration | $Platform"
        status      = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        note        = if ($exitCode -eq 0) { '빌드 성공' } else { "빌드 실패 (exit code $exitCode)" }
        exit_code   = $exitCode
        log_excerpt = $logExcerpt
    }
}

try {
    $context = Read-JsonUtf8 -Path $reviewContextPath

    if ($context.is_docs_only) {
        $result = New-VerificationResult `
            -Status 'skipped' `
            -Summary '문서 전용 변경으로 판단되어 빌드 검증을 생략했습니다.' `
            -Checks @() `
            -Reason 'docs_only' `
            -SkipIsSafe $true

        Write-VerificationResult -Result $result
        exit 0
    }

    if (-not $IsWindows) {
        $result = New-VerificationResult `
            -Status 'failed' `
            -Summary 'Windows 환경이 아니어서 DX12 빌드 검증을 수행할 수 없습니다.' `
            -Checks @() `
            -Reason 'non_windows_environment'

        Write-VerificationResult -Result $result
        exit 0
    }

    $solutionPath = Join-Path (Get-Location).Path 'dx12Engine\dx12Engine.sln'
    if (-not (Test-Path -LiteralPath $solutionPath)) {
        throw "Solution file was not found: $solutionPath"
    }

    if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) {
        $result = New-VerificationResult `
            -Status 'failed' `
            -Summary 'msbuild를 찾지 못해 빌드 검증을 수행할 수 없습니다.' `
            -Checks @() `
            -Reason 'msbuild_missing'

        Write-VerificationResult -Result $result
        exit 0
    }

    $checks = @(
        Invoke-BuildCheck -SolutionPath $solutionPath -Configuration 'Debug' -Platform 'x64'
        Invoke-BuildCheck -SolutionPath $solutionPath -Configuration 'Release' -Platform 'x64'
    )

    $failedCheckCount = @($checks | Where-Object { $_.status -eq 'failed' }).Count
    if ($failedCheckCount -gt 0) {
        $result = New-VerificationResult `
            -Status 'failed' `
            -Summary '기본 빌드 검증에서 하나 이상의 실패가 발생했습니다.' `
            -Checks $checks `
            -Reason 'build_failed'
    }
    else {
        $result = New-VerificationResult `
            -Status 'passed' `
            -Summary 'Debug | x64, Release | x64 빌드 검증이 통과했습니다.' `
            -Checks $checks `
            -Reason 'build_passed'
    }

    Write-VerificationResult -Result $result
}
catch {
    $result = New-VerificationResult `
        -Status 'failed' `
        -Summary "검증 단계 실행에 실패했습니다: $($_.Exception.Message)" `
        -Checks @() `
        -Reason 'verification_exception'

    Write-VerificationResult -Result $result
}
