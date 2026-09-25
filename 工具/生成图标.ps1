# ============================================================================
# 微信读书脚本 · 生成发布用图标
# ----------------------------------------------------------------------------
# 产出：发布/图标-96.png（GreasyFork 的脚本图标，96x96）
#
# 设计：深色圆角底 + 三张色卡（白 / 米黄 / 青绿），中间那张带金色描边 = 面板里
#       「当前生效」的样子。图案元素全部来自脚本自己的配色，零第三方素材。
#       故意做得极简：GreasyFork 在列表里只显示到 ~32px，细节多了会糊成一团。
#
# 画法是先按 4 倍（384）画再缩到 96 —— 圆角和边缘会得到抗锯齿，比直接画 96 干净。
#
# 用法：pwsh -File "工具\生成图标.ps1"
# ============================================================================
param([int]$Size = 96, [int]$Scale = 4)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

$Root = Split-Path $PSScriptRoot -Parent
$OutDir = Join-Path $Root '发布'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# 与脚本 COLORS 里的官方实测底色保持一致
$C_WHITE = '#f8f8fa'
$C_SEPIA = '#f5efd9'
$C_GREEN = '#c0edc6'
$C_GOLD  = '#c8a06a'   # 面板里「当前生效」的描边色
$C_BG    = '#1f2126'   # 深色底，在 GreasyFork 的白页面上跳得出来

function BrushOf($hex) {
  $h = $hex.TrimStart('#')
  $r = [Convert]::ToInt32($h.Substring(0, 2), 16)
  $g = [Convert]::ToInt32($h.Substring(2, 2), 16)
  $b = [Convert]::ToInt32($h.Substring(4, 2), 16)
  return New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($r, $g, $b))
}
function RoundPath($x, $y, $w, $h, $r) {
  # 所有坐标先算成变量再传：直接写 $x+$w-$r*2 这类表达式夹在参数列表里，
  # 容易被 PowerShell 的逗号列表绑定规则吃掉（本项目已在别处踩过两次）。
  $rr = $r * 2
  $right = $x + $w - $rr
  $bottom = $y + $h - $rr
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x,     $y,      $rr, $rr, 180, 90)
  $p.AddArc($right, $y,      $rr, $rr, 270, 90)
  $p.AddArc($right, $bottom, $rr, $rr,   0, 90)
  $p.AddArc($x,     $bottom, $rr, $rr,  90, 90)
  $p.CloseFigure()
  return $p
}

$W = $Size * $Scale
$bmp = New-Object System.Drawing.Bitmap($W, $W)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)

# 底部圆角方块（铺满）
$pad = $W * 0.02
$outer = RoundPath $pad $pad ($W - $pad * 2) ($W - $pad * 2) ($W * 0.22)
$g.FillPath((BrushOf $C_BG), $outer)

# 三张色卡：宽 0.21W、高 0.30W、圆角 0.06W，水平居中排布
$cw = $W * 0.21
$ch = $W * 0.30
$gap = $W * 0.055
$total = $cw * 3 + $gap * 2
$x0 = ($W - $total) / 2
$cy = ($W - $ch) / 2

$cards = @(
  @($C_WHITE, $false),
  @($C_SEPIA, $true),    # 中间这张 = 「当前生效」，加金色描边
  @($C_GREEN, $false)
)
$penGold = New-Object System.Drawing.Pen(([System.Drawing.Color]::FromArgb(200, 160, 106)), ($W * 0.035))
$penGold.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

for ($i = 0; $i -lt 3; $i++) {
  $x = $x0 + $i * ($cw + $gap)
  $path = RoundPath $x $cy $cw $ch ($W * 0.06)
  $g.FillPath((BrushOf $cards[$i][0]), $path)
  if ($cards[$i][1]) { $g.DrawPath($penGold, $path) }
  $path.Dispose()
}

# 缩到目标尺寸
$out = New-Object System.Drawing.Bitmap($Size, $Size)
$g2 = [System.Drawing.Graphics]::FromImage($out)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$dst = New-Object System.Drawing.Rectangle(0, 0, $Size, $Size)
$g2.DrawImage($bmp, $dst, 0, 0, $W, $W, [System.Drawing.GraphicsUnit]::Pixel)
$g2.Dispose()

$png = Join-Path $OutDir '图标-96.png'
$out.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)

# 自检：尺寸对不对、三个色卡的颜色有没有画上去
$check = [System.Drawing.Bitmap]::FromFile($png)
$fail = @()
if ($check.Width -ne $Size -or $check.Height -ne $Size) { $fail += "尺寸是 $($check.Width)x$($check.Height)，应为 ${Size}x${Size}" }
$mid = $check.GetPixel([int]($Size / 2), [int]($Size / 2))
if ([Math]::Abs($mid.R - 245) -gt 12 -or [Math]::Abs($mid.G - 239) -gt 12 -or [Math]::Abs($mid.B - 217) -gt 12) {
  $fail += "中间色卡颜色不对：实测 rgb($($mid.R),$($mid.G),$($mid.B))，期望接近 #f5efd9"
}
$corner = $check.GetPixel(1, 1)
if ($corner.A -ne 0) { $fail += "左上角应透明，实测 alpha=$($corner.A)" }
$check.Dispose()
$out.Dispose(); $bmp.Dispose(); $g.Dispose()

Write-Host ""
Write-Host "===== 生成发布图标 =====" -ForegroundColor Cyan
"  $png"
"  {0}x{1}  {2:N0} B" -f $Size, $Size, (Get-Item $png).Length
if ($fail.Count) {
  $fail | ForEach-Object { Write-Host "  [失败] $_" -ForegroundColor Red }
  exit $fail.Count
}
Write-Host "  校验通过：尺寸正确、中间色卡是米黄、圆角外透明" -ForegroundColor Green
exit 0
