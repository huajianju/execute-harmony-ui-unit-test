# Generic HarmonyOS build + install + unit test (+ optional multi-device test plan)
[CmdletBinding()]
param(
  [ValidateSet('debug','release')][string]$BuildMode = 'debug',
  [string]$Product = '',
  [string]$Device = '',
  [string]$BundleName = '',
  [string]$TestPlan = '',
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

# ---------------- device / install / test helpers ----------------

function Get-HdcTargets {
  $o = & hdc list targets 2>$null
  $list = @()
  foreach($x in ($o -split "`r?`n")){ $t=$x.Trim(); if($t -and $t -ne '[Empty]'){ $list += $t } }
  return [string[]]$list
}

# Verify a hdc serial is truly online & responsive (guards against transient/blank/invalid serials)
function Test-HdcSerial {
  param([string]$Serial)
  if([string]::IsNullOrWhiteSpace($Serial)){ return $false }
  try { $r = & hdc -t $Serial shell echo __HDC_OK__ 2>$null; return ($LASTEXITCODE -eq 0 -and (($r -join '') -match '__HDC_OK__')) } catch { return $false }
}

# Wait for the system to fully boot (bootevent=true). Returns $true if confirmed.
function Wait-BootFinished {
  param([Parameter(Mandatory)][string]$Serial,[int]$WaitSec=180)
  $deadline=(Get-Date).AddSeconds($WaitSec)
  while((Get-Date) -lt $deadline){
    foreach($p in 'bootevent.boot.finished','bootevent.system.ready'){
      $r=''
      try { $r = & hdc -t $Serial shell param get $p 2>$null } catch {}
      if("$r" -match 'true'){ return $true }
    }
    Start-Sleep -Seconds 3
  }
  # diagnostics: dump actual param values so we can identify the correct boot flag for this image
  $d1='';$d2=''
  try { $d1 = (& hdc -t $Serial shell param get bootevent.boot.finished 2>$null) -join '' } catch {}
  try { $d2 = (& hdc -t $Serial shell param get bootevent.system.ready 2>$null) -join '' } catch {}
  Write-Host ("    [诊断] bootevent.boot.finished='{0}'; bootevent.system.ready='{1}'" -f $d1,$d2) -ForegroundColor Yellow
  return $false
}

# Wake the screen + disable auto-suspend + swipe-up to unlock. MUST be called AFTER boot finished.
function Unlock-Screen {
  param([Parameter(Mandatory)][string]$Serial)
  Write-Host "  主动唤醒并解锁屏幕..." -ForegroundColor DarkGray
  $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
  $r1 = (& hdc -t $Serial shell power-shell wakeup 2>&1 | Out-String).Trim()
  $null = & hdc -t $Serial shell power-shell timeout -o 600000 2>&1
  Start-Sleep -Seconds 3
  # 上滑解锁，重试 2 次（不同分辨率坐标可能不同）
  $r3 = ''
  foreach($i in 1..2){
    $r3 = (& hdc -t $Serial shell uinput -T -m 540 2000 540 400 500 2>&1 | Out-String).Trim()
    Start-Sleep -Seconds 2
  }
  $ErrorActionPreference = $prevEAP
  Write-Host ("    power-shell wakeup : {0}" -f $(if($r1){$r1}else{'(无输出/ok)'})) -ForegroundColor DarkGray
  Write-Host ("    uinput swipe x2   : {0}" -f $(if($r3){$r3}else{'(无输出/ok)'})) -ForegroundColor DarkGray
}

# Ensure the device is fully booted, then wake & unlock. Called before install on every device.
function Wait-DeviceReady {
  param([Parameter(Mandatory)][string]$Serial,[int]$BootTimeout=20)
  Write-Host "  确认系统完全启动（bootTimeout=${BootTimeout}s）..." -ForegroundColor DarkGray
  if(Wait-BootFinished -Serial $Serial -WaitSec $BootTimeout){ Write-Host "    bootevent=true" -ForegroundColor Green }
  else {
    Write-Host "    未检测到 bootevent，额外等待 15s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
  }
  # 兜底：用 bm dump 能响应来确认系统服务就绪（bootevent 拿不到时尤为重要）
  $bmDeadline = (Get-Date).AddSeconds(90)
  $bmReady = $false
  while((Get-Date) -lt $bmDeadline){
    try { $r = & hdc -t $Serial shell bm dump -a 2>$null; if($LASTEXITCODE -eq 0 -and "$r".Trim().Length -gt 0){ $bmReady = $true; break } } catch {}
    Start-Sleep -Seconds 5
  }
  if($bmReady){ Write-Host "    系统服务就绪（bm dump 可用）" -ForegroundColor Green }
  else { Write-Host "    系统服务仍未就绪，继续尝试唤醒..." -ForegroundColor Yellow }
  Unlock-Screen -Serial $Serial
}

function Uninstall-FromDevice {
  param([string]$Dev,[string]$Bundle)
  & hdc -t $Dev shell bm uninstall -n $Bundle 2>$null
}

function Install-HapToDevice {
  param([string]$Dev,[string]$HapPath,[string]$Label)
  $hd = @('-t',$Dev)
  $tmp = "data/local/tmp/hap_$(Get-Random)"
  & hdc @hd shell mkdir $tmp 2>$null
  & hdc @hd file send $HapPath $tmp 2>$null
  $instOut = (& hdc @hd shell bm install -p $tmp 2>&1 | Out-String).Trim()
  $rc = $LASTEXITCODE
  & hdc @hd shell rm -rf $tmp 2>$null
  Write-Host ("    bm install output: {0}" -f $instOut) -ForegroundColor DarkGray
  if($rc -ne 0){ Write-Host ("  [{0}] install FAILED (rc={1})" -f $Label,$rc) -ForegroundColor Red; return $false }
  return $true
}

# Run aa test on a device with optional class filter; return raw output string
function Invoke-AaTest {
  param([string]$Dev,[string]$Bundle,[string]$Suite,[string]$ClassFilter,[int]$Timeout)
  $hd = @('-t',$Dev)
  $cmd = "aa test -b `"$Bundle`" -m `"$Suite`" -s unittest OpenHarmonyTestRunner -s timeout $Timeout"
  if($ClassFilter){ $cmd += " -s class `"$ClassFilter`"" }
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'SilentlyContinue'
  $out = & hdc @hd shell $cmd 2>&1 | Out-String
  $ErrorActionPreference = $prevEAP
  return $out
}

# Parse OHOS aa test output into a structured result object
function Get-TestResult {
  param([string]$TestOut)
  $res = [pscustomobject]@{
    Output=$TestOut; HasSummary=$false; Run=0; Pass=0; Fail=0; Err=0; Ignore=0; ReportCode='N/A';
    Tests=New-Object System.Collections.ArrayList
  }
  $m = [regex]::Match($TestOut,'Tests run:\s*(\d+).*?Failure:\s*(\d+).*?Error:\s*(\d+).*?Pass:\s*(\d+).*?Ignore:\s*(\d+)')
  if($m.Success){
    $res.HasSummary=$true
    $res.Run=[int]$m.Groups[1].Value; $res.Fail=[int]$m.Groups[2].Value; $res.Err=[int]$m.Groups[3].Value; $res.Pass=[int]$m.Groups[4].Value; $res.Ignore=[int]$m.Groups[5].Value
  }
  $codeM=[regex]::Match($TestOut,'OHOS_REPORT_CODE:\s*(-?\d+)')
  if($codeM.Success){ $res.ReportCode=$codeM.Groups[1].Value }
  $cls='';$tst='';$stm='';$stk='';$last=$null
  foreach($ln in ($TestOut -split "`r?`n")){
    $s=$ln.Trim()
    if($s -match '^OHOS_REPORT_STATUS:\s*class=(.*)'){ $cls=$Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*test=(.*)'){ $tst=$Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*stream=(.*)'){ $stm=$Matches[1].Trim() }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*stack=(.*)'){ $stk += $Matches[1].Trim() + "`n" }
    elseif($s -match '^OHOS_REPORT_STATUS:\s*consuming=(\d+)'){ if($last){ $last.Consuming=[int]$Matches[1] } }
    elseif($s -match '^OHOS_REPORT_STATUS_CODE:\s*(-?\d+)'){
      $code=[int]$Matches[1]
      if($code -ne 1){
        $r = if($code -eq 0){'✅ PASS'} elseif($code -eq -2){'❌ FAIL'} else{'⛔ ERROR'}
        $o=[pscustomobject]@{Class=$cls;Test=$tst;Code=$code;Result=$r;Stream=$stm;Stack=$stk;Consuming=''}
        [void]$res.Tests.Add($o); $last=$o; $stm='';$stk=''
      }
    }
  }
  return $res
}

function Find-EmulatorExe {
  if($env:DEVECO_SDK_HOME){
    $cand = Join-Path $env:DEVECO_SDK_HOME '..\tools\emulator\Emulator.exe'
    if(Test-Path -LiteralPath $cand){ return (Resolve-Path $cand).Path }
  }
  return ''
}

# Parse `Emulator -list -details` JSON to find an instance by name.
# Returns @{Running=[bool]; Port=[string]} or $null.
function Get-EmulatorInstanceInfo {
  param([Parameter(Mandatory)][string]$EmuExe,[Parameter(Mandatory)][string]$Name)
  try {
    $raw = (& $EmuExe -list -details 2>&1) -join "`n"
    $json = $null
    try { $json = $raw | ConvertFrom-Json } catch {
      $s = $raw.IndexOf('['); $e = $raw.LastIndexOf(']')
      if($s -ge 0 -and $e -gt $s){ try { $json = $raw.Substring($s,$e-$s+1) | ConvertFrom-Json } catch {} }
    }
    if(-not $json){ return $null }
    foreach($it in $json){
      if("$($it.name)" -eq $Name){
        $running = ("$($it.isRunning)" -imatch 'true')
        $port = ''
        # NOTE: -list -details uses FLAT keys like "hw.hdc.port"; value is "notset" when not running.
        $rawPort = if($it.PSObject.Properties.Name -contains 'hw.hdc.port'){ "$($it.'hw.hdc.port')" } else { '' }
        if($rawPort -match '^\d+$'){ $port = $rawPort }  # ignore 'notset' / non-numeric
        return @{ Running=$running; Port=$port }
      }
    }
  } catch {}
  return $null
}

function Resolve-EmulatorSerial {
  param([Parameter(Mandatory)][string]$EmuExe,[Parameter(Mandatory)][string]$Name,[int]$HdcPort=0,[int]$WaitSec=180)
  $info = Get-EmulatorInstanceInfo -EmuExe $EmuExe -Name $Name
  $wasRunning = ($info -and $info.Running)
  # capture BEFORE launching: retry to ensure already-connected devices (e.g. real phone) are included,
  # so the diff fallback won't mistakenly pick them up as the "new" emulator.
  $before = @()
  $bd = (Get-Date).AddSeconds(10)
  while((Get-Date) -lt $bd){ $before = @(Get-HdcTargets); if($before.Count -gt 0){ break }; Start-Sleep -Seconds 2 }
  if(-not $wasRunning){
    Write-Host ("  模拟器 '{0}' 未运行，执行启动：{1} -start {0}" -f $Name,$EmuExe) -ForegroundColor Cyan
    try { & $EmuExe -license accept 2>&1 | Out-Null } catch {}
    $startArgs = '-start "{0}"' -f $Name
    if($HdcPort -gt 0){ $startArgs += ' -hdcport {0}' -f $HdcPort; Write-Host ("  指定 hdc 端口：{0}（-hdcport）" -f $HdcPort) -ForegroundColor Cyan }
    try { Start-Process -FilePath $EmuExe -ArgumentList $startArgs -ErrorAction Stop }
    catch { Write-Host ("  启动调用返回异常：{0}" -f $_.Exception.Message) -ForegroundColor Yellow }
  } else {
    Write-Host ("  模拟器 '{0}' 已在运行，等待 hdc 识别..." -f $Name) -ForegroundColor DarkGray
  }
  $deadline=(Get-Date).AddSeconds($WaitSec)
  while((Get-Date) -lt $deadline){
    Start-Sleep -Seconds 5
    $targets = @(Get-HdcTargets)
    $cand = $null
    # 1) configured hdc port: tconn (CLI-launched emulators are NOT auto-discovered by hdc), then match & verify
    if($HdcPort -gt 0){
      $tconn = "127.0.0.1:$HdcPort"
      try { & hdc tconn $tconn 2>$null | Out-Null } catch {}
      Start-Sleep -Seconds 2
      $targets = @(Get-HdcTargets)
      $m = @($targets | Where-Object { $_ -match ":$HdcPort`$" })
      if($m.Count -gt 0){ $cand = $m[0] }
      elseif(Test-HdcSerial $tconn){ $cand = $tconn }
    }
    # 2) fallback: hw.hdc.port from -list -details (when it is numeric)
    if(-not $cand){
      $info2 = Get-EmulatorInstanceInfo -EmuExe $EmuExe -Name $Name
      $port2 = if($info2 -and $info2.Running){ $info2.Port } else { '' }
      if($port2){
        $tconn2 = "127.0.0.1:$port2"
        try { & hdc tconn $tconn2 2>$null | Out-Null } catch {}
        Start-Sleep -Seconds 2
        $targets = @(Get-HdcTargets)
        $m2 = @($targets | Where-Object { $_ -match ":$([regex]::Escape($port2))`$" })
        if($m2.Count -gt 0){ $cand = $m2[0] }
        elseif(Test-HdcSerial $tconn2){ $cand = $tconn2 }
      }
    }
    # 3) fallback: newly-online diff (verified). Reliable now that Get-HdcTargets returns a flat array
    #    (before correctly includes already-connected real devices, so diff only picks the new emulator).
    if(-not $cand -and -not $wasRunning){
      $new = @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($before -notcontains $_) })
      foreach($cc in $new){ if(Test-HdcSerial $cc){ $cand = $cc; break } }
    }
    if($cand){
      $candStr = [string](@($cand)[0])   # ensure a single string (guard against array/object[] typing)
      Write-Host ("  模拟器 '{0}' hdc 已连接（序列号 {1}）" -f $Name,$candStr) -ForegroundColor Green
      return $candStr
    }
    $rr=[int](($deadline-(Get-Date)).TotalSeconds); Write-Host ("    仍在等待模拟器就绪（剩余 $rr 秒）...") -ForegroundColor DarkGray
  }
  # timed out: dump diagnostics
  Write-Host "  [诊断] 模拟器 '$Name' 识别失败：" -ForegroundColor Yellow
  $diag = Get-EmulatorInstanceInfo -EmuExe $EmuExe -Name $Name
  if($diag){ Write-Host ("    Emulator -list -details -> isRunning={0}, hw.hdc.port={1}" -f $diag.Running, $(if($diag.Port){$diag.Port}else{'(notset/空)'})) -ForegroundColor Yellow }
  else { Write-Host "    Emulator -list -details -> 未找到实例 '$Name' 或 JSON 解析失败" -ForegroundColor Yellow }
  $cur = @(Get-HdcTargets)
  Write-Host ("    hdc list targets -> {0}" -f $(if($cur.Count){$cur -join ', '}else{'[Empty]'})) -ForegroundColor Yellow
  if($HdcPort -eq 0){ Write-Host "    提示：hw.hdc.port 为 notset 时，请在配置中给该模拟器指定 hdcport（如 \"hdcport\": 5554，范围 10000-16555），脚本会用 -hdcport 启动并 tconn 该端口。" -ForegroundColor Yellow }
  return ''
}

