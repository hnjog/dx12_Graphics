. "$PSScriptRoot\ai_orchestration_common.ps1"

$tempRoot = Get-TempRoot
$commentPath = Join-Path $tempRoot 'ai-orchestrator-comment.md'
$summaryPath = Join-Path $tempRoot 'ai-orchestrator-summary.md'
$mergedResultPath = Join-Path $tempRoot 'ai-orchestrator-merged-result.json'

$reviewContextPath = [string]$env:REVIEW_CONTEXT_PATH
if ([string]::IsNullOrWhiteSpace($reviewContextPath) -or -not (Test-Path -LiteralPath $reviewContextPath)) {
    throw 'REVIEW_CONTEXT_PATH environment variable is required and must point to an existing file.'
}

function New-MergedReviewResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Summary,
        [Parameter(Mandatory = $true)]
        [string]$OverallAssessment,
        [Parameter(Mandatory = $true)]
        [string]$RiskLevel,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Findings,
        [Parameter(Mandatory = $true)]
        [bool]$HumanGateRequired,
        [Parameter(Mandatory = $true)]
        [string]$HumanGateReason,
        [Parameter(Mandatory = $true)]
        [bool]$ShouldNotifySlack,
        [Parameter(Mandatory = $true)]
        [string]$FinalDecision,
        [Parameter(Mandatory = $true)]
        [string]$ReviewStatus,
        [string]$ModeratorMode = '',
        [string]$ModeratorFallbackReason = ''
    )

    return [pscustomobject]@{
        summary                   = $Summary
        overall_assessment        = $OverallAssessment
        risk_level                = $RiskLevel
        findings                  = $Findings
        human_gate_required       = $HumanGateRequired
        human_gate_reason         = $HumanGateReason
        should_notify_slack       = $ShouldNotifySlack
        final_decision            = $FinalDecision
        review_status             = $ReviewStatus
        moderator_mode            = $ModeratorMode
        moderator_fallback_reason = $ModeratorFallbackReason
    }
}

function Get-LocalizedRiskLevel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RiskLevel
    )

    switch ($RiskLevel) {
        'low' { return '낮음' }
        'medium' { return '보통' }
        'high' { return '높음' }
        'unknown' { return '알 수 없음' }
        default { return $RiskLevel }
    }
}

function Get-LocalizedDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Decision
    )

    switch ($Decision) {
        'pass' { return '통과' }
        'needs_human' { return '사람 검토 필요' }
        'failed' { return '실패' }
        default { return $Decision }
    }
}

function Get-LocalizedVerificationStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    switch ($Status) {
        'passed' { return '통과' }
        'failed' { return '실패' }
        'skipped' { return '건너뜀' }
        default { return $Status }
    }
}

function Get-LocalizedSeverity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Severity
    )

    switch ($Severity) {
        'Blocker' { return '차단' }
        'Major' { return '주요' }
        'Minor' { return '경미' }
        'Suggestion' { return '제안' }
        default { return $Severity }
    }
}

function Get-LocalizedHumanGateReason {
    param(
        [AllowEmptyString()]
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return $Reason
    }

    $parts = @(
        ($Reason -split ';') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $localized = foreach ($part in $parts) {
        switch ($part) {
            'verification_failed' { 'verification 실행이 실패했습니다' }
            'verification_skipped_unsafely' { 'verification이 안전하지 않은 이유로 건너뛰어졌습니다' }
            'specialist_review_failed' { 'specialist review 실행이 실패했습니다' }
            'specialist_reviews_unavailable' { '사용 가능한 specialist review 결과가 없습니다' }
            'verification_or_review_failed' { 'verification 또는 review 실행이 실패했습니다' }
            'major_findings_present' { '주요 이슈가 남아 있습니다' }
            'merge_failed' { 'merge 단계가 실패했습니다' }
            'none' { '없음' }
            default { $part }
        }
    }

    return ($localized -join '; ')
}

function Get-ReviewerDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reviewer
    )

    switch ($Reviewer) {
        'dx12_lifetime_sync' { return 'dx12_lifetime_sync' }
        'regression_testing' { return 'regression_testing' }
        default { return $Reviewer }
    }
}

