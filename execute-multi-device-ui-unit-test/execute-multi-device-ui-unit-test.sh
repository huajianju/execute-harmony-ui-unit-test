#!/usr/bin/env bash
# execute-multi-device-ui-unit-test.sh — Generic HarmonyOS build + install + UT + report + cleanup (macOS / Linux)
# Bash 3.2+ compatible. Mirrors execute-multi-device-ui-unit-test.ps1. Supports multi-device test plan.
#
# Usage:
#   ./execute-multi-device-ui-unit-test.sh                     # full flow (single device)
#   ./execute-multi-device-ui-unit-test.sh --no-test           # skip unit tests
#   ./execute-multi-device-ui-unit-test.sh --test-plan my.json5 # multi-device: launch emulators + per-device test cases
#   ./execute-multi-device-ui-unit-test.sh -h                  # help

set -u

# ---------------- helpers ----------------
c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_cyan='\033[36m'; c_gray='\033[90m'
step(){ printf "\n${c_cyan}==> %s${c_reset}\n" "$*"; }
ok(){   printf "  ${c_green}%s${c_reset}\n" "$*"; }
warn(){ printf "  ${c_yellow}%s${c_reset}\n" "$*" >&2; }
err(){  printf "${c_red}ERROR: %s${c_reset}\n" "$*"; }
die(){ err "$*"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
TOOL=""; TMPD=""

# ---------------- args ----------------
BUILD_MODE="debug"; PRODUCT=""; DEVICE=""; BUNDLE_NAME=""; TEST_PLAN=""
CLEAN=0; LAUNCH=0; SKIP_OHPM=0; NO_UNINSTALL=0; NO_TEST=0; KEEP_ARTIFACTS=0; TEST_TIMEOUT=15000

usage(){ cat <<'EOF'
Usage: execute-multi-device-ui-unit-test.sh [options]
  --build-mode debug|release   Build mode (default: debug)
  --product <name>             Product (auto-detected from build-profile.json5)
  --device <sn>                Target device serial (single-device mode; required if multiple connected)
  --bundle-name <name>         Bundle name (auto-detected from AppScope/app.json5)
  --test-plan <path>           Multi-device test plan (JSON5). If omitted, auto-detects device-test-plan.json5 in project root.
  --clean                      Run 'hvigorw clean' before build
  --launch                     Launch the app after install
  --skip-ohpm                  Skip 'ohpm install'
  --no-uninstall               Don't uninstall the previous version first
  --no-test                    Skip unit tests (default: run UT and export report)
  --keep-artifacts             Keep build/install artifacts (default: clean them up)
  --test-timeout <ms>          Per-test timeout in ms (default: 15000)
  -h, --help                   Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build-mode)    BUILD_MODE="$2"; shift 2;;
    --build-mode=*)  BUILD_MODE="${1#*=}"; shift;;
    --product)       PRODUCT="$2"; shift 2;;
    --product=*)     PRODUCT="${1#*=}"; shift;;
    --device)        DEVICE="$2"; shift 2;;
    --device=*)      DEVICE="${1#*=}"; shift;;
    --bundle-name)   BUNDLE_NAME="$2"; shift 2;;
    --bundle-name=*) BUNDLE_NAME="${1#*=}"; shift;;
    --test-plan)     TEST_PLAN="$2"; shift 2;;
    --test-plan=*)   TEST_PLAN="${1#*=}"; shift;;
    --test-timeout)  TEST_TIMEOUT="$2"; shift 2;;
    --test-timeout=*) TEST_TIMEOUT="${1#*=}"; shift;;
    --clean)         CLEAN=1; shift;;
    --launch)        LAUNCH=1; shift;;
    --skip-ohpm)     SKIP_OHPM=1; shift;;
    --no-uninstall)  NO_UNINSTALL=1; shift;;
    --test)          shift;;
    --no-test)       NO_TEST=1; shift;;
    --keep-artifacts) KEEP_ARTIFACTS=1; shift;;
    -h|--help)       usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
  esac
done