# Stop an emulator instance (best-effort)
function Stop-EmulatorInstance {
  param([Parameter(Mandatory)][string]$EmuExe,[Parameter(Mandatory)][string]$Name,[string]$Serial='')
  if($Serial){ try { & hdc tdisconn $Serial 2>$null | Out-Null } catch {} }
  try { & $EmuExe -stop $Name 2>&1 | Out-Null } catch {}
}

# put CWD (project root, contains hvigorw/hvigorw.bat) first in PATH so `hvigorw` resolves
$env:PATH = "$PWD;$env:PATH"
# auto-add DevEco tool dirs to PATH (hdc/hvigorw/ohpm) derived from DEVECO_SDK_HOME
if($env:DEVECO_SDK_HOME){
  $tc = Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\toolchains'
  $devRoot = Split-Path $env:DEVECO_SDK_HOME -Parent
  foreach($d in @($tc, (Join-Path $devRoot 'tools\hvigor\bin'), (Join-Path $devRoot 'tools\ohpm\bin'))){
    if((Test-Path -LiteralPath $d) -and ($env:PATH -notlike "*$d*")){ $env:PATH = "$env:PATH;$d" }
  }
}

# ---------------- 0. env check ----------------
Write-Step "Environment check"
foreach($t in 'hvigorw','hdc','ohpm','node'){ if(-not(Get-Command $t -ErrorAction SilentlyContinue)){Die "Command not found: $t"} }
Write-Host "  OK" -ForegroundColor Green

