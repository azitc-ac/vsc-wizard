# Erzeugt das Programm-Icon (assets\VscWizard.ico, alle Windows-Größen) und das
# Intune-Logo (assets\VscWizard.png, 256 px) per System.Drawing - reproduzierbar, kein
# Grafikprogramm nötig. Motiv: Smartcard mit goldenem Chip (angelehnt an das Windows-
# Smartcard-Symbol), Variante "Tpm" zusätzlich TPM-Baustein mit Beinchen dahinter. Kleine Größen vereinfacht.
#
# Aufruf: powershell.exe -File .\assets\New-VscWizardIcon.ps1
param([string]$OutDir = $PSScriptRoot, [ValidateSet('Card', 'Tpm')][string]$Variant = 'Tpm')
Add-Type -AssemblyName System.Drawing

function New-RoundRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure(); return $p
}
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function New-IconBitmap([int]$S) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([System.Drawing.Color]::Transparent)
    $small = $S -le 24

    # Variante "Tpm": Beinchen OBEN und UNTEN, die hinter der Karte hervorschauen (kein
    # Chip-Körper, keine seitlichen Beinchen) - deutet den TPM-Chip an, in dem die Karte
    # steckt. Ab 32 px; darunter nur die Karte (verschwimmt sonst).
    $withTpm = ($Variant -eq 'Tpm') -and $S -ge 32
    if ($withTpm) {
        $pinCount = 5
        $pinW = [Math]::Max(1.5, 0.06 * $S)
        $pinTop = 0.05 * $S; $pinBottom = 0.95 * $S
        $span0 = 0.20 * $S; $span1 = 0.80 * $S
        $pinBrush = New-Object System.Drawing.SolidBrush((C 140 147 158))
        for ($i = 0; $i -lt $pinCount; $i++) {
            $px = $span0 + $i * ($span1 - $span0) / ($pinCount - 1) - $pinW / 2
            $g.FillRectangle($pinBrush, $px, $pinTop, $pinW, ($pinBottom - $pinTop))   # verdeckt von der Karte in der Mitte
        }
        $pinBrush.Dispose()
    }
    # Karte (Querformat), mittig.
    $cx = 0.05 * $S; $cy = 0.20 * $S; $cw = 0.90 * $S; $ch = 0.60 * $S
    if ($withTpm) { $cx = 0.08 * $S; $cy = 0.19 * $S; $cw = 0.84 * $S; $ch = 0.62 * $S }
    if ($small) { $cx = 0.03 * $S; $cy = 0.16 * $S; $cw = 0.94 * $S; $ch = 0.68 * $S }
    $card = New-RoundRect $cx $cy $cw $ch ([Math]::Max(1.5, 0.08 * $S))
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF($cx, $cy)), (New-Object System.Drawing.PointF($cx, ($cy + $ch))), (C 37 128 224), (C 10 76 150))
    $g.FillPath($grad, $card); $grad.Dispose()
    if (-not $small) {
        # dezenter Glanz oben + feiner Rand
        $hl = New-RoundRect ($cx + 0.02 * $S) ($cy + 0.02 * $S) ($cw - 0.04 * $S) ($ch * 0.42) (0.06 * $S)
        $hb = New-Object System.Drawing.SolidBrush((C 255 255 255 28)); $g.FillPath($hb, $hl); $hb.Dispose(); $hl.Dispose()
        $pen = New-Object System.Drawing.Pen((C 6 52 104), [Math]::Max(1, $S / 96)); $g.DrawPath($pen, $card); $pen.Dispose()
    }
    $card.Dispose()

    # Goldener Chip mit Kontaktfeldern.
    $kx = $cx + 0.12 * $cw; $kw = 0.25 * $cw; $kh = 0.30 * $ch; $ky = $cy + 0.30 * $ch
    if ($small) { $kx = $cx + 0.12 * $cw; $kw = 0.34 * $cw; $kh = 0.40 * $ch; $ky = $cy + 0.28 * $ch }
    $chip = New-RoundRect $kx $ky $kw $kh ([Math]::Max(1, 0.035 * $S))
    $cg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF($kx, $ky)), (New-Object System.Drawing.PointF(($kx + $kw), ($ky + $kh))), (C 250 222 120), (C 200 150 40))
    $g.FillPath($cg, $chip); $cg.Dispose()
    if ($S -ge 32) {
        $lp = New-Object System.Drawing.Pen((C 150 105 20), [Math]::Max(1, $S / 110))
        $g.DrawPath($lp, $chip)
        $g.DrawLine($lp, $kx, ($ky + $kh / 2), ($kx + $kw), ($ky + $kh / 2))
        $g.DrawLine($lp, ($kx + $kw / 3), $ky, ($kx + $kw / 3), ($ky + $kh))
        $g.DrawLine($lp, ($kx + 2 * $kw / 3), $ky, ($kx + 2 * $kw / 3), ($ky + $kh))
        $lp.Dispose()
    }
    $chip.Dispose()

    if ($S -ge 48) {
        # Zwei helle "Textzeilen" auf der Karte.
        $tb = New-Object System.Drawing.SolidBrush((C 255 255 255 150))
        $ly = $cy + 0.74 * $ch; $lh = [Math]::Max(1.5, 0.045 * $S)
        $l1 = New-RoundRect ($cx + 0.12 * $cw) $ly (0.34 * $cw) $lh ($lh / 2); $g.FillPath($tb, $l1); $l1.Dispose()
        $l2 = New-RoundRect ($cx + 0.12 * $cw + 0.38 * $cw) $ly (0.12 * $cw) $lh ($lh / 2); $g.FillPath($tb, $l2); $l2.Dispose()
        $tb.Dispose()
    }

    $g.Dispose()
    return $bmp
}

# ICO: 256 px als PNG (Standard), kleinere Größen als 32-Bit-BMP (DIB mit Alpha + AND-Maske)
# - System.Drawing.Icon (WinForms-Fenstersymbol) liest PNG-Einträge nur bei 256 px.
function ConvertTo-IcoDib([System.Drawing.Bitmap]$b) {
    $s = $b.Width
    $ms = New-Object System.IO.MemoryStream; $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]40); $bw.Write([int32]$s); $bw.Write([int32](2 * $s)); $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]0); $bw.Write([uint32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $s - 1; $y -ge 0; $y--) { for ($x = 0; $x -lt $s; $x++) { $c = $b.GetPixel($x, $y); $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A) } }
    $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
    for ($y = $s - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskRow
        for ($x = 0; $x -lt $s; $x++) { if ($b.GetPixel($x, $y).A -eq 0) { $row[[int][Math]::Floor($x / 8)] = $row[[int][Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8)) } }
        $bw.Write($row)
    }
    $bw.Flush(); return , $ms.ToArray()
}
$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$pngs = foreach ($s in $sizes) {
    $b = New-IconBitmap $s
    if ($s -ge 256) { $ms = New-Object System.IO.MemoryStream; $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $data = $ms.ToArray() }
    else { $data = ConvertTo-IcoDib $b }
    $b.Dispose()
    , $data
}
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($out)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s })); $w.Write([byte]$(if ($s -ge 256) { 0 } else { $s }))
    $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$len); $w.Write([uint32]$offset); $offset += $len
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutDir 'VscWizard.ico'), $out.ToArray())
$logo = New-IconBitmap 256; $logo.Save((Join-Path $OutDir 'VscWizard.png'), [System.Drawing.Imaging.ImageFormat]::Png); $logo.Dispose()
Write-Host "Icon erzeugt: $(Join-Path $OutDir 'VscWizard.ico') ($($sizes -join ', ') px) + VscWizard.png (256 px)"
