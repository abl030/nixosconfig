<#
.SYNOPSIS
    Sets the Windows desktop wallpaper to reflect the current Cullen biodynamic
    ("moon day") type, from the bdday API at https://bd.ablz.au.

.DESCRIPTION
    Renders a wallpaper showing the day type currently in force
    (Root / Leaf / Flower / Fruit), its sign and element, and when it next
    changes. Icons are drawn as GDI+ vector paths rather than glyphs, because
    GDI+ renders colour emoji as monochrome tofu and there is no MDI font on
    Windows.

    Intended to run from the "BdDay-Wallpaper" scheduled task inside the user's
    interactive session. It will NOT work usefully over SSH: an SSH session has
    its own non-interactive window station, so SystemParametersInfo there does
    not touch the logged-on desktop.

    Runs entirely as the ordinary user. It needs no elevation: it writes only
    under %LOCALAPPDATA% and HKCU.

    API semantics (see docs/wiki/services/biodynamic-day.md): the top-level
    `day_type` is a WHOLE-DAY descriptor and reads e.g. "Fruit/Leaf" on a
    transition day, so it is not the current type. `ingress.next` is the
    moment-relative object: `from_day_type` is what is in force now, and
    `.at` / `.to_day_type` are the next changeover.

.PARAMETER Restore
    Puts back the wallpaper recorded at install time and exits.

.PARAMETER Force
    Re-render and re-apply even when nothing has changed.

.PARAMETER RenderOnly
    Render the image to this path and exit without touching the desktop, the
    registry, or the recorded original. Safe to run over SSH, and the way to
    preview a design change before it lands on someone's screen.

.PARAMETER PreviewType
    Force a day type instead of using the live one. Only meaningful with
    -RenderOnly; it exists so all four icons can be proofed on demand rather
    than waiting days for the calendar to reach them.
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$Force,
    [string]$RenderOnly,
    [ValidateSet('Root', 'Leaf', 'Flower', 'Fruit')]
    [string]$PreviewType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:LOCALAPPDATA 'bdday-wallpaper'
$OriginalFile = Join-Path $StateDir 'original-wallpaper.txt'
$StateFile = Join-Path $StateDir 'state.txt'
$LogFile = Join-Path $StateDir 'bdday-wallpaper.log'
$ApiBase = 'https://bd.ablz.au'

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Verbose $line
    # Keep the log bounded; this runs every 15 minutes forever.
    try {
        $lines = @(Get-Content -Path $LogFile -ErrorAction Stop)
        if ($lines.Count -gt 400) {
            Set-Content -Path $LogFile -Value $lines[-200..-1] -Encoding UTF8
        }
    } catch { }
}

# --- wallpaper plumbing ------------------------------------------------------

if (-not ('BdDayWallpaperNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BdDayWallpaperNative {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
    private const int SPI_SETDESKWALLPAPER = 20;
    private const int SPIF_UPDATEINIFILE = 0x01;
    private const int SPIF_SENDWININICHANGE = 0x02;
    public static bool Set(string path) {
        return SystemParametersInfo(SPI_SETDESKWALLPAPER, 0, path, SPIF_UPDATEINIFILE | SPIF_SENDWININICHANGE) != 0;
    }
}
'@
}

function Set-Wallpaper {
    param([string]$Path, [string]$Style = '10')
    # 10 = Fill. All three displays here are 1920x1080, so one image at the
    # primary resolution fills every monitor correctly.
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value $Style
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'
    return [BdDayWallpaperNative]::Set($Path)
}

function Get-CurrentWallpaper {
    try { return (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction Stop).WallPaper }
    catch { return '' }
}

if ($Restore) {
    if (-not (Test-Path $OriginalFile)) {
        Write-Log 'restore requested but no original wallpaper was recorded'
        Write-Output 'No original wallpaper recorded; nothing to restore.'
        exit 1
    }
    $orig = (Get-Content -Path $OriginalFile -Raw).Trim()
    $parts = $orig -split '\|', 2
    $origPath = $parts[0]
    $origStyle = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { '10' }
    if (Set-Wallpaper -Path $origPath -Style $origStyle) {
        Write-Log "restored original wallpaper: $origPath"
        Write-Output "Restored: $origPath"
        exit 0
    }
    Write-Log "FAILED to restore original wallpaper: $origPath"
    exit 1
}