# ---------------- 1. detect params ----------------
Write-Step "Detecting project params"
$bp = ConvertFrom-Json5 (Join-Path $Root 'build-profile.json5')
if(-not $Product){ $Product = $bp.app.products[0].name }
if(-not $BundleName){ $app = ConvertFrom-Json5 (Join-Path $Root 'AppScope/app.json5'); $BundleName = $app.app.bundleName }
$Entry=$null;$EntrySrc=$null
foreach($m in $bp.modules){
  $rel = $m.srcPath -replace '^[./\\]+','' -replace '/','\'
  $mj = Join-Path $Root (Join-Path $rel 'src\main\module.json5')
  if(Test-Path -LiteralPath $mj){ $mo = ConvertFrom-Json5 $mj; if($mo.module.type -eq 'entry'){$Entry=$mo.module;$EntrySrc=$m.srcPath;break} }
}
if(-not $Entry){ Die "No entry module found" }
$ModuleName=$Entry.name; $AbilityName=$Entry.mainElement
$rel = $EntrySrc -replace '^[./\\]+','' -replace '/','\'
$buildDir = Join-Path $Root (Join-Path $rel 'build')
Write-Host ("  bundle={0}  product={1}  module={2}  ability={3}  mode={4}" -f $BundleName,$Product,$ModuleName,$AbilityName,$BuildMode)

