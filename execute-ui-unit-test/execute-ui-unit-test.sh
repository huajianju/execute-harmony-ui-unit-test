#!/usr/bin/env bash
# execute-ui-unit-test.sh — Generic HarmonyOS build + install + UT + report + cleanup (macOS / Linux)
# Bash 3.2+ compatible. Mirrors execute-ui-unit-test.ps1. Do not rely on Windows-specific behavior.
#
# Usage:
#   ./execute-ui-unit-test.sh                     # full flow: build app -> install -> UT -> report -> cleanup
#   ./execute-ui-unit-test.sh --no-test           # skip unit tests
#   ./execute-ui-unit-test.sh --build-mode release --clean
#   ./execute-ui-unit-test.sh --launch --keep-artifacts
#   ./execute-ui-unit-test.sh -h                  # help

set -u

# ---------------- helpers ----------------
c_reset='\033[0m'; c_red='\033[31m'; c_green='\033[32m'; c_yellow='\033[33m'; c_cyan='\033[36m'; c_gray='\033[90m'
step(){ printf "\n${c_cyan}==> %s${c_reset}\n" "$*"; }
ok(){   printf "  ${c_green}%s${c_reset}\n" "$*"; }
warn(){ printf "  ${c_yellow}%s${c_reset}\n" "$*"; }
err(){  printf "${c_red}ERROR: %s${c_reset}\n" "$*"; }
die(){ err "$*"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---------------- args ----------------
BUILD_MODE="debug"; PRODUCT=""; DEVICE=""; BUNDLE_NAME=""
CLEAN=0; LAUNCH=0; SKIP_OHPM=0; NO_UNINSTALL=0; NO_TEST=0; KEEP_ARTIFACTS=0; TEST_TIMEOUT=15000

usage(){ cat <<'EOF'
Usage: execute-ui-unit-test.sh [options]
  --build-mode debug|release   Build mode (default: debug)
  --product <name>             Product (auto-detected from build-profile.json5)
  --device <sn>                Target device serial (required if multiple connected)
  --bundle-name <name>         Bundle name (auto-detected from AppScope/app.json5)
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
    --test-timeout)  TEST_TIMEOUT="$2"; shift 2;;
    --test-timeout=*) TEST_TIMEOUT="${1#*=}"; shift;;
    --clean)         CLEAN=1; shift;;
    --launch)        LAUNCH=1; shift;;
    --skip-ohpm)     SKIP_OHPM=1; shift;;
    --no-uninstall)  NO_UNINSTALL=1; shift;;
    --test)          shift;;            # accepted (default-on), backward compat
    --no-test)       NO_TEST=1; shift;;
    --keep-artifacts) KEEP_ARTIFACTS=1; shift;;
    -h|--help)       usage; exit 0;;
    *) err "Unknown option: $1"; usage; exit 1;;
  esac
done

