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
        [string]$ReviewStatus
    )

    return [pscustomobject]@{
        summary             = $Summary
        overall_assessment  = $OverallAssessment
        risk_level          = $RiskLevel
        findings            = $Findings
        human_gate_required = $HumanGateRequired
        human_gate_reason   = $HumanGateReason
        should_notify_slack = $ShouldNotifySlack
        final_decision      = $FinalDecision
        review_status       = $ReviewStatus
    }
}

function Get-UniqueFindings {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Findings
    )

    $seen = New-Object System.Collections.Generic.HashSet[string]
    $unique = @()

    foreach ($finding in $Findings) {
        $key = "{0}|{1}|{2}|{3}|{4}" -f `
            ([string]$finding.severity), `
            ([string]$finding.file), `
            ([string]$finding.title), `
            ([string]$finding.line_start), `
            ([string]$finding.line_end)

        if ($seen.Add($key)) {
            $unique += $finding
        }
    }

    return ,$unique
}

function Get-DeterministicMergedResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Verification,
        [Parameter(Mandatory = $true)]
        [object[]]$SpecialistResults
    )

    $allFindings = @()
    foreach ($specialist in $SpecialistResults) {
        $allFindings += @($specialist.findings)
    }

    $uniqueFindings = Get-UniqueFindings -Findings $allFindings
    $blockerCount = @($uniqueFindings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($uniqueFindings | Where-Object { $_.severity -eq 'Major' }).Count
    $hasFailedSpecialist = @($SpecialistResults | Where-Object { $_.review_status -eq 'failed' }).Count -gt 0
    $verificationSkipIsSafe = $false
    if ($null -ne $Verification.PSObject.Properties['skip_is_safe']) {
        $verificationSkipIsSafe = [bool]$Verification.skip_is_safe
    }
    $verificationSkippedUnsafe = $Verification.verification_status -eq 'skipped' -and -not $verificationSkipIsSafe

    $humanGateRequired = $false
    $humanGateReason = ''
    $shouldNotifySlack = $false
    $finalDecision = 'pass'
    $riskLevel = 'low'

    if ($Verification.verification_status -eq 'failed' -or $verificationSkippedUnsafe -or $hasFailedSpecialist) {
        $humanGateRequired = $true
        if ($verificationSkippedUnsafe) {
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
        $summary = 'No material findings were reported after combining specialist reviews and verification.'
    }
    else {
        $summary = "The moderator collected $($uniqueFindings.Count) material findings from specialist reviews."
    }

    $overallAssessment = ''
    switch ($finalDecision) {
        'failed' {
            if ($verificationSkippedUnsafe) {
                $overallAssessment = 'Verification was skipped for an unsafe reason, so a person should review the result.'
            }
            else {
                $overallAssessment = 'The orchestration or verification stage failed, so a person should review the result.'
            }
        }
        'needs_human' {
            $overallAssessment = 'A person should make the final decision because major findings remain.'
        }
        default {
            $overallAssessment = 'The current automated review and verification gate passed without major issues.'
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
        -ReviewStatus 'completed')
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
    $humanGateLabel = "Not required"
    if ($MergedReview.human_gate_required) {
        $humanGateLabel = "Required"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("## AI Orchestration MVP")
    $lines.Add("")
    $lines.Add("- Base branch: $($Context.base_ref)")
    $lines.Add("- Head branch: $($Context.head_ref)")
    $lines.Add("- Final decision: $($MergedReview.final_decision)")
    $lines.Add("- Risk level: $($MergedReview.risk_level)")
    $lines.Add("- Human Gate: $humanGateLabel")
    if (-not [string]::IsNullOrWhiteSpace([string]$MergedReview.human_gate_reason)) {
        $lines.Add("- Human Gate reason: $($MergedReview.human_gate_reason)")
    }
    $lines.Add("- Verification status: $($Verification.verification_status)")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- Verification reason: $($Verification.verification_reason)")
    }
    $lines.Add("- Finding counts: blocker $blockerCount / major $majorCount / minor $minorCount / suggestion $suggestionCount")
    $lines.Add("")
    $lines.Add("### Summary")
    $lines.Add([string]$MergedReview.summary)
    $lines.Add("")
    $lines.Add("### Overall Assessment")
    $lines.Add([string]$MergedReview.overall_assessment)
    $lines.Add("")
    $lines.Add("### Specialist Review Summary")
    foreach ($specialist in $SpecialistResults) {
        $lines.Add("- $([string]$specialist.reviewer): $([string]$specialist.summary)")
    }
    $lines.Add("")
    $lines.Add("### Verification Result")
    $lines.Add("- Status: $($Verification.verification_status)")
    $lines.Add("- Summary: $($Verification.summary)")
    if (-not [string]::IsNullOrWhiteSpace([string]$Verification.verification_reason)) {
        $lines.Add("- Reason: $($Verification.verification_reason)")
    }
    foreach ($check in @($Verification.checks)) {
        $lines.Add("- $($check.name): $($check.status) - $($check.note)")
        if ($null -ne $check.PSObject.Properties['exit_code']) {
            $lines.Add("  - Exit code: $($check.exit_code)")
        }
        if ($null -ne $check.PSObject.Properties['log_excerpt'] -and -not [string]::IsNullOrWhiteSpace([string]$check.log_excerpt)) {
            $lines.Add("  - Log excerpt:")
            foreach ($line in @(([string]$check.log_excerpt) -split "\r?\n")) {
                $lines.Add("    $line")
            }
        }
    }
    $lines.Add("")
    $lines.Add("### Findings")

    if ($findings.Count -eq 0) {
        $lines.Add("- No material findings were reported.")
    }
    else {
        $index = 1
        foreach ($finding in $findings) {
            $location = [string]$finding.file
            if ([int]$finding.line_start -gt 0) {
                $location = "{0}:{1}" -f $location, $finding.line_start
            }

            $lines.Add("$index. [$([string]$finding.severity)] $($finding.title)")
            $lines.Add("   - Location: $location")
            $lines.Add("   - Risk: $($finding.risk)")
            $lines.Add("   - Recommendation: $($finding.recommendation)")
            $lines.Add("   - Confidence: $($finding.confidence)")
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
        throw 'No specialist review result files were found for merge.'
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$env:VERIFICATION_RESULT_PATH) -and (Test-Path -LiteralPath $env:VERIFICATION_RESULT_PATH)) {
        $verification = Read-JsonUtf8 -Path $env:VERIFICATION_RESULT_PATH
    }
    else {
        $verification = [pscustomobject]@{
            verification_status = 'failed'
            summary             = 'Verification result file was missing, so the verification state could not be trusted.'
            verification_reason = 'missing_result'
            skip_is_safe        = $false
            checks              = @()
        }
    }

    $mergedReview = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$env:OPENAI_API_KEY)) {
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
        }
        catch {
            $mergedReview = Get-DeterministicMergedResult -Verification $verification -SpecialistResults $specialistResults
        }
    }
    else {
        $mergedReview = Get-DeterministicMergedResult -Verification $verification -SpecialistResults $specialistResults
    }

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
        summary             = 'The merge stage failed, so the verification state should not be trusted.'
        verification_reason = 'merge_failed'
        skip_is_safe        = $false
        checks              = @()
    }

    $mergedReview = New-MergedReviewResult `
        -Summary 'The orchestration merge stage failed.' `
        -OverallAssessment ([string]$_.Exception.Message) `
        -RiskLevel 'unknown' `
        -Findings @() `
        -HumanGateRequired $true `
        -HumanGateReason 'merge_failed' `
        -ShouldNotifySlack $true `
        -FinalDecision 'failed' `
        -ReviewStatus 'failed'

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
}
