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

try {
    $reviewRules = Get-Content -LiteralPath 'docs/review-rules.md' -Raw -Encoding utf8
    $testingStrategy = Get-Content -LiteralPath 'docs/testing-strategy.md' -Raw -Encoding utf8
    $prTemplate = Get-Content -LiteralPath '.github/pull_request_template.md' -Raw -Encoding utf8

    $null = git fetch --no-tags --depth=1 origin $baseRef
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch origin/$baseRef for orchestration context."
    }

    $compareRange = "origin/$baseRef...HEAD"
    $changedFiles = @(git diff --name-only $compareRange)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to collect changed files for compare range $compareRange."
    }

    $prTitle = if ($null -ne $pr) { [string]$pr.title } else { '' }
    $prBody = if ($null -ne $pr) { [string]$pr.body } else { '' }
    $prUrl = if ($null -ne $pr) { [string]$pr.html_url } else { '' }
    $headRef = if ($null -ne $pr) { [string]$pr.head.ref } else { [string]$env:GITHUB_REF_NAME }
    $scopeTags = Get-OrchestrationScopeTags -ChangedFiles $changedFiles
    $filePlans = Get-ReviewFilePlan -Paths $changedFiles
    $diffText = ''
    $changedFilesNote = ''

    if ($changedFiles.Count -gt 0) {
        $diffBundle = Get-BoundedDiffByFile -CompareRange $compareRange -FilePlans $filePlans -MaxLength 55000
        $diffText = [string]$diffBundle.text

        if ($diffBundle.remaining_file_count -gt 0) {
            $diffNote = "오케스트레이션 입력 길이를 제한하기 위해 중요도가 높은 파일 순으로 diff를 구성했습니다. 포함 파일 수: $($diffBundle.included_file_count), 제외 파일 수: $($diffBundle.remaining_file_count), 마지막 절단 파일: $($diffBundle.truncated_file_path)"
        }

        $changedFilesForPrompt = @($filePlans.path | Select-Object -First 80)
        if ($changedFiles.Count -gt $changedFilesForPrompt.Count) {
            $changedFilesNote = "Changed files list was sorted by review priority and truncated to the first $($changedFilesForPrompt.Count) entries."
        }
    }

    $context = [pscustomobject]@{
        repository               = [string]$env:GITHUB_REPOSITORY
        base_ref                 = $baseRef
        head_ref                 = $headRef
        pr_title                 = $prTitle
        pr_body                  = $prBody
        pr_url                   = $prUrl
        compare_range            = if ($changedFiles.Count -gt 0) { $compareRange } else { '' }
        changed_files            = $changedFiles
        changed_files_note       = $changedFilesNote
        scope_tags               = $scopeTags
        is_docs_only             = [bool]($scopeTags -contains 'docs_only')
        diff_text                = $diffText
        diff_note                = $diffNote
        review_rules_excerpt     = Get-BoundedText -Text $reviewRules -MaxLength 4500 -Label 'review rules'
        testing_strategy_excerpt = Get-BoundedText -Text $testingStrategy -MaxLength 3500 -Label 'testing strategy'
        pr_template_excerpt      = Get-BoundedText -Text $prTemplate -MaxLength 2000 -Label 'pull request template'
    }

    Write-JsonUtf8 -Path $contextPath -Value $context

    Set-WorkflowOutput -Name 'review_context_path' -Value $contextPath
    Set-WorkflowOutput -Name 'base_ref' -Value $baseRef
    Set-WorkflowOutput -Name 'changed_file_count' -Value ([string]$changedFiles.Count)
    Set-WorkflowOutput -Name 'docs_only' -Value ($context.is_docs_only.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'scope_tags' -Value (($scopeTags -join ','))
}
catch {
    $context = [pscustomobject]@{
        repository               = [string]$env:GITHUB_REPOSITORY
        base_ref                 = $baseRef
        head_ref                 = [string]$env:GITHUB_REF_NAME
        pr_title                 = ''
        pr_body                  = ''
        pr_url                   = ''
        compare_range            = ''
        changed_files            = @()
        changed_files_note       = ''
        scope_tags               = @('context_collection_failed')
        is_docs_only             = $false
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
}