# ---------------- node tool (JSON5 parse + report gen) ----------------
TOOL="$(mktemp 2>/dev/null || echo "/tmp/_bi_tool_$$.js")"
_TESTOUT_FILE=""
trap 'rm -f "$TOOL" "$_TESTOUT_FILE" 2>/dev/null' EXIT
cat > "$TOOL" <<'NODE'
const fs=require('fs');
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
else if(cmd==='mkreport'){
  const out=process.argv[3], testoutPath=process.argv[4];
  const bundle=process.argv[5], suite=process.argv[6], target=process.argv[7];
  const device=process.argv[8], product=process.argv[9], mode=process.argv[10], timeout=process.argv[11];
  const testout=fs.readFileSync(testoutPath,'utf8');
  const lines=testout.split(/\r?\n/);
  const tests=[]; let lastObj=null; let cls='',tst='',stm='',stk='';
  let mm;
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
        const res = code===0?'✅ PASS' : code===-2?'❌ FAIL':'⛔ ERROR';
        const o={Class:cls,Test:tst,Code:code,Result:res,Stream:stm,Stack:stk,Consuming:''};
        tests.push(o); lastObj=o; stm=''; stk='';
      }
    }
  }
  let run=0,pass=0,fail=0,errc=0,ign=0;
  let sum=testout.match(/Tests run:\s*(\d+).*?Failure:\s*(\d+).*?Error:\s*(\d+).*?Pass:\s*(\d+).*?Ignore:\s*(\d+)/);
  if(sum){ run=+sum[1];fail=+sum[2];errc=+sum[3];pass=+sum[4];ign=+sum[5]; }
  let codeM=testout.match(/OHOS_REPORT_CODE:\s*(-?\d+)/);
  const repCode=codeM?codeM[1]:'N/A';
  const overall=(fail+errc)===0?'✅ 全部通过':'❌ 存在失败/错误';
  const now=new Date(); const pad=n=>String(n).padStart(2,'0');
  const stamp=`${now.getFullYear()}-${pad(now.getMonth()+1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  let sb=[];
  const L=(x)=>sb.push(x);
  L('# 单元测试执行结果'); L('');
  L(`> 自动生成于 ${stamp} ，由 execute-ui-unit-test.sh 执行 UT 后导出。`); L('');
  L('## 执行信息'); L('');
  L('| 项目 | 值 |'); L('|---|---|');
  L(`| 应用包名 bundleName | ${bundle} |`);
  L(`| 测试套件 suite | ${suite} |`);
  L(`| 测试目标 target | ${target} |`);
  L(`| 设备 device | ${device} |`);
  L(`| 构建 product / mode | ${product} / ${mode} |`);
  L(`| 用例超时 timeout(ms) | ${timeout} |`);
  L(`| 执行时间 | ${stamp} |`);
  L(`| OHOS_REPORT_CODE | ${repCode} (0 = 全部通过) |`); L('');
  L('## 汇总结果'); L('');
  L('| 总数 | 通过 | 失败 | 错误 | 忽略 | 总体 |'); L('|---|---|---|---|---|---|');
  L(`| ${run} | ${pass} | ${fail} | ${errc} | ${ign} | ${overall} |`); L('');
  L('## 用例明细'); L('');
  L('| # | 测试类 | 测试用例 | 结果 | 耗时(ms) |'); L('|---|---|---|---|---|');
  let idx=0; for(const t of tests){ idx++; L(`| ${idx} | ${t.Class} | ${t.Test} | ${t.Result} | ${t.Consuming} |`); }
  L('');
  const failed=tests.filter(t=>t.Code!==0);
  if(failed.length>0){
    L('## 失败详情'); L('');
    for(const f of failed){
      L(`### ${f.Class}.${f.Test}`); L('');
      L(`- **结果**: ${f.Result}`);
      L(`- **消息**: ${f.Stream}`);
      if(f.Stack){ L('- **堆栈**:'); L('```'); L(f.Stack.trim()); L('```'); }
      L('');
    }
  }
  L('## 原始输出'); L('');
  L('<details><summary>展开查看完整 aa test 输出</summary>'); L('');
  L('```'); L(testout.trim()); L('```'); L(''); L('</details>'); L('');
  fs.writeFileSync(out, sb.join('\n'), 'utf8');
}
else { process.stderr.write('unknown tool command: '+cmd+'\n'); process.exit(2); }
}catch(e){ process.stderr.write('tool error: '+e.message+'\n'); process.exit(2); }
NODE
# field extraction helper: json5file | ... ; here we use: node "$TOOL" read <file> <accessor>
jread(){ node "$TOOL" read "$1" "$2"; }

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

# find entry module
ENTRY_SRC=""; MODULE_NAME=""; ABILITY_NAME=""
while IFS= read -r src; do
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
# prefer signed, non-test
while IFS= read -r -d '' f; do
  parent="$(basename "$(dirname "$f")")"
  case "$parent" in *[Tt]est*) continue;; esac
  case "$(basename "$f")" in *-signed.hap) HAP="$f"; break;; esac
done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
if [ -z "$HAP" ]; then
  newest=""
  while IFS= read -r -d '' f; do
    parent="$(basename "$(dirname "$f")")"
    case "$parent" in *[Tt]est*) continue;; esac
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
  done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
  HAP="$newest"
fi
[ -n "$HAP" ] || die "No HAP found under: $BUILD_DIR"
echo "  HAP = $HAP"

