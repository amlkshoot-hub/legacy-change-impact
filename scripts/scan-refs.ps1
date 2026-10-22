#requires -Version 5.1
<#
.SYNOPSIS
    扫描一组符号在仓库中的引用，按 L1(静态) / L2(隐式) / L3(数据契约) 分层输出。
    供 legacy-change-impact 技能做变更影响面分析。只找命中，不做判断，不改任何文件。

.DESCRIPTION
    分层规则：
      L3  文件本身是数据/配置（sql/yml/json/properties/xml/...），改了不可回滚
      L2  字符串字面量内的引用、被引号包裹的引用、同源命名（前缀/后缀共名）
      L1  普通代码中的词边界引用，编译器或解释器会直接报错
    每层独立计数与截断，互不挤占配额。

.EXAMPLE
    .\scan-refs.ps1 -Root C:\repo -Symbol get_user_profile,user_profile,profile_cache_ttl -Git

.EXAMPLE
    .\scan-refs.ps1 -Root C:\repo -Symbol nick_name -Json | Out-File report.json -Encoding utf8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Root,

    [Parameter(Mandatory = $true, Position = 1)]
    [string[]]$Symbol,

    [string[]]$Include = @(
        '.py', '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.java', '.kt', '.go',
        '.cs', '.rb', '.php', '.rs', '.scala', '.swift', '.vue', '.svelte', '.html',
        '.sql', '.yml', '.yaml', '.json', '.properties', '.ini', '.xml', '.toml',
        '.env', '.conf', '.cfg', '.sh', '.ps1', '.proto'
    ),

    [int]$MaxHits = 200,
    [int]$MaxFiles = 20000,
    [long]$MaxFileBytes = 5242880,
    [switch]$Git,
    [switch]$IgnoreCase,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 常量 ----------
$DataExt = @('.sql', '.yml', '.yaml', '.json', '.properties', '.ini', '.xml', '.toml',
    '.env', '.conf', '.cfg', '.proto', '.html')

$ExcludeDirNames = @(
    'node_modules', '.git', '.svn', '.hg', 'dist', 'build', 'out', 'target',
    'venv', '.venv', '__pycache__', '.next', '.nuxt', 'coverage', 'htmlcov',
    'vendor', 'bin', 'obj', '.idea', '.vscode', '.mypy_cache', '.pytest_cache',
    '.tox', '.gradle', '.terraform', 'logs', 'tmp', 'temp', '.cache'
)

$TestPathPattern = '(?i)(^|[\\/_.-])(test|tests|spec|specs|__tests__|fixture|fixtures|snapshot|snapshots|golden|mocks?)([\\/_.-]|$)'

$Cmp = if ($IgnoreCase) { [System.StringComparison]::OrdinalIgnoreCase }
       else { [System.StringComparison]::Ordinal }

$CH_SQ = [char]39; $CH_DQ = [char]34; $CH_BT = [char]96; $CH_BS = [char]92

# ---------- 工具函数 ----------
function Test-InStringLiteral {
    # 判断 pos 处的命中是否落在双引号 / 反引号字符串内部（按奇偶引号近似）
    param([string]$Line, [int]$Pos)
    $dq = 0; $bt = 0; $esc = $false
    for ($k = 0; $k -lt $Pos; $k++) {
        $c = $Line[$k]
        if ($esc) { $esc = $false; continue }
        if ($c -eq $CH_BS) { $esc = $true; continue }
        if ($c -eq $CH_DQ) { $dq++ }
        elseif ($c -eq $CH_BT) { $bt++ }
    }
    return ((($dq % 2) -eq 1) -or (($bt % 2) -eq 1))
}

function Test-QuoteAdjacent {
    param([string]$Line, [int]$Pos, [int]$Len)
    $b = if ($Pos -gt 0) { $Line[$Pos - 1] } else { [char]' ' }
    $j = $Pos + $Len
    $a = if ($j -lt $Line.Length) { $Line[$j] } else { [char]' ' }
    return (($b -eq $CH_SQ) -or ($b -eq $CH_DQ) -or ($b -eq $CH_BT) -or
            ($a -eq $CH_SQ) -or ($a -eq $CH_DQ) -or ($a -eq $CH_BT))
}

# ---------- 校验根目录 ----------
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Root 不是目录或不存在: $Root"
}
$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

