# ============================================================================
# Windows PowerShell 5.1 解析检查
# ----------------------------------------------------------------------------
#   powershell -NoProfile -File "工具\检查5.1解析.ps1"      # 真正的 5.1（CI 用这个）
#   pwsh       -NoProfile -File "工具\检查5.1解析.ps1"      # 会**故意失败**，见下
#
# 退出码：0 = 全部能解析；>0 = 解析失败的脚本数；3 = 用错了宿主（不是 5.1，等于没验）
#
# 为什么单列一关：$ShellExe 特意写了「优先 pwsh，没有就退回 Windows PowerShell 5.1」，
# 但 CI 上只在 Linux + pwsh 7 跑过 —— 这条回退的宣称从没被实测过。
#
# ⚠️ 为什么必须是「一个带 BOM 的脚本」，而不是把逻辑写进 workflow 的 run: 块：
#   GitHub 把 run: 块写成 **UTF-8 无 BOM**，而 5.1 对无 BOM 的脚本按 ANSI 解码 ——
#   中文变乱码，连字符串的结束引号都会被吃掉，整个步骤直接语法错。实测报错就是
#   `The string is missing the terminator: "`。仓库里的 .ps1 都带 BOM（第 5 关守着），
#   5.1 能正确读。所以 5.1 的步骤只应「启动 5.1 + 指向本脚本」，run: 块里不要写中文。
#   这条规矩由 工具/关卡-仓库卫生.ps1 自动检查。
#
# ⚠️ 为什么用 pwsh 跑要故意失败：本会话就犯过这个错 —— 在 pwsh 7 里调
#   [Language.Parser]::ParseFile 以为在验 5.1，其实用的是 7 的解析器，等于没验。
#   宁可报错，也不要给出一个「看起来验过了」的假结论。
# ============================================================================
param([switch]$AllowAnyHost)

$ErrorActionPreference = 'Continue'

$major = $PSVersionTable.PSVersion.Major
Write-Host ""
Write-Host ("===== 解析检查 · 宿主 PowerShell {0} =====" -f $PSVersionTable.PSVersion) -ForegroundColor Cyan
Write-Host ""

if ($major -ge 6 -and -not $AllowAnyHost) {
  Write-Host "  用错了宿主：本脚本的意义是**用 5.1 的解析器**检查，而不是用当前这个。" -ForegroundColor Red
  Write-Host "  在 pwsh 7 里跑得到的结果对 5.1 毫无意义（本会话踩过这个坑）。" -ForegroundColor Red
  Write-Host "  正确用法：powershell -NoProfile -File `"工具\检查5.1解析.ps1`"" -ForegroundColor Yellow
  Write-Host ""
  exit 3
}

$Root = Split-Path $PSScriptRoot -Parent
$files = @(Get-ChildItem (Join-Path $Root '工具') -Filter *.ps1 | Sort-Object Name)
$bad = 0
foreach ($f in $files) {
  $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) {
    Write-Host ("  FAIL  {0}" -f $f.Name) -ForegroundColor Red
    $errs | Select-Object -First 3 | ForEach-Object {
      Write-Host ("        L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
    }
    $bad++
  } else {
    Write-Host ("  PASS  {0}" -f $f.Name)
  }
}

Write-Host ""
if ($bad -eq 0) {
  Write-Host ("结论：{0} 个脚本全部能解析（宿主 PS {1}）" -f $files.Count, $PSVersionTable.PSVersion) -ForegroundColor Green
  Write-Host ""
  exit 0
} else {
  Write-Host ("结论：{0} 个脚本解析失败" -f $bad) -ForegroundColor Red
  Write-Host ""
  exit $bad
}
