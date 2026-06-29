# Generic HarmonyOS build + install to device/emulator
[CmdletBinding()]
param(
  [ValidateSet('debug','release')][string]$BuildMode = 'debug',
  [string]$Product = '',
  [string]$Device = '',
  [string]$BundleName = '',
  [switch]$Clean,
  [switch]$Launch,
  [switch]$SkipOhpm,
  [switch]$NoUninstall,
  [switch]$Test,
  [switch]$NoTest,
  [switch]$KeepArtifacts,
  [int]$TestTimeout = 15000
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Die($m){ Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# JSON5 parser: node strips comments/trailing commas then JSON.parse
function ConvertFrom-Json5 {
  param([Parameter(Mandatory)][string]$Path)
  $code = @'
const fs=require('fs');const raw=fs.readFileSync(process.argv[2],'utf8');
let o='',i=0,s=false,q='';
while(i<raw.length){const c=raw[i],n=raw[i+1];
 if(s){o+=c;if(c==='\\'){o+=raw[i+1];i+=2;continue;}if(c===q)s=false;i++;continue;}
 if(c==='"'||c==="'"){s=true;q=c;o+=c;i++;continue;}
 if(c==='/'&&n==='/'){while(i<raw.length&&raw[i]!=='\n')i++;continue;}
 if(c==='/'&&n==='*'){i+=2;while(i<raw.length&&!(raw[i]==='*'&&raw[i+1]==='/'))i++;i+=2;continue;}
 o+=c;i++;}
o=o.replace(/,\s*([}\]])/g,'$1');process.stdout.write(JSON.stringify(JSON.parse(o)));
'@
  $tmp=[IO.Path]::GetTempFileName(); [IO.File]::WriteAllText($tmp, $code)
  try { $j=& node $tmp $Path; if($LASTEXITCODE -ne 0){Die "Parse failed: $Path"}; return $j|ConvertFrom-Json }
  finally { Remove-Item -LiteralPath $tmp -Force }
}

# Force-remove a path, handling Windows long paths (>260) via \\?\ prefix
function Remove-PathForce {
  param([Parameter(Mandatory)][string]$Path)
  if(-not (Test-Path -LiteralPath $Path)){ return $true }
  try {
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $long = '\\?\' + $full
    $item = Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer){ [IO.Directory]::Delete($long, $true) }
    else { [IO.File]::Delete($long) }
    return $true
  } catch {
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $true } catch { return $false }
  }
}

# 0. Env check
Write-Step "Environment check"
foreach($t in 'hvigorw','hdc','ohpm','node'){ if(-not(Get-Command $t -ErrorAction SilentlyContinue)){Die "Command not found: $t"} }
Write-Host "  OK" -ForegroundColor Green

# 1. Detect params
Write-Step "Detecting project params"
$bp = ConvertFrom-Json5 (Join-Path $Root 'build-profile.json5')
if(-not $Product){ $Product = $bp.app.products[0].name }
if(-not $BundleName){ $app = ConvertFrom-Json5 (Join-Path $Root 'AppScope/app.json5'); $BundleName = $app.app.bundleName }
$Entry=$null; $EntrySrc=$null
foreach($m in $bp.modules){
  $rel = $m.srcPath -replace '^[./\\]+','' -replace '/','\'
  $mj = Join-Path $Root (Join-Path $rel 'src\main\module.json5')
  if(Test-Path -LiteralPath $mj){ $mo = ConvertFrom-Json5 $mj; if($mo.module.type -eq 'entry'){$Entry=$mo.module;$EntrySrc=$m.srcPath;break} }
}
if(-not $Entry){ Die "No entry module found" }
$ModuleName=$Entry.name; $AbilityName=$Entry.mainElement
Write-Host ("  bundle={0}  product={1}  module={2}  ability={3}  mode={4}" -f $BundleName,$Product,$ModuleName,$AbilityName,$BuildMode)

# 2. Dependencies
if(-not $SkipOhpm){ Write-Step "Installing deps (ohpm install)"; & ohpm install; if($LASTEXITCODE -ne 0){Die "ohpm install failed"} }

# 3. Clean
if($Clean){ Write-Step "Clean (hvigorw clean)"; & hvigorw clean --no-daemon; if($LASTEXITCODE -ne 0){Die "clean failed"} }

# 4. Build HAP (commons/shopping are har, compiled into the entry HAP)
Write-Step "Build HAP (assembleHap)"
& hvigorw -p "product=$Product" -p "buildMode=$BuildMode" assembleHap --no-daemon
if($LASTEXITCODE -ne 0){ Die "Build failed" }