$Symbol = @($Symbol | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
if ($Symbol.Count -eq 0) { throw 'Symbol 不能为空' }

$IncludeSet = @{}
foreach ($e in $Include) {
    $k = if ($e.StartsWith('.')) { $e.ToLowerInvariant() } else { ('.' + $e).ToLowerInvariant() }
    $IncludeSet[$k] = $true
}

# ---------- 遍历文件（剪枝 + 防环） ----------
$files = [System.Collections.Generic.List[string]]::new()
$visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$stack = [System.Collections.Generic.Stack[string]]::new()
$stack.Push($rootFull)
[void]$visited.Add($rootFull)
$walkTruncated = $false

while ($stack.Count -gt 0) {
    if ($files.Count -ge $MaxFiles) { $walkTruncated = $true; break }
    $dir = $stack.Pop()
    try { $entries = [System.IO.Directory]::EnumerateFileSystemEntries($dir) }
    catch { continue }

    foreach ($entry in $entries) {
        try {
            if ([System.IO.Directory]::Exists($entry)) {
                $name = [System.IO.Path]::GetFileName($entry)
                if ($ExcludeDirNames -contains $name) { continue }
                $attr = [System.IO.File]::GetAttributes($entry)
                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($visited.Add($entry)) { $stack.Push($entry) }
            }
            else {
                $ext = [System.IO.Path]::GetExtension($entry)
                if ($ext -and $IncludeSet.ContainsKey($ext.ToLowerInvariant())) { $files.Add($entry) }
            }
        }
        catch { continue }
    }
}

# ---------- 扫描 ----------
$buckets = @{}
$trunc = @{}
foreach ($s in $Symbol) {
    $buckets[$s] = @{
        L1 = [System.Collections.Generic.List[object]]::new()
        L2 = [System.Collections.Generic.List[object]]::new()
        L3 = [System.Collections.Generic.List[object]]::new()
    }
    $trunc[$s] = @{ L1 = $false; L2 = $false; L3 = $false }
}

$fileCount = 0
$bytesRead = 0

foreach ($file in $files) {
    $fileCount++
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    $isDataLane = $DataExt -contains $ext
    $rel = $file.Substring($rootFull.Length).TrimStart('\', '/')
    $isTest = [regex]::IsMatch($rel, $TestPathPattern)

    try {
        $len = ([System.IO.FileInfo]::new($file)).Length
        if ($len -eq 0 -or $len -gt $MaxFileBytes) { continue }
        $bytesRead += $len
        $lines = [System.IO.File]::ReadAllLines($file)
    }
    catch { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -gt 4000) { $line = $line.Substring(0, 4000) }

        foreach ($sym in $Symbol) {
            $pos = $line.IndexOf($sym, $Cmp)
            if ($pos -lt 0) { continue }

            # 逐个命中位置聚合判定
            $inStr = $false
            $exact = $true
            $p = $pos
            while ($p -ge 0) {
                if (Test-QuoteAdjacent -Line $line -Pos $p -Len $sym.Length) { $inStr = $true }
                elseif (Test-InStringLiteral -Line $line -Pos $p) { $inStr = $true }

                $b = if ($p -gt 0) { $line[$p - 1] } else { [char]' ' }
                $j = $p + $sym.Length
                $a = if ($j -lt $line.Length) { $line[$j] } else { [char]' ' }
                if (($b -match '[A-Za-z0-9_]') -or ($a -match '[A-Za-z0-9_]')) { $exact = $false }

                $p = $line.IndexOf($sym, $p + 1, $Cmp)
            }

            if ($isDataLane) { $lane = 'L3' }
            elseif ($inStr -or -not $exact) { $lane = 'L2' }
            else { $lane = 'L1' }

            if ($buckets[$sym][$lane].Count -ge $MaxHits) { $trunc[$sym][$lane] = $true; continue }

            $text = $line.Trim()
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }

            $buckets[$sym][$lane].Add([pscustomobject]@{
                Symbol  = $sym
                Lane    = $lane
                File    = $rel
                Line    = $i + 1
                Text    = $text
                IsTest  = $isTest
                InStr   = $inStr
                Kind    = if ($exact) { 'exact' } else { 'substring' }
            })
        }
    }
}

# ---------- Git 追溯 ----------
$gitRoots = @()
$gitInfo = @{}
$gitNote = $null
if ($Git) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitNote = 'git 未安装，已跳过历史追溯'
    }
    else {
        if (Test-Path -LiteralPath (Join-Path $rootFull '.git')) { $gitRoots += $rootFull }
        else {
            $gitRoots += @(Get-ChildItem -LiteralPath $rootFull -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
                Select-Object -First 3 -ExpandProperty FullName)
        }
        if ($gitRoots.Count -eq 0) {
            $gitNote = '根目录及下一级都没有 .git，已跳过历史追溯'
        }
        else {
            foreach ($sym in $Symbol) {
                $commits = @()
                foreach ($gr in $gitRoots) {
                    try {
                        $out = & git -C $gr log "-S$sym" --format='%h %cs %s' -n 5 -- . 2>$null
                        foreach ($c in @($out | Where-Object { $_ -and $_.Trim() })) {
                            $label = if ($gitRoots.Count -gt 1) { "[$(Split-Path $gr -Leaf)] " } else { '' }
                            $commits += ($label + $c)
                        }
                    }
                    catch { }
                }
                $gitInfo[$sym] = $commits
            }
            if ($gitRoots.Count -gt 1) { $gitNote = "追溯了 $($gitRoots.Count) 个子仓库: $($gitRoots -join ' | ')" }
        }
    }
}