function Get-UniqueFindings {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Findings
    )

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = @()

    foreach ($finding in $Findings) {
        $key = "{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f `
            ([string]$finding.severity), `
            ([string]$finding.file), `
            ([string]$finding.title), `
            ([string]$finding.line_start), `
            ([string]$finding.line_end), `
            ([string]$finding.risk), `
            ([string]$finding.recommendation)

        if ($seen.Add($key)) {
            $unique += $finding
        }
    }

    return ,$unique
}

function Get-SpecialistExecutionStats {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SpecialistResults
    )

    $completedCount = @($SpecialistResults | Where-Object { $_.review_status -eq 'completed' }).Count
    $skippedCount = @($SpecialistResults | Where-Object { $_.review_status -eq 'skipped' }).Count
    $failedCount = @($SpecialistResults | Where-Object { $_.review_status -eq 'failed' }).Count

    return [pscustomobject]@{
        completed = $completedCount
        skipped   = $skippedCount
        failed    = $failedCount
        total     = @($SpecialistResults).Count
    }
}

function Get-VerificationSafety {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Verification
    )

    $skipIsSafe = $false
    if ($null -ne $Verification.PSObject.Properties['skip_is_safe']) {
        $skipIsSafe = [bool]$Verification.skip_is_safe
    }

    $status = [string]$Verification.verification_status
    return [pscustomobject]@{
        skip_is_safe  = $skipIsSafe
        unsafe_skip   = $status -eq 'skipped' -and -not $skipIsSafe
        failed        = $status -eq 'failed'
        reason        = [string]$Verification.verification_reason
    }
}

function Apply-FinalDecisionGuard {
    param(
        [Parameter(Mandatory = $true)]
        [object]$MergedReview,
        [Parameter(Mandatory = $true)]
        [object]$Verification,
        [Parameter(Mandatory = $true)]
        [object[]]$SpecialistResults,
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    $verificationSafety = Get-VerificationSafety -Verification $Verification
    $specialistStats = Get-SpecialistExecutionStats -SpecialistResults $SpecialistResults
    $isDocsOnlySafeSkip = @($Context.scope_tags) -contains 'docs_only' -and
        [string]$Verification.verification_status -eq 'skipped' -and
        $verificationSafety.skip_is_safe -and
        $specialistStats.completed -eq 0
    $guardReason = ''
    $targetDecision = ''

    if ($verificationSafety.failed) {
        $guardReason = 'verification_failed'
        $targetDecision = 'failed'
    }
    elseif ($verificationSafety.unsafe_skip) {
        $guardReason = 'verification_skipped_unsafely'
        $targetDecision = 'failed'
    }
    elseif ($specialistStats.failed -gt 0) {
        $guardReason = 'specialist_review_failed'
        $targetDecision = 'needs_human'
    }
    elseif ($specialistStats.completed -eq 0 -and -not $isDocsOnlySafeSkip) {
        $guardReason = 'specialist_reviews_unavailable'
        $targetDecision = 'needs_human'
    }

    if ([string]::IsNullOrWhiteSpace($guardReason)) {
        return $MergedReview
    }

    if ([string]$MergedReview.final_decision -ne 'failed' -and $targetDecision -eq 'failed') {
        $MergedReview.final_decision = 'failed'
        $MergedReview.risk_level = 'high'
    }
    elseif ([string]$MergedReview.final_decision -eq 'pass') {
        $MergedReview.final_decision = $targetDecision
        if ([string]$MergedReview.risk_level -eq 'low') {
            $MergedReview.risk_level = 'medium'
        }
    }

    $MergedReview.human_gate_required = $true
    $MergedReview.should_notify_slack = $true
    if ([string]::IsNullOrWhiteSpace([string]$MergedReview.human_gate_reason) -or [string]$MergedReview.human_gate_reason -eq 'none') {
        $MergedReview.human_gate_reason = $guardReason
    }
    elseif ([string]$MergedReview.human_gate_reason -notmatch [regex]::Escape($guardReason)) {
        $MergedReview.human_gate_reason = "$($MergedReview.human_gate_reason); $guardReason"
    }

    if ([string]$MergedReview.overall_assessment -notmatch 'Final guard') {
        $MergedReview.overall_assessment = "$($MergedReview.overall_assessment)`nFinal guard: $guardReason."
    }

    return $MergedReview
}

function Get-ContextOrchestrationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context
    )

    if ($null -ne $Context.PSObject.Properties['orchestration_plan']) {
        return $Context.orchestration_plan
    }

    return [pscustomobject]@{
        mode                   = 'legacy'
        allow_openai_moderator = $true
        moderator_policy       = 'always'
        reason                 = 'missing_orchestration_plan'
    }
}

