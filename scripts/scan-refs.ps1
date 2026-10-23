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

    命名变体：输入 WlwCardApplication 会自动派生 wlw_card_application / wlw-card-application /
    WLW_CARD_APPLICATION / wlwCardApplication 等一起扫（-NoVariants 关闭）。

    diff 模式：-Diff 从 git diff 自动提取改动的类名/函数名/表名/配置键作为锚点，不用手输符号。

.EXAMPLE
    .\scan-refs.ps1 -Root C:\repo -Symbol get_user_profile,user_profile,profile_cache_ttl -Git

.EXAMPLE
    .\scan-refs.ps1 -Root C:\repo -Diff HEAD~1

.EXAMPLE
    .\scan-refs.ps1 -Root C:\repo -Diff working -Json | Out-File report.json -Encoding utf8
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Root,

    [Parameter(Position = 1)]
    [string[]]$Symbol,

    # git diff 的版本范围：HEAD~1 / main / 'working'(未暂存) / 'staged'(已暂存)
    [string]$Diff,

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
    [switch]$NoVariants,
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

$RxOpt = if ($IgnoreCase) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
         else { [System.Text.RegularExpressions.RegexOptions]::None }

$CH_SQ = [char]39; $CH_DQ = [char]34; $CH_BT = [char]96; $CH_BS = [char]92

# 关键词黑名单：从 diff 提取锚点时挡掉语法噪音
$Keywords = @(
    'if', 'else', 'for', 'foreach', 'while', 'return', 'new', 'class', 'public', 'private',
    'protected', 'static', 'final', 'void', 'int', 'long', 'bool', 'boolean', 'string', 'var',
    'let', 'const', 'function', 'def', 'import', 'from', 'package', 'using', 'namespace',
    'try', 'catch', 'finally', 'throw', 'throws', 'switch', 'case', 'break', 'continue',
    'true', 'false', 'null', 'nil', 'none', 'undefined', 'this', 'self', 'super', 'await',
    'async', 'yield', 'lambda', 'interface', 'enum', 'struct', 'record', 'trait', 'abstract',
    'synchronized', 'override', 'virtual', 'extern', 'inline', 'select', 'where', 'update',
    'set', 'values', 'table', 'index', 'column', 'add', 'drop', 'alter', 'create', 'into'
)

# ---------- 工具函数 ----------
function Get-Words {
    param([string]$Text)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in ($Text -split '[_\-\.\s/]+')) {
        if (-not $seg) { continue }
        foreach ($m in [regex]::Matches($seg, '[A-Z]+(?![a-z])|[A-Z][a-z0-9]*|[a-z0-9]+')) {
            $out.Add($m.Value)
        }
    }
    return $out.ToArray()
}

function Get-SymbolVariants {
    # 由一个符号派生命名变体（camel / Pascal / snake / kebab / 常量 / 无分隔）
    param([string]$Sym)
    $words = Get-Words -Text $Sym
    if ($words.Count -eq 0) { return @($Sym) }
    $lower = @($words | ForEach-Object { $_.ToLowerInvariant() })
    $cap = @($lower | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) })

    $camel = $lower[0]
    for ($i = 1; $i -lt $lower.Count; $i++) { $camel += $cap[$i] }

    $list = [System.Collections.Generic.List[string]]::new()
    $list.Add($Sym)
    $list.Add(($lower -join '_'))
    $list.Add(($lower -join '-'))
    $list.Add(($lower -join ''))
    $list.Add(($cap -join ''))
    $list.Add($camel)
    $list.Add(($lower -join '_').ToUpperInvariant())

    # 必须区分大小写：UserProfile / userProfile / USER_PROFILE 是三个不同变体
    $seen = [hashtable]::new([System.StringComparer]::Ordinal)
    $res = @()
    foreach ($v in $list) {
        if (-not $v -or $v.Length -lt 3) { continue }
        $key = if ($IgnoreCase) { $v.ToLowerInvariant() } else { $v }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $res += $v
    }
    return $res
}