# 5. Locate artifact (prefer -signed)
Write-Step "Locate HAP artifact"
$rel = $EntrySrc -replace '^[./\\]+','' -replace '/','\'
$buildDir = Join-Path $Root (Join-Path $rel 'build')
$haps = Get-ChildItem -Path $buildDir -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -notmatch 'test' }
if(-not $haps){ Die "No HAP found under: $buildDir" }
$hap = @($haps | Where-Object {$_.Name -match '-signed\.hap$'})[0]
if(-not $hap){ $hap = @($haps | Sort-Object LastWriteTime -Desc)[0] }
Write-Host ("  HAP = {0}" -f $hap.FullName)

# 6. Device selection
$_out = & hdc list targets
$targets = @($_out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '[Empty]' })
# No device detected: interactive menu (re-detect / auto-start emulator / quit)
while($targets.Count -eq 0){
  if([Console]::IsInputRedirected){
    Write-Host ""
    Write-Host "未检测到设备/模拟器（模拟器可能未启动）。" -ForegroundColor Yellow
    Write-Host "请先在 DevEco Studio 启动模拟器，或用 USB 连接真机并开启调试，然后重跑脚本。" -ForegroundColor Yellow
    Die "No device/emulator detected (non-interactive)"
  }
  Write-Host ""
  Write-Host "未检测到设备/模拟器（模拟器可能未启动）。" -ForegroundColor Yellow
  Write-Host "请选择：" -ForegroundColor Yellow
  Write-Host "  [1] 我已手动启动模拟器/连接真机 —— 重新检测" -ForegroundColor Yellow
  Write-Host "  [2] 自动启动本地模拟器（输入模拟器路径 + 设备名称，由脚本自动启动并等待就绪）" -ForegroundColor Yellow
  Write-Host "  [q] 退出" -ForegroundColor Yellow
  $choice = Read-Host "请输入选项 [1/2/q]（默认 1）"
  switch -Regex ($choice){
    '^q' { Die "用户取消，未连接设备/模拟器" }
    '^2' {
      # 2a. Emulator executable path (auto-discover from DEVECO_SDK_HOME)
      $emuDefault = $null
      if($env:DEVECO_SDK_HOME){
        $cand = Join-Path $env:DEVECO_SDK_HOME '..\tools\emulator\Emulator.exe'
        if(Test-Path -LiteralPath $cand){ $emuDefault = (Resolve-Path $cand).Path }
      }
      if($emuDefault){
        $emuPath = Read-Host "请输入模拟器可执行文件路径（回车使用默认：$emuDefault）"
        if(-not $emuPath){ $emuPath = $emuDefault }
      } else {
        $emuPath = Read-Host "请输入模拟器可执行文件路径（如 D:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe）"
      }
      if([string]::IsNullOrWhiteSpace($emuPath) -or -not (Test-Path -LiteralPath $emuPath -PathType Leaf)){
        Write-Host "  路径不存在或不是可执行文件（请输入完整的 Emulator.exe 文件路径，而非目录）。" -ForegroundColor Red
        break
      }
      # 2b. List available device instances for reference
      Write-Host "  正在查询可用模拟器实例（Emulator -list）..." -ForegroundColor Cyan
      try {
        $listOut = & $emuPath -list 2>&1 | Out-String
        if([string]::IsNullOrWhiteSpace($listOut)){
          Write-Host "  未查询到模拟器实例，请确认 Emulator.exe 路径是否正确。" -ForegroundColor Red
          break
        }
        Write-Host $listOut -ForegroundColor DarkGray
      } catch {
        Write-Host ("  执行 -list 失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        break
      }
      # 2c. Device name
      $emuName = Read-Host "请输入要启动的设备名称（上列表中的某一项）"
      if(-not $emuName){
        Write-Host "  设备名称为空，请重新选择。" -ForegroundColor Red
        break
      }
      # 2d. Launch emulator async (-start <name>; handle names with spaces via quoting)
      Write-Host ("  正在启动模拟器：{0} -start {1}" -f $emuPath, $emuName) -ForegroundColor Cyan
      try {
        $emuArgs = '-start "{0}"' -f $emuName
        Start-Process -FilePath $emuPath -ArgumentList $emuArgs -ErrorAction Stop
      } catch {
        Write-Host ("  启动失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
        break
      }
      # 2e. Poll for device to come online via hdc (up to 180s, every 5s)
      Write-Host "  等待模拟器启动并连接 hdc（最多 180 秒，每 5 秒检测一次）..." -ForegroundColor Cyan
      $deadline = (Get-Date).AddSeconds(180)
      while(((Get-Date) -lt $deadline) -and ($targets.Count -eq 0)){
        Start-Sleep -Seconds 5
        $_out = & hdc list targets
        $targets = @($_out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '[Empty]' })
        if($targets.Count -gt 0){
          Write-Host ("  模拟器已就绪：{0}" -f ($targets -join ', ')) -ForegroundColor Green
        } else {
          $remaining = [int](($deadline - (Get-Date))).TotalSeconds
          Write-Host ("    仍在等待（剩余 {0} 秒）..." -f $remaining) -ForegroundColor DarkGray
        }
      }
      if($targets.Count -eq 0){
        Write-Host "  模拟器在 180 秒内未连接到 hdc，请检查设备名或模拟器状态。" -ForegroundColor Yellow
      }
      break
    }
    default {
      # [1] or empty: re-detect
      $_out = & hdc list targets
      $targets = @($_out -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '[Empty]' })
      break
    }
  }
}
if($Device){ if($targets -notcontains $Device){Die "Device not connected: $Device (available: $($targets -join ', '))"} }
else { if($targets.Count -gt 1){Die "Multiple devices ($($targets -join ', ')), specify with -Device"}; $Device=$targets[0] }
Write-Host ("  device = {0}" -f $Device)
$hdcDev = @('-t',$Device)