function Test-ShouldUseOpenAiModerator {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [object]$Verification,
        [Parameter(Mandatory = $true)]
        [object[]]$SpecialistResults
    )

    $plan = Get-ContextOrchestrationPlan -Context $Context
    $verificationSafety = Get-VerificationSafety -Verification $Verification
    $specialistStats = Get-SpecialistExecutionStats -SpecialistResults $SpecialistResults

    if ($specialistStats.failed -gt 0 -or $verificationSafety.failed -or $verificationSafety.unsafe_skip) {
        return $true
    }

    $hasPartialDiff = $false
    if ($null -ne $Context.PSObject.Properties['diff_was_truncated']) {
        $hasPartialDiff = [bool]$Context.diff_was_truncated
    }
    elseif (
        $null -ne $plan.PSObject.Properties['reason'] -and
        ([string]$plan.reason -split ',') -contains 'partial_diff'
    ) {
        $hasPartialDiff = $true
    }

    if ($hasPartialDiff) {
        return $true
    }

    $allowOpenAiModerator = $true
    if ($null -ne $plan.PSObject.Properties['allow_openai_moderator']) {
        $allowOpenAiModerator = [bool]$plan.allow_openai_moderator
    }

    if (-not $allowOpenAiModerator) {
        return $false
    }

    $allFindings = @()
    foreach ($specialist in $SpecialistResults) {
        $allFindings += @($specialist.findings)
    }

    return (
        $allFindings.Count -gt 0
    )
}

