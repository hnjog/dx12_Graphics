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
        'low' { return '??쓬' }
        'medium' { return '蹂댄넻' }
        'high' { return '?믪쓬' }
        'unknown' { return '?????놁쓬' }
        default { return $RiskLevel }
    }
}

function Get-LocalizedDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Decision
    )

    switch ($Decision) {
        'pass' { return '?듦낵' }
        'needs_human' { return '?щ엺 寃???꾩슂' }
        'failed' { return '?ㅽ뙣' }
        default { return $Decision }
    }
}

function Get-LocalizedVerificationStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    switch ($Status) {
        'passed' { return '?듦낵' }
        'failed' { return '?ㅽ뙣' }
        'skipped' { return '嫄대꼫?' }
        default { return $Status }
    }
}

function Get-LocalizedSeverity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Severity
    )

    switch ($Severity) {
        'Blocker' { return '李⑤떒' }
        'Major' { return '二쇱슂' }
        'Minor' { return '寃쎈?' }
        'Suggestion' { return '?쒖븞' }
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
            'verification_failed' { 'verification ?ㅽ뻾???ㅽ뙣?덉뒿?덈떎' }
            'verification_skipped_unsafely' { 'verification???덉쟾?섏? ?딆? ?댁쑀濡?嫄대꼫?곗뼱議뚯뒿?덈떎' }
            'specialist_review_failed' { 'specialist review ?ㅽ뻾???ㅽ뙣?덉뒿?덈떎' }
            'specialist_reviews_unavailable' { '?ъ슜 媛?ν븳 specialist review 寃곌낵媛 ?놁뒿?덈떎' }
            'verification_or_review_failed' { 'verification ?먮뒗 review ?ㅽ뻾???ㅽ뙣?덉뒿?덈떎' }
            'major_findings_present' { '二쇱슂 ?댁뒋媛 ?⑥븘 ?덉뒿?덈떎' }
            'merge_failed' { 'merge ?④퀎媛 ?ㅽ뙣?덉뒿?덈떎' }
            'none' { '?놁쓬' }
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
        $summary = 'specialist review? verification 寃곌낵瑜?醫낇빀????蹂닿퀬??留뚰븳 二쇱슂 ?댁뒋瑜?李얠? 紐삵뻽?듬땲??'
    }
    else {
        $summary = "moderator媛 specialist review 寃곌낵瑜?醫낇빀??二쇱슂 ?댁뒋 $($uniqueFindings.Count)嫄댁쓣 ?뺣━?덉뒿?덈떎."
    }

    $overallAssessment = ''
    switch ($finalDecision) {
        'failed' {
            if ($verificationSafety.unsafe_skip) {
                $overallAssessment = 'verification???덉쟾?섏? ?딆? ?댁쑀濡?嫄대꼫?곗뼱???먮룞 ?먮떒???좊ː?섍린 ?대졄?듬땲?? ?щ엺??寃곌낵瑜?寃?좏빐???⑸땲??'
            }
            else {
                $overallAssessment = '?ㅼ??ㅽ듃?덉씠???먮뒗 verification ?④퀎媛 ?ㅽ뙣???먮룞 ?먮떒???좊ː?섍린 ?대졄?듬땲?? ?щ엺??寃곌낵瑜?寃?좏빐???⑸땲??'
            }
        }
        'needs_human' {
            $overallAssessment = '?⑥븘 ?덈뒗 二쇱슂 ?댁뒋 ?먮뒗 ?댁쁺??遺덊솗?ㅼ꽦 ?뚮Ц???щ엺??理쒖쥌 ?먮떒???대젮???⑸땲??'
        }
        default {
            $overallAssessment = '?꾩옱 ?먮룞 由щ럭? verification gate 湲곗??먯꽌??癒몄?瑜?留됱쓣 留뚰븳 二쇱슂 臾몄젣瑜??뺤씤?섏? 紐삵뻽?듬땲??'
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
    $humanGateLabel = "불필요"
    if ($MergedReview.human_gate_required) {
        $humanGateLabel = "필요"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("## AI Orchestration MVP")
    $lines.Add("")
    $lines.Add("- 湲곗? 釉뚮옖移? $($Context.base_ref)")
    $lines.Add("- ?묒뾽 釉뚮옖移? $($Context.head_ref)")
    $lines.Add("- 理쒖쥌 ?먮떒: $([string](Get-LocalizedDecision -Decision ([string]$MergedReview.final_decision))) ($($MergedReview.final_decision))")
    $lines.Add("- ?꾪뿕?? $([string](Get-LocalizedRiskLevel -RiskLevel ([string]$MergedReview.risk_level)))")
    $lines.Add("- Human Gate: $humanGateLabel")
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.human_gate_reason)) {
        $lines.Add("- Human Gate ?ъ쑀: $(Get-LocalizedHumanGateReason -Reason ([string]$MergedReview.human_gate_reason))")
    }
    $lines.Add("- Verification ?곹깭: $([string](Get-LocalizedVerificationStatus -Status ([string]$Verification.verification_status)))")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- Verification ?ъ쑀: $($Verification.verification_reason)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.moderator_mode)) {
        $lines.Add("- Moderator mode: $($MergedReview.moderator_mode)")
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.moderator_fallback_reason)) {
        $lines.Add("- Moderator fallback ?ъ쑀: $($MergedReview.moderator_fallback_reason)")
    }
    if ($null -ne $Context.PSObject.Properties['orchestration_plan']) {
        $plan = $Context.orchestration_plan
        $lines.Add("- ?ㅼ??ㅽ듃?덉씠??紐⑤뱶: $($plan.mode)")
        $lines.Add("- Specialist 怨꾪쉷: dx12 $($plan.run_dx12_specialist) / regression $($plan.run_regression_specialist)")
        $lines.Add("- Moderator ?뺤콉: $($plan.moderator_policy)")
    }
    if ($null -ne $Context.PSObject.Properties['sensitive_content_masked'] -and [bool]$Context.sensitive_content_masked) {
        $maskedTypesLabel = ''
        if ($null -ne $Context.PSObject.Properties['masked_content_types'] -and @($Context.masked_content_types).Count -gt 0) {
            $maskedTypesLabel = " ($(@($Context.masked_content_types) -join ', '))"
        }
        $lines.Add("- 민감정보 마스킹: 적용됨$maskedTypesLabel")
    }
    $specialistStats = Get-SpecialistExecutionStats -SpecialistResults $SpecialistResults
    $lines.Add("- Specialist ?ㅽ뻾: completed $($specialistStats.completed) / skipped $($specialistStats.skipped) / failed $($specialistStats.failed)")
    $lines.Add("- ?댁뒋 ?? 李⑤떒 $blockerCount / 二쇱슂 $majorCount / 寃쎈? $minorCount / ?쒖븞 $suggestionCount")
    $lines.Add("")
    $lines.Add("### ?붿빟")
    $lines.Add([string]$MergedReview.summary)
    $lines.Add("")
    $lines.Add("### 醫낇빀 ?먮떒")
    $lines.Add([string]$MergedReview.overall_assessment)
    $lines.Add("")
    $lines.Add("### Specialist 由щ럭 ?붿빟")
    $lines.Add("- ?ㅽ뻾 ?붿빟: completed $($specialistStats.completed) / skipped $($specialistStats.skipped) / failed $($specialistStats.failed)")
    foreach ($specialist in $SpecialistResults) {
        $lines.Add("- $(Get-ReviewerDisplayName -Reviewer ([string]$specialist.reviewer)): $([string]$specialist.summary)")
    }
    $lines.Add("")
    $lines.Add("### Verification 寃곌낵")
    $lines.Add("- ?곹깭: $([string](Get-LocalizedVerificationStatus -Status ([string]$Verification.verification_status)))")
    $lines.Add("- ?붿빟: $($Verification.summary)")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- ?ъ쑀: $($Verification.verification_reason)")
    }
    foreach ($check in @($Verification.checks)) {
        $lines.Add("- $($check.name): $([string](Get-LocalizedVerificationStatus -Status ([string]$check.status))) - $($check.note)")
        if ($null -ne $check.PSObject.Properties['exit_code']) {
            $lines.Add("  - Exit code: $($check.exit_code)")
        }
        if ($null -ne $check.PSObject.Properties['log_excerpt'] -and -not [string]::IsNullOrWhiteSpace([string]$check.log_excerpt)) {
            $lines.Add("  - 濡쒓렇 諛쒖톸:")
            foreach ($line in @(([string]$check.log_excerpt) -split "\r?\n")) {
                $lines.Add("    $line")
            }
        }
    }
    $lines.Add("")
    $lines.Add("### ?몃? ?댁뒋")

    if ($findings.Count -eq 0) {
        $lines.Add("- 蹂닿퀬??二쇱슂 ?댁뒋媛 ?놁뒿?덈떎.")
    }
    else {
        $index = 1
        foreach ($finding in $findings) {
            $location = [string]$finding.file
            if ([int]$finding.line_start -gt 0) {
                $location = "{0}:{1}" -f $location, $finding.line_start
            }

            $lines.Add("$index. [$(Get-LocalizedSeverity -Severity ([string]$finding.severity))] $($finding.title)")
            $lines.Add("   - ?꾩튂: $location")
            $lines.Add("   - ?꾪뿕: $($finding.risk)")
            $lines.Add("   - 沅뚯옣 ??? $($finding.recommendation)")
            $lines.Add("   - ?좊ː?? $($finding.confidence)")
            $index++
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Context.diff_note)) {
        $lines.Add("")
        $lines.Add("> $($Context.diff_note)")
    }

    Set-Content -Path $Path -Value ($lines -join "`n") -Encoding utf8
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
        throw 'merge ?④퀎?먯꽌 ?ъ슜??specialist review 寃곌낵 ?뚯씪??李얠? 紐삵뻽?듬땲??'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:VERIFICATION_RESULT_PATH) -and (Test-Path -LiteralPath $env:VERIFICATION_RESULT_PATH)) {
        $verification = Read-JsonUtf8 -Path $env:VERIFICATION_RESULT_PATH
    }
    else {
        $verification = [pscustomobject]@{
            verification_status = 'failed'
            summary             = 'verification 寃곌낵 ?뚯씪???놁뼱 ?꾩옱 寃利??곹깭瑜??좊ː?????놁뒿?덈떎.'
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
            Write-Warning "OpenAI moderator ?ㅽ뻾???ㅽ뙣?섏뿬 deterministic fallback?쇰줈 ?泥댄빀?덈떎. ?곸꽭: $fallbackReason"
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
            -ModeratorFallbackReason '議곌굔遺 ?ㅼ??ㅽ듃?덉씠???뺤콉???곕씪 OpenAI moderator瑜?嫄대꼫?곗뿀?듬땲??'
    }
    else {
        $mergedReview = Get-DeterministicMergedResult `
            -Verification $verification `
            -SpecialistResults $specialistResults `
            -ModeratorMode 'deterministic_no_api_key' `
            -ModeratorFallbackReason 'OPENAI_API_KEY媛 ?ㅼ젙?섏? ?딆븯?듬땲??'
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
        summary             = 'merge ?④퀎媛 ?ㅽ뙣?덉쑝誘濡?verification ?곹깭瑜??좊ː?????놁뒿?덈떎.'
        verification_reason = 'merge_failed'
        skip_is_safe        = $false
        checks              = @()
    }

    $mergedReview = New-MergedReviewResult `
        -Summary '?ㅼ??ㅽ듃?덉씠??merge ?④퀎媛 ?ㅽ뙣?덉뒿?덈떎.' `
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