# ---------------- 2. deps ----------------
if(-not $SkipOhpm){ Write-Step "Installing deps (ohpm install)"; & ohpm install; if($LASTEXITCODE -ne 0){Die "ohpm install failed"} }

# ---------------- 3. clean ----------------
if($Clean){ Write-Step "Clean (hvigorw clean)"; & hvigorw clean --no-daemon; if($LASTEXITCODE -ne 0){Die "clean failed"} }

# ---------------- 4. build app HAP ----------------
Write-Step "Build HAP (assembleHap)"
& hvigorw -p "product=$Product" -p "buildMode=$BuildMode" assembleHap --no-daemon
if($LASTEXITCODE -ne 0){ Die "Build failed" }

# ---------------- 5. locate app HAP ----------------
Write-Step "Locate HAP artifact"
$haps = Get-ChildItem -Path $buildDir -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -notmatch 'test' }
if(-not $haps){ Die "No HAP found under: $buildDir" }
$hap = @($haps | Where-Object {$_.Name -match '-signed\.hap$'})[0]
if(-not $hap){ $hap = @($haps | Sort-Object LastWriteTime -Desc)[0] }
Write-Host ("  HAP = {0}" -f $hap.FullName)

# ---------------- 6. resolve device plan (parse only; emulators start per-device in step 8) ----------------
Write-Step "Resolving device plan"
# each device: { Label; ClassFilter; Emulator; HdcPort; DeviceSerial; IsEmulator }
$devices = @()
$emuExe = ''
$bootTimeout = 20
$planFile = $TestPlan
if(-not $planFile){
  foreach($n in 'device-test-plan.json5','device-test-plan.example.json5'){
    $cand = Join-Path $Root $n
    if(Test-Path -LiteralPath $cand){ $planFile = $cand; break }
  }
}