# Record the pre-existing wallpaper exactly once, so -Restore has a target.
# Never re-capture: after the first run the current wallpaper is one of ours.
if (-not $RenderOnly -and -not (Test-Path $OriginalFile)) {
    $cur = Get-CurrentWallpaper
    $curStyle = try { (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -ErrorAction Stop).WallpaperStyle } catch { '10' }
    if ($cur -and ($cur -notlike (Join-Path $StateDir '*'))) {
        Set-Content -Path $OriginalFile -Value ("{0}|{1}" -f $cur, $curStyle) -Encoding UTF8
        Write-Log "recorded original wallpaper: $cur (style $curStyle)"
    }
}

# --- data --------------------------------------------------------------------

$now = Get-Date
$uri = '{0}/v1/day/{1}?at={2}' -f $ApiBase, $now.ToString('yyyy-MM-dd'), $now.ToString('HH:mm')

try {
    $data = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -UseBasicParsing
} catch {
    Write-Log "API fetch failed: $($_.Exception.Message)"
    exit 1
}

$next = $data.ingress.next
$dayType = [string]$next.from_day_type
$sign = [string]$next.from_sign
$nextType = [string]$next.to_day_type
$nextSign = [string]$next.to_sign

if (-not $dayType) {
    Write-Log 'API response had no ingress.next.from_day_type; aborting'
    exit 1
}

if ($PreviewType) {
    if (-not $RenderOnly) { throw '-PreviewType is only valid together with -RenderOnly.' }
    $dayType = $PreviewType
}