function Find-GitRoots {
    param([string]$RootPath)
    if (Test-Path -LiteralPath (Join-Path $RootPath '.git')) { return @($RootPath) }
    return @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
        Select-Object -First 3 -ExpandProperty FullName)
}

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

function Get-DiffAnchors {
    # 从 git diff 里提取"被改动的定义"作为锚点：类/函数/表/配置键/注解字符串
    param([string]$GitRoot, [string]$Spec, [hashtable]$AllowExt)

    $gitArgs = @('diff', '--unified=0', '--no-color')
    switch ($Spec) {
        'working' { }
        'staged' { $gitArgs += '--cached' }
        default { $gitArgs += $Spec }
    }

    try { $raw = & git -C $GitRoot @gitArgs 2>$null }
    catch { return @() }
    if (-not $raw) { return @() }

    $defRes = @(
        '\bdef\s+([A-Za-z_]\w{2,})',
        '\bclass\s+([A-Za-z_]\w{2,})',
        '\b(?:interface|enum|struct|record|trait)\s+([A-Za-z_]\w{2,})',
        '\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_][\w\-]{2,})',
        '\bfunction\s+([A-Za-z_][\w\-]{2,})',
        '\b(?:public|private|protected)\s+(?:static\s+|final\s+|abstract\s+|synchronized\s+)*[\w<>\[\],\.\?\s]+\s+([A-Za-z_]\w{2,})\s*\(',
        '^\s*[\w<>\[\],\.\?]+\s+([A-Za-z_]\w{2,})\s*\([^;]*\)\s*\{',
        '\bconst\s+([A-Za-z_]\w{2,})\s*=',
        '\b(?:ALTER|CREATE|DROP)\s+TABLE\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?\W?([A-Za-z_][\w\.]*)',
        '\b(?:UPDATE|FROM|INTO|JOIN)\s+([A-Za-z_]\w{3,})',
        '@\w+\(\s*"([^"]{2,})"'
    )
    $keyRes = @('^\s*["'']?([A-Za-z_][\w\.\-]{2,})["'']?\s*[:=]')
    $ConfigExt = @('.yml', '.yaml', '.properties', '.ini', '.json', '.toml', '.conf', '.cfg', '.env')

    $hits = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    $curExt = ''

    foreach ($line in $raw) {
        if ($line -match '^\+\+\+ b/(.+)$') {
            $e = [System.IO.Path]::GetExtension($Matches[1].Trim()).ToLowerInvariant()
            $curExt = if ($AllowExt -and $AllowExt.ContainsKey($e)) { $e } else { '' }
            continue
        }
        if ($line -match '^\+\+\+ /dev/null') { $curExt = ''; continue }
        if (-not $curExt) { continue }
        if ($line -notmatch '^[+-]' -or $line -match '^(\+\+\+|---)') { continue }
        $body = $line.Substring(1)
        if ([string]::IsNullOrWhiteSpace($body)) { continue }

        $pats = $defRes
        if ($ConfigExt -contains $curExt) { $pats = $defRes + $keyRes }

        foreach ($p in $pats) {
            $m = [regex]::Match($body, $p)
            if (-not $m.Success) { continue }
            $v = $m.Groups[1].Value.Trim()
            if ($v.Length -lt 3) { continue }
            if ($Keywords -contains $v.ToLowerInvariant()) { continue }
            if ($v -match '^\d') { continue }
            if (-not $hits.ContainsKey($v)) {
                $hits[$v] = 0
                $order.Add($v)
            }
            $hits[$v]++
        }
    }

    # 5.1 的 Sort-Object 没有 -Stable：用「次数降序 + 首次出现升序」的复合排序保证稳定
    $orderIndex = @{}
    for ($oi = 0; $oi -lt $order.Count; $oi++) { $orderIndex[$order[$oi]] = $oi }
    $ranked = $order | Sort-Object @{ Expression = { $hits[$_] }; Descending = $true }, @{ Expression = { $orderIndex[$_] }; Ascending = $true }
    return @($ranked | Select-Object -First 12)
}

