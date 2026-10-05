# ============================================================================
# 官方实测值 · 复核 / 重算
# ----------------------------------------------------------------------------
# 用途：`工具/官方实测值.ps1` 里的每个数字都应当能从「官方背景截图」里那张图重算出来。
# 这个脚本就做这件事 —— **把「数字对不对」从人工核对换成机器核对**。
#
#   pwsh -File "工具\采样官方纹理.ps1"          # 复核：图与数字是否仍然一致
#   pwsh -File "工具\采样官方纹理.ps1" -Write   # 重算并覆盖 官方实测值.ps1
#
# 退出码：0 = 全部一致；>0 = 不一致的条目数
#
# 采样法和 工具/像素验证.ps1 用的**完全同一套**（左侧页边三段，避开正文）：
#   y 5-15% / 45-55% / 85-95%，x 1.2-5.5%，取该区域平均色再折算亮度 luma。
#   月亮盒：x 84-92%，y 5-9%（不从 y 0 起算 —— 顶部是站点导航栏，搜索图标压在月亮位置上）。
#
# ⚠️ 官方截图不在仓库里（腾讯内容 + 27 MB，见 .gitignore），所以本脚本只能在
#    「手上有截图」的机器上跑（也就是维护者本机）。仓库里能自动核对的是
#    「用例覆盖是否齐全」，见 工具/像素验证.ps1 里的覆盖自检。
#
# 映射（哪张图对应哪一组）是**一次性建立并冻结**的事实：官方截图文件名是微信时间戳，
# 不含任何颜色/纹理信息。当初建立方式：用当时（手写）的期望值去 40 张图里做
# 一对一最近邻匹配 —— 15 组全部匹配到**互不相同**的图，误差 0~3，三组「月」的
# 月亮抬升还正好等于手写的 moonRef（37/25/20）。所以这个映射是可信的，之后只需复核。
# ============================================================================
param(
  [string]$Root = (Split-Path $PSScriptRoot -Parent),
  [string]$Dir = '官方背景截图',
  [switch]$Write
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

$dataFile = Join-Path $PSScriptRoot '官方实测值.ps1'
if (-not (Test-Path $dataFile)) { Write-Host "找不到 $dataFile" -ForegroundColor Red; exit 1 }
. $dataFile

$imgDir = Join-Path $Root $Dir
if (-not (Test-Path $imgDir)) {
  Write-Host ""
  Write-Host "找不到官方截图目录：$imgDir" -ForegroundColor Yellow
  Write-Host "  官方截图不入库（腾讯内容 + 27 MB）。这个脚本只做「图 ↔ 数字」的复核与重算，" -ForegroundColor DarkGray
  Write-Host "  没有图就没法复核 —— 但仓库里的 像素验证 不受影响（它用的是 官方实测值.ps1）。" -ForegroundColor DarkGray
  exit 2
}

function Bands($bmp) {
  $out = @()
  foreach ($r in @(@(0.05, 0.15), @(0.45, 0.55), @(0.85, 0.95))) {
    $sr = 0L; $sg = 0L; $sb = 0L; $n = 0
    for ($y = [int]($bmp.Height * $r[0]); $y -lt [int]($bmp.Height * $r[1]); $y += 7) {
      for ($x = [int]($bmp.Width * 0.012); $x -lt [int]($bmp.Width * 0.055); $x += 5) {
        $c = $bmp.GetPixel($x, $y); $sr += $c.R; $sg += $c.G; $sb += $c.B; $n++
      }
    }
    $out += , @([int]($sr / $n), [int]($sg / $n), [int]($sb / $n))
  }
  return $out
}
function MoonBox($bmp) {
  $s = 0L; $n = 0
  for ($y = [int]($bmp.Height * 0.05); $y -lt [int]($bmp.Height * 0.09); $y += 4) {
    for ($x = [int]($bmp.Width * 0.84); $x -lt [int]($bmp.Width * 0.92); $x += 4) {
      $c = $bmp.GetPixel($x, $y); $s += ($c.R + $c.G + $c.B); $n++
    }
  }
  return [int]($s / (3 * $n))
}
function Lum($t) { return [int](($t[0] + $t[1] + $t[2]) / 3) }

Write-Host ""
Write-Host "===== 官方实测值复核（$($official.Count) 条，来源 $Dir）=====" -ForegroundColor Cyan
Write-Host ""

$tol = 2          # 采样本身有 ±1~2 的抖动（JPEG 压缩 + 取整），超过就是真的对不上
$bad = 0
$fresh = @()
foreach ($o in $official) {
  $p = Join-Path $imgDir $o.file
  if (-not (Test-Path $p)) {
    Write-Host ("  FAIL  {0,-14} 找不到来源图 {1}" -f $o.key, $o.file) -ForegroundColor Red
    $bad++
    continue
  }
  $bmp = [System.Drawing.Image]::FromFile($p)
  $b = Bands $bmp
  $lift = (MoonBox $bmp) - (Lum $b[0])
  $bmp.Dispose()
  $now = @((Lum $b[0]), (Lum $b[1]), (Lum $b[2]))
  $d = [Math]::Abs($now[0] - $o.bands[0]) + [Math]::Abs($now[1] - $o.bands[1]) + [Math]::Abs($now[2] - $o.bands[2])
  $dm = [Math]::Abs($lift - $o.moon)
  $line = ("  {0,-6} {1,-14} 记录 {2,3} {3,3} {4,3} / 月 {5,3}   实测 {6,3} {7,3} {8,3} / 月 {9,3}" -f `
    $(if ($d -le $tol -and $dm -le $tol) { 'PASS' } else { 'FAIL' }), $o.key,
    $o.bands[0], $o.bands[1], $o.bands[2], $o.moon, $now[0], $now[1], $now[2], $lift)
  if ($d -gt $tol -or $dm -gt $tol) { Write-Host $line -ForegroundColor Red; $bad++ }
  else { Write-Host $line }
  $fresh += [pscustomobject]@{ key = $o.key; file = $o.file; bands = $now; moon = $lift }
}

if ($Write) {
  # 只重算数字，**不动映射**（file → key 是冻结的事实，见文件头）
  $t = Get-Content $dataFile -Raw -Encoding UTF8
  foreach ($f in $fresh) {
    $re = [regex]::Escape("key = '$($f.key)'; file = '$($f.file)'; bands = @(")
    $t = [regex]::Replace($t, $re + "[^}]*\}", ("key = '{0}'; file = '{1}'; bands = @({2}, {3}, {4}); moon = {5} }}" -f `
      $f.key, $f.file, $f.bands[0], $f.bands[1], $f.bands[2], $f.moon))
  }
  [IO.File]::WriteAllText($dataFile, $t, (New-Object System.Text.UTF8Encoding($true)))
  Write-Host ""
  Write-Host "已重算并写回：$dataFile" -ForegroundColor Yellow
}

Write-Host ""
if ($bad -eq 0) {
  Write-Host "结论：全部一致 —— 每个数字都能从记录的官方截图重算出来" -ForegroundColor Green
  Write-Host ""
  exit 0
} else {
  Write-Host "结论：$bad 条对不上（要么数字被改过，要么换了来源图）" -ForegroundColor Red
  Write-Host ""
  exit $bad
}
