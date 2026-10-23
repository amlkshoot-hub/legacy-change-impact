#requires -Version 5.1
<#
.SYNOPSIS
    legacy-change-impact 的自动化验证。不依赖 Pester，pwsh 7 / Windows PowerShell 5.1 / Linux pwsh 均可运行。

.DESCRIPTION
    覆盖范围：
      · SKILL.md 元数据完整性
      · 命名变体派生与大小写敏感去重（回归：大小写不敏感哈希表吞变体）
      · camelCase 引用确实被扫到（案例核心能力）
      · L1/L2/L3 分层判定
      · 测试文件存在性判断（回归：属性被枚举成数组导致全部误判为存在）
      · -Diff 只从可扫描文件类型提取锚点（回归：文档 diff 产生噪音锚点）
      · CRLF 行尾下 -Diff 仍能工作（回归：路径尾部 CR 导致扩展名匹配失败）
      · 单仓库 -Diff 可用（回归：$gitRoots 标量拆包）
      · JSON 输出结构
      · 失败时退出码非零

.EXAMPLE
    pwsh -File ./tests/run-tests.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

# 5.1 下 param 默认值里取 $PSScriptRoot 会得到空串，改在脚本体里兜底
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }

# ---------- 跨平台路径helper：一律按段拼接，不写死分隔符 ----------
function Join-Rel {
    param([string]$Base, [string]$Rel)
    $p = $Base
    foreach ($seg in ($Rel -split '[\\/]+')) {
        if ($seg) { $p = Join-Path $p $seg }
    }
    return $p
}

function To-Slash {
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

$scriptPath = Join-Rel $RepoRoot 'scripts/scan-refs.ps1'
$caseRepo   = Join-Rel $RepoRoot 'examples/case-study/repo'
$skillMd    = Join-Path $RepoRoot 'SKILL.md'

if (-not (Test-Path $scriptPath)) { throw "找不到扫描脚本: $scriptPath" }

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()

function Write-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Fail++
        $script:Failures += ("{0}{1}" -f $Name, $(if ($Detail) { " — $Detail" } else { '' }))
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " — $Detail" } else { '' })) -ForegroundColor Red
    }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "[$Name]" -ForegroundColor Cyan
    try { & $Body }
    catch {
        Write-Result -Name $Name -Ok $false -Detail $_.Exception.Message
    }
}

function Get-ScanJson {
    param([hashtable]$Params)
    # 用哈希表 splat：数组 splat 会把 "-Symbol" 当成位置参数
    $h = @{}
    foreach ($k in $Params.Keys) { $h[$k] = $Params[$k] }
    $h['Json'] = $true
    $raw = & $scriptPath @h | Out-String
    return ($raw | ConvertFrom-Json)
}

