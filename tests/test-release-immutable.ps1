$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$releaseYml = [System.IO.File]::ReadAllText((Join-Path $repo '.github\workflows\release.yml'))

$fail = 0
function Assert-True([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "PASS: $label" }
    else { $script:fail++; Write-Host "FAIL: $label" }
}

# ---- 1. 发布冻结：发布前显式检查 Release 已存在则直接失败 ----
Assert-True "publish job checks gh release view" ($releaseYml -match 'gh release view "\$tag"')
Assert-True "existing release fails with explicit message" ($releaseYml -match '已存在，禁止覆盖，请增加版本号')
Assert-True "guard step named" ($releaseYml -match 'Refuse to overwrite existing release')
Assert-True "guard runs before creating release" (($releaseYml.IndexOf('Refuse to overwrite existing release') -gt 0) -and ($releaseYml.IndexOf('Create GitHub Release') -gt $releaseYml.IndexOf('Refuse to overwrite existing release')))
Assert-True "no delete-existing-release step anywhere" ($releaseYml -notmatch 'delete_release|delete-existing|delete_release')
Assert-True "softprops still used for creation only" ($releaseYml -match 'softprops/action-gh-release')

# ---- 2. 既有 tag 必须仍在本地仓库（v1.0.0 / v1.0.1 冻结不动） ----
git -C $repo rev-parse -q --verify refs/tags/v1.0.0 | Out-Null
$v100ok = $LASTEXITCODE -eq 0
git -C $repo rev-parse -q --verify refs/tags/v1.0.1 | Out-Null
$v101ok = $LASTEXITCODE -eq 0
Assert-True "v1.0.0 tag still exists" $v100ok
Assert-True "v1.0.1 tag still exists" $v101ok

# v1.0.1 的合并提交（be90cf8）必须是当前分支祖先：说明后续修复没有改写 v1.0.1 历史
git -C $repo merge-base --is-ancestor be90cf8 HEAD
Assert-True "v1.0.1 merge commit is ancestor of current branch" ($LASTEXITCODE -eq 0)

if ($fail -eq 0) { Write-Host 'RELEASE IMMUTABLE TESTS PASSED' } else { Write-Host "FAILURES: $fail" }
exit $(if ($fail -eq 0) { 0 } else { 1 })