# ---------------- 6. device selection ----------------
get_targets(){
  TARGETS=()
  local line
  while IFS= read -r line; do
    # rtrim
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    [ "$line" = "[Empty]" ] && continue
    TARGETS+=("$line")
  done < <(hdc list targets 2>/dev/null)
}
get_targets
while [ "${#TARGETS[@]}" -eq 0 ]; do
  if [ ! -t 0 ]; then
    warn "未检测到设备/模拟器（模拟器可能未启动）。"
    warn "请先在 DevEco Studio 启动模拟器，或用 USB 连接真机并开启调试，然后重跑脚本。"
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
      # 2a. discover emulator executable
      EMU_DEFAULT=""
      if [ -n "${DEVECO_SDK_HOME:-}" ]; then
        for cand in \
          "$DEVECO_SDK_HOME/tools/emulator/Emulator" \
          "$DEVECO_SDK_HOME/../tools/emulator/Emulator" \
          "$DEVECO_SDK_HOME/../tools/emulator/Emulator.app/Contents/MacOS/Emulator" \
          "$DEVECO_SDK_HOME/tools/emulator/emulator" ; do
          if [ -f "$cand" ]; then EMU_DEFAULT="$cand"; break; fi
        done
      fi
      if [ -n "$EMU_DEFAULT" ]; then
        read -r -e -p "请输入模拟器可执行文件路径（回车使用默认：$EMU_DEFAULT）: " emu_path </dev/tty
        [ -z "$emu_path" ] && emu_path="$EMU_DEFAULT"
      else
        read -r -e -p "请输入模拟器可执行文件路径: " emu_path </dev/tty
      fi
      if [ -z "$emu_path" ] || [ ! -f "$emu_path" ]; then
        warn "路径不存在或不是可执行文件（请输入完整的 Emulator 文件路径，而非目录）。"
        continue
      fi
      chmod +x "$emu_path" 2>/dev/null
      # 2b. list instances
      step "查询可用模拟器实例（Emulator -list）"
      if ! list_out="$("$emu_path" -list 2>&1)"; then
        warn "执行 -list 失败：$list_out"
        continue
      fi
      if [ -z "$list_out" ]; then warn "未查询到模拟器实例，请确认 Emulator 路径是否正确。"; continue; fi
      echo "$list_out"
      # 2c. device name
      read -r -e -p "请输入要启动的设备名称（上列表中的某一项）: " emu_name </dev/tty
      if [ -z "$emu_name" ]; then warn "设备名称为空，请重新选择。"; continue; fi
      # 2d. launch async
      step "启动模拟器：$emu_path -start $emu_name"
      nohup "$emu_path" -start "$emu_name" >/dev/null 2>&1 &
      # 2e. poll hdc (up to 180s)
      step "等待模拟器启动并连接 hdc（最多 180 秒，每 5 秒检测一次）"
      deadline=$(( $(date +%s) + 180 ))
      get_targets
      while [ $(date +%s) -lt $deadline ] && [ "${#TARGETS[@]}" -eq 0 ]; do
        sleep 5
        get_targets
        if [ "${#TARGETS[@]}" -gt 0 ]; then
          ok "模拟器已就绪：${TARGETS[*]}"
        else
          printf "  ${c_gray}仍在等待（剩余 %s 秒）...${c_reset}\n" "$(( deadline - $(date +%s) ))"
        fi
      done
      if [ "${#TARGETS[@]}" -eq 0 ]; then warn "模拟器在 180 秒内未连接到 hdc，请检查设备名或模拟器状态。"; fi
      ;;
    *)  # [1] or empty: re-detect
      get_targets
      ;;
  esac
done

if [ -n "$DEVICE" ]; then
  found=0
  for t in "${TARGETS[@]}"; do [ "$t" = "$DEVICE" ] && found=1; done
  [ "$found" -eq 1 ] || die "Device not connected: $DEVICE (available: ${TARGETS[*]})"
else
  if [ "${#TARGETS[@]}" -gt 1 ]; then die "Multiple devices (${TARGETS[*]}), specify with --device"; fi
  DEVICE="${TARGETS[0]}"
fi
echo "  device = $DEVICE"
hdc_dev=(-t "$DEVICE")

# ---------------- 7. uninstall previous (default) ----------------
if [ "$NO_UNINSTALL" -eq 0 ]; then
  step "Uninstall previous version"
  hdc "${hdc_dev[@]}" shell bm uninstall -n "$BUNDLE_NAME" 2>/dev/null
  echo "  (ignored if not installed)"
fi

# ---------------- 8. push & install app HAP ----------------
step "Push and install HAP"
tmp="data/local/tmp/hap_$RANDOM"
hdc "${hdc_dev[@]}" shell mkdir "$tmp"
hdc "${hdc_dev[@]}" file send "$HAP" "$tmp"
hdc "${hdc_dev[@]}" shell bm install -p "$tmp"
rc=$?
hdc "${hdc_dev[@]}" shell rm -rf "$tmp"
[ $rc -eq 0 ] || die "Install failed"

# ---------------- 9. launch (optional) ----------------
if [ "$LAUNCH" -eq 1 ]; then
  step "Launch app"
  hdc "${hdc_dev[@]}" shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME" -m "$MODULE_NAME"
fi

