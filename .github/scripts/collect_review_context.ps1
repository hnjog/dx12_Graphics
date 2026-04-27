. "$PSScriptRoot\ai_orchestration_common.ps1"

$tempRoot = Get-TempRoot
$contextPath = Join-Path $tempRoot 'ai-orchestrator-review-context.json'

$baseRef = $env:AI_REVIEW_BASE_REF
if ([string]::IsNullOrWhiteSpace($baseRef)) {
    $baseRef = 'develop'
}

$event = $null
if ($env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH)) {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw -Encoding utf8 | ConvertFrom-Json
}

$pr = $null
if ($null -ne $event -and $null -ne $event.pull_request) {
    $pr = $event.pull_request
    if (-not [string]::IsNullOrWhiteSpace([string]$pr.base.ref)) {
        $baseRef = [string]$pr.base.ref
    }
}

$diffNote = ''

function Add-DiffNote {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Note
    )

    if ([string]::IsNullOrWhiteSpace($Note)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:diffNote)) {
        $script:diffNote = $Note
    }
    else {
        $script:diffNote = "$script:diffNote`n$Note"
    }
}

function Get-OptionalText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (Test-Path -LiteralPath $Path) {
        return (Get-Content -LiteralPath $Path -Raw -Encoding utf8)
    }

    return "[$Label was not found at $Path. Continue review with the available PR context.]"
}

function Test-GitRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    $null = git rev-parse --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