if($planFile){
  if(-not (Test-Path -LiteralPath $planFile)){ Die "Test plan not found: $planFile" }
  Write-Host ("  计划文件：{0}" -f $planFile) -ForegroundColor Cyan
  $plan = ConvertFrom-Json5 $planFile
  $planDevices = @($plan.devices)
  if($planDevices.Count -eq 0){ Die "Test plan has no devices: $planFile" }
  if($plan.bootTimeout){ $bootTimeout = [int]$plan.bootTimeout }
  $needLaunch = @($planDevices | Where-Object { $_.emulator -and $_.emulator.Trim() })
  if($plan.emulatorPath -and (Test-Path -LiteralPath $plan.emulatorPath -PathType Leaf)){ $emuExe = $plan.emulatorPath }
  if((-not $emuExe) -and $needLaunch.Count -gt 0){ $emuExe = Find-EmulatorExe }
  if((-not $emuExe) -and $needLaunch.Count -gt 0){
    if([Console]::IsInputRedirected){ Die "需要启动模拟器但未找到 Emulator.exe，且当前为非交互环境。请在计划文件设置 emulatorPath，或配置 DEVECO_SDK_HOME。" }
    Write-Host "  未自动发现 Emulator.exe，请手动输入路径。" -ForegroundColor Yellow
    $emuExe = Read-Host "请输入模拟器可执行文件路径（如 D:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe）"
    if(-not (Test-Path -LiteralPath $emuExe -PathType Leaf)){ Die "Emulator 路径不存在：$emuExe" }
  }
  if($needLaunch.Count -gt 0 -and $emuExe){
    Write-Host "  可用模拟器实例（Emulator -list）：" -ForegroundColor Cyan
    try { $lo = & $emuExe -list 2>&1 | Out-String; if($lo.Trim()){ Write-Host $lo -ForegroundColor DarkGray } } catch {}
  }
  $idx=0
  foreach($pd in $planDevices){
    $idx++
    $label = if($pd.name){ $pd.name } elseif($pd.emulator){ $pd.emulator } elseif($pd.device){ $pd.device } else { "device$idx" }
    $tests = @($pd.tests | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    $cf = $tests -join ','
    $emuName = if($pd.emulator){ $pd.emulator.Trim() } else { '' }
    $hp = if($pd.hdcport){ [int]$pd.hdcport } else { 0 }
    $devSerial = if($pd.device){ $pd.device.Trim() } else { '' }
    if($emuName){
      if(-not $emuExe){ Die "设备 $label 配置了 emulator 但缺少 Emulator.exe（请设置 emulatorPath 或 DEVECO_SDK_HOME）。" }
      $devices += [pscustomobject]@{ Label=$label; ClassFilter=$cf; Emulator=$emuName; HdcPort=$hp; DeviceSerial=''; IsEmulator=$true }
      Write-Host ("  设备 {0}：模拟器 '{1}'（hdcport={2}，将在执行时启动、跑完即关闭）" -f $label,$emuName,$(if($hp){$hp}else{'未指定'})) -ForegroundColor Cyan
    } elseif($devSerial){
      $online = $false
      $tryDeadline = (Get-Date).AddSeconds(15)
      while((Get-Date) -lt $tryDeadline){
        $cur = @(Get-HdcTargets)
        if($cur -contains $devSerial){ $online = $true; break }
        Start-Sleep -Seconds 2
      }
      if($online){
        $devices += [pscustomobject]@{ Label=$label; ClassFilter=$cf; Emulator=''; HdcPort=0; DeviceSerial=$devSerial; IsEmulator=$false }
        Write-Host ("  设备 {0}：已在线（{1}），直接复用" -f $label,$devSerial) -ForegroundColor Green
      } else {
        $cur = @(Get-HdcTargets)
        Write-Host ("  设备 {0} 的 device '{1}' 不在线，跳过。当前 hdc list targets: {2}" -f $label,$devSerial,$(if($cur.Count){$cur -join ', '}else{'[Empty]'})) -ForegroundColor Yellow
      }
    } else { Die "设备 $label 缺少 emulator/device 配置，无法确定目标设备。" }
  }
  if($devices.Count -eq 0){ Die "计划文件中没有任何可用设备（真机不在线且无模拟器，或配置缺失）。" }
  $planMode = "multi ($([IO.Path]::GetFileName($planFile)))，串行（一次只跑一个模拟器，跑完即关）"
} else {
  # single-device mode: interactive device selection
  $targets = @(Get-HdcTargets)
  while($targets.Count -eq 0){
    if([Console]::IsInputRedirected){
      Write-Host ""; Write-Host "未检测到设备/模拟器（模拟器可能未启动）。" -ForegroundColor Yellow
      Write-Host "请先在 DevEco Studio 启动模拟器，或用 USB 连接真机并开启调试，然后重跑脚本（多设备可用 -TestPlan）。" -ForegroundColor Yellow
      Die "No device/emulator detected (non-interactive)"
    }
    Write-Host ""; Write-Host "未检测到设备/模拟器（模拟器可能未启动）。" -ForegroundColor Yellow
    Write-Host "请选择：" -ForegroundColor Yellow
    Write-Host "  [1] 我已手动启动模拟器/连接真机 —— 重新检测" -ForegroundColor Yellow
    Write-Host "  [2] 自动启动本地模拟器（输入模拟器路径 + 设备名称，由脚本自动启动并等待就绪）" -ForegroundColor Yellow
    Write-Host "  [q] 退出" -ForegroundColor Yellow
    $choice = Read-Host "请输入选项 [1/2/q]（默认 1）"
    switch -Regex ($choice){
      '^q'{ Die "用户取消，未连接设备/模拟器" }
      '^2'{
        $emuDefault = Find-EmulatorExe
        if($emuDefault){ $emuPath = Read-Host "请输入模拟器可执行文件路径（回车使用默认：$emuDefault）"; if(-not $emuPath){ $emuPath=$emuDefault } }
        else { $emuPath = Read-Host "请输入模拟器可执行文件路径（如 D:\Program Files\Huawei\DevEco Studio\tools\emulator\Emulator.exe）" }
        if([string]::IsNullOrWhiteSpace($emuPath) -or -not (Test-Path -LiteralPath $emuPath -PathType Leaf)){ Write-Host "  路径不存在或不是可执行文件。" -ForegroundColor Red; break }
        Write-Host "  正在查询可用模拟器实例（Emulator -list）..." -ForegroundColor Cyan
        try { $listOut = & $emuPath -list 2>&1 | Out-String; if([string]::IsNullOrWhiteSpace($listOut)){ Write-Host "  未查询到模拟器实例。" -ForegroundColor Red; break }; Write-Host $listOut -ForegroundColor DarkGray }
        catch { Write-Host ("  执行 -list 失败：{0}" -f $_.Exception.Message) -ForegroundColor Red; break }
        $emuName = Read-Host "请输入要启动的设备名称（上列表中的某一项）"
        if(-not $emuName){ Write-Host "  设备名称为空，请重新选择。" -ForegroundColor Red; break }
        $hp = Read-Host "指定 hdc 端口（10000-16555，强烈建议；回车跳过）"
        $hpInt = 0; if($hp -and ($hp -match '^\d+$')){ $hpInt=[int]$hp }
        $ser = Resolve-EmulatorSerial -EmuExe $emuPath -Name $emuName -HdcPort $hpInt
        if($ser){ $emuExe=$emuPath; $devices += [pscustomobject]@{ Label=$emuName; ClassFilter=''; Emulator=$emuName; HdcPort=$hpInt; DeviceSerial=$ser; IsEmulator=$true }; $targets = @(Get-HdcTargets) }
        else { Write-Host "  模拟器在 180 秒内未就绪。" -ForegroundColor Yellow }
        break
      }
      default { $targets = @(Get-HdcTargets) }
    }
  }
  if($devices.Count -eq 0){
    if($Device){ if($targets -notcontains $Device){Die "Device not connected: $Device (available: $($targets -join ', '))"}; $sel=$Device }
    else { if($targets.Count -gt 1){Die "Multiple devices ($($targets -join ', ')), specify with -Device (or use -TestPlan for multi-device mode)"}; $sel=$targets[0] }
    $devices += [pscustomobject]@{ Label=$sel; ClassFilter=''; Emulator=''; HdcPort=0; DeviceSerial=$sel; IsEmulator=$false }
  }
  $planMode = 'single'
}
Write-Host ("  模式：{0}，设备数：{1}" -f $planMode,$devices.Count) -ForegroundColor Cyan
foreach($d in $devices){
  $extra = if($d.ClassFilter){" 用例过滤：{0}" -f $d.ClassFilter}else{}
  $kind = if($d.IsEmulator){ "模拟器 $($d.Emulator)" } else { "设备 $($d.DeviceSerial)" }
  $port = if($d.IsEmulator -and $d.HdcPort){" hdcport=$($d.HdcPort)"}else{''}
  Write-Host ("    - {0}（{1}{2}{3}）" -f $d.Label,$kind,$port,$extra)
}

# ---------------- 7. test target detection + build (only if tests run) ----------------
$TestTarget=''; $SuitName=''; $testHap=$null
if(-not $NoTest){
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

  Write-Step "Build test HAP (assembleHap -p module=$ModuleName@$TestTarget)"
  & hvigorw -p "product=$Product" -p "module=$ModuleName@$TestTarget" assembleHap --no-daemon
  if($LASTEXITCODE -ne 0){ Die "Test build failed" }

  $testHap = Get-ChildItem -Path $buildDir -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue |
             Where-Object { $_.Directory.Name -eq $TestTarget } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $testHap){ Die "Test HAP not found under $buildDir (target=$TestTarget)" }
  Write-Host ("  testHAP = {0}" -f $testHap.FullName)
}