# ---------------- 10. unit tests (default) ----------------
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
  TEST_HAP=""; newest_t=""
  while IFS= read -r -d '' f; do
    parent="$(basename "$(dirname "$f")")"
    if [ "$parent" = "$TEST_TARGET" ]; then
      if [ -z "$newest_t" ] || [ "$f" -nt "$newest_t" ]; then newest_t="$f"; fi
    fi
  done < <(find "$BUILD_DIR" -name '*.hap' -print0 2>/dev/null)
  TEST_HAP="$newest_t"
  [ -n "$TEST_HAP" ] || die "Test HAP not found under $BUILD_DIR (target=$TEST_TARGET)"
  echo "  testHAP = $TEST_HAP"

  step "Push and install test HAP"
  ttmp="data/local/tmp/hap_$RANDOM"
  hdc "${hdc_dev[@]}" shell mkdir "$ttmp"
  hdc "${hdc_dev[@]}" file send "$TEST_HAP" "$ttmp"
  hdc "${hdc_dev[@]}" shell bm install -p "$ttmp"
  rc=$?
  hdc "${hdc_dev[@]}" shell rm -rf "$ttmp"
  [ $rc -eq 0 ] || die "Test HAP install failed"

  step "Run unit tests (aa test, timeout=${TEST_TIMEOUT} ms)"
  test_out="$(hdc "${hdc_dev[@]}" shell aa test -b "$BUNDLE_NAME" -m "$SUIT_NAME" -s unittest OpenHarmonyTestRunner -s timeout "$TEST_TIMEOUT" 2>&1)"

  # console summary
  summary="$(printf '%s\n' "$test_out" | grep 'Tests run:' | tail -1)"
  repcode="$(printf '%s\n' "$test_out" | grep 'OHOS_REPORT_CODE:' | tail -1 | sed -E 's/.*OHOS_REPORT_CODE:[[:space:]]*//')"
  if [ -n "$summary" ]; then
    pcnt(){ printf '%s\n' "$summary" | sed -nE "s/.*$1:[[:space:]]*([0-9]+).*/\1/p"; }
    run="$(pcnt 'Tests run')"; fail="$(pcnt 'Failure')"; errc="$(pcnt 'Error')"; pass="$(pcnt 'Pass')"; ign="$(pcnt 'Ignore')"
    if [ "$(( ${fail:-0} + ${errc:-0} ))" -eq 0 ]; then
      ok "Result: run=${run} pass=${pass} failure=${fail} error=${errc} ignore=${ign}"
    else
      warn "Result: run=${run} pass=${pass} failure=${fail} error=${errc} ignore=${ign}"
    fi
  else
    warn "(summary line not found)"
  fi
  [ -n "$repcode" ] && echo "  OHOS_REPORT_CODE = $repcode (0 = all passed)"
  printf '%s\n' "$test_out" | grep -E 'Error in |actualValue is' | while IFS= read -r fl; do warn "$fl"; done

  # export markdown report
  step "Exporting report"
  _TESTOUT_FILE="$(mktemp 2>/dev/null || echo /tmp/_testout_$$.txt)"
  printf '%s' "$test_out" > "$_TESTOUT_FILE"
  ts="$(date +%Y%m%d_%H%M%S)"
  report_name="执行结果_${ts}.md"
  report_path="$ROOT/$report_name"
  node "$TOOL" mkreport "$report_path" "$_TESTOUT_FILE" "$BUNDLE_NAME" "$SUIT_NAME" "$TEST_TARGET" "$DEVICE" "$PRODUCT" "$BUILD_MODE" "$TEST_TIMEOUT" \
    || die "Report generation failed"
  ok "report: $report_path"
fi

# ---------------- 11. cleanup artifacts (default) ----------------
if [ "$KEEP_ARTIFACTS" -eq 0 ]; then
  step "Cleaning up artifacts"
  hdc "${hdc_dev[@]}" shell bm uninstall -n "$BUNDLE_NAME" 2>/dev/null
  warn "device: uninstalled $BUNDLE_NAME"
  nbuild=0; nohm=0; nlock=0
  while IFS= read -r -d '' d; do
    case "$d" in *oh_modules*) continue;; esac
    rm -rf "$d" && nbuild=$((nbuild+1))
  done < <(find "$ROOT" -type d -name build -print0 2>/dev/null)
  while IFS= read -r -d '' d; do
    case "$(dirname "$d")" in *oh_modules*) continue;; esac
    rm -rf "$d" && nohm=$((nohm+1))
  done < <(find "$ROOT" -type d -name oh_modules -print0 2>/dev/null)
  while IFS= read -r -d '' f; do
    case "$f" in *oh_modules*) continue;; esac
    rm -f "$f" && nlock=$((nlock+1))
  done < <(find "$ROOT" -type f -name oh-package-lock.json5 -print0 2>/dev/null)
  echo "  removed: build=$nbuild  oh_modules=$nohm  oh-package-lock=$nlock"
fi

printf "\n${c_green}==> Done!${c_reset}\n"