# 7. Uninstall old version (default)
if(-not $NoUninstall){ Write-Step "Uninstall previous version"; & hdc @hdcDev shell bm uninstall -n $BundleName 2>$null; Write-Host "  (ignored if not installed)" -ForegroundColor DarkGray }

# 8. Push & install
Write-Step "Push and install HAP"
$tmp = "data/local/tmp/hap_$(Get-Random)"
& hdc @hdcDev shell mkdir $tmp
& hdc @hdcDev file send $hap.FullName $tmp
& hdc @hdcDev shell bm install -p $tmp
if($LASTEXITCODE -ne 0){ & hdc @hdcDev shell rm -rf $tmp; Die "Install failed" }
& hdc @hdcDev shell rm -rf $tmp

# 9. Launch (opt-in via -Launch)
if($Launch){ Write-Step "Launch app"; & hdc @hdcDev shell aa start -a $AbilityName -b $BundleName -m $ModuleName }

# 10. Run unit tests (default on; opt out via -NoTest)
if(-not $NoTest){
  # Detect test target & suite name
  Write-Step "Detecting test target"
  $entryBpPath = Join-Path $Root (Join-Path $rel 'build-profile.json5')
  if(-not (Test-Path -LiteralPath $entryBpPath)){ Die "Entry build-profile not found: $entryBpPath" }
  $entryBp = ConvertFrom-Json5 $entryBpPath
  $TestTarget = @($entryBp.targets | Where-Object { $_.name -match 'test' } | Select-Object -First 1).name
  if(-not $TestTarget){ Die "No test target (e.g. ohosTest) found in $entryBpPath" }
  $testModJson = Join-Path $Root (Join-Path $rel ("src\" + $TestTarget + "\module.json5"))
  if(-not (Test-Path -LiteralPath $testModJson)){ Die "Test module.json5 not found: $testModJson" }
  $testMod = ConvertFrom-Json5 $testModJson
  $SuitName = $testMod.module.name
  Write-Host ("  testTarget={0}  suite={1}" -f $TestTarget,$SuitName)

  # Build test HAP
  Write-Step "Build test HAP (assembleHap -p module=$ModuleName@$TestTarget)"
  & hvigorw -p "product=$Product" -p "module=$ModuleName@$TestTarget" assembleHap --no-daemon
  if($LASTEXITCODE -ne 0){ Die "Test build failed" }

  # Locate test HAP (its immediate parent dir is the test target name)
  $testHap = Get-ChildItem -Path $buildDir -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
             Where-Object { $_.Directory.Name -eq $TestTarget } |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $testHap){ Die "Test HAP not found under $buildDir (target=$TestTarget)" }
  Write-Host ("  testHAP = {0}" -f $testHap.FullName)

  # Install test HAP
  Write-Step "Push and install test HAP"
  $ttmp = "data/local/tmp/hap_$(Get-Random)"
  & hdc @hdcDev shell mkdir $ttmp
  & hdc @hdcDev file send $testHap.FullName $ttmp
  & hdc @hdcDev shell bm install -p $ttmp
  $instRC = $LASTEXITCODE
  & hdc @hdcDev shell rm -rf $ttmp
  if($instRC -ne 0){ Die "Test HAP install failed" }

  # Run aa test
  Write-Step "Run unit tests (aa test, timeout=$TestTimeout ms)"
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  $testOut = & hdc @hdcDev shell aa test -b $BundleName -m $SuitName -s unittest OpenHarmonyTestRunner -s timeout $TestTimeout 2>&1 | Out-String
  $ErrorActionPreference = $prevEAP

  # Parse & report result
  $m = [regex]::Match($testOut, 'Tests run:\s*(\d+).*?Failure:\s*(\d+).*?Error:\s*(\d+).*?Pass:\s*(\d+).*?Ignore:\s*(\d+)')
  $codeM = [regex]::Match($testOut, 'OHOS_REPORT_CODE:\s*(-?\d+)')
  if($m.Success){
    $run=[int]$m.Groups[1].Value; $fail=[int]$m.Groups[2].Value; $err=[int]$m.Groups[3].Value; $pass=[int]$m.Groups[4].Value; $ign=[int]$m.Groups[5].Value
    $color = if($fail+$err -eq 0){'Green'}else{'Yellow'}
    Write-Host ("  Result: run={0} pass={1} failure={2} error={3} ignore={4}" -f $run,$pass,$fail,$err,$ign) -ForegroundColor $color
  } else {
    Write-Host "  (summary line not found, see full output above)" -ForegroundColor Yellow
  }
  if($codeM.Success){ Write-Host ("  OHOS_REPORT_CODE = {0} (0 = all passed)" -f $codeM.Groups[1].Value) }
  $fails = $testOut -split "`r?`n" | Where-Object { $_ -match 'Error in |actualValue is' }
  if($fails){
    Write-Host "  -- failure details --" -ForegroundColor Yellow
    foreach($f in $fails){ Write-Host ("    " + $f.Trim()) -ForegroundColor Yellow }
  }

  # 11. Export markdown report (执行结果_<timestamp>.md)
  Write-Step "Exporting report"
  $tlist = New-Object System.Collections.ArrayList
  $lastObj = $null
  $cls=''; $tst=''; $stm=''; $stk=''
  foreach($ln in ($testOut -split "`r?`n")){
    $s = $ln.Trim()
    if($s -match '^OHOS_REPORT_STATUS:\s*class=(.*)'){ $cls = $Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*test=(.*)'){ $tst = $Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*stream=(.*)'){ $stm = $Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*stack=(.*)'){ $stk = $stk + $Matches[1].Trim() + "`n" }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*consuming=(\d+)'){ if($lastObj){ $lastObj.Consuming = [int]$Matches[1] } }
    elseif($s -match '^OHOS_REPORT_STATUS_CODE:\s*(-?\d+)'){
      $code = [int]$Matches[1]
      if($code -ne 1){
        $res = if($code -eq 0){'✅ PASS'} elseif($code -eq -2){'❌ FAIL'} else{'⛔ ERROR'}
        $o = [pscustomobject]@{ Class=$cls; Test=$tst; Code=$code; Result=$res; Stream=$stm; Stack=$stk; Consuming='' }
        [void]$tlist.Add($o); $lastObj = $o; $stm=''; $stk=''
      }
    }
  }
  $now = Get-Date
  $ts = Get-Date $now -Format 'yyyyMMdd_HHmmss'
  $stamp = Get-Date $now -Format 'yyyy-MM-dd HH:mm:ss'
  $repCode = if($codeM.Success){ $codeM.Groups[1].Value } else { 'N/A' }
  $rRun=0;$rPass=0;$rFail=0;$rErr=0;$rIgn=0
  if($m.Success){ $rRun=[int]$m.Groups[1].Value;$rFail=[int]$m.Groups[2].Value;$rErr=[int]$m.Groups[3].Value;$rPass=[int]$m.Groups[4].Value;$rIgn=[int]$m.Groups[5].Value }
  $overall = if(($rFail+$rErr) -eq 0){'✅ 全部通过'}else{'❌ 存在失败/错误'}
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# 单元测试执行结果")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("> 自动生成于 $stamp ，由 execute-ui-unit-test.ps1 执行 UT 后导出。")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 执行信息")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| 项目 | 值 |")
  [void]$sb.AppendLine("|---|---|")
  [void]$sb.AppendLine("| 应用包名 bundleName | $BundleName |")
  [void]$sb.AppendLine("| 测试套件 suite | $SuitName |")
  [void]$sb.AppendLine("| 测试目标 target | $TestTarget |")
  [void]$sb.AppendLine("| 设备 device | $Device |")
  [void]$sb.AppendLine("| 构建 product / mode | $Product / $BuildMode |")
  [void]$sb.AppendLine("| 用例超时 timeout(ms) | $TestTimeout |")
  [void]$sb.AppendLine("| 执行时间 | $stamp |")
  [void]$sb.AppendLine("| OHOS_REPORT_CODE | $repCode (0 = 全部通过) |")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 汇总结果")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| 总数 | 通过 | 失败 | 错误 | 忽略 | 总体 |")
  [void]$sb.AppendLine("|---|---|---|---|---|---|")
  [void]$sb.AppendLine("| $rRun | $rPass | $rFail | $rErr | $rIgn | $overall |")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 用例明细")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| # | 测试类 | 测试用例 | 结果 | 耗时(ms) |")
  [void]$sb.AppendLine("|---|---|---|---|---|")
  $i=0; foreach($t in $tlist){ $i++; [void]$sb.AppendLine("| $i | $($t.Class) | $($t.Test) | $($t.Result) | $($t.Consuming) |") }
  [void]$sb.AppendLine("")
  $failed = @($tlist | Where-Object { $_.Code -ne 0 })
  if($failed.Count -gt 0){
    [void]$sb.AppendLine("## 失败详情")
    [void]$sb.AppendLine("")
    foreach($f in $failed){
      [void]$sb.AppendLine("### $($f.Class).$($f.Test)")
      [void]$sb.AppendLine("")
      [void]$sb.AppendLine("- **结果**: $($f.Result)")
      [void]$sb.AppendLine("- **消息**: $($f.Stream)")
      if($f.Stack){
        [void]$sb.AppendLine("- **堆栈**:")
        [void]$sb.AppendLine('```')
        [void]$sb.Append($f.Stack.Trim())
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine('```')
      }
      [void]$sb.AppendLine("")
    }
  }
  [void]$sb.AppendLine("## 原始输出")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("<details><summary>展开查看完整 aa test 输出</summary>")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine('```')
  [void]$sb.AppendLine($testOut.Trim())
  [void]$sb.AppendLine('```')
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("</details>")
  [void]$sb.AppendLine("")
  $reportName = "执行结果_$ts.md"
  $reportPath = Join-Path $Root $reportName
  [IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
  Write-Host ("  report: {0}" -f $reportPath) -ForegroundColor Green
}