# ---------------- 8. per device: start emulator -> install -> test -> stop emulator ----------------
$devResults = @()
$di=0
foreach($d in $devices){
  $di++
  $hdr = "[$di/$($devices.Count)] $($d.Label)"
  Write-Step $hdr
  $serial = ''
  $needClose = $false
  if($d.IsEmulator){
    if($d.DeviceSerial){
      $serial = $d.DeviceSerial  # already started (single-device mode option 2)
      Write-Host ("  模拟器已启动，序列号 {0}" -f $serial) -ForegroundColor DarkGray
    } else {
      Write-Host ("  启动模拟器 '{0}'（hdcport={1}）..." -f $d.Emulator,$(if($d.HdcPort){$d.HdcPort}else{'未指定'})) -ForegroundColor Cyan
      $serial = Resolve-EmulatorSerial -EmuExe $emuExe -Name $d.Emulator -HdcPort $d.HdcPort
      if(-not $serial){
        Write-Host "  模拟器启动失败，跳过该设备。" -ForegroundColor Red
        $devResults += [pscustomobject]@{ Label=$d.Label; Serial=''; ClassFilter=$d.ClassFilter; Result=$null }
        continue
      }
    }
    $needClose = $true
  } else {
    $serial = $d.DeviceSerial
    $cur = @(Get-HdcTargets)
    if($cur -notcontains $serial){
      Write-Host "  设备 $serial 不在线，跳过。" -ForegroundColor Red
      $devResults += [pscustomobject]@{ Label=$d.Label; Serial=$serial; ClassFilter=$d.ClassFilter; Result=$null }
      continue
    }
  }
  Write-Host ("  serial = {0}" -f $serial)
  try {
    Wait-DeviceReady -Serial $serial -BootTimeout $bootTimeout
    if(-not $NoUninstall){ Write-Host "  uninstall previous..."; Uninstall-FromDevice -Dev $serial -Bundle $BundleName }
    Write-Host "  install app HAP..."
    if(-not (Install-HapToDevice -Dev $serial -HapPath $hap.FullName -Label $hdr)){
      Write-Host "  应用安装失败，跳过。" -ForegroundColor Red
      $devResults += [pscustomobject]@{ Label=$d.Label; Serial=$serial; ClassFilter=$d.ClassFilter; Result=$null }
      continue
    }
    if($Launch){ Write-Host "  launch app..."; & hdc -t $serial shell aa start -a $AbilityName -b $BundleName -m $ModuleName }
    $r = [pscustomobject]@{ Label=$d.Label; Serial=$serial; ClassFilter=$d.ClassFilter; Result=$null }
    if(-not $NoTest){
      Write-Host "  install test HAP..."
      if(-not (Install-HapToDevice -Dev $serial -HapPath $testHap.FullName -Label $hdr)){
        Write-Host "  测试 HAP 安装失败，跳过测试。" -ForegroundColor Red
        $devResults += $r
        continue
      }
      $filterDesc = if($d.ClassFilter){ $d.ClassFilter } else { '(全量)' }
      Write-Host ("  run aa test (class filter: {0}, timeout={1}ms)..." -f $filterDesc,$TestTimeout)
      Unlock-Screen -Serial $serial   # re-unlock right before aa test (screen may re-lock during install)
      $out = Invoke-AaTest -Dev $serial -Bundle $BundleName -Suite $SuitName -ClassFilter $d.ClassFilter -Timeout $TestTimeout
      $res = Get-TestResult -TestOut $out
      $r.Result = $res
      if($res.HasSummary){
        $color = if($res.Fail+$res.Err -eq 0){'Green'}else{'Yellow'}
        Write-Host ("  结果：run={0} pass={1} failure={2} error={3} ignore={4}  code={5}" -f $res.Run,$res.Pass,$res.Fail,$res.Err,$res.Ignore,$res.ReportCode) -ForegroundColor $color
      } else { Write-Host "  (未解析到汇总行，详见报告)" -ForegroundColor Yellow }
    }
    $devResults += $r
  } finally {
    if($needClose){
      Write-Host ("  关闭模拟器 '{0}'..." -f $d.Emulator) -ForegroundColor Cyan
      Stop-EmulatorInstance -EmuExe $emuExe -Name $d.Emulator -Serial $serial
      Start-Sleep -Seconds 3
      Write-Host "  模拟器已关闭" -ForegroundColor DarkGray
    }
  }
}

