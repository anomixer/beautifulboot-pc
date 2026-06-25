function Reverse-Bits([byte]$b) {
    $rev = 0
    for ($i = 0; $i -lt 8; $i++) {
        $bit = (1 -shl $i)
        if (($b -band $bit) -ne 0) {
            $rev = $rev -bor (1 -shl (7 - $i))
        }
    }
    return $rev
}

$url = "https://raw.githubusercontent.com/dhepper/font8x8/master/font8x8_basic.h"
$content = (Invoke-WebRequest -Uri $url -UseBasicParsing).Content
$lines = $content -split "`r?`n"
$font_data = @()
$font_data += "; -----------------------------------------------------------"
$font_data += "; Custom 8x8 font generated from font8x8_basic.h (bit-reversed)"
$font_data += "; -----------------------------------------------------------"
$font_data += "FONT_DATA:"

foreach ($line in $lines) {
    if ($line -match '\{\s*(0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2},\s*0x[0-9a-fA-F]{2})\s*\}') {
        $bytes_str = $Matches[1]
        # Parse the 8 hex bytes
        $bytes = $bytes_str -split ',\s*' | ForEach-Object { [byte][int]$_ }
        $rev_bytes = @()
        foreach ($b in $bytes) {
            $rev_b = Reverse-Bits $b
            $rev_bytes += "0x{0:X2}" -f $rev_b
        }
        $bytes_joined = $rev_bytes -join ", "
        $font_data += "    db $bytes_joined"
    }
}
$font_data | Out-File -FilePath "c:\dev\bb\font.inc" -Encoding ascii