# 临时工作区
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("lcimpact-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force

function New-DiffFixture {
    # 造一个单仓库（覆盖 $gitRoots 标量拆包回归），改动分别落在 .java 与 .md 上，
    # 且 .java 用 CRLF 行尾（覆盖路径尾部 CR 的回归）
    param([string]$Path)

    if (Test-Path $Path) { Remove-Item $Path -Recurse -Force }
    $srcDir = Join-Path $Path 'src'
    $null = New-Item -ItemType Directory $srcDir -Force

    $javaFile = Join-Path $srcDir 'Service.java'
    $mdFile   = Join-Path $Path 'notes.md'

    $javaV1 = "public class Service {" + "`r`n" + "    void oldMethod() {}" + "`r`n" + "}" + "`r`n"
    $mdV1 = "# Notes" + "`r`n" + "oldMethod is documented here." + "`r`n"
    [System.IO.File]::WriteAllText($javaFile, $javaV1, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($mdFile, $mdV1, [System.Text.UTF8Encoding]::new($false))

    & git -C $Path init -q 2>$null
    & git -C $Path add -A 2>$null
    & git -C $Path -c user.name=test -c user.email=test@example.com commit -qm init 2>$null

    $javaV2 = "public class Service {" + "`r`n" + "    void oldMethod() {}" + "`r`n" + "    public void addedMethod() {}" + "`r`n" + "}" + "`r`n"
    $mdV2 = "# Notes" + "`r`n" + "oldMethod is documented here." + "`r`n" + "docOnlyAnchor appears only in docs." + "`r`n"
    [System.IO.File]::WriteAllText($javaFile, $javaV2, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($mdFile, $mdV2, [System.Text.UTF8Encoding]::new($false))
}

try {
    # ---------------------------------------------------------------- T01
    Invoke-Case 'T01 SKILL.md 元数据' {
        $md = Get-Content -LiteralPath $skillMd -Raw
        $hasName = $md -match '(?m)^name:\s*legacy-change-impact\s*$'
        $hasDesc = $md -match '(?m)^description:\s*\S.{20,}'
        Write-Result 'T01 SKILL.md 含 name 与 description' ($hasName -and $hasDesc) `
            "name=$hasName description=$hasDesc"
    }

    # ---------------------------------------------------------------- T02
    Invoke-Case 'T02 命名变体派生' {
        $j = Get-ScanJson @{ Root = $caseRepo; Symbol = 'applicant_name' }
        $v = @($j.results[0].variants)
        $expect = @('applicant_name', 'applicant-name', 'applicantname', 'ApplicantName', 'applicantName', 'APPLICANT_NAME')
        $missing = @($expect | Where-Object { $v -notcontains $_ })
        $dupCase = ($v.Count -ne @($v | Select-Object -Unique).Count)
        Write-Result 'T02 派生 6 个变体且大小写不折叠' (($v.Count -eq 6) -and ($missing.Count -eq 0) -and (-not $dupCase)) `
            "实际 $($v.Count) 个: $($v -join ','); 缺失: $($missing -join ',')"
    }

    # ---------------------------------------------------------------- T03
    Invoke-Case 'T03 camelCase 引用被扫到' {
        $j = Get-ScanJson @{ Root = $caseRepo; Symbol = 'applicant_name' }
        $hits = @($j.results[0].hits)
        $camel = @($hits | Where-Object { $_.Matched -ceq 'applicantName' })
        $pascal = @($hits | Where-Object { $_.Matched -ceq 'ApplicantName' })
        Write-Result 'T03 命中 camelCase 变体' (($camel.Count + $pascal.Count) -eq 23) `
            "camel=$($camel.Count) pascal=$($pascal.Count)（期望 23）"
    }

    # ---------------------------------------------------------------- T04
    Invoke-Case 'T04 三层分类' {
        $j = Get-ScanJson @{ Root = $caseRepo; Symbol = 'applicant_name' }
        $hits = @($j.results[0].hits)

        $annotation = @($hits | Where-Object { (To-Slash $_.File) -like '*/Order.java' -and $_.Line -eq 14 })[0]
        $migration  = @($hits | Where-Object { (To-Slash $_.File) -like '*.sql' -and (To-Slash $_.File) -like '*V12*' })[0]
        $tsField    = @($hits | Where-Object { (To-Slash $_.File) -like '*order.ts' -and $_.Line -eq 5 })[0]

        $ok1 = $annotation -and $annotation.Lane -eq 'L2' -and $annotation.InStr
        $ok2 = $migration -and $migration.Lane -eq 'L3'
        $ok3 = $tsField -and $tsField.Lane -eq 'L1'
        Write-Result 'T04 @TableField=L2 / 迁移=L3 / TS 字段=L1' ($ok1 -and $ok2 -and $ok3) `
            "annotation=$($annotation.Lane) migration=$($migration.Lane) ts=$($tsField.Lane)"
    }

    # ---------------------------------------------------------------- T05
    Invoke-Case 'T05 测试文件存在性' {
        $j = Get-ScanJson @{ Root = $caseRepo; Symbol = 'applicant_name' }
        $guessed = @($j.suggestedTests.guessed | ForEach-Object { To-Slash $_ })
        $notExist = @($j.suggestedTests.guessed | Where-Object { -not (Test-Path -LiteralPath (Join-Rel $caseRepo $_)) })
        $hasReal = $guessed -contains 'src/test/java/com/acme/order/OrderServiceTest.java'
        $hasFalse = $guessed -contains 'src/test/java/com/acme/order/OrderMapperTest.java'
        Write-Result 'T05 只报告真实存在的测试文件' (($notExist.Count -eq 0) -and $hasReal -and (-not $hasFalse)) `
            "不存在却被报告: $($notExist -join ','); 含真实: $hasReal; 含伪造: $hasFalse"
    }

    # ---------------------------------------------------------------- T06
    $diffFixture = Join-Path $tmpRoot 'diffrepo'
    New-DiffFixture -Path $diffFixture

    Invoke-Case 'T06 diff 按文件类型过滤' {
        $j = Get-ScanJson @{ Root = $diffFixture; Diff = 'working' }
        $anchors = @($j.diffAnchors)
        $hasJava = $anchors -ccontains 'addedMethod'
        $hasDoc  = $anchors -ccontains 'docOnlyAnchor'
        Write-Result 'T06 只提取代码文件里的锚点' ($hasJava -and (-not $hasDoc)) `
            "锚点: $($anchors -join ','); 命中 java=$hasJava 混入文档=$hasDoc"
    }

    # ---------------------------------------------------------------- T07
    Invoke-Case 'T07 CRLF 行尾' {
        $j = Get-ScanJson @{ Root = $diffFixture; Diff = 'working' }
        $hit = @($j.results | Where-Object { $_.symbol -ceq 'addedMethod' })
        $ok = ($hit.Count -eq 1) -and ($hit[0].count.L1 -ge 1)
        Write-Result 'T07 CRLF 下仍能提取并扫到定义' $ok `
            "symbol 数=$($j.results.Count); L1=$($hit[0].count.L1)"
    }

    # ---------------------------------------------------------------- T08
    Invoke-Case 'T08 JSON 结构' {
        $j = Get-ScanJson @{ Root = $caseRepo; Symbol = 'applicant_name' }
        $fields = 'root', 'filesScanned', 'symbols', 'results', 'suggestedTests', 'elapsedMs'
        $missing = @($fields | Where-Object { $null -eq $j.$_ })
        $lane = $j.results[0].count
        $okLane = ($null -ne $lane.L1) -and ($null -ne $lane.L2) -and ($null -ne $lane.L3)
        Write-Result 'T08 必需字段齐全' (($missing.Count -eq 0) -and $okLane) `
            "缺失: $($missing -join ',')"
    }

    # ---------------------------------------------------------------- T09
    Invoke-Case 'T09 无锚点时退出码非零' {
        $exeName = if ($PSVersionTable.PSEdition -eq 'Core') {
            if ($env:OS -eq 'Windows_NT') { 'pwsh.exe' } else { 'pwsh' }
        } else { 'powershell.exe' }
        $psExe = Join-Path $PSHOME $exeName

        # 造一个"无改动"的仓库：-Diff HEAD 取不到锚点，应显式失败而不是静默扫空
        $emptyRepo = Join-Path $tmpRoot 'emptydiff'
        $sub = Join-Path $emptyRepo 'src'
        $null = New-Item -ItemType Directory $sub -Force
        [System.IO.File]::WriteAllText((Join-Path $sub 'A.java'), "public class A {}`r`n", [System.Text.UTF8Encoding]::new($false))
        & git -C $emptyRepo init -q 2>$null
        & git -C $emptyRepo add -A 2>$null
        & git -C $emptyRepo -c user.name=test -c user.email=test@example.com commit -qm init 2>$null

        $exeArgs = @('-NoProfile')
        if ($env:OS -eq 'Windows_NT') { $exeArgs += @('-ExecutionPolicy', 'Bypass') }
        $exeArgs += @('-File', $scriptPath, '-Root', $emptyRepo, '-Diff', 'HEAD')

        # 5.1 会把原生命令的 stderr 变成终止错误（EAP=Stop 时直接抛），临时降级
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $psExe @exeArgs *> $null
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
        Write-Result 'T09 空锚点返回非零' ($code -ne 0) "exit=$code"
    }
}
finally {
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host ('=' * 60)
Write-Host ("通过 {0} / 失败 {1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) {
    Write-Host '失败项:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host ('=' * 60)

if ($script:Fail -gt 0) { exit 1 }
exit 0