function Join-RelPath {
    # 按路径段拼接，不依赖分隔符字面量（Windows / Linux 通用）
    param([string]$Base, [string]$Rel)
    $p = $Base
    foreach ($seg in ($Rel -split '[\\/]+')) {
        if ($seg) { $p = Join-Path $p $seg }
    }
    return $p
}

function To-NativeRel {
    # 把统一用 / 表示的相对路径转成当前平台的分隔符
    param([string]$Rel)
    $parts = @($Rel -split '[\\/]+' | Where-Object { $_ })
    return ($parts -join [System.IO.Path]::DirectorySeparatorChar)
}

function Get-TestCandidates {
    # 由命中源文件推测测试文件路径，并标注是否真实存在。
    # 内部统一用 / 计算，输出时转成平台分隔符，避免 Windows/Linux 差异。
    param([string]$RootPath, [string[]]$SourceFiles)

    $result = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($relRaw in $SourceFiles) {
        $rel = $relRaw -replace '\\', '/'
        $name = [System.IO.Path]::GetFileNameWithoutExtension($rel)
        $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
        if (-not $name) { continue }

        $slash = $rel.LastIndexOf('/')
        $dir = if ($slash -gt 0) { $rel.Substring(0, $slash) } else { '' }

        $cands = @()
        switch ($ext) {
            '.java' {
                $t = $rel -replace '(^|/)src/main/java/', '${1}src/test/java/'
                $t = $t -replace '\.java$', 'Test.java'
                $cands += $t
                $cands += ($t -replace 'Test\.java$', 'Tests.java')
            }
            '.kt' {
                $t = $rel -replace '(^|/)src/main/kotlin/', '${1}src/test/kotlin/'
                $cands += ($t -replace '\.kt$', 'Test.kt')
            }
            '.cs' { $cands += ($rel -replace '\.cs$', 'Tests.cs') }
            '.go' { $cands += ($rel -replace '\.go$', '_test.go') }
            '.py' {
                $cands += ((@($dir, "test_$name.py") | Where-Object { $_ }) -join '/')
                $cands += ((@($dir, "${name}_test.py") | Where-Object { $_ }) -join '/')
                $cands += "tests/test_$name.py"
                $cands += "tests/${name}_test.py"
            }
            '.ts' {
                $cands += ($rel -replace '\.ts$', '.test.ts')
                $cands += ($rel -replace '\.ts$', '.spec.ts')
                $cands += ((@($dir, '__tests__', "$name.test.ts") | Where-Object { $_ }) -join '/')
            }
            '.tsx' {
                $cands += ($rel -replace '\.tsx$', '.test.tsx')
                $cands += ((@($dir, '__tests__', "$name.test.tsx") | Where-Object { $_ }) -join '/')
            }
            '.js' {
                $cands += ($rel -replace '\.js$', '.test.js')
                $cands += ($rel -replace '\.js$', '.spec.js')
            }
            '.vue' {
                $cands += ($rel -replace '\.vue$', '.spec.ts')
                $cands += ((@($dir, '__tests__', "$name.spec.ts") | Where-Object { $_ }) -join '/')
            }
        }

        foreach ($c in $cands) {
            $norm = To-NativeRel $c
            if (-not $norm) { continue }
            if ($seen.ContainsKey($norm)) { continue }
            $seen[$norm] = $true
            $full = Join-RelPath -Base $RootPath -Rel $norm
            $result.Add([pscustomobject]@{
                Source = $rel
                Test   = $norm
                Exists = [bool](Test-Path -LiteralPath $full)
            })
        }
    }
    return $result.ToArray()
}
function Get-TestRunner {
    # 探测构建系统，给出可执行的测试命令提示
    param([string]$RootPath, [string[]]$TestFiles)

    $has = { param($rel) Test-Path -LiteralPath (Join-Path $RootPath $rel) }

    if (& $has 'pom.xml') {
        $classes = @($TestFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
        if ($classes.Count -gt 0) { return 'mvn -q -Dtest=' + ($classes -join ',') + ' test' }
        return 'mvn -q test'
    }
    if ((& $has 'build.gradle') -or (& $has 'build.gradle.kts')) {
        $patterns = @($TestFiles | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_) } | Select-Object -Unique)
        if ($patterns.Count -gt 0) { return 'gradle test --tests "' + ($patterns -join '" --tests "') + '"' }
        return 'gradle test'
    }
    if (& $has 'go.mod') { return 'go test ./...' }
    if ((& $has 'pyproject.toml') -or (& $has 'pytest.ini') -or (& $has 'tox.ini') -or (& $has 'setup.cfg')) {
        if ($TestFiles.Count -gt 0) { return 'pytest ' + (($TestFiles | Select-Object -First 3) -join ' ') }
        return 'pytest'
    }
    if (& $has 'package.json') {
        if ($TestFiles.Count -gt 0) { return 'npm test -- ' + (($TestFiles | Select-Object -First 3) -join ' ') }
        return 'npm test'
    }
    return $null
}