$sw.Stop()

# ---------- JSON 输出 ----------
if ($Json) {
    $payload = [pscustomobject]@{
        root          = $rootFull
        scannedAt     = (Get-Date).ToString('s')
        filesScanned  = $fileCount
        walkTruncated = $walkTruncated
        elapsedMs     = $sw.ElapsedMilliseconds
        symbols       = $Symbol
        results       = @(
            foreach ($sym in $Symbol) {
                [pscustomobject]@{
                    symbol = $sym
                    count  = [pscustomobject]@{
                        L1 = $buckets[$sym]['L1'].Count
                        L2 = $buckets[$sym]['L2'].Count
                        L3 = $buckets[$sym]['L3'].Count
                    }
                    truncated = [pscustomobject]@{
                        L1 = $trunc[$sym]['L1']
                        L2 = $trunc[$sym]['L2']
                        L3 = $trunc[$sym]['L3']
                    }
                    hits = @(
                        $buckets[$sym]['L3'] + $buckets[$sym]['L2'] + $buckets[$sym]['L1']
                    )
                    git = @($gitInfo[$sym])
                }
            }
        )
        gitNote       = $gitNote
    }
    $payload | ConvertTo-Json -Depth 6
    return
}

# ---------- 文本输出 ----------
Write-Host ''
Write-Host "扫描根目录 : $rootFull"
Write-Host "文件数     : $fileCount$(if ($walkTruncated) { ' (已达 MaxFiles 上限，结果不完整)' })"
Write-Host "读取体积   : $([math]::Round($bytesRead / 1MB, 1)) MB"
Write-Host "符号       : $($Symbol -join ', ')"
Write-Host '图例       : [str]=字符串内引用  [sub]=同源命名  [test]=测试资产'
Write-Host ''

function Show-Group {
    param($Items, [string]$Label, [int]$Limit)
    if ($Items.Count -eq 0) { return }
    Write-Host ''
    Write-Host "  $Label"
    $show = if ($Items.Count -gt $Limit) { $Items[0..($Limit - 1)] } else { $Items }
    foreach ($h in $show) {
        $tag = if ($h.IsTest) { ' [test]' } elseif ($h.InStr) { ' [str]' } elseif ($h.Kind -eq 'substring') { ' [sub]' } else { '' }
        Write-Host ("    {0}:{1}{2}" -f $h.File, $h.Line, $tag)
        Write-Host ("      {0}" -f $h.Text)
    }
    if ($Items.Count -gt $Limit) {
        Write-Host ("    ... 还有 {0} 处，用 -Json 取全量" -f ($Items.Count - $Limit))
    }
}

foreach ($sym in $Symbol) {
    $l1 = $buckets[$sym]['L1']
    $l2 = $buckets[$sym]['L2']
    $l3 = $buckets[$sym]['L3']
    $total = $l1.Count + $l2.Count + $l3.Count
    $flag = if ($trunc[$sym]['L1'] -or $trunc[$sym]['L2'] -or $trunc[$sym]['L3']) { '  ⚠ 有层级截断' } else { '' }

    Write-Host ('=' * 78)
    Write-Host ("[{0}]  命中 {1} 处   L3={2}  L2={3}  L1={4}{5}" -f $sym, $total, $l3.Count, $l2.Count, $l1.Count, $flag)
    Write-Host ('=' * 78)

    Show-Group -Items $l3 -Label 'L3 数据/配置契约（改了不可回滚，重点看）' -Limit 40

    $l2str = @($l2 | Where-Object { $_.InStr })
    $l2sub = @($l2 | Where-Object { -not $_.InStr })
    Show-Group -Items $l2str -Label 'L2 字符串内引用（不报错，静默出错）' -Limit 40
    Show-Group -Items $l2sub -Label "L2 同源命名（可能同源，逐个确认是否要跟着改）" -Limit 8

    Show-Group -Items $l1 -Label 'L1 静态引用（编译器会报）' -Limit 12

    if ($gitInfo[$sym] -and $gitInfo[$sym].Count -gt 0) {
        Write-Host ''
        Write-Host '  Git 历史（-S 追溯，改动越频繁越危险）'
        foreach ($c in $gitInfo[$sym]) { Write-Host "    $c" }
    }
    Write-Host ''
}

if ($gitNote) { Write-Host "注: $gitNote" }
Write-Host ("用时 {0:N0} ms" -f $sw.ElapsedMilliseconds)
Write-Host ''
Write-Host '提示：本脚本只找命中，定级与判定由分析者负责；截断或跳过的路径必须写进报告的未验证项。'
