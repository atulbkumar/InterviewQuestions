# PowerShell script to add, commit, and push the SpringBootPostgresKubeSidecar.md change
# Usage: Run in a PowerShell prompt on your machine.

$RepoPath = "c:\Interview Questions\Database"
$File = "SpringBootPostgresKubeSidecar.md"
$Message = "Add Spring Boot + Postgres sidecar guide"

Set-Location -Path $RepoPath

Write-Host "Repository path: $RepoPath"

# Check git available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Error "git is not installed or not in PATH. Install Git or ensure it's available in PATH."
  exit 1
}

# Ensure we're in a git repo
$gitStatus = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Error "Not inside a git repository at $RepoPath"
  exit 1
}

# Add file
git add -- "$File"
if ($LASTEXITCODE -ne 0) { Write-Error "git add failed"; exit 1 }

# Commit
git commit -m "$Message"
if ($LASTEXITCODE -ne 0) {
  Write-Warning "git commit exited with non-zero status. There may be nothing to commit or an error occurred."
} else {
  Write-Host "Committed: $Message"
}

# Push
Write-Host "Pushing to remote..."
git push
if ($LASTEXITCODE -ne 0) { Write-Error "git push failed"; exit 1 }

Write-Host "Done."