# ---------------- node tool (JSON5 parse + plan + report gen) ----------------
TOOL="$(mktemp 2>/dev/null || echo "/tmp/_bi_tool_$$.js")"
trap 'rm -f "$TOOL" 2>/dev/null; [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null' EXIT
cat > "$TOOL" <<'NODE'
const fs=require('fs'); const path=require('path');
function parseJson5(p){
  const raw=fs.readFileSync(p,'utf8');
  let o='',i=0,s=false,q='';
  while(i<raw.length){const c=raw[i],n=raw[i+1];
    if(s){o+=c;if(c==='\\'){o+=raw[i+1];i+=2;continue;}if(c===q)s=false;i++;continue;}
    if(c==='"'||c==="'"){s=true;q=c;o+=c;i++;continue;}
    if(c==='/'&&n==='/'){while(i<raw.length&&raw[i]!=='\n')i++;continue;}
    if(c==='/'&&n==='*'){i+=2;while(i<raw.length&&!(raw[i]==='*'&&raw[i+1]==='/'))i++;i+=2;continue;}
    o+=c;i++;}
  o=o.replace(/,\s*([}\]])/g,'$1');
  return JSON.parse(o);
}
function parseTestOut(testout){
  const lines=String(testout).split(/\r?\n/);
  const tests=[]; let lastObj=null,cls='',tst='',stm='',stk='',mm;
  for(const ln of lines){
    const s=ln.trim();
    if(mm=s.match(/^OHOS_REPORT_STATUS:\s*class=(.*)/)){ cls=mm[1].trim(); }
    else if(mm=s.match(/^OHOS_REPORT_STATUS:\s*test=(.*)/)){ tst=mm[1].trim(); }
    else if(mm=s.match(/^OHOS_REPORT_STATUS:\s*stream=(.*)/)){ stm=mm[1].trim(); }
    else if(mm=s.match(/^OHOS_REPORT_STATUS:\s*stack=(.*)/)){ stk+=mm[1].trim()+'\n'; }
    else if(mm=s.match(/^OHOS_REPORT_STATUS:\s*consuming=(\d+)/)){ if(lastObj) lastObj.Consuming=parseInt(mm[1]); }
    else if(mm=s.match(/^OHOS_REPORT_STATUS_CODE:\s*(-?\d+)/)){
      const code=parseInt(mm[1]);
      if(code!==1){
        const res=code===0?'✅ PASS':code===-2?'❌ FAIL':'⛔ ERROR';
        const o={Class:cls,Test:tst,Code:code,Result:res,Stream:stm,Stack:stk,Consuming:''};
        tests.push(o); lastObj=o; stm=''; stk='';
      }
    }
  }
  let run=0,pass=0,fail=0,errc=0,ign=0,hasSummary=false;
  const sum=String(testout).match(/Tests run:\s*(\d+).*?Failure:\s*(\d+).*?Error:\s*(\d+).*?Pass:\s*(\d+).*?Ignore:\s*(\d+)/);
  if(sum){ hasSummary=true; run=+sum[1];fail=+sum[2];errc=+sum[3];pass=+sum[4];ign=+sum[5]; }
  const codeM=String(testout).match(/OHOS_REPORT_CODE:\s*(-?\d+)/);
  return {hasSummary,run,pass,fail,errc,ign,reportCode:codeM?codeM[1]:'N/A',tests};
}
const cmd=process.argv[2];
try{
if(cmd==='read'){
  const obj=parseJson5(process.argv[3]);
  let acc=process.argv[4]||'';
  if(acc && !/^[\w.\[\]"']+$/.test(acc)){ process.exit(0); }
  let v; try{ v = acc ? eval('obj'+acc) : obj; }catch(e){ v=undefined; }
  process.stdout.write(v==null?'':String(v));
}
else if(cmd==='modules'){
  const obj=parseJson5(process.argv[3]);
  process.stdout.write((obj.modules||[]).map(m=>m.srcPath).filter(Boolean).join('\n'));
}
else if(cmd==='testtarget'){
  const obj=parseJson5(process.argv[3]);
  const t=(obj.targets||[]).find(x=>/test/i.test(x.name||''));
  process.stdout.write(t?t.name:'');
}
else if(cmd==='plan'){
  const obj=parseJson5(process.argv[3]);
  process.stdout.write('EMUPATH\t'+(obj.emulatorPath||'')+'\n');
  process.stdout.write('BOOTTIMEOUT\t'+(obj.bootTimeout!=null?obj.bootTimeout:20)+'\n');
  for(const d of (obj.devices||[])){
    const name=(d.name||d.emulator||d.device||'').toString();
    const dev=(d.device||'').toString().trim();
    const emu=(d.emulator||'').toString().trim();
    const tests=Array.isArray(d.tests)?d.tests.filter(x=>x&&String(x).trim()).map(x=>String(x).trim()):[];
    const hdcport=(d.hdcport!=null)?String(d.hdcport):'';
    process.stdout.write([name,dev,emu,tests.join(','),hdcport].join('\t')+'\n');
  }
}
else if(cmd==='mkreport2'){
  const out=process.argv[3];
  const bundle=process.argv[4],suite=process.argv[5],target=process.argv[6];
  const product=process.argv[7],mode=process.argv[8],timeout=process.argv[9];
  const stamp=process.argv[10],planMode=process.argv[11],deviceCount=parseInt(process.argv[12]);
  const tmpd=process.argv[13];
  const devices=[]; let tRun=0,tPass=0,tFail=0,tErr=0,tIgn=0;
  for(let i=0;i<deviceCount;i++){
    const infoP=path.join(tmpd,`info_${i}.tsv`), fileP=path.join(tmpd,`dev_${i}.txt`);
    let label='',serial='',classFilter='';
    if(fs.existsSync(infoP)){ const parts=fs.readFileSync(infoP,'utf8').split('\t'); label=parts[0]||''; serial=parts[1]||''; classFilter=(parts[2]||'').replace(/[\r\n]+$/,''); }
    const testout=fs.existsSync(fileP)?fs.readFileSync(fileP,'utf8'):'';
    const r=parseTestOut(testout);
    if(r.hasSummary){ tRun+=r.run;tPass+=r.pass;tFail+=r.fail;tErr+=r.errc;tIgn+=r.ign; }
    devices.push({label,serial,classFilter,testout,r});
  }
  const overall=(tFail+tErr)===0?'✅ 全部通过':'❌ 存在失败/错误';
  let sb=[]; const L=(x)=>sb.push(x);
  L('# 单元测试执行结果'); L('');
  L(`> 自动生成于 ${stamp} ，由 execute-multi-device-ui-unit-test.sh 执行后导出。`); L('');
  L('## 执行信息'); L('');
  L('| 项目 | 值 |'); L('|---|---|');
  L(`| 应用包名 bundleName | ${bundle} |`);
  if(suite) L(`| 测试套件 suite | ${suite} |`);
  if(target) L(`| 测试目标 target | ${target} |`);
  L(`| 构建 product / mode | ${product} / ${mode} |`);
  L(`| 用例超时 timeout(ms) | ${timeout} |`);
  L(`| 执行模式 | ${planMode}（设备 ${deviceCount} 台） |`);
  L(`| 执行时间 | ${stamp} |`); L('');
  L('## 全局汇总'); L('');
  L('| 总数 | 通过 | 失败 | 错误 | 忽略 | 总体 |'); L('|---|---|---|---|---|---|');
  L(`| ${tRun} | ${tPass} | ${tFail} | ${tErr} | ${tIgn} | ${overall} |`); L('');
  let idx=0;
  for(const dv of devices){
    idx++;
    L(`## 设备 ${idx}：${dv.label}`); L('');
    L(`- **序列号**：${dv.serial}`);
    const fd = dv.classFilter ? dv.classFilter : '（全量，未指定 class 筛选）';
    L(`- **用例筛选**：${fd}`);
    const r=dv.r;
    L(`- **OHOS_REPORT_CODE**：${r.reportCode} (0 = 全部通过)`); L('');
    if(r.hasSummary){
      L('| 总数 | 通过 | 失败 | 错误 | 忽略 |'); L('|---|---|---|---|---|');
      L(`| ${r.run} | ${r.pass} | ${r.fail} | ${r.errc} | ${r.ign} |`); L('');
    }
    if(r.tests.length>0){
      L('| # | 测试类 | 测试用例 | 结果 | 耗时(ms) |'); L('|---|---|---|---|---|');
      let j=0; for(const t of r.tests){ j++; L(`| ${j} | ${t.Class} | ${t.Test} | ${t.Result} | ${t.Consuming} |`); }
      L('');
    }
    const failed=r.tests.filter(t=>t.Code!==0);
    if(failed.length>0){
      L('### 失败详情'); L('');
      for(const f of failed){
        L(`#### ${f.Class}.${f.Test}`); L('');
        L(`- **结果**：${f.Result}`);
        L(`- **消息**：${f.Stream}`);
        if(f.Stack){ L('- **堆栈**：'); L('```'); L(f.Stack.trim()); L('```'); }
        L('');
      }
    }
    L('<details><summary>展开查看该设备完整 aa test 输出</summary>'); L('');
    L('```'); L(String(dv.testout).trim()); L('```'); L(''); L('</details>'); L('');
  }
  fs.writeFileSync(out, sb.join('\n'), 'utf8');
}
else if(cmd==='emulator'){
  // argv[3]=raw output of "Emulator -list -details", argv[4]=instance name
  // prints "isRunning(0/1)\t<hdcport>" to stdout, or nothing if not found/unparseable
  const raw=process.argv[3]||''; const want=process.argv[4]||'';
  const getField=(obj,dp)=>{ const ps=dp.split('.'); let v=obj,ok=true; for(const p of ps){ if(v==null){ok=false;break;} v=v[p]; } if(ok&&v!==undefined) return v; return obj[dp]; };
  let arr=null;
  try{ arr=JSON.parse(raw); }catch(e){ const s=raw.indexOf('['),e2=raw.lastIndexOf(']'); if(s>=0&&e2>s){ try{ arr=JSON.parse(raw.slice(s,e2+1)); }catch(_){} } }
  if(!Array.isArray(arr)){ process.exit(0); }
  for(const it of arr){
    if((it.name||'')===want){
      const running=String(it.isRunning||'').toLowerCase()==='true';
      const portRaw=getField(it,'hw.hdc.port');  // flat key; "notset" when not running
      const port=(portRaw!=null && /^\d+$/.test(String(portRaw)))?String(portRaw):'';
      process.stdout.write((running?'1':'0')+'\t'+port);
      process.exit(0);
    }
  }
  process.exit(0);
}
else { process.stderr.write('unknown tool command: '+cmd+'\n'); process.exit(2); }
}catch(e){ process.stderr.write('tool error: '+e.message+'\n'); process.exit(2); }
NODE
jread(){ node "$TOOL" read "$1" "$2"; }

# ---------------- bash device helpers ----------------
get_targets(){
  TARGETS=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    [ "$line" = "[Empty]" ] && continue
    TARGETS+=("$line")
  done < <(hdc list targets 2>/dev/null)
}
uninstall_from_device(){ hdc -t "$1" shell bm uninstall -n "$2" 2>/dev/null; }
install_hap(){
  local dev="$1" hap="$2" label="$3" hd=(-t "$dev") out rc
  local tmp="data/local/tmp/hap_$RANDOM"
  hdc "${hd[@]}" shell mkdir "$tmp" 2>/dev/null
  hdc "${hd[@]}" file send "$hap" "$tmp" 2>/dev/null
  out="$(hdc "${hd[@]}" shell bm install -p "$tmp" 2>&1)"
  rc=$?
  hdc "${hd[@]}" shell rm -rf "$tmp" 2>/dev/null
  echo "    bm install output: $out" >&2
  if [ $rc -ne 0 ]; then warn "[$label] install FAILED (rc=$rc)"; return 1; fi
  return 0
}
run_aa_test(){
  local dev="$1" bundle="$2" suite="$3" cf="$4" timeout="$5" hd=(-t "$dev")
  local cmd="aa test -b \"$bundle\" -m \"$suite\" -s unittest OpenHarmonyTestRunner -s timeout $timeout"
  if [ -n "$cf" ]; then cmd="$cmd -s class \"$cf\""; fi
  hdc "${hd[@]}" shell "$cmd" 2>&1
}
find_emulator(){
  if [ -n "${DEVECO_SDK_HOME:-}" ]; then
    for cand in \
      "$DEVECO_SDK_HOME/tools/emulator/Emulator" \
      "$DEVECO_SDK_HOME/../tools/emulator/Emulator" \
      "$DEVECO_SDK_HOME/../tools/emulator/Emulator.app/Contents/MacOS/Emulator" \
      "$DEVECO_SDK_HOME/tools/emulator/emulator" ; do
      if [ -f "$cand" ]; then echo "$cand"; return 0; fi
    done
  fi
  return 1
}
# Verify a hdc serial is truly online & responsive (guards against transient/blank/invalid serials)
test_serial_online(){
  local s="$1"
  [ -n "$s" ] || return 1
  hdc -t "$s" shell echo __HDC_OK__ 2>/dev/null | grep -q __HDC_OK__
}

# Wait for the system to fully boot (bootevent=true). Returns 0 if confirmed.
wait_boot_finished(){
  local serial="$1" waitsec="${2:-180}" deadline=$(( $(date +%s) + waitsec )) p r
  while [ $(date +%s) -lt $deadline ]; do
    for p in bootevent.boot.finished bootevent.system.ready; do
      r="$(hdc -t "$serial" shell param get "$p" 2>/dev/null)"
      echo "$r" | grep -q true && return 0
    done
    sleep 3
  done
  # diagnostics: dump actual param values so we can identify the correct boot flag for this image
  local d1 d2
  d1="$(hdc -t "$serial" shell param get bootevent.boot.finished 2>/dev/null)"
  d2="$(hdc -t "$serial" shell param get bootevent.system.ready 2>/dev/null)"
  warn "    [诊断] bootevent.boot.finished='$d1'; bootevent.system.ready='$d2'"
  return 1
}

# Wake screen + disable auto-suspend + swipe-up to unlock. MUST be called AFTER boot finished.
unlock_screen(){
  local serial="$1" r1 r3 i
  echo "  主动唤醒并解锁屏幕..." >&2
  r1="$(hdc -t "$serial" shell power-shell wakeup 2>&1)"
  hdc -t "$serial" shell power-shell timeout -o 600000 >/dev/null 2>&1 || true
  sleep 3
  r3=""
  for i in 1 2; do
    r3="$(hdc -t "$serial" shell uinput -T -m 540 2000 540 400 500 2>&1)"
    sleep 2
  done
  echo "    power-shell wakeup : ${r1:-(无输出/ok)}" >&2
  echo "    uinput swipe x2   : ${r3:-(无输出/ok)}" >&2
}

# Ensure fully booted, then wake & unlock. Called before install on every device.
wait_device_ready(){
  local serial="$1" bt="${2:-20}"
  echo "  确认系统完全启动（bootTimeout=${bt}s）..." >&2
  if wait_boot_finished "$serial" "$bt"; then ok "    bootevent=true"; else
    warn "    未检测到 bootevent，额外等待 15s..."
    sleep 15
  fi
  # 兜底：用 bm dump 能响应来确认系统服务就绪
  local bm_deadline=$(( $(date +%s) + 90 )) bm_ready=0 r
  while [ $(date +%s) -lt $bm_deadline ]; do
    r="$(hdc -t "$serial" shell bm dump -a 2>/dev/null)"
    if [ -n "$r" ]; then bm_ready=1; break; fi
    sleep 5
  done
  if [ "$bm_ready" = 1 ]; then ok "    系统服务就绪（bm dump 可用）"; else warn "    系统服务仍未就绪，继续尝试唤醒..."; fi
  unlock_screen "$serial"
}

# Ensure emulator is running (start if not); print its REAL hdc serial from `hdc list targets`.
# $1=emuexe $2=name $3=hdcport ; uses -hdcport + tconn (does NOT rely on hw.hdc.port).
resolve_emulator_serial(){
  local emuexe="$1" name="$2" hdcport="${3:-0}" raw info running port wasrunning t b skip tconn cand
  raw="$("$emuexe" -list -details 2>&1)"
  info="$(node "$TOOL" emulator "$raw" "$name")"
  running=""; [ -n "$info" ] && running="${info%%$'\t'*}"
  wasrunning=0; [ "$running" = "1" ] && wasrunning=1
  if [ "$wasrunning" = 0 ]; then
    step "模拟器 '$name' 未运行，执行启动：$emuexe -start $name" >&2
    "$emuexe" -license accept >/dev/null 2>&1 || true
  else
    ok "模拟器 '$name' 已在运行，等待 hdc 识别..." >&2
  fi
  # capture BEFORE launching: retry to ensure already-connected devices (e.g. real phone) are included,
  # so the diff fallback won't mistakenly pick them up as the "new" emulator.
  local _bdeadline=$(( $(date +%s) + 10 ))
  local before=()
  while [ $(date +%s) -lt $_bdeadline ]; do
    get_targets
    if [ ${#TARGETS[@]} -gt 0 ]; then before=("${TARGETS[@]}"); break; fi
    sleep 2
  done
  if [ "$wasrunning" = 0 ]; then
    if [ "$hdcport" -gt 0 ] 2>/dev/null; then
      nohup "$emuexe" -start "$name" -hdcport "$hdcport" >/dev/null 2>&1 &
      ok "指定 hdc 端口：$hdcport（-hdcport）" >&2
    else
      nohup "$emuexe" -start "$name" >/dev/null 2>&1 &
    fi
  fi
  local deadline=$(( $(date +%s) + 180 ))
  while [ $(date +%s) -lt $deadline ]; do
    sleep 5
    get_targets
    cand=""
    # 1) configured hdc port: tconn, then match & verify
    if [ "$hdcport" -gt 0 ] 2>/dev/null; then
      tconn="127.0.0.1:$hdcport"
      hdc tconn "$tconn" >/dev/null 2>&1 || true
      sleep 2
      get_targets
      if [ ${#TARGETS[@]} -gt 0 ]; then
        for t in "${TARGETS[@]}"; do case "$t" in *":$hdcport") if test_serial_online "$t"; then cand="$t"; break; fi;; esac; done
      fi
      if [ -z "$cand" ] && test_serial_online "$tconn"; then cand="$tconn"; fi
    fi
    # 2) fallback: hw.hdc.port from -list -details (numeric only)
    if [ -z "$cand" ]; then
      raw="$("$emuexe" -list -details 2>&1)"
      info="$(node "$TOOL" emulator "$raw" "$name")"
      port=""
      if [ -n "$info" ]; then running="${info%%$'\t'*}"; port="${info#*$'\t'}"; else running=""; fi
      if [ -n "$port" ]; then
        tconn="127.0.0.1:$port"
        hdc tconn "$tconn" >/dev/null 2>&1 || true
        sleep 2
        get_targets
        if [ ${#TARGETS[@]} -gt 0 ]; then
          for t in "${TARGETS[@]}"; do case "$t" in *":$port") if test_serial_online "$t"; then cand="$t"; break; fi;; esac; done
        fi
        if [ -z "$cand" ] && test_serial_online "$tconn"; then cand="$tconn"; fi
      fi
    fi
    # 3) fallback: newly-online diff, verified
    if [ -z "$cand" ] && [ "$wasrunning" = 0 ] && [ ${#TARGETS[@]} -gt 0 ]; then
      for t in "${TARGETS[@]}"; do
        [ -n "$t" ] || continue
        skip=0
        if [ ${#before[@]} -gt 0 ]; then for b in "${before[@]}"; do [ "$t" = "$b" ] && skip=1 && break; done; fi
        if [ "$skip" = 0 ] && test_serial_online "$t"; then cand="$t"; break; fi
      done
    fi
    if [ -n "$cand" ]; then
      ok "模拟器 '$name' hdc 已连接（序列号 $cand）" >&2
      printf '%s' "$cand"; return 0
    fi
    printf "  ${c_gray}仍在等待模拟器就绪（剩余 %s 秒）...${c_reset}\n" "$(( deadline - $(date +%s) ))" >&2
  done
  # timed out: diagnostics
  warn "[诊断] 模拟器 '$name' 识别失败"
  raw="$("$emuexe" -list -details 2>&1)"; info="$(node "$TOOL" emulator "$raw" "$name")"
  if [ -n "$info" ]; then running="${info%%$'\t'*}"; port="${info#*$'\t'}"; warn "  Emulator -list -details -> isRunning=$running, hw.hdc.port=${port:-（notset/空）}"; else warn "  Emulator -list -details -> 未找到实例或解析失败"; fi
  get_targets
  if [ ${#TARGETS[@]} -gt 0 ]; then warn "  hdc list targets -> ${TARGETS[*]}"; else warn "  hdc list targets -> [Empty]"; fi
  if [ "$hdcport" = "0" ] || [ -z "$hdcport" ]; then warn "  提示：hw.hdc.port 为 notset 时，请在配置中给该模拟器指定 hdcport（如 5554，范围 10000-16555）。"; fi
  return 1
}

# Stop an emulator instance (best-effort): $1=emuexe $2=name $3=serial(optional)
stop_emulator(){
  local emuexe="$1" name="$2" serial="${3:-}"
  [ -n "$serial" ] && hdc tdisconn "$serial" >/dev/null 2>&1 || true
  "$emuexe" -stop "$name" >/dev/null 2>&1 || true
}

# put CWD (project root, contains hvigorw) first in PATH so `hvigorw` resolves
case ":$PATH:" in *":$PWD:"*) ;; *) PATH="$PWD:$PATH";; esac
export PATH
# auto-add DevEco tool dirs to PATH (hdc/hvigorw/ohpm) derived from DEVECO_SDK_HOME
if [ -n "${DEVECO_SDK_HOME:-}" ]; then
  DEVROOT="$(cd "$DEVECO_SDK_HOME/.." 2>/dev/null && pwd)"
  for d in "$DEVECO_SDK_HOME/default/openharmony/toolchains" "$DEVROOT/tools/hvigor/bin" "$DEVROOT/tools/ohpm/bin"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in *":$d:"*) ;; *) PATH="$PATH:$d";; esac
  done
  export PATH
fi

# ---------------- 0. env check ----------------
step "Environment check"
for t in hvigorw hdc ohpm node; do
  command -v "$t" >/dev/null 2>&1 || die "Command not found: $t (configure HarmonyOS command line tools)"
done
ok "OK"

# ---------------- 1. detect params ----------------
step "Detecting project params"
BP_JSON="$ROOT/build-profile.json5"
APP_JSON="$ROOT/AppScope/app.json5"
[ -f "$BP_JSON" ] || die "build-profile.json5 not found at $BP_JSON"
[ -f "$APP_JSON" ] || die "AppScope/app.json5 not found at $APP_JSON"
[ -z "$PRODUCT" ]     && PRODUCT="$(jread "$BP_JSON" '.app.products[0].name')"
[ -z "$BUNDLE_NAME" ] && BUNDLE_NAME="$(jread "$APP_JSON" '.app.bundleName')"
ENTRY_SRC=""; MODULE_NAME=""; ABILITY_NAME=""
while IFS= read -r src || [ -n "$src" ]; do
  [ -z "$src" ] && continue
  rel="${src#./}"
  mj="$ROOT/$rel/src/main/module.json5"
  if [ -f "$mj" ]; then
    mtype="$(jread "$mj" '.module.type')"
    if [ "$mtype" = "entry" ]; then
      ENTRY_SRC="$src"; MODULE_NAME="$(jread "$mj" '.module.name')"; ABILITY_NAME="$(jread "$mj" '.module.mainElement')"
      break
    fi
  fi
done < <(node "$TOOL" modules "$BP_JSON")
[ -n "$ENTRY_SRC" ] || die "No entry module found"
ENTRY_REL="${ENTRY_SRC#./}"
BUILD_DIR="$ROOT/$ENTRY_REL/build"
printf "  bundle=%s  product=%s  module=%s  ability=%s  mode=%s\n" "$BUNDLE_NAME" "$PRODUCT" "$MODULE_NAME" "$ABILITY_NAME" "$BUILD_MODE"

# ---------------- 2. deps ----------------
if [ "$SKIP_OHPM" -eq 0 ]; then
  step "Installing deps (ohpm install)"
  ohpm install || die "ohpm install failed"
fi

# ---------------- 3. clean ----------------
if [ "$CLEAN" -eq 1 ]; then
  step "Clean (hvigorw clean)"
  hvigorw clean --no-daemon || die "clean failed"
fi

# ---------------- 4. build app HAP ----------------
step "Build HAP (assembleHap)"
hvigorw --no-daemon -p "product=$PRODUCT" -p "buildMode=$BUILD_MODE" assembleHap || die "Build failed"

# ---------------- 5. locate app HAP ----------------
step "Locate HAP artifact"
HAP=""
while IFS= read -r -d '' f || [ -n "$f" ]; do
  parent="$(basename "$(dirname "$f")")"
  case "$parent" in *[Tt]est*) continue;; esac
  case "$(basename "$f")" in *-signed.hap) HAP="$f"; break;; esac
done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
if [ -z "$HAP" ]; then
  newest=""
  while IFS= read -r -d '' f || [ -n "$f" ]; do
    parent="$(basename "$(dirname "$f")")"
    case "$parent" in *[Tt]est*) continue;; esac
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
  HAP="$newest"
fi
[ -n "$HAP" ] || die "No HAP found under: $BUILD_DIR"
echo "  HAP = $HAP"

# ---------------- 6. resolve device plan (parse only; emulators start per-device in step 8) ----------------
step "Resolving device plan"
DEV_SERIAL=(); DEV_LABEL=(); DEV_FILTER=(); DEV_EMULATOR=(); DEV_HDCPORT=(); DEV_ISEMULATOR=()
EMU_EXE=""
BOOT_TIMEOUT=20
PLAN_FILE="$TEST_PLAN"
if [ -z "$PLAN_FILE" ]; then
  for n in device-test-plan.json5 device-test-plan.example.json5; do
    if [ -f "$ROOT/$n" ]; then PLAN_FILE="$ROOT/$n"; break; fi
  done
fi

if [ -n "$PLAN_FILE" ]; then
  [ -f "$PLAN_FILE" ] || die "Test plan not found: $PLAN_FILE"
  echo "  计划文件：$PLAN_FILE"
  PLAN_LINES=()
  while IFS= read -r line || [ -n "$line" ]; do PLAN_LINES+=("$line"); done < <(node "$TOOL" plan "$PLAN_FILE")
  line0="${PLAN_LINES[0]:-}"
  if [ "${line0:0:7}" = "EMUPATH" ]; then EMU_EXE="${line0:8}"; fi
  line1="${PLAN_LINES[1]:-}"
  if [ "${line1:0:11}" = "BOOTTIMEOUT" ]; then BOOT_TIMEOUT="${line1:12}"; fi
  need_launch=0
  for line in "${PLAN_LINES[@]:2}"; do
    IFS=$'\t' read -r _name _dev _emu _cf _hp <<<"$line"
    if [ -n "$_emu" ]; then need_launch=1; break; fi
  done
  if [ "$need_launch" = 1 ]; then
    if [ -z "$EMU_EXE" ]; then EMU_EXE="$(find_emulator || true)"; fi
    if [ -z "$EMU_EXE" ]; then
      if [ ! -t 0 ]; then die "需要启动模拟器但未找到 Emulator，且非交互环境。请在计划文件设置 emulatorPath 或配置 DEVECO_SDK_HOME。"; fi
      warn "未自动发现 Emulator，请手动输入路径。"
      read -r -e -p "请输入模拟器可执行文件路径: " EMU_EXE </dev/tty
      [ -f "$EMU_EXE" ] || die "Emulator 路径不存在：$EMU_EXE"
    fi
    chmod +x "$EMU_EXE" 2>/dev/null
    step "可用模拟器实例（Emulator -list）"
    "$EMU_EXE" -list 2>&1 || true
  fi
  idx=0
  for line in "${PLAN_LINES[@]:2}"; do
    idx=$((idx+1))
    _name=""; _dev=""; _emu=""; _cf=""; _hp=""
    IFS=$'\t' read -r _name _dev _emu _cf _hp <<<"$line"
    [ -z "$_name" ] && _name="device$idx"
    if [ -n "$_emu" ]; then
      [ -n "$EMU_EXE" ] || die "设备 $_name 配置了 emulator 但缺少 Emulator（请设置 emulatorPath 或 DEVECO_SDK_HOME）。"
      hp="0"; if [ -n "$_hp" ] && [[ "$_hp" =~ ^[0-9]+$ ]]; then hp="$_hp"; fi
      DEV_SERIAL+=(""); DEV_LABEL+=("$_name"); DEV_FILTER+=("$_cf"); DEV_EMULATOR+=("$_emu"); DEV_HDCPORT+=("$hp"); DEV_ISEMULATOR+=("1")
      echo "  设备 $_name：模拟器 '$_emu'（hdcport=${hp}，将在执行时启动、跑完即关闭）"
    elif [ -n "$_dev" ]; then
      _retry_end=$(( $(date +%s) + 15 ))
      found=0
      while [ $(date +%s) -lt $_retry_end ] && [ "$found" = 0 ]; do
        get_targets
        if [ ${#TARGETS[@]} -gt 0 ]; then for t in "${TARGETS[@]}"; do [ "$t" = "$_dev" ] && found=1 && break; done; fi
        [ "$found" = 0 ] && sleep 2
      done
      if [ "$found" = 1 ]; then
        DEV_SERIAL+=("$_dev"); DEV_LABEL+=("$_name"); DEV_FILTER+=("$_cf"); DEV_EMULATOR+=(""); DEV_HDCPORT+=("0"); DEV_ISEMULATOR+=("0")
        ok "设备 $_name：已在线（$_dev），直接复用"
      else
        get_targets
        warn "设备 $_name 的 device '$_dev' 不在线，跳过。当前 hdc list targets: ${TARGETS[*]:-[Empty]}"
      fi
    else
      die "设备 $_name 缺少 emulator/device 配置，无法确定目标设备。"
    fi
  done
  [ ${#DEV_SERIAL[@]} -gt 0 ] || die "计划文件中没有任何可用设备（真机不在线且无模拟器，或配置缺失）。"
  PLAN_MODE="multi ($(basename "$PLAN_FILE"))，串行（一次只跑一个模拟器，跑完即关）"
else
  # single-device mode: interactive device selection
  get_targets
  while [ "${#TARGETS[@]}" -eq 0 ]; do
    if [ ! -t 0 ]; then
      warn "未检测到设备/模拟器（模拟器可能未启动）。"
      warn "请先在 DevEco Studio 启动模拟器，或用 USB 连接真机并开启调试，然后重跑脚本（多设备可用 --test-plan）。"
      die "No device/emulator detected (non-interactive)"
    fi
    warn "未检测到设备/模拟器（模拟器可能未启动）。"
    echo "请选择："
    echo "  [1] 我已手动启动模拟器/连接真机 —— 重新检测"
    echo "  [2] 自动启动本地模拟器（输入模拟器路径 + 设备名称，由脚本自动启动并等待就绪）"
    echo "  [q] 退出"
    read -r -p "请输入选项 [1/2/q]（默认 1）: " choice </dev/tty
    case "$choice" in
      q|Q) die "用户取消，未连接设备/模拟器" ;;
      2)
        EMU_DEFAULT="$(find_emulator || true)"
        if [ -n "$EMU_DEFAULT" ]; then
          read -r -e -p "请输入模拟器可执行文件路径（回车使用默认：$EMU_DEFAULT）: " emu_path </dev/tty
          [ -z "$emu_path" ] && emu_path="$EMU_DEFAULT"
        else
          read -r -e -p "请输入模拟器可执行文件路径: " emu_path </dev/tty
        fi
        if [ -z "$emu_path" ] || [ ! -f "$emu_path" ]; then warn "路径不存在或不是可执行文件。"; continue; fi
        chmod +x "$emu_path" 2>/dev/null
        step "查询可用模拟器实例（Emulator -list）"
        if ! list_out="$("$emu_path" -list 2>&1)"; then warn "执行 -list 失败：$list_out"; continue; fi
        [ -n "$list_out" ] || { warn "未查询到模拟器实例。"; continue; }
        echo "$list_out"
        read -r -e -p "请输入要启动的设备名称（上列表中的某一项）: " emu_name </dev/tty
        [ -n "$emu_name" ] || { warn "设备名称为空，请重新选择。"; continue; }
        read -r -e -p "指定 hdc 端口（10000-16555，强烈建议；回车跳过）: " hp_in </dev/tty
        hp="0"; if [ -n "$hp_in" ] && [[ "$hp_in" =~ ^[0-9]+$ ]]; then hp="$hp_in"; fi
        ser="$(resolve_emulator_serial "$emu_path" "$emu_name" "$hp")"
        if [ -n "$ser" ]; then
          EMU_EXE="$emu_path"
          DEV_SERIAL+=("$ser"); DEV_LABEL+=("$emu_name"); DEV_FILTER+=(""); DEV_EMULATOR+=("$emu_name"); DEV_HDCPORT+=("$hp"); DEV_ISEMULATOR+=("1")
          get_targets
        else warn "模拟器在 180 秒内未就绪。"; fi
        ;;
      *) get_targets ;;
    esac
  done
  if [ ${#DEV_SERIAL[@]} -eq 0 ]; then
    if [ -n "$DEVICE" ]; then
      found=0
      for t in "${TARGETS[@]}"; do [ "$t" = "$DEVICE" ] && found=1; done
      [ "$found" = 1 ] || die "Device not connected: $DEVICE (available: ${TARGETS[*]})"
      sel="$DEVICE"
    else
      if [ "${#TARGETS[@]}" -gt 1 ]; then die "Multiple devices (${TARGETS[*]}), specify with --device (or use --test-plan for multi-device mode)"; fi
      sel="${TARGETS[0]}"
    fi
    DEV_SERIAL+=("$sel"); DEV_LABEL+=("$sel"); DEV_FILTER+=(""); DEV_EMULATOR+=(""); DEV_HDCPORT+=("0"); DEV_ISEMULATOR+=("0")
  fi
  PLAN_MODE="single"
fi
echo "  模式：$PLAN_MODE，设备数：${#DEV_SERIAL[@]}"
i=0
while [ $i -lt ${#DEV_SERIAL[@]} ]; do
  kind="设备 ${DEV_SERIAL[$i]}"
  [ "${DEV_ISEMULATOR[$i]}" = "1" ] && kind="模拟器 ${DEV_EMULATOR[$i]}"
  extra=""
  [ "${DEV_ISEMULATOR[$i]}" = "1" ] && [ "${DEV_HDCPORT[$i]}" != "0" ] && extra=" hdcport=${DEV_HDCPORT[$i]}"
  [ -n "${DEV_FILTER[$i]}" ] && extra="$extra 用例过滤：${DEV_FILTER[$i]}"
  printf "    - %s（%s%s）\n" "${DEV_LABEL[$i]}" "$kind" "$extra"
  i=$((i+1))
done

# ---------------- 7. test target detection + build ----------------
TEST_TARGET=""; SUIT_NAME=""; TEST_HAP=""
if [ "$NO_TEST" -eq 0 ]; then
  step "Detecting test target"
  ENTRY_BP="$ROOT/$ENTRY_REL/build-profile.json5"
  TEST_TARGET="$(node "$TOOL" testtarget "$ENTRY_BP")"
  [ -n "$TEST_TARGET" ] || die "No test target (e.g. ohosTest) found in $ENTRY_BP"
  TEST_MOD_JSON="$ROOT/$ENTRY_REL/src/$TEST_TARGET/module.json5"
  [ -f "$TEST_MOD_JSON" ] || die "Test module.json5 not found: $TEST_MOD_JSON"
  SUIT_NAME="$(jread "$TEST_MOD_JSON" '.module.name')"
  echo "  testTarget=$TEST_TARGET  suite=$SUIT_NAME"

  step "Build test HAP (assembleHap -p module=$MODULE_NAME@$TEST_TARGET)"
  hvigorw --no-daemon -p "product=$PRODUCT" -p "module=$MODULE_NAME@$TEST_TARGET" assembleHap || die "Test build failed"

  step "Locate test HAP"
  newest_t=""
  while IFS= read -r -d '' f || [ -n "$f" ]; do
    parent="$(basename "$(dirname "$f")")"
    if [ "$parent" = "$TEST_TARGET" ]; then if [ -z "$newest_t" ] || [ "$f" -nt "$newest_t" ]; then newest_t="$f"; fi; fi
  done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
  TEST_HAP="$newest_t"
  [ -n "$TEST_HAP" ] || die "Test HAP not found under $BUILD_DIR (target=$TEST_TARGET)"
  echo "  testHAP = $TEST_HAP"
fi

# ---------------- 8. per device: start emulator -> install -> test -> stop emulator ----------------
TMPD="$(mktemp -d 2>/dev/null || echo "/tmp/_eudir_$$")"
mkdir -p "$TMPD"
n=${#DEV_SERIAL[@]}
i=0
while [ $i -lt $n ]; do
  label="${DEV_LABEL[$i]}"; cf="${DEV_FILTER[$i]}"; isemu="${DEV_ISEMULATOR[$i]}"
  emu="${DEV_EMULATOR[$i]}"; hp="${DEV_HDCPORT[$i]}"
  i1=$((i+1))
  step "[$i1/$n] $label"
  serial=""
  needclose=0
  if [ "$isemu" = "1" ]; then
    if [ -n "${DEV_SERIAL[$i]}" ]; then
      serial="${DEV_SERIAL[$i]}"   # already started (single-device mode option 2)
      echo "  模拟器已启动，序列号 $serial"
    else
      echo "  启动模拟器 '$emu'（hdcport=${hp}）..."
      serial="$(resolve_emulator_serial "$EMU_EXE" "$emu" "$hp")"
      if [ -z "$serial" ]; then
        warn "模拟器启动失败，跳过该设备。"
        printf '%s\t%s\t%s\n' "$label" "" "$cf" > "$TMPD/info_${i}.tsv"; : > "$TMPD/dev_${i}.txt"
        i=$((i+1)); continue
      fi
    fi
    needclose=1
  else
    serial="${DEV_SERIAL[$i]}"
    get_targets
    found=0
    if [ ${#TARGETS[@]} -gt 0 ]; then for t in "${TARGETS[@]}"; do [ "$t" = "$serial" ] && found=1 && break; done; fi
    if [ "$found" = 0 ]; then
      warn "设备 $serial 不在线，跳过。"
      printf '%s\t%s\t%s\n' "$label" "$serial" "$cf" > "$TMPD/info_${i}.tsv"; : > "$TMPD/dev_${i}.txt"
      i=$((i+1)); continue
    fi
  fi
  echo "  serial = $serial"
  printf '%s\t%s\t%s\n' "$label" "$serial" "$cf" > "$TMPD/info_${i}.tsv"; : > "$TMPD/dev_${i}.txt"
  wait_device_ready "$serial" "$BOOT_TIMEOUT"
  if [ "$NO_UNINSTALL" -eq 0 ]; then echo "  uninstall previous..."; uninstall_from_device "$serial" "$BUNDLE_NAME"; fi
  echo "  install app HAP..."
  if ! install_hap "$serial" "$HAP" "$label"; then
    warn "应用安装失败，跳过。"
    if [ "$needclose" = 1 ]; then echo "  关闭模拟器 '$emu'..."; stop_emulator "$EMU_EXE" "$emu" "$serial"; sleep 3; fi
    i=$((i+1)); continue
  fi
  if [ "$LAUNCH" -eq 1 ]; then echo "  launch app..."; hdc -t "$serial" shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME" -m "$MODULE_NAME"; fi
  if [ "$NO_TEST" -eq 0 ]; then
    echo "  install test HAP..."
    if ! install_hap "$serial" "$TEST_HAP" "$label"; then
      warn "测试 HAP 安装失败，跳过测试。"
    else
      if [ -n "$cf" ]; then fdesc="$cf"; else fdesc="(全量)"; fi
      echo "  run aa test (class filter: $fdesc, timeout=${TEST_TIMEOUT}ms)..."
      unlock_screen "$serial"   # re-unlock right before aa test (screen may re-lock during install)
    run_aa_test "$serial" "$BUNDLE_NAME" "$SUIT_NAME" "$cf" "$TEST_TIMEOUT" > "$TMPD/dev_${i}.txt"
      summary="$(grep 'Tests run:' "$TMPD/dev_${i}.txt" | tail -1)"
      repcode="$(grep 'OHOS_REPORT_CODE:' "$TMPD/dev_${i}.txt" | tail -1 | sed -E 's/.*OHOS_REPORT_CODE:[[:space:]]*//')"
      if [ -n "$summary" ]; then
        pcnt(){ printf '%s\n' "$summary" | sed -nE "s/.*$1:[[:space:]]*([0-9]+).*/\1/p"; }
        run="$(pcnt 'Tests run')"; fail="$(pcnt 'Failure')"; errc="$(pcnt 'Error')"; pass="$(pcnt 'Pass')"; ign="$(pcnt 'Ignore')"
        if [ "$(( ${fail:-0} + ${errc:-0} ))" -eq 0 ]; then ok "结果：run=${run} pass=${pass} failure=${fail} error=${errc} ignore=${ign} code=${repcode}"; else warn "结果：run=${run} pass=${pass} failure=${fail} error=${errc} ignore=${ign} code=${repcode}"; fi
      else warn "(未解析到汇总行，详见报告)"; fi
    fi
  fi
  if [ "$needclose" = 1 ]; then
    echo "  关闭模拟器 '$emu'..."
    stop_emulator "$EMU_EXE" "$emu" "$serial"
    sleep 3
    ok "模拟器已关闭"
  fi
  i=$((i+1))
done

# ---------------- 9. export report ----------------
if [ "$NO_TEST" -eq 0 ]; then
  step "Exporting report"
  ts="$(date +%Y%m%d_%H%M%S)"
  stamp="$(date '+%Y-%m-%d %H:%M:%S')"
  report_name="执行结果_${ts}.md"
  report_path="$ROOT/$report_name"
  node "$TOOL" mkreport2 "$report_path" "$BUNDLE_NAME" "$SUIT_NAME" "$TEST_TARGET" "$PRODUCT" "$BUILD_MODE" "$TEST_TIMEOUT" "$stamp" "$PLAN_MODE" "$n" "$TMPD" \
    || die "Report generation failed"
  ok "report: $report_path"
fi

# ---------------- 10. cleanup (real devices only; emulators already stopped) ----------------
if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
  step "Cleaning up artifacts"
  i=0
  while [ $i -lt $n ]; do
    if [ "${DEV_ISEMULATOR[$i]}" = "0" ]; then uninstall_from_device "${DEV_SERIAL[$i]}" "$BUNDLE_NAME"; warn "device ${DEV_SERIAL[$i]}: uninstalled $BUNDLE_NAME"; fi
    i=$((i+1))
  done
  nbuild=0; nohm=0; nlock=0
  while IFS= read -r -d '' d || [ -n "$d" ]; do
    case "$d" in *oh_modules*) continue;; esac
    rm -rf "$d" && nbuild=$((nbuild+1))
  done < <(find "$ROOT" -type d -name build -print0 2>/dev/null)
  while IFS= read -r -d '' d || [ -n "$d" ]; do
    case "$(dirname "$d")" in *oh_modules*) continue;; esac
    rm -rf "$d" && nohm=$((nohm+1))
  done < <(find "$ROOT" -type d -name oh_modules -print0 2>/dev/null)
  while IFS= read -r -d '' f || [ -n "$f" ]; do
    case "$f" in *oh_modules*) continue;; esac
    rm -f "$f" && nlock=$((nlock+1))
  done < <(find "$ROOT" -type f -name oh-package-lock.json5 -print0 2>/dev/null)
  echo "  removed: build=$nbuild  oh_modules=$nohm  oh-package-lock=$nlock"
fi

printf "\n${c_green}==> Done!${c_reset}\n"