# ---------- 校验参数与根目录 ----------
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Root 不是目录或不存在: $Root"
}
$rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

$IncludeSet = @{}
foreach ($e in $Include) {
    $k = if ($e.StartsWith('.')) { $e.ToLowerInvariant() } else { ('.' + $e).ToLowerInvariant() }
    $IncludeSet[$k] = $true
}
$gitRoots = @(Find-GitRoots -RootPath $rootFull)

$diffAnchors = @()
$diffNote = $null
if ($Diff) {
    if ($gitRoots.Count -eq 0) {
        $diffNote = "指定了 -Diff '$Diff'，但根目录及下一级都没有 git 仓库"
    }
    else {
        $diffAnchors = @(Get-DiffAnchors -GitRoot $gitRoots[0] -Spec $Diff -AllowExt $IncludeSet)
        if ($diffAnchors.Count -eq 0) {
            $diffNote = "diff '$Diff' 里没有提取到锚点（可能只改了空格/注释，或版本范围写错）"
        }
    }
}

$Symbol = @(@($Symbol) + @($diffAnchors) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
if ($Symbol.Count -eq 0) {
    if ($Diff) { throw "未从 -Diff '$Diff' 提取到任何锚点；请改用 -Symbol 指定" }
    throw '必须提供 -Symbol 或 -Diff'
}

# ---------- 派生变体 ----------
$anchorOf = [hashtable]::new([System.StringComparer]::Ordinal)
$allVariants = [System.Collections.Generic.List[string]]::new()
$anchorVariants = @{}

foreach ($a in $Symbol) {
    $vars = if ($NoVariants) { @($a) } else { @(Get-SymbolVariants -Sym $a) }
    $anchorVariants[$a] = $vars
    foreach ($v in $vars) {
        $key = if ($IgnoreCase) { $v.ToLowerInvariant() } else { $v }
        if (-not $anchorOf.ContainsKey($key)) {
            $anchorOf[$key] = $a
            $allVariants.Add($v)
        }
    }
}

$sortedVariants = @($allVariants | Sort-Object -Property Length -Descending)
$alt = ($sortedVariants | ForEach-Object { [regex]::Escape($_) }) -join '|'
$rx = [regex]::new($alt, $RxOpt)



# ---------- 遍历文件 ----------
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
foreach ($a in $Symbol) {
    $buckets[$a] = @{
        L1 = [System.Collections.Generic.List[object]]::new()
        L2 = [System.Collections.Generic.List[object]]::new()
        L3 = [System.Collections.Generic.List[object]]::new()
    }
    $trunc[$a] = @{ L1 = $false; L2 = $false; L3 = $false }
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

        $ms = $rx.Matches($line)
        if ($ms.Count -eq 0) { continue }

        $lineAnchors = @{}
        foreach ($m in $ms) {
            $vkey = if ($IgnoreCase) { $m.Value.ToLowerInvariant() } else { $m.Value }
            $anchor = $anchorOf[$vkey]
            if (-not $anchor) { continue }

            $inStr = (Test-QuoteAdjacent -Line $line -Pos $m.Index -Len $m.Length) -or
                     (Test-InStringLiteral -Line $line -Pos $m.Index)

            $b = if ($m.Index -gt 0) { $line[$m.Index - 1] } else { [char]' ' }
            $j = $m.Index + $m.Length
            $after = if ($j -lt $line.Length) { $line[$j] } else { [char]' ' }
            $exact = -not ((($b -match '[A-Za-z0-9_]') -or ($after -match '[A-Za-z0-9_]')))

            if ($isDataLane) { $lane = 'L3' }
            elseif ($inStr -or -not $exact) { $lane = 'L2' }
            else { $lane = 'L1' }

            $lk = "$anchor|$lane"
            if ($lineAnchors.ContainsKey($lk)) { continue }

            if ($buckets[$anchor][$lane].Count -ge $MaxHits) { $trunc[$anchor][$lane] = $true; continue }
            $lineAnchors[$lk] = $true

            $text = $line.Trim()
            if ($text.Length -gt 200) { $text = $text.Substring(0, 200) + '...' }

            $buckets[$anchor][$lane].Add([pscustomobject]@{
                Anchor  = $anchor
                Matched = $m.Value
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

# ---------- 测试映射 ----------
$allHits = @(
    foreach ($a in $Symbol) { $buckets[$a]['L1'] + $buckets[$a]['L2'] + $buckets[$a]['L3'] }
)
$hitFiles = @($allHits | Where-Object { -not $_.IsTest } | ForEach-Object { $_.File } | Select-Object -Unique)
$existingTests = @($allHits | Where-Object { $_.IsTest } | ForEach-Object { $_.File } | Select-Object -Unique)

$testCands = @(Get-TestCandidates -RootPath $rootFull -SourceFiles @($hitFiles | Select-Object -First 40))
$guessedTests = @($testCands | Where-Object { $_.Exists } | ForEach-Object { $_.Test } | Select-Object -Unique)

$allTests = @(@($existingTests) + @($guessedTests) | Select-Object -Unique)
$testCmd = Get-TestRunner -RootPath $rootFull -TestFiles $allTests

# ---------- Git 追溯 ----------
$gitInfo = @{}
$gitHistoryNote = $null
if ($Git) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $gitHistoryNote = 'git 未安装，已跳过历史追溯'
    }
    elseif ($gitRoots.Count -eq 0) {
        $gitHistoryNote = '根目录及下一级都没有 .git，已跳过历史追溯'
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
        if ($gitRoots.Count -gt 1) { $gitHistoryNote = "追溯了 $($gitRoots.Count) 个子仓库: $($gitRoots -join ' | ')" }
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
        diff          = $Diff
        diffAnchors   = @($diffAnchors)
        symbols       = $Symbol
        results       = @(
            foreach ($sym in $Symbol) {
                [pscustomobject]@{
                    symbol    = $sym
                    variants  = @($anchorVariants[$sym])
                    count     = [pscustomobject]@{
                        L1 = $buckets[$sym]['L1'].Count
                        L2 = $buckets[$sym]['L2'].Count
                        L3 = $buckets[$sym]['L3'].Count
                    }
                    truncated = [pscustomobject]@{
                        L1 = $trunc[$sym]['L1']
                        L2 = $trunc[$sym]['L2']
                        L3 = $trunc[$sym]['L3']
                    }
                    hits      = @($buckets[$sym]['L3'] + $buckets[$sym]['L2'] + $buckets[$sym]['L1'])
                    git       = @($gitInfo[$sym])
                }
            }
        )
        suggestedTests = [pscustomobject]@{
            existing = @($existingTests)
            guessed  = @($guessedTests)
            command  = $testCmd
        }
        gitNote       = $gitHistoryNote
        diffNote      = $diffNote
    }
    $payload | ConvertTo-Json -Depth 6
    return
}

# ---------- 文本输出 ----------
Write-Host ''
Write-Host "扫描根目录 : $rootFull"
Write-Host "文件数     : $fileCount$(if ($walkTruncated) { ' (已达 MaxFiles 上限，结果不完整)' })"
Write-Host "读取体积   : $([math]::Round($bytesRead / 1MB, 1)) MB"
Write-Host "锚点       : $($Symbol -join ', ')"
if (-not $NoVariants) {
    $summary = @($Symbol | ForEach-Object { "$_(" + ($anchorVariants[$_].Count) + "变体)" })
    Write-Host "命名变体   : $($summary -join '  ')"
}
if ($Diff) {
    Write-Host "diff 来源  : $Diff  →  提取 $($diffAnchors.Count) 个锚点"
    if ($diffAnchors.Count -gt 0) { Write-Host "              $($diffAnchors -join ', ')" }
}
if ($diffNote) { Write-Host "注意       : $diffNote" }
Write-Host '图例       : [str]=字符串内引用  [sub]=同源命名  [var:]=变体命中  [test]=测试资产'
Write-Host ''

function Show-Group {
    param($Items, [string]$Label, [int]$Limit)
    if ($Items.Count -eq 0) { return }
    Write-Host ''
    Write-Host "  $Label"
    $show = if ($Items.Count -gt $Limit) { $Items[0..($Limit - 1)] } else { $Items }
    foreach ($h in $show) {
        $tags = @()
        if ($h.IsTest) { $tags += 'test' }
        if ($h.InStr) { $tags += 'str' }
        if ($h.Kind -eq 'substring') { $tags += 'sub' }
        if ($h.Matched -ne $h.Anchor) { $tags += ('var:' + $h.Matched) }
        $tag = if ($tags.Count -gt 0) { ' [' + ($tags -join ' ') + ']' } else { '' }
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

    Show-Group -Items $l3 -Label 'L3 数据/配置契约（回滚成本高，重点看）' -Limit 40

    $l2str = @($l2 | Where-Object { $_.InStr })
    $l2sub = @($l2 | Where-Object { -not $_.InStr })
    Show-Group -Items $l2str -Label 'L2 字符串内引用（不报错，静默出错）' -Limit 40
    Show-Group -Items $l2sub -Label 'L2 同源命名（可能同源，逐个确认是否要跟着改）' -Limit 8

    Show-Group -Items $l1 -Label 'L1 静态引用（编译器会报）' -Limit 12

    if ($gitInfo[$sym] -and $gitInfo[$sym].Count -gt 0) {
        Write-Host ''
        Write-Host '  Git 历史（-S 追溯，改动越频繁越危险）'
        foreach ($c in $gitInfo[$sym]) { Write-Host "    $c" }
    }
    Write-Host ''
}

Write-Host ('=' * 78)
Write-Host '建议执行的回归'
Write-Host ('=' * 78)
if ($existingTests.Count -eq 0 -and $guessedTests.Count -eq 0) {
    Write-Host '  未找到相关测试文件——这条要写进报告的"未验证项"，不要声称已验证'
}
else {
    if ($existingTests.Count -gt 0) {
        Write-Host '  命中里直接出现的测试资产:'
        foreach ($t in $existingTests) { Write-Host "    $t" }
    }
    if ($guessedTests.Count -gt 0) {
        Write-Host '  按命名约定推测且确实存在:'
        foreach ($t in $guessedTests) { Write-Host "    $t" }
    }
    if ($testCmd) { Write-Host ''; Write-Host "  建议命令: $testCmd" }
}
Write-Host ''

if ($gitHistoryNote) { Write-Host "注: $gitHistoryNote" }
Write-Host ("用时 {0:N0} ms" -f $sw.ElapsedMilliseconds)
Write-Host ''
Write-Host '提示：本脚本只找命中，定级与判定由分析者负责；截断或跳过的路径必须写进报告的未验证项。'
