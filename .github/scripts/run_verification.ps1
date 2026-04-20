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
        [array]$Checks
    )

    return [pscustomobject]@{
        verification_status = $Status
        summary             = $Summary
        checks              = $Checks
    }
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

    & msbuild @arguments
    $exitCode = $LASTEXITCODE

    return [pscustomobject]@{
        name   = "$Configuration | $Platform"
        status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        note   = if ($exitCode -eq 0) { '빌드 성공' } else { "빌드 실패 (exit code $exitCode)" }
    }
}

try {
    $context = Read-JsonUtf8 -Path $reviewContextPath

    if ($context.is_docs_only) {
        $result = New-VerificationResult `
            -Status 'skipped' `
            -Summary '문서 전용 변경으로 판단되어 빌드 검증을 생략했습니다.' `
            -Checks @()

        Write-JsonUtf8 -Path $verificationResultPath -Value $result
        Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
        Set-WorkflowOutput -Name 'verification_status' -Value 'skipped'
        exit 0
    }

    if (-not $IsWindows) {
        $result = New-VerificationResult `
            -Status 'skipped' `
            -Summary 'Windows 환경이 아니어서 DX12 빌드 검증을 건너뛰었습니다.' `
            -Checks @()

        Write-JsonUtf8 -Path $verificationResultPath -Value $result
        Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
        Set-WorkflowOutput -Name 'verification_status' -Value 'skipped'
        exit 0
    }

    $solutionPath = Join-Path (Get-Location).Path 'dx12Engine\dx12Engine.sln'
    if (-not (Test-Path -LiteralPath $solutionPath)) {
        throw "Solution file was not found: $solutionPath"
    }

    if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) {
        $result = New-VerificationResult `
            -Status 'skipped' `
            -Summary 'msbuild를 찾지 못해 빌드 검증을 건너뛰었습니다.' `
            -Checks @()

        Write-JsonUtf8 -Path $verificationResultPath -Value $result
        Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
        Set-WorkflowOutput -Name 'verification_status' -Value 'skipped'
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
            -Summary '기본 빌드 검증에서 실패가 발생했습니다.' `
            -Checks $checks
    }
    else {
        $result = New-VerificationResult `
            -Status 'passed' `
            -Summary 'Debug | x64, Release | x64 빌드 검증이 통과했습니다.' `
            -Checks $checks
    }

    Write-JsonUtf8 -Path $verificationResultPath -Value $result
    Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
    Set-WorkflowOutput -Name 'verification_status' -Value ([string]$result.verification_status)
}
catch {
    $result = New-VerificationResult `
        -Status 'failed' `
        -Summary "검증 단계 실행에 실패했습니다: $($_.Exception.Message)" `
        -Checks @()

    Write-JsonUtf8 -Path $verificationResultPath -Value $result
    Set-WorkflowOutput -Name 'verification_result_path' -Value $verificationResultPath
    Set-WorkflowOutput -Name 'verification_status' -Value 'failed'
}
