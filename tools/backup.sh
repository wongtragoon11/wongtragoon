#!/usr/bin/env bash
# สำรองฐานข้อมูล Realtime Database ของเกมทั้งก้อน แล้วเข้ารหัส (ใช้ใน GitHub Actions เท่านั้น)
# ต้องมี FIREBASE_DB_SECRET (รหัสลับฐานข้อมูล) และ BACKUP_PASSWORD (รหัสผ่านเปิดไฟล์สำรอง) ใน GitHub Secrets
set -euo pipefail
DB_URL="${DB_URL:-https://wongtragoon-6123-default-rtdb.firebaseio.com}"
OUT="${OUT:-out}"
SKIP=" presence boom voice vmsg devdiag "   # ข้อมูลชั่วคราว (ตำแหน่งสด เสียงดังไกล เสียงคุย ข้อความเสียง รายงานเครื่อง) ไม่ต้องสำรอง
if [ -z "${FIREBASE_DB_SECRET:-}" ]; then echo "::error::ยังไม่ได้ตั้ง FIREBASE_DB_SECRET ใน GitHub Secrets"; exit 1; fi
if [ -z "${BACKUP_PASSWORD:-}" ] || [ "${#BACKUP_PASSWORD}" -lt 8 ]; then echo "::error::ยังไม่ได้ตั้ง BACKUP_PASSWORD ใน GitHub Secrets หรือสั้นกว่า 8 ตัว"; exit 1; fi
echo "::add-mask::${FIREBASE_DB_SECRET}"; echo "::add-mask::${BACKUP_PASSWORD}"
STAMP="$(TZ=Asia/Bangkok date +%Y-%m-%d_%H%M)"
WORK="$(mktemp -d)"; DIR="$WORK/backup-$STAMP"; mkdir -p "$DIR" "$OUT"
get() { curl -sS -f --retry 3 --retry-delay 5 --max-time 600 -o "$2" "$DB_URL/$1.json?auth=${FIREBASE_DB_SECRET}&$3"; }
if ! get "" "$WORK/keys.json" "shallow=true"; then echo "::error::อ่านรายชื่อข้อมูลจากฐานข้อมูลไม่ได้ รหัสลับอาจผิด"; exit 1; fi
KEYS="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(" ".join(sorted(d.keys())) if isinstance(d,dict) else "")' "$WORK/keys.json")"
if [ -z "$KEYS" ]; then echo "::error::ฐานข้อมูลว่างหรืออ่านไม่ได้"; exit 1; fi
ok=0; fail=0; skipped=""; failed=""
# ส่วนที่ใหญ่เกินกว่า Firebase จะส่งในครั้งเดียว (เช่น svbak เซฟสำรองรายชั่วโมงของทุกคน) ดึงทีละลูกแทน เก็บในโฟลเดอร์ชื่อส่วนนั้น
split() { local k="$1" sub; mkdir -p "$DIR/$k"
  if ! get "$k" "$WORK/sub.json" "shallow=true"; then return 1; fi
  sub="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(" ".join(sorted(d.keys())) if isinstance(d,dict) else "")' "$WORK/sub.json")"
  local bad=0; for c in $sub; do if ! get "$k/$c" "$DIR/$k/$c.json" "format=export"; then bad=$((bad+1)); rm -f "$DIR/$k/$c.json"; echo "::warning::ดึง $k/$c ไม่ได้"; fi; done
  [ "$bad" -eq 0 ]; }
for k in $KEYS; do
  case "$SKIP" in *" $k "*) skipped="$skipped $k"; continue;; esac
  if get "$k" "$DIR/$k.json" "format=export" 2>/dev/null; then ok=$((ok+1)); continue; fi
  rm -f "$DIR/$k.json"; echo "ส่วน $k ใหญ่เกินหรือดึงครั้งเดียวไม่ได้ ดึงทีละลูกแทน"
  if split "$k"; then ok=$((ok+1)); else fail=$((fail+1)); failed="$failed $k"; fi
done
python3 - "$DIR" "$STAMP" "$ok" "$fail" "$failed" "$skipped" <<'PY'
import json,os,sys
d,stamp,ok,fail,failed,skipped=sys.argv[1:7]
files={}
for f in sorted(os.listdir(d)):
    q=os.path.join(d,f)
    if f.endswith('.json'): files[f[:-5]]=os.path.getsize(q)
    elif os.path.isdir(q): files[f+'/']=sum(os.path.getsize(os.path.join(q,x)) for x in os.listdir(q))
saves=0
try:
    s=json.load(open(os.path.join(d,'saves.json')));saves=len(s) if isinstance(s,dict) else 0
except Exception: pass
json.dump({'time':stamp,'ok':int(ok),'fail':int(fail),'failed':failed.split(),'skipped':skipped.split(),'saves':saves,'bytes':files},open(os.path.join(d,'manifest.json'),'w'),ensure_ascii=False,indent=1)
PY
tar -C "$WORK" -czf "$WORK/backup-$STAMP.tar.gz" "backup-$STAMP"
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_PASSWORD -in "$WORK/backup-$STAMP.tar.gz" -out "$OUT/backup-$STAMP.tar.gz.enc"
# ตรวจว่าเปิดไฟล์ที่เข้ารหัสกลับได้จริง ก่อนเก็บ
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BACKUP_PASSWORD -in "$OUT/backup-$STAMP.tar.gz.enc" | tar -tzf - >/dev/null
SAVES="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["saves"])' "$DIR/manifest.json")"
SIZE="$(du -h "$OUT/backup-$STAMP.tar.gz.enc" | cut -f1)"
{ echo "## สำรองข้อมูล $STAMP"; echo "- สำรองสำเร็จ $ok ส่วน ล้มเหลว $fail ส่วน${failed:+ (}${failed# }${failed:+)}"; echo "- เซฟผู้เล่น $SAVES บัญชี"; echo "- ขนาดไฟล์เข้ารหัส $SIZE"; echo "- ข้ามข้อมูลชั่วคราว:${skipped}"; } >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "name=backup-$STAMP" >> "${GITHUB_OUTPUT:-/dev/null}"
rm -rf "$WORK"
if [ "$fail" -gt 0 ]; then echo "::error::สำรองไม่ครบ $fail ส่วน:$failed"; exit 1; fi
if [ "$SAVES" -lt 1 ]; then echo "::error::ไม่พบเซฟผู้เล่นในไฟล์สำรอง"; exit 1; fi