# ---------------- 9. export report (only if tests ran) ----------------
if(-not $NoTest){
  Write-Step "Exporting report"
  $now=Get-Date
  $ts=Get-Date $now -Format 'yyyyMMdd_HHmmss'
  $stamp=Get-Date $now -Format 'yyyy-MM-dd HH:mm:ss'
  $tRun=0;$tPass=0;$tFail=0;$tErr=0;$tIgn=0
  foreach($r in $devResults){ if($r.Result -and $r.Result.HasSummary){ $tRun+=$r.Result.Run;$tPass+=$r.Result.Pass;$tFail+=$r.Result.Fail;$tErr+=$r.Result.Err;$tIgn+=$r.Result.Ignore } }
  $overall = if(($tFail+$tErr) -eq 0){'✅ 全部通过'}else{'❌ 存在失败/错误'}
  $sb=New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# 单元测试执行结果"); [void]$sb.AppendLine("")
  [void]$sb.AppendLine("> 自动生成于 $stamp ，由 execute-multi-device-ui-unit-test.ps1 执行后导出。"); [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 执行信息"); [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| 项目 | 值 |"); [void]$sb.AppendLine("|---|---|")
  [void]$sb.AppendLine("| 应用包名 bundleName | $BundleName |")
  if($SuitName){ [void]$sb.AppendLine("| 测试套件 suite | $SuitName |") }
  if($TestTarget){ [void]$sb.AppendLine("| 测试目标 target | $TestTarget |") }
  [void]$sb.AppendLine("| 构建 product / mode | $Product / $BuildMode |")
  [void]$sb.AppendLine("| 用例超时 timeout(ms) | $TestTimeout |")
  [void]$sb.AppendLine("| 执行模式 | $planMode（设备 $($devices.Count) 台） |")
  [void]$sb.AppendLine("| 执行时间 | $stamp |"); [void]$sb.AppendLine("")
  [void]$sb.AppendLine("## 全局汇总"); [void]$sb.AppendLine("")
  [void]$sb.AppendLine("| 总数 | 通过 | 失败 | 错误 | 忽略 | 总体 |"); [void]$sb.AppendLine("|---|---|---|---|---|---|")
  [void]$sb.AppendLine("| $tRun | $tPass | $tFail | $tErr | $tIgn | $overall |"); [void]$sb.AppendLine("")
  $i=0
  foreach($r in $devResults){
    $i++
    [void]$sb.AppendLine("## 设备 ${i}：$($r.Label)"); [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- **序列号**：$($r.Serial)")
    $fd = if($r.ClassFilter){ $r.ClassFilter } else { '（全量，未指定 class 筛选）' }
    [void]$sb.AppendLine("- **用例筛选**：$fd")
    if($r.Result){
      $res=$r.Result
      [void]$sb.AppendLine("- **OHOS_REPORT_CODE**：$($res.ReportCode) (0 = 全部通过)"); [void]$sb.AppendLine("")
      if($res.HasSummary){
        [void]$sb.AppendLine("| 总数 | 通过 | 失败 | 错误 | 忽略 |"); [void]$sb.AppendLine("|---|---|---|---|---|")
        [void]$sb.AppendLine("| $($res.Run) | $($res.Pass) | $($res.Fail) | $($res.Err) | $($res.Ignore) |"); [void]$sb.AppendLine("")
      }
      if($res.Tests.Count -gt 0){
        [void]$sb.AppendLine("| # | 测试类 | 测试用例 | 结果 | 耗时(ms) |"); [void]$sb.AppendLine("|---|---|---|---|---|")
        $j=0; foreach($t in $res.Tests){ $j++; [void]$sb.AppendLine("| $j | $($t.Class) | $($t.Test) | $($t.Result) | $($t.Consuming) |") }
        [void]$sb.AppendLine("")
      }
      $failed = @($res.Tests | Where-Object { $_.Code -ne 0 })
      if($failed.Count -gt 0){
        [void]$sb.AppendLine("### 失败详情"); [void]$sb.AppendLine("")
        foreach($f in $failed){
          [void]$sb.AppendLine("#### $($f.Class).$($f.Test)"); [void]$sb.AppendLine("")
          [void]$sb.AppendLine("- **结果**：$($f.Result)")
          [void]$sb.AppendLine("- **消息**：$($f.Stream)")
          if($f.Stack){ [void]$sb.AppendLine("- **堆栈**："); [void]$sb.AppendLine('```'); [void]$sb.Append($f.Stack.Trim()); [void]$sb.AppendLine(""); [void]$sb.AppendLine('```') }
          [void]$sb.AppendLine("")
        }
      }
      [void]$sb.AppendLine("<details><summary>展开查看该设备完整 aa test 输出</summary>"); [void]$sb.AppendLine("")
      [void]$sb.AppendLine('```'); [void]$sb.AppendLine($res.Output.Trim()); [void]$sb.AppendLine('```'); [void]$sb.AppendLine(""); [void]$sb.AppendLine("</details>"); [void]$sb.AppendLine("")
    } else {
      [void]$sb.AppendLine("_（未执行测试 / 该设备启动失败）_"); [void]$sb.AppendLine("")
    }
  }
  $reportName="执行结果_$ts.md"
  $reportPath=Join-Path $Root $reportName
  [IO.File]::WriteAllText($reportPath,$sb.ToString(),(New-Object System.Text.UTF8Encoding $true))
  Write-Host ("  report: {0}" -f $reportPath) -ForegroundColor Green
  Write-Host ("  汇总：总数=$tRun 通过=$tPass 失败=$tFail 错误=$tErr 忽略=$tIgn  ->  $overall") -ForegroundColor $(if(($tFail+$tErr)-eq 0){'Green'}else{'Yellow'})
}

# ---------------- 10. cleanup (real devices only; emulators already stopped) ----------------
if(-not $KeepArtifacts){
  Write-Step "Cleaning up artifacts"
  foreach($d in $devices){ if(-not $d.IsEmulator){ Uninstall-FromDevice -Dev $d.DeviceSerial -Bundle $BundleName; Write-Host ("  device $($d.DeviceSerial): uninstalled $BundleName") -ForegroundColor DarkGray } }
  $nBuild=0
  foreach($bd in (Get-ChildItem -Path $Root -Recurse -Directory -Filter 'build' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\oh_modules\\' })){ if((Test-Path -LiteralPath $bd.FullName) -and (Remove-PathForce $bd.FullName)){ $nBuild++ } }
  $nOhm=0
  foreach($od in (Get-ChildItem -Path $Root -Recurse -Directory -Filter 'oh_modules' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\oh_modules\\' })){ if((Test-Path -LiteralPath $od.FullName) -and (Remove-PathForce $od.FullName)){ $nOhm++ } }
  $nLock=0
  foreach($lf in (Get-ChildItem -Path $Root -Recurse -Filter 'oh-package-lock.json5' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\oh_modules\\' -and $_.FullName -notmatch '\\build\\' })){ if((Test-Path -LiteralPath $lf.FullName) -and (Remove-PathForce $lf.FullName)){ $nLock++ } }
  Write-Host ("  removed: build={0}  oh_modules={1}  oh-package-lock={2}" -f $nBuild,$nOhm,$nLock)
}

Write-Host "`n==> Done!" -ForegroundColor Green