# PowerShell 5.1's JSON deserialiser sometimes coerces ISO-8601 strings to
# [datetime] on its own, and the API emits 9 fractional digits where .NET
# accepts at most 7 - handle both shapes.
$rawAt = $next.at
if ($rawAt -is [datetime]) {
    $nextAt = [datetimeoffset]$rawAt
} else {
    $trimmed = ([string]$rawAt) -replace '(\.\d{1,7})\d*', '$1'
    $nextAt = [datetimeoffset]::Parse($trimmed, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}
$nextLocal = $nextAt.ToLocalTime()

# Element comes from whichever segment actually contains "now", so the wording
# always matches the API's own (Earth / Water / Air / Fire).
$element = ''
foreach ($seg in @($data.segments)) {
    if ([string]$seg.day_type -eq $dayType) { $element = [string]$seg.element }
}
if (-not $element) {
    $element = @{ Root = 'Earth'; Leaf = 'Water'; Flower = 'Air'; Fruit = 'Fire' }[$dayType]
}

$dayDelta = ($nextLocal.Date - $now.Date).Days
$whenWord = if ($dayDelta -eq 0) { 'today' } elseif ($dayDelta -eq 1) { 'tomorrow' } else { $nextLocal.ToString('ddd d MMM') }
$timeWord = $nextLocal.ToString('h:mm tt').ToLower()
$changeLine = 'Changes to {0} ({1})' -f $nextType, $nextSign
$whenLine = '{0} at {1}' -f $whenWord, $timeWord

# Built from a code point rather than typed literally: PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI, which would mangle a pasted middle dot.
$Sep = [string][char]0x00B7

$phaseLine = ''
try {
    $phaseLine = '{0} {1} {2}% lit' -f [string]$data.phase.name, $Sep, ([math]::Round([double]$data.phase.illumination_pct))
} catch { }

# --- palette -----------------------------------------------------------------

$palettes = @{
    Root   = @{ Base = '#161109'; Glow = '#E0A15C'; Accent = '#E8AE6B'; Leafy = '#7FB069' }
    Leaf   = @{ Base = '#0B1917'; Glow = '#5FD3A8'; Accent = '#6FDCB4'; Leafy = '#6FDCB4' }
    Flower = @{ Base = '#140F1D'; Glow = '#C08BE8'; Accent = '#CD9CF0'; Leafy = '#7FB069' }
    Fruit  = @{ Base = '#1A0F10'; Glow = '#F0785A'; Accent = '#F58A6C'; Leafy = '#7FB069' }
}
$pal = if ($palettes.ContainsKey($dayType)) { $palettes[$dayType] } else { $palettes['Leaf'] }

function ConvertTo-Color {
    param([string]$Hex, [int]$Alpha = 255)
    $h = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(
        $Alpha,
        [convert]::ToInt32($h.Substring(0, 2), 16),
        [convert]::ToInt32($h.Substring(2, 2), 16),
        [convert]::ToInt32($h.Substring(4, 2), 16))
}

# --- resolution --------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$width = 1920; $height = 1080
try {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    # An SSH / non-interactive station reports a placeholder screen; ignore
    # anything implausibly small so we never render a 1024x768 wallpaper.
    if ($b.Width -ge 1280 -and $b.Height -ge 720) { $width = $b.Width; $height = $b.Height }
} catch { }

# --- skip when nothing changed ----------------------------------------------

$contentKey = ($dayType, $sign, $element, $changeLine, $whenLine, $phaseLine, $width, $height) -join '|'
$currentWp = Get-CurrentWallpaper
$stateMatches = $false
if ((Test-Path $StateFile) -and -not $Force -and -not $RenderOnly) {
    $prev = (Get-Content -Path $StateFile -Raw).Trim()
    if ($prev -eq $contentKey -and $currentWp -like (Join-Path $StateDir '*') -and (Test-Path $currentWp)) {
        $stateMatches = $true
    }
}
if ($stateMatches) { exit 0 }

# --- drawing helpers ---------------------------------------------------------

function New-UnitPoint {
    param($Box, [double]$X, [double]$Y)
    return New-Object System.Drawing.PointF(
        [single]($Box.X + $X * $Box.Width),
        [single]($Box.Y + $Y * $Box.Height))
}

function Add-LeafFigure {
    param($Path, $Box, [double]$Tilt = 0.0)
    # Two mirrored beziers from the stem tip to the point.
    $Path.AddBezier(
        (New-UnitPoint $Box 0.50 0.98), (New-UnitPoint $Box (0.02 + $Tilt) 0.76),
        (New-UnitPoint $Box (0.04 + $Tilt) 0.20), (New-UnitPoint $Box 0.50 0.02))
    $Path.AddBezier(
        (New-UnitPoint $Box 0.50 0.02), (New-UnitPoint $Box (0.96 + $Tilt) 0.20),
        (New-UnitPoint $Box (0.98 + $Tilt) 0.76), (New-UnitPoint $Box 0.50 0.98))
    $Path.CloseFigure()
}

function Draw-BdIcon {
    param($G, [string]$Type, $Box, $Pal)

    $accent = ConvertTo-Color $Pal.Accent
    $accentBrush = New-Object System.Drawing.SolidBrush($accent)
    $veinPen = New-Object System.Drawing.Pen((ConvertTo-Color $Pal.Base 200), [single]($Box.Width * 0.018))
    $veinPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $veinPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    switch ($Type) {
        'Leaf' {
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath
            Add-LeafFigure -Path $p -Box $Box
            $G.FillPath($accentBrush, $p)
            $G.DrawLine($veinPen, (New-UnitPoint $Box 0.50 0.92), (New-UnitPoint $Box 0.50 0.12))
            # Veins sweep outward AND toward the tip (which is at the top, so
            # the outer end sits at a smaller y).
            foreach ($y in 0.36, 0.51, 0.66, 0.81) {
                $G.DrawLine($veinPen, (New-UnitPoint $Box 0.50 $y), (New-UnitPoint $Box 0.26 ($y - 0.10)))
                $G.DrawLine($veinPen, (New-UnitPoint $Box 0.50 $y), (New-UnitPoint $Box 0.74 ($y - 0.10)))
            }
            $p.Dispose()
        }
        'Root' {
            # Carrot: tapered body pointing down, three fronds above.
            $p = New-Object System.Drawing.Drawing2D.GraphicsPath
            $p.AddBezier(
                (New-UnitPoint $Box 0.50 1.00), (New-UnitPoint $Box 0.32 0.74),
                (New-UnitPoint $Box 0.25 0.58), (New-UnitPoint $Box 0.26 0.46))
            $p.AddBezier(
                (New-UnitPoint $Box 0.26 0.46), (New-UnitPoint $Box 0.38 0.38),
                (New-UnitPoint $Box 0.62 0.38), (New-UnitPoint $Box 0.74 0.46))
            $p.AddBezier(
                (New-UnitPoint $Box 0.74 0.46), (New-UnitPoint $Box 0.75 0.58),
                (New-UnitPoint $Box 0.68 0.74), (New-UnitPoint $Box 0.50 1.00))
            $p.CloseFigure()
            $G.FillPath($accentBrush, $p)
            foreach ($pair in @(@(0.38, 0.60), @(0.44, 0.72), @(0.52, 0.84))) {
                $G.DrawLine($veinPen,
                    (New-UnitPoint $Box ($pair[0]) ($pair[1])),
                    (New-UnitPoint $Box ($pair[0] + 0.16) ($pair[1] - 0.04)))
            }
            $p.Dispose()

            $frondBrush = New-Object System.Drawing.SolidBrush((ConvertTo-Color $Pal.Leafy))
            $fw = $Box.Width * 0.30; $fh = $Box.Height * 0.42
            foreach ($spec in @(@(-26, 0.30), @(0, 0.24), @(26, 0.42))) {
                $state = $G.Save()
                $G.TranslateTransform(
                    [single]($Box.X + $Box.Width * $spec[1] + $fw * 0.2),
                    [single]($Box.Y + $Box.Height * 0.44))
                $G.RotateTransform([single]$spec[0])
                $fb = New-Object System.Drawing.RectangleF([single](-$fw / 2), [single](-$fh), [single]$fw, [single]$fh)
                $fp = New-Object System.Drawing.Drawing2D.GraphicsPath
                Add-LeafFigure -Path $fp -Box $fb
                $G.FillPath($frondBrush, $fp)
                $fp.Dispose()
                $G.Restore($state)
            }
            $frondBrush.Dispose()
        }
        'Flower' {
            $cx = $Box.X + $Box.Width * 0.5
            $cy = $Box.Y + $Box.Height * 0.52
            $pw = $Box.Width * 0.30
            $ph = $Box.Height * 0.42
            for ($i = 0; $i -lt 6; $i++) {
                $state = $G.Save()
                $G.TranslateTransform([single]$cx, [single]$cy)
                $G.RotateTransform([single]($i * 60))
                $G.FillEllipse($accentBrush, [single](-$pw / 2), [single](-$ph), [single]$pw, [single]($ph * 0.92))
                $G.Restore($state)
            }
            $coreR = $Box.Width * 0.16
            $coreBrush = New-Object System.Drawing.SolidBrush((ConvertTo-Color '#F5D06A'))
            $G.FillEllipse($coreBrush, [single]($cx - $coreR), [single]($cy - $coreR), [single]($coreR * 2), [single]($coreR * 2))
            $coreBrush.Dispose()
        }
        'Fruit' {
            # Two cherries with stems meeting at a common point.
            $stemPen = New-Object System.Drawing.Pen((ConvertTo-Color $Pal.Leafy), [single]($Box.Width * 0.045))
            $stemPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $stemPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $G.DrawBezier($stemPen,
                (New-UnitPoint $Box 0.60 0.08), (New-UnitPoint $Box 0.46 0.26),
                (New-UnitPoint $Box 0.36 0.38), (New-UnitPoint $Box 0.30 0.54))
            $G.DrawBezier($stemPen,
                (New-UnitPoint $Box 0.60 0.08), (New-UnitPoint $Box 0.74 0.30),
                (New-UnitPoint $Box 0.76 0.44), (New-UnitPoint $Box 0.72 0.60))
            $stemPen.Dispose()

            $r1 = $Box.Width * 0.21
            $r2 = $Box.Width * 0.185
            $c1 = New-UnitPoint $Box 0.30 0.76
            $c2 = New-UnitPoint $Box 0.72 0.80
            $G.FillEllipse($accentBrush, [single]($c1.X - $r1), [single]($c1.Y - $r1), [single]($r1 * 2), [single]($r1 * 2))
            $G.FillEllipse($accentBrush, [single]($c2.X - $r2), [single]($c2.Y - $r2), [single]($r2 * 2), [single]($r2 * 2))

            $leafBrush = New-Object System.Drawing.SolidBrush((ConvertTo-Color $Pal.Leafy))
            $state = $G.Save()
            $G.TranslateTransform((New-UnitPoint $Box 0.60 0.08).X, (New-UnitPoint $Box 0.60 0.08).Y)
            $G.RotateTransform(58)
            $lw = $Box.Width * 0.20; $lh = $Box.Height * 0.26
            $lb = New-Object System.Drawing.RectangleF([single]0, [single](-$lw / 2), [single]$lh, [single]$lw)
            $lp = New-Object System.Drawing.Drawing2D.GraphicsPath
            $lp.AddBezier(
                (New-UnitPoint $lb 0.00 0.50), (New-UnitPoint $lb 0.30 0.02),
                (New-UnitPoint $lb 0.80 0.10), (New-UnitPoint $lb 1.00 0.42))
            $lp.AddBezier(
                (New-UnitPoint $lb 1.00 0.42), (New-UnitPoint $lb 0.65 0.72),
                (New-UnitPoint $lb 0.25 0.85), (New-UnitPoint $lb 0.00 0.50))
            $lp.CloseFigure()
            $G.FillPath($leafBrush, $lp)
            $lp.Dispose()
            $G.Restore($state)
            $leafBrush.Dispose()
        }
    }

    $accentBrush.Dispose()
    $veinPen.Dispose()
}

# --- render ------------------------------------------------------------------

$bmp = New-Object System.Drawing.Bitmap($width, $height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# Background: near-black base with a vertical lift, then a soft off-centre glow
# in the day's accent colour.
$baseCol = ConvertTo-Color $pal.Base
$topCol = ConvertTo-Color '#05070A'
$bgRect = New-Object System.Drawing.Rectangle(0, 0, $width, $height)
$bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $bgRect, $topCol, $baseCol, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillRectangle($bgBrush, $bgRect)
$bgBrush.Dispose()

$glowR = [int]($height * 1.15)
$glowCx = [int]($width * 0.30)
$glowCy = [int]($height * 0.46)
$glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
$glowPath.AddEllipse($glowCx - $glowR, $glowCy - $glowR, $glowR * 2, $glowR * 2)
$glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
$glowBrush.CenterColor = ConvertTo-Color $pal.Glow 64
$glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
$g.FillPath($glowBrush, $glowPath)
$glowBrush.Dispose(); $glowPath.Dispose()

$s = $height / 1080.0

$fontTitle = New-Object System.Drawing.Font('Segoe UI Light', [single](96 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fontSub = New-Object System.Drawing.Font('Segoe UI', [single](34 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fontBody = New-Object System.Drawing.Font('Segoe UI Semibold', [single](30 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fontBodyLight = New-Object System.Drawing.Font('Segoe UI', [single](30 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$fontFoot = New-Object System.Drawing.Font('Segoe UI', [single](21 * $s), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)

$brushPrimary = New-Object System.Drawing.SolidBrush((ConvertTo-Color '#F2F5F7'))
$brushSecondary = New-Object System.Drawing.SolidBrush((ConvertTo-Color '#9FB0B8'))
$brushAccent = New-Object System.Drawing.SolidBrush((ConvertTo-Color $pal.Accent))
$brushFoot = New-Object System.Drawing.SolidBrush((ConvertTo-Color '#6B7B84'))

# Layout: icon left, text block right, whole group centred as one unit.
$iconSize = $height * 0.30
$gap = $width * 0.045
$titleText = '{0} day' -f $dayType.ToUpper()
$titleSize = $g.MeasureString($titleText, $fontTitle)
$subText = '{0}  {1}  {2}' -f $sign, $Sep, $element
$subSize = $g.MeasureString($subText, $fontSub)
$changeSize = $g.MeasureString($changeLine, $fontBody)
$whenSize = $g.MeasureString($whenLine, $fontBodyLight)

$textWidth = [Math]::Max([Math]::Max($titleSize.Width, $subSize.Width), [Math]::Max($changeSize.Width, $whenSize.Width))
$groupWidth = $iconSize + $gap + $textWidth
$groupLeft = ($width - $groupWidth) / 2.0
$centreY = $height * 0.47

$iconBox = New-Object System.Drawing.RectangleF(
    [single]$groupLeft, [single]($centreY - $iconSize / 2.0), [single]$iconSize, [single]$iconSize)
Draw-BdIcon -G $g -Type $dayType -Box $iconBox -Pal $pal

$textLeft = $groupLeft + $iconSize + $gap
$blockHeight = $titleSize.Height + $subSize.Height + ($height * 0.055) + $changeSize.Height + $whenSize.Height
$y = $centreY - $blockHeight / 2.0

$g.DrawString($titleText, $fontTitle, $brushPrimary, [single]$textLeft, [single]$y)
$y += $titleSize.Height * 0.96
$g.DrawString($subText, $fontSub, $brushAccent, [single]($textLeft + 4 * $s), [single]$y)
$y += $subSize.Height + $height * 0.055

# Divider above the "what changes next" block.
$rulePen = New-Object System.Drawing.Pen((ConvertTo-Color '#FFFFFF' 34), [single](1.5 * $s))
$g.DrawLine($rulePen, [single]($textLeft + 4 * $s), [single]($y - $height * 0.028), [single]($textLeft + $textWidth), [single]($y - $height * 0.028))
$rulePen.Dispose()

$g.DrawString($changeLine, $fontBody, $brushPrimary, [single]($textLeft + 4 * $s), [single]$y)
$y += $changeSize.Height * 1.02
$g.DrawString($whenLine, $fontBodyLight, $brushSecondary, [single]($textLeft + 4 * $s), [single]$y)

# Footer, bottom-left, well clear of desktop icons at top-left.
$footY = $height - ($height * 0.075)
$footText = if ($phaseLine) { "$phaseLine   $Sep   bd.ablz.au" } else { 'bd.ablz.au' }
$g.DrawString($footText, $fontFoot, $brushFoot, [single]($width * 0.055), [single]$footY)

$g.Dispose()

# Windows caches the wallpaper aggressively by path, so alternate between two
# filenames to guarantee the change is actually picked up.
$slotA = Join-Path $StateDir 'wallpaper-a.png'
$slotB = Join-Path $StateDir 'wallpaper-b.png'
$target = if ($RenderOnly) { $RenderOnly } elseif ((Get-CurrentWallpaper) -eq $slotA) { $slotB } else { $slotA }

$bmp.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
foreach ($f in $fontTitle, $fontSub, $fontBody, $fontBodyLight, $fontFoot) { $f.Dispose() }
foreach ($b in $brushPrimary, $brushSecondary, $brushAccent, $brushFoot) { $b.Dispose() }

if ($RenderOnly) {
    Write-Output ("Rendered {0}x{1} to {2} ({3} day, {4}, {5}; {6} {7})" -f $width, $height, $target, $dayType, $sign, $element, $nextType, $whenLine)
    exit 0
}

if (Set-Wallpaper -Path $target) {
    Set-Content -Path $StateFile -Value $contentKey -Encoding UTF8
    Write-Log ("applied {0} day ({1}, {2}); next {3} {4} [{5}x{6}]" -f $dayType, $sign, $element, $nextType, $whenLine, $width, $height)
    Write-Output ("{0} day - {1} - {2} {3}" -f $dayType, $sign, $changeLine, $whenLine)
    exit 0
}

Write-Log 'SystemParametersInfo failed to apply the wallpaper'
exit 1
