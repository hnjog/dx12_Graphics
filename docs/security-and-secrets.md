# Security and Secrets

## Purpose

This document defines the first-pass security rules for the AI review and AI orchestration workflows in `dx12_Graphics`.

The goal is not to build a full DLP system. The immediate goal is to reduce the chance that obvious secrets or sensitive strings are sent to external services during automated review.

## Secrets Currently Used

- `OPENAI_API_KEY`
  - Required for AI Review and AI Orchestration OpenAI calls
  - Stored as a GitHub Actions secret
- `SLACK_WEBHOOK_URL`
  - Optional
  - Used only when Slack notification is enabled
  - Stored as a GitHub Actions secret
- `GITHUB_TOKEN`
  - Provided by GitHub Actions
  - Used for PR comment update operations with scoped workflow permissions

## What Leaves the Repository

The current review workflows may send the following data to OpenAI:

- PR title
- PR body
- changed file list
- bounded unified diff
- excerpts from:
  - `docs/review-rules.md`
  - `docs/testing-strategy.md`
  - `.github/pull_request_template.md` (orchestration path)

The current workflows may send the following summary data to Slack:

- review status
- risk level
- finding counts
- short summary text
- PR link

## Current Safeguards

### 1. GitHub Secrets

- OpenAI and Slack credentials are not committed into the repository.
- They are injected only through GitHub Actions secrets.

### 2. Narrow Workflow Permissions

- workflows use scoped permissions instead of broad write access
- current permissions are limited to:
  - `contents: read`
  - `issues: write`
  - `pull-requests: write`

### 3. First-pass Sensitive Text Masking

Before PR content is sent to OpenAI, the workflows now try to mask obvious sensitive-looking strings.

Current first-pass masking includes:

- Slack webhook URLs
- OpenAI-style API keys
- GitHub personal access tokens
- Slack tokens
- AWS access key IDs
- `Bearer ...` style tokens
- private key blocks
- obvious inline credential assignments such as:
  - `password=...`
  - `token: ...`
  - `secret = ...`
  - `api_key = ...`

### 4. Slack Summary-Only Pattern

- Slack messages are intended to stay high-level.
- Detailed diff content is not posted directly to Slack.

## Operator Rules

The following content should not be placed into PR titles, PR bodies, or committed diffs:

- real API keys
- webhook URLs
- bearer tokens
- passwords or shared secrets
- private keys or certificates
- production credentials
- customer PII
- private internal operational data that should not leave the repository

Even with masking enabled, the safest rule is still:

> Do not put secrets into the PR in the first place.

## Known Limitations

- Masking is heuristic, not guaranteed.
- False positives are possible.
- False negatives are possible.
- File names are not currently redacted.
- Review results may still describe sensitive code areas at a high level.
- This is not a replacement for secret scanning, credential hygiene, or incident response.

## Recommended Next Steps

1. Add representative tests for masked and unmasked review inputs
2. Consider human-gate escalation when sensitive content is detected
3. Consider reducing Slack detail even further for high-risk repositories
4. Add repository secret scanning if the project starts handling more operational credentials