# 12. Clean up artifacts (default on; opt out via -KeepArtifacts)
if(-not $KeepArtifacts){
  Write-Step "Cleaning up artifacts"
  # 12a. Uninstall app from device (installation artifact)
  & hdc @hdcDev shell bm uninstall -n $BundleName 2>$null
  Write-Host ("  device: uninstalled {0}" -f $BundleName) -ForegroundColor DarkGray

  # 12b. Remove build/ dirs (exclude those nested inside oh_modules)
  $nBuild=0
  foreach($d in (Get-ChildItem -Path $Root -Recurse -Directory -Filter 'build' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\oh_modules\\' })){
    if((Test-Path -LiteralPath $d.FullName) -and (Remove-PathForce $d.FullName)){ $nBuild++ }
  }
  # 12c. Remove oh_modules/ dirs (top-level only)
  $nOhm=0
  foreach($d in (Get-ChildItem -Path $Root -Recurse -Directory -Filter 'oh_modules' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\oh_modules\\' })){
    if((Test-Path -LiteralPath $d.FullName) -and (Remove-PathForce $d.FullName)){ $nOhm++ }
  }
  # 12d. Remove oh-package-lock.json5 (exclude inside oh_modules/build)
  $nLock=0
  foreach($f in (Get-ChildItem -Path $Root -Recurse -Filter 'oh-package-lock.json5' -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\oh_modules\\' -and $_.FullName -notmatch '\\build\\' })){
    if((Test-Path -LiteralPath $f.FullName) -and (Remove-PathForce $f.FullName)){ $nLock++ }
  }
  Write-Host ("  removed: build={0}  oh_modules={1}  oh-package-lock={2}" -f $nBuild,$nOhm,$nLock)
}

Write-Host "`n==> Done!" -ForegroundColor Green