function Get-DeterministicMergedResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Verification,
        [Parameter(Mandatory = $true)]
        [object[]]$SpecialistResults,
        [string]$ModeratorMode = 'deterministic',
        [string]$ModeratorFallbackReason = ''
    )

    $allFindings = @()
    foreach ($specialist in $SpecialistResults) {
        $allFindings += @($specialist.findings)
    }

    $uniqueFindings = Get-UniqueFindings -Findings $allFindings
    $blockerCount = @($uniqueFindings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($uniqueFindings | Where-Object { $_.severity -eq 'Major' }).Count
    $specialistStats = Get-SpecialistExecutionStats -SpecialistResults $SpecialistResults
    $hasFailedSpecialist = $specialistStats.failed -gt 0
    $verificationSafety = Get-VerificationSafety -Verification $Verification

    $humanGateRequired = $false
    $humanGateReason = ''
    $shouldNotifySlack = $false
    $finalDecision = 'pass'
    $riskLevel = 'low'

    if ($verificationSafety.failed -or $verificationSafety.unsafe_skip -or $hasFailedSpecialist) {
        $humanGateRequired = $true
        if ($verificationSafety.unsafe_skip) {
            $humanGateReason = 'verification_skipped_unsafely'
        }
        else {
            $humanGateReason = 'verification_or_review_failed'
        }
        $shouldNotifySlack = $true
        $finalDecision = 'failed'
        $riskLevel = 'high'
    }
    elseif ($blockerCount -gt 0 -or $majorCount -gt 0) {
        $humanGateRequired = $true
        $humanGateReason = 'major_findings_present'
        $shouldNotifySlack = $true
        $finalDecision = 'needs_human'
        if ($blockerCount -gt 0) {
            $riskLevel = 'high'
        }
        else {
            $riskLevel = 'medium'
        }
    }
    elseif ($uniqueFindings.Count -gt 0) {
        $riskLevel = 'medium'
    }

    $summary = ''
    if ($uniqueFindings.Count -eq 0) {
        $summary = 'specialist review와 verification 결과를 종합한 뒤 보고할 만한 주요 이슈를 찾지 못했습니다.'
    }
    else {
        $summary = "moderator가 specialist review 결과를 종합해 주요 이슈 $($uniqueFindings.Count)건을 정리했습니다."
    }

    $overallAssessment = ''
    switch ($finalDecision) {
        'failed' {
            if ($verificationSafety.unsafe_skip) {
                $overallAssessment = 'verification이 안전하지 않은 이유로 건너뛰어져 자동 판단을 신뢰하기 어렵습니다. 사람이 결과를 검토해야 합니다.'
            }
            else {
                $overallAssessment = '오케스트레이션 또는 verification 단계가 실패해 자동 판단을 신뢰하기 어렵습니다. 사람이 결과를 검토해야 합니다.'
            }
        }
        'needs_human' {
            $overallAssessment = '남아 있는 주요 이슈 또는 운영상 불확실성 때문에 사람이 최종 판단을 내려야 합니다.'
        }
        default {
            $overallAssessment = '현재 자동 리뷰와 verification gate 기준에서는 머지를 막을 만한 주요 문제를 확인하지 못했습니다.'
        }
    }

    return (New-MergedReviewResult `
        -Summary $summary `
        -OverallAssessment $overallAssessment `
        -RiskLevel $riskLevel `
        -Findings $uniqueFindings `
        -HumanGateRequired $humanGateRequired `
        -HumanGateReason $humanGateReason `
        -ShouldNotifySlack $shouldNotifySlack `
        -FinalDecision $finalDecision `
        -ReviewStatus 'completed' `
        -ModeratorMode $ModeratorMode `
        -ModeratorFallbackReason $ModeratorFallbackReason)
}

function Write-OrchestrationMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Context,
        [Parameter(Mandatory = $true)]
        [object]$MergedReview,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$SpecialistResults,
        [Parameter(Mandatory = $true)]
        [object]$Verification
    )

    $findings = @($MergedReview.findings)
    $blockerCount = @($findings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($findings | Where-Object { $_.severity -eq 'Major' }).Count
    $minorCount = @($findings | Where-Object { $_.severity -eq 'Minor' }).Count
    $suggestionCount = @($findings | Where-Object { $_.severity -eq 'Suggestion' }).Count
    $humanGateLabel = '불필요'
    if ($MergedReview.human_gate_required) {
        $humanGateLabel = '필요'
    }

    $localizedDecision = Get-LocalizedDecision -Decision ([string]$MergedReview.final_decision)
    $localizedRiskLevel = Get-LocalizedRiskLevel -RiskLevel ([string]$MergedReview.risk_level)
    $localizedVerificationStatus = Get-LocalizedVerificationStatus -Status ([string]$Verification.verification_status)
    $localizedHumanGateReason = Get-LocalizedHumanGateReason -Reason ([string]$MergedReview.human_gate_reason)
    $specialistStats = Get-SpecialistExecutionStats -SpecialistResults $SpecialistResults

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## AI Orchestration MVP')
    $lines.Add('')
    $lines.Add("- 기준 브랜치: $($Context.base_ref)")
    $lines.Add("- 작업 브랜치: $($Context.head_ref)")
    $lines.Add("- 최종 판단: $localizedDecision ($($MergedReview.final_decision))")
    $lines.Add("- 위험도: $localizedRiskLevel")
    $lines.Add("- Human Gate: $humanGateLabel")
    if (-not [string]::IsNullOrWhiteSpace($localizedHumanGateReason)) {
        $lines.Add("- Human Gate 사유: $localizedHumanGateReason")
    }
    $lines.Add("- Verification 상태: $localizedVerificationStatus")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- Verification 사유: $($Verification.verification_reason)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.moderator_mode)) {
        $lines.Add("- Moderator mode: $($MergedReview.moderator_mode)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.moderator_fallback_reason)) {
        $lines.Add("- Moderator fallback 사유: $($MergedReview.moderator_fallback_reason)")
    }
    if ($null -ne $Context.PSObject.Properties['orchestration_plan']) {
        $plan = $Context.orchestration_plan
        $lines.Add("- 오케스트레이션 모드: $($plan.mode)")
        $lines.Add("- Specialist 계획: dx12 $($plan.run_dx12_specialist) / regression $($plan.run_regression_specialist)")
        $lines.Add("- Moderator 정책: $($plan.moderator_policy)")
    }
    if ($null -ne $Context.PSObject.Properties['sensitive_content_masked'] -and [bool]$Context.sensitive_content_masked) {
        $maskedTypesLabel = ''
        if ($null -ne $Context.PSObject.Properties['masked_content_types'] -and @($Context.masked_content_types).Count -gt 0) {
            $maskedTypesLabel = " ($(@($Context.masked_content_types) -join ', '))"
        }
        $lines.Add("- 민감정보 마스킹: 적용됨$maskedTypesLabel")
    }
    $lines.Add("- Specialist 실행: completed $($specialistStats.completed) / skipped $($specialistStats.skipped) / failed $($specialistStats.failed)")
    $lines.Add("- 이슈 수: 차단 $blockerCount / 주요 $majorCount / 경미 $minorCount / 제안 $suggestionCount")
    $lines.Add('')
    $lines.Add('### 요약')
    $lines.Add([string]$MergedReview.summary)
    $lines.Add('')
    $lines.Add('### 종합 판단')
    $lines.Add([string]$MergedReview.overall_assessment)
    $lines.Add('')
    $lines.Add('### Specialist 리뷰 요약')
    $lines.Add("- 실행 요약: completed $($specialistStats.completed) / skipped $($specialistStats.skipped) / failed $($specialistStats.failed)")
    foreach ($specialist in $SpecialistResults) {
        $lines.Add("- $(Get-ReviewerDisplayName -Reviewer ([string]$specialist.reviewer)): $([string]$specialist.summary)")
    }
    $lines.Add('')
    $lines.Add('### Verification 결과')
    $lines.Add("- 상태: $localizedVerificationStatus")
    $lines.Add("- 요약: $($Verification.summary)")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- 사유: $($Verification.verification_reason)")
    }
    foreach ($check in @($Verification.checks)) {
        $checkStatus = Get-LocalizedVerificationStatus -Status ([string]$check.status)
        $lines.Add("- $($check.name): $checkStatus - $($check.note)")
        if ($null -ne $check.PSObject.Properties['exit_code']) {
            $lines.Add("  - Exit code: $($check.exit_code)")
        }
        if ($null -ne $check.PSObject.Properties['log_excerpt'] -and -not [string]::IsNullOrWhiteSpace([string]$check.log_excerpt)) {
            $lines.Add('  - 로그 발췌:')
            foreach ($line in @(([string]$check.log_excerpt) -split "\r?\n")) {
                $lines.Add("    $line")
            }
        }
    }
    $lines.Add('')
    $lines.Add('### 세부 이슈')

    if ($findings.Count -eq 0) {
        $lines.Add('- 보고된 주요 이슈가 없습니다.')
    }
    else {
        $index = 1
        foreach ($finding in $findings) {
            $location = [string]$finding.file
            if ([int]$finding.line_start -gt 0) {
                $location = "{0}:{1}" -f $location, $finding.line_start
            }

            $localizedSeverity = Get-LocalizedSeverity -Severity ([string]$finding.severity)
            $lines.Add("$index. [$localizedSeverity] $($finding.title)")
            $lines.Add("   - 위치: $location")
            $lines.Add("   - 위험: $($finding.risk)")
            $lines.Add("   - 권장 대응: $($finding.recommendation)")
            $lines.Add("   - 신뢰도: $($finding.confidence)")
            $index++
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Context.diff_note)) {
        $lines.Add('')
        $lines.Add("> $($Context.diff_note)")
    }

    $markdownText = $lines -join "`n"
    $maskedMarkdown = Protect-SensitiveText -Text $markdownText
    Set-Content -Path $Path -Value ([string]$maskedMarkdown.text) -Encoding utf8
}

try {
    $context = Read-JsonUtf8 -Path $reviewContextPath

    $specialistResults = @()
    foreach ($path in @($env:DX12_REVIEW_PATH, $env:REGRESSION_REVIEW_PATH)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$path) -and (Test-Path -LiteralPath $path)) {
            $specialistResults += Read-JsonUtf8 -Path $path
        }
    }

    if ($specialistResults.Count -eq 0) {
        throw 'merge 단계에서 사용할 specialist review 결과 파일을 찾지 못했습니다.'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:VERIFICATION_RESULT_PATH) -and (Test-Path -LiteralPath $env:VERIFICATION_RESULT_PATH)) {
        $verification = Read-JsonUtf8 -Path $env:VERIFICATION_RESULT_PATH
    }
    else {
        $verification = [pscustomobject]@{
            verification_status = 'failed'
            summary             = 'verification 결과 파일이 없어 현재 검증 상태를 신뢰할 수 없습니다.'
            verification_reason = 'missing_result'
            skip_is_safe        = $false
            checks              = @()
        }
    }

    $mergedReview = $null
    $shouldUseOpenAiModerator = Test-ShouldUseOpenAiModerator -Context $context -Verification $verification -SpecialistResults $specialistResults
    if (-not [string]::IsNullOrWhiteSpace([string]$env:OPENAI_API_KEY) -and $shouldUseOpenAiModerator) {
        try {
            $reviewerPayload = $specialistResults | ConvertTo-Json -Depth 100
            $verificationPayload = $verification | ConvertTo-Json -Depth 100

            $instructions = @(
                'You are the moderator for the dx12_Graphics AI orchestration MVP.'
                'Merge specialist findings, remove obvious duplicates, and produce a final decision.'
                'The final decision must be one of:'
                '- pass: no human gate is needed'
                '- needs_human: a person should make the final decision'
                '- failed: the orchestration or verification state is not trustworthy enough'
                'Prioritize correctness, DX12 safety, regression risk, and verification results over style comments.'
                'Only treat verification_status=skipped as acceptable when verification_reason=docs_only and skip_is_safe=true.'
                'If verification is skipped for any other reason, do not return pass.'
                'If every specialist review is skipped, do not return pass.'
                'If any specialist review failed, require a human gate.'
                'Write all user-facing prose in Korean.'
                'Write concise user-facing prose.'
                'Keep enum values exactly as specified in the schema.'
                'Return at most 8 findings.'
            ) -join "`n"

            $userPrompt = @(
                "Scope tags: $(@($context.scope_tags) -join ', ')"
                "Base branch: $($context.base_ref)"
                "Head branch: $($context.head_ref)"
                "PR title: $($context.pr_title)"
                ''
                'Specialist review results:'
                [string]$reviewerPayload
                ''
                'Verification result:'
                [string]$verificationPayload
            ) -join "`n"

            $schema = @{
                type                 = 'object'
                additionalProperties = $false
                properties           = @{
                    summary             = @{ type = 'string' }
                    overall_assessment  = @{ type = 'string' }
                    risk_level          = @{ type = 'string'; enum = @('low', 'medium', 'high', 'unknown') }
                    findings            = @{
                        type  = 'array'
                        items = @{
                            type                 = 'object'
                            additionalProperties = $false
                            properties           = @{
                                severity       = @{ type = 'string'; enum = @('Blocker', 'Major', 'Minor', 'Suggestion') }
                                title          = @{ type = 'string' }
                                file           = @{ type = 'string' }
                                line_start     = @{ type = 'integer'; minimum = 0 }
                                line_end       = @{ type = 'integer'; minimum = 0 }
                                risk           = @{ type = 'string' }
                                recommendation = @{ type = 'string' }
                                confidence     = @{ type = 'number'; minimum = 0; maximum = 1 }
                            }
                            required             = @('severity', 'title', 'file', 'line_start', 'line_end', 'risk', 'recommendation', 'confidence')
                        }
                    }
                    human_gate_required = @{ type = 'boolean' }
                    human_gate_reason   = @{ type = 'string' }
                    should_notify_slack = @{ type = 'boolean' }
                    final_decision      = @{ type = 'string'; enum = @('pass', 'needs_human', 'failed') }
                }
                required             = @('summary', 'overall_assessment', 'risk_level', 'findings', 'human_gate_required', 'human_gate_reason', 'should_notify_slack', 'final_decision')
            }

            $body = @{
                model        = if ([string]::IsNullOrWhiteSpace([string]$env:OPENAI_MODEL)) { 'gpt-5.4-mini' } else { [string]$env:OPENAI_MODEL }
                instructions = $instructions
                input        = $userPrompt
                reasoning    = @{
                    effort = 'low'
                }
                text         = @{
                    format = @{
                        type   = 'json_schema'
                        name   = 'merged_review'
                        strict = $true
                        schema = $schema
                    }
                }
            }

            $headers = @{
                Authorization = "Bearer $($env:OPENAI_API_KEY)"
                'Content-Type' = 'application/json'
            }

            $response = Invoke-OpenAIResponsesRequest -Headers $headers -Body $body -TimeoutSeconds 90
            $rawText = Get-ResponseText -Response $response
            if ([string]::IsNullOrWhiteSpace($rawText)) {
                throw 'OpenAI moderator response did not contain output_text content.'
            }

            $mergedReview = $rawText | ConvertFrom-Json
            $mergedReview | Add-Member -NotePropertyName review_status -NotePropertyValue 'completed' -Force
            $mergedReview | Add-Member -NotePropertyName moderator_mode -NotePropertyValue 'openai' -Force
            $mergedReview | Add-Member -NotePropertyName moderator_fallback_reason -NotePropertyValue '' -Force
        }
        catch {
            $fallbackReason = Get-OpenAIErrorDetail -Exception $_.Exception
            Write-Warning "OpenAI moderator 실행이 실패하여 deterministic fallback으로 대체합니다. 상세: $fallbackReason"
            $mergedReview = Get-DeterministicMergedResult `
                -Verification $verification `
                -SpecialistResults $specialistResults `
                -ModeratorMode 'deterministic_fallback' `
                -ModeratorFallbackReason $fallbackReason
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$env:OPENAI_API_KEY)) {
        $mergedReview = Get-DeterministicMergedResult `
            -Verification $verification `
            -SpecialistResults $specialistResults `
            -ModeratorMode 'deterministic_conditional_skip' `
            -ModeratorFallbackReason '조건부 오케스트레이션 정책에 따라 OpenAI moderator를 건너뛰었습니다.'
    }
    else {
        $mergedReview = Get-DeterministicMergedResult `
            -Verification $verification `
            -SpecialistResults $specialistResults `
            -ModeratorMode 'deterministic_no_api_key' `
            -ModeratorFallbackReason 'OPENAI_API_KEY가 설정되지 않았습니다.'
    }

    $mergedReview = Apply-FinalDecisionGuard -MergedReview $mergedReview -Verification $verification -SpecialistResults $specialistResults -Context $context

    Write-OrchestrationMarkdown -Path $commentPath -Context $context -MergedReview $mergedReview -SpecialistResults $specialistResults -Verification $verification
    Write-OrchestrationMarkdown -Path $summaryPath -Context $context -MergedReview $mergedReview -SpecialistResults $specialistResults -Verification $verification
    Write-JsonUtf8 -Path $mergedResultPath -Value $mergedReview

    $findings = @($mergedReview.findings)
    $blockerCount = @($findings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($findings | Where-Object { $_.severity -eq 'Major' }).Count
    $minorCount = @($findings | Where-Object { $_.severity -eq 'Minor' }).Count
    $suggestionCount = @($findings | Where-Object { $_.severity -eq 'Suggestion' }).Count

    Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
    Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
    Set-WorkflowOutput -Name 'merged_result_path' -Value $mergedResultPath
    Set-WorkflowOutput -Name 'review_status' -Value ([string]$mergedReview.review_status)
    Set-WorkflowOutput -Name 'blocker_count' -Value ([string]$blockerCount)
    Set-WorkflowOutput -Name 'major_count' -Value ([string]$majorCount)
    Set-WorkflowOutput -Name 'minor_count' -Value ([string]$minorCount)
    Set-WorkflowOutput -Name 'suggestion_count' -Value ([string]$suggestionCount)
    Set-WorkflowOutput -Name 'should_notify_slack' -Value (([bool]$mergedReview.should_notify_slack).ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'human_gate_required' -Value (([bool]$mergedReview.human_gate_required).ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'human_gate_reason' -Value ([string]$mergedReview.human_gate_reason)
    Set-WorkflowOutput -Name 'final_decision' -Value ([string]$mergedReview.final_decision)
    Set-WorkflowOutput -Name 'moderator_mode' -Value ([string]$mergedReview.moderator_mode)
    Set-WorkflowOutput -Name 'moderator_fallback_reason' -Value ([string]$mergedReview.moderator_fallback_reason)
}
catch {
    if (Test-Path -LiteralPath $reviewContextPath) {
        $context = Read-JsonUtf8 -Path $reviewContextPath
    }
    else {
        $context = [pscustomobject]@{
            base_ref  = [string]$env:AI_REVIEW_BASE_REF
            head_ref  = [string]$env:GITHUB_REF_NAME
            diff_note = ''
        }
    }

    $verification = [pscustomobject]@{
        verification_status = 'failed'
        summary             = 'merge 단계가 실패했으므로 verification 상태를 신뢰할 수 없습니다.'
        verification_reason = 'merge_failed'
        skip_is_safe        = $false
        checks              = @()
    }

    $mergedReview = New-MergedReviewResult `
        -Summary '오케스트레이션 merge 단계가 실패했습니다.' `
        -OverallAssessment ([string]$_.Exception.Message) `
        -RiskLevel 'unknown' `
        -Findings @() `
        -HumanGateRequired $true `
        -HumanGateReason 'merge_failed' `
        -ShouldNotifySlack $true `
        -FinalDecision 'failed' `
        -ReviewStatus 'failed' `
        -ModeratorMode 'merge_failed' `
        -ModeratorFallbackReason ([string]$_.Exception.Message)

    Write-OrchestrationMarkdown -Path $commentPath -Context $context -MergedReview $mergedReview -SpecialistResults @() -Verification $verification
    Write-OrchestrationMarkdown -Path $summaryPath -Context $context -MergedReview $mergedReview -SpecialistResults @() -Verification $verification
    Write-JsonUtf8 -Path $mergedResultPath -Value $mergedReview

    Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
    Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
    Set-WorkflowOutput -Name 'merged_result_path' -Value $mergedResultPath
    Set-WorkflowOutput -Name 'review_status' -Value 'failed'
    Set-WorkflowOutput -Name 'blocker_count' -Value '0'
    Set-WorkflowOutput -Name 'major_count' -Value '0'
    Set-WorkflowOutput -Name 'minor_count' -Value '0'
    Set-WorkflowOutput -Name 'suggestion_count' -Value '0'
    Set-WorkflowOutput -Name 'should_notify_slack' -Value 'true'
    Set-WorkflowOutput -Name 'human_gate_required' -Value 'true'
    Set-WorkflowOutput -Name 'human_gate_reason' -Value 'merge_failed'
    Set-WorkflowOutput -Name 'final_decision' -Value 'failed'
    Set-WorkflowOutput -Name 'moderator_mode' -Value 'merge_failed'
    Set-WorkflowOutput -Name 'moderator_fallback_reason' -Value ([string]$_.Exception.Message)
}
