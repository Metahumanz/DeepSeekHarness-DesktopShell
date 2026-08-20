$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$releaseYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github/workflows/release.yml'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 发布冻结：发布前显式检查 Release 已存在则直接失败 ----
Assert-True "publish job checks gh release view" ($releaseYml.Contains('gh release view "$tag"'))
Assert-True "existing release fails with explicit message" ($releaseYml -match '已存在，禁止覆盖，请增加版本号')
Assert-True "guard step named" ($releaseYml -match 'Refuse to overwrite existing release')
Assert-True "guard runs before creating release" (($releaseYml.IndexOf('Refuse to overwrite existing release') -gt 0) -and ($releaseYml.IndexOf('Create GitHub Release') -gt $releaseYml.IndexOf('Refuse to overwrite existing release')))
Assert-True "no delete-existing-release step anywhere" ($releaseYml -notmatch 'delete_release|delete-existing')
Assert-True "softprops still used for creation only" ($releaseYml -match 'softprops/action-gh-release')

# ---- 2. 已发布 tag 不可改写：必须存在且是当前 HEAD 祖先 ----
$frozenTags = @('v1.0.0', 'v1.0.1', 'v1.0.2', 'v1.0.3', 'v1.0.4')
foreach ($tag in $frozenTags) {
    git -C $repo rev-parse -q --verify "refs/tags/$tag" | Out-Null
    Assert-True "$tag tag still exists" ($LASTEXITCODE -eq 0)
    git -C $repo merge-base --is-ancestor "refs/tags/$tag" HEAD
    Assert-True "$tag commit is ancestor of current HEAD" ($LASTEXITCODE -eq 0)
}

if ($fail -eq 0) { Write-Host 'RELEASE IMMUTABLE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