try {
    $reviewRules = Get-OptionalText -Path 'docs/review-rules.md' -Label 'review rules'
    $testingStrategy = Get-OptionalText -Path 'docs/testing-strategy.md' -Label 'testing strategy'
    $prTemplate = Get-OptionalText -Path '.github/pull_request_template.md' -Label 'pull request template'

    $baseRemoteRef = "origin/$baseRef"
    $fetchRefSpec = "+refs/heads/{0}:refs/remotes/origin/{0}" -f $baseRef
    $fetchOutput = git fetch --no-tags origin $fetchRefSpec 2>&1
    $fetchExitCode = $LASTEXITCODE
    if ($fetchExitCode -ne 0) {
        $fetchDetail = ([string](@($fetchOutput) -join "`n")).Trim()
        if ([string]::IsNullOrWhiteSpace($fetchDetail)) {
            $fetchDetail = "git fetch exited with code $fetchExitCode."
        }

        throw "Failed to refresh $baseRemoteRef for orchestration context. Stale local refs are not reused. $fetchDetail"
    }

    if (-not (Test-GitRef -Ref $baseRemoteRef)) {
        throw "Fetched base ref $baseRemoteRef could not be verified for orchestration context."
    }

    $mergeBaseOutput = git merge-base HEAD $baseRemoteRef
    $mergeBaseExitCode = $LASTEXITCODE
    $mergeBase = [string](@($mergeBaseOutput | Select-Object -First 1))
    if ($mergeBaseExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBase)) {
        $mergeBase = $baseRemoteRef
        Add-DiffNote -Note "merge-base를 안정적으로 계산하지 못해 $baseRemoteRef 기준 diff로 대체했습니다. 리뷰 결과는 실제 PR diff와 다를 수 있습니다."
    }

    $compareRange = "$mergeBase...HEAD"
    $changedFilesOutput = git diff --name-only $compareRange
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to collect changed files for compare range $compareRange."
    }

    $changedFiles = @($changedFilesOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $prTitle = if ($null -ne $pr) { [string]$pr.title } else { '' }
    $prBody = if ($null -ne $pr) { [string]$pr.body } else { '' }
    $prUrl = if ($null -ne $pr) { [string]$pr.html_url } else { '' }
    $headRef = if ($null -ne $pr) { [string]$pr.head.ref } else { [string]$env:GITHUB_REF_NAME }
    $scopeTags = Get-OrchestrationScopeTags -ChangedFiles $changedFiles
    $filePlans = Get-ReviewFilePlan -Paths $changedFiles
    $diffText = ''
    $changedFilesNote = ''
    $diffWasTruncated = $false
    $maskedContentTypes = @()
    $sensitiveContentMasked = $false

    if ($changedFiles.Count -gt 0) {
        $diffBundle = Get-BoundedDiffByFile -CompareRange $compareRange -FilePlans $filePlans -MaxLength 55000
        $diffText = [string]$diffBundle.text

        if ($diffBundle.remaining_file_count -gt 0) {
            $diffWasTruncated = $true
            Add-DiffNote -Note "오케스트레이션 입력 길이를 제한하기 위해 중요도가 높은 파일 순으로 diff를 구성했습니다. 포함 파일 수: $($diffBundle.included_file_count), 제외 파일 수: $($diffBundle.remaining_file_count), 마지막 절단 파일: $($diffBundle.truncated_file_path). 제외된 파일이 있으므로 specialist review는 부분 diff 기반 결과로 해석해야 합니다."
        }

        $changedFilesForPrompt = @($filePlans.path | Select-Object -First 80)
        if ($changedFiles.Count -gt $changedFilesForPrompt.Count) {
            $changedFilesNote = "Changed files list was sorted by review priority and truncated to the first $($changedFilesForPrompt.Count) of $($changedFiles.Count) entries. Diff text is bounded separately using the same priority order."
        }
    }
    else {
        $changedFilesForPrompt = @()
    }

    $maskedFragments = @(
        Protect-SensitiveText -Text $prTitle,
        Protect-SensitiveText -Text $prBody,
        Protect-SensitiveText -Text $diffText,
        Protect-SensitiveText -Text (Get-BoundedText -Text $reviewRules -MaxLength 4500 -Label 'review rules'),
        Protect-SensitiveText -Text (Get-BoundedText -Text $testingStrategy -MaxLength 3500 -Label 'testing strategy'),
        Protect-SensitiveText -Text (Get-BoundedText -Text $prTemplate -MaxLength 2000 -Label 'pull request template')
    )

    $prTitle = [string]$maskedFragments[0].text
    $prBody = [string]$maskedFragments[1].text
    $diffText = [string]$maskedFragments[2].text
    $reviewRulesForPrompt = [string]$maskedFragments[3].text
    $testingStrategyForPrompt = [string]$maskedFragments[4].text
    $prTemplateForPrompt = [string]$maskedFragments[5].text

    foreach ($fragment in $maskedFragments) {
        if ($fragment.has_sensitive_content) {
            $sensitiveContentMasked = $true
            $maskedContentTypes += @($fragment.labels)
        }
    }

    if ($sensitiveContentMasked) {
        $maskedContentTypes = @($maskedContentTypes | Select-Object -Unique)
        if ($scopeTags -notcontains 'sensitive_content_masked') {
            $scopeTags += 'sensitive_content_masked'
        }

        Add-DiffNote -Note "Potential sensitive strings were masked before PR context was sent to AI reviewers. Categories: $($maskedContentTypes -join ', ')."
    }

    $orchestrationPlan = Get-OrchestrationExecutionPlan `
        -ScopeTags $scopeTags `
        -ChangedFileCount $changedFiles.Count `
        -DiffWasTruncated $diffWasTruncated

    $context = [pscustomobject]@{
        repository               = [string]$env:GITHUB_REPOSITORY
        base_ref                 = $baseRef
        head_ref                 = $headRef
        pr_title                 = $prTitle
        pr_body                  = $prBody
        pr_url                   = $prUrl
        compare_range            = if ($changedFiles.Count -gt 0) { $compareRange } else { '' }
        merge_base               = [string]$mergeBase
        changed_files            = $changedFilesForPrompt
        changed_files_note       = $changedFilesNote
        scope_tags               = $scopeTags
        is_docs_only             = [bool]($scopeTags -contains 'docs_only')
        diff_was_truncated       = [bool]$diffWasTruncated
        sensitive_content_masked = [bool]$sensitiveContentMasked
        masked_content_types     = $maskedContentTypes
        orchestration_plan       = $orchestrationPlan
        diff_text                = $diffText
        diff_note                = $diffNote
        review_rules_excerpt     = $reviewRulesForPrompt
        testing_strategy_excerpt = $testingStrategyForPrompt
        pr_template_excerpt      = $prTemplateForPrompt
    }

    Write-JsonUtf8 -Path $contextPath -Value $context

    Set-WorkflowOutput -Name 'review_context_path' -Value $contextPath
    Set-WorkflowOutput -Name 'base_ref' -Value $baseRef
    Set-WorkflowOutput -Name 'changed_file_count' -Value ([string]$changedFiles.Count)
    Set-WorkflowOutput -Name 'docs_only' -Value ($context.is_docs_only.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'scope_tags' -Value (($scopeTags -join ','))
    Set-WorkflowOutput -Name 'sensitive_content_masked' -Value ($sensitiveContentMasked.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'orchestration_mode' -Value ([string]$orchestrationPlan.mode)
    Set-WorkflowOutput -Name 'run_dx12_specialist' -Value ($orchestrationPlan.run_dx12_specialist.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'run_regression_specialist' -Value ($orchestrationPlan.run_regression_specialist.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'allow_openai_moderator' -Value ($orchestrationPlan.allow_openai_moderator.ToString().ToLowerInvariant())
}
catch {
    $orchestrationPlan = Get-OrchestrationExecutionPlan `
        -ScopeTags @('context_collection_failed') `
        -ChangedFileCount 0

    $context = [pscustomobject]@{
        repository               = [string]$env:GITHUB_REPOSITORY
        base_ref                 = $baseRef
        head_ref                 = [string]$env:GITHUB_REF_NAME
        pr_title                 = ''
        pr_body                  = ''
        pr_url                   = ''
        compare_range            = ''
        merge_base               = ''
        changed_files            = @()
        changed_files_note       = ''
        scope_tags               = @('context_collection_failed')
        is_docs_only             = $false
        diff_was_truncated       = $false
        sensitive_content_masked = $false
        masked_content_types     = @()
        orchestration_plan       = $orchestrationPlan
        diff_text                = ''
        diff_note                = ''
        review_rules_excerpt     = ''
        testing_strategy_excerpt = ''
        pr_template_excerpt      = ''
        collection_error         = [string]$_.Exception.Message
    }

    Write-JsonUtf8 -Path $contextPath -Value $context

    Set-WorkflowOutput -Name 'review_context_path' -Value $contextPath
    Set-WorkflowOutput -Name 'base_ref' -Value $baseRef
    Set-WorkflowOutput -Name 'changed_file_count' -Value '0'
    Set-WorkflowOutput -Name 'docs_only' -Value 'false'
    Set-WorkflowOutput -Name 'scope_tags' -Value 'context_collection_failed'
    Set-WorkflowOutput -Name 'sensitive_content_masked' -Value 'false'
    Set-WorkflowOutput -Name 'orchestration_mode' -Value ([string]$orchestrationPlan.mode)
    Set-WorkflowOutput -Name 'run_dx12_specialist' -Value 'false'
    Set-WorkflowOutput -Name 'run_regression_specialist' -Value 'false'
    Set-WorkflowOutput -Name 'allow_openai_moderator' -Value 'false'
}
