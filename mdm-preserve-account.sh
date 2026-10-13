#!/bin/bash
# 保留现有账户；运行时指定原 Data 卷 UUID 与账户短名称。
# 默认 check；apply / restore 仅允许在可识别的 macOS Recovery 中执行。
# 不承诺 macOS 27 绕过有效；不解除 Apple 服务端的组织归属。
set -Eeuo pipefail
umask 077

EXPECTED_UUID=${MDM_DATA_UUID:-}
EXPECTED_USER=${MDM_ACCOUNT:-}
ACTION=${1:-check}
BACKUP_ARG=${2:-}
DATA=''
BACKUP=''
BACKUP_READY=0
LOG=''
REL=(
  'private/etc/hosts'
  'private/var/db/ConfigurationProfiles/Settings/.cloudConfigHasActivationRecord'
  'private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound'
  'private/var/db/ConfigurationProfiles/Settings/.cloudConfigProfileInstalled'
  'private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound'
)
DOMAINS=(deviceenrollment.apple.com mdmenrollment.apple.com iprofiles.apple.com)

say() { printf '%s\n' "$*"; }
die() { say "停止：$*" >&2; exit 1; }
usage() {
  say '用法：bash mdm-preserve-account.sh [check|apply|restore 备份目录]'
  say 'check：只读。apply / restore：恢复环境内操作，逐次确认。'
}
log() {
  say "$*"
  if [[ -n "$LOG" ]]; then printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; fi
}
plist_value() { plutil -extract "$1" raw -o - -; }

locate_data() {
  local info uuid
  [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || die '此版本仅适用于 Apple Silicon Mac。'
  info=$(diskutil info -plist "$EXPECTED_UUID") || die '找不到原 Data 卷；不要改用猜测的卷名。'
  uuid=$(printf '%s\n' "$info" | plist_value VolumeUUID) || die '无法读取卷 UUID。'
  [[ "$uuid" == "$EXPECTED_UUID" ]] || die 'Data 卷 UUID 不匹配。'
  DATA=$(printf '%s\n' "$info" | plist_value MountPoint) || die 'Data 卷未挂载，请先在磁盘工具中解锁并挂载。'
  [[ -n "$DATA" && "$DATA" != / && -d "$DATA" ]] || die 'Data 卷挂载点无效。'
  [[ -f "$DATA/private/etc/hosts" ]] || die '目标卷缺少 hosts。'
  [[ -d "$DATA/private/var/db/ConfigurationProfiles/Settings" ]] || die '目标系统的注册标记目录不存在，需重新评估版本适配。'
  [[ -d "$DATA/Users/$EXPECTED_USER" ]] || die '未找到现有用户主目录。'
  # 仅确认账户记录存在，不读取其中的口令数据，也不调用任何账户写入命令。
  [[ -f "$DATA/private/var/db/dslocal/nodes/Default/users/$EXPECTED_USER.plist" ]] || {
    if [[ "$ACTION" != check ]]; then die '未找到现有账户记录；不能继续。'; fi
    say '普通登录环境可能无权确认账户记录；apply 时会在恢复环境重新检查。'
  }
  local r
  for r in "${REL[@]}"; do
    [[ ! -e "$DATA/$r" || -f "$DATA/$r" ]] || die "预期为普通文件：$r"
  done
}

require_recovery() {
  local bootname
  [[ $(id -u) == 0 ]] || die 'apply / restore 须在恢复环境的终端中执行；不要在当前系统加 sudo 强行运行。'
  bootname=$(diskutil info -plist / | plist_value VolumeName) || die '无法确认启动环境。'
  case "$bootname" in
    'macOS Base System'|'OS X Base System') ;;
    *) die "启动卷为 ${bootname}，未识别为 macOS Recovery。" ;;
  esac
  [[ -d /System/Installation/CDIS ]] || die '缺少 Recovery 安装工具目录，停止写入。'
  [[ "$DATA" == /Volumes/* ]] || die '目标必须是恢复环境中挂载在 /Volumes 下的 Data 卷。'
  [[ -w "$DATA/private/etc" && -w "$DATA/private/var/db/ConfigurationProfiles/Settings" ]] || die '目标卷不可写，请先在磁盘工具确认已解锁并挂载。'
}

domain_ok() {
  awk -v domain="$1" '
    { sub(/#.*/, ""); for (i=2; i<=NF; i++) if (tolower($i)==domain) {
        count++; if ($1!="0.0.0.0") bad=1
      }
    }
    END { exit !(count==1 && !bad) }
  ' "$DATA/private/etc/hosts"
}

report() {
  say "目标 Data 卷：$DATA"
  say "保留账户：${EXPECTED_USER}（不修改账户记录、密码、权限或主目录）"
  local d i
  for d in "${DOMAINS[@]}"; do
    if domain_ok "$d"; then say "${d}：已有单条屏蔽记录"; else say "${d}：未规范屏蔽"; fi
  done
  for ((i=1; i<${#REL[@]}; i++)); do
    if [[ -e "$DATA/${REL[$i]}" ]]; then say "存在：${REL[$i]##*/}"; else say "不存在：${REL[$i]##*/}"; fi
  done
  say '以上仅为本地文件状态，不代表组织已释放设备，也不代表 macOS 27 绕过成功。'
}

confirm() {
  local answer
  say "将对 $DATA 执行 ${ACTION}，仅涉及 hosts 和四个注册标记。"
  say '不改账户、不抹盘、不关闭 SIP、不改 launchd、不重启。'
  say '卷内备份只能撤销本次文件改动，不能代替升级前的完整外置备份。'
  [[ -t 0 ]] || die '请在交互式终端执行，禁止管道自动确认。'
  read -r -p "确认请输入 $1，其他输入取消：" answer
  [[ "$answer" == "$1" ]] || die '已取消，没有修改目标文件。'
}

create_backup() {
  local root i
  root="$DATA/private/var/db/douglax-mdm-backups"
  mkdir -p "$root"
  BACKUP=$(mktemp -d "$root/$(date '+%Y%m%d-%H%M%S').XXXXXX")
  LOG="$BACKUP/operations.log"
  printf '%s\n' "$EXPECTED_UUID" > "$BACKUP/volume_uuid"
  for ((i=0; i<${#REL[@]}; i++)); do
    if [[ -e "$DATA/${REL[$i]}" ]]; then
      cp -p "$DATA/${REL[$i]}" "$BACKUP/$i.original"
      cmp -s "$DATA/${REL[$i]}" "$BACKUP/$i.original"
      printf 'present\n' > "$BACKUP/$i.state"
    else
      printf 'absent\n' > "$BACKUP/$i.state"
    fi
  done
  touch "$BACKUP/READY"
  BACKUP_READY=1
  log "备份完成：$BACKUP"
}

validate_backup() {
  local i state
  [[ -f "$BACKUP/READY" && -f "$BACKUP/volume_uuid" ]] || return 1
  [[ $(cat "$BACKUP/volume_uuid") == "$EXPECTED_UUID" ]] || return 1
  for ((i=0; i<${#REL[@]}; i++)); do
    [[ -f "$BACKUP/$i.state" ]] || return 1
    state=$(cat "$BACKUP/$i.state") || return 1
    case "$state" in
      present) [[ -f "$BACKUP/$i.original" ]] || return 1 ;;
      absent) ;;
      *) return 1 ;;
    esac
  done
}

restore_files() {
  local i state
  validate_backup || { say '备份不完整或不属于本机，未开始回滚。' >&2; return 1; }
  for ((i=0; i<${#REL[@]}; i++)); do
    state=$(cat "$BACKUP/$i.state") || return 1
    if [[ "$state" == present ]]; then
      cp -p "$BACKUP/$i.original" "$DATA/${REL[$i]}" || { say "恢复失败：${REL[$i]}" >&2; return 1; }
      cmp -s "$BACKUP/$i.original" "$DATA/${REL[$i]}" || return 1
    else
      rm -f "$DATA/${REL[$i]}" || { say "恢复原先不存在的状态失败：${REL[$i]}" >&2; return 1; }
      [[ ! -e "$DATA/${REL[$i]}" ]] || return 1
    fi
  done
}

on_error() {
  local code=$1 line=$2
  trap - ERR
  set +e
  say "失败：第 $line 行，退出码 ${code}；不会报告修改成功。" >&2
  if [[ "$BACKUP_READY" == 1 ]]; then
    if restore_files; then
      log '已回滚 hosts 和四个标记到本次修改前。'
    else
      log "自动回滚未完成，请保留备份并排查：$BACKUP"
    fi
  fi
  exit "$code"
}
trap 'on_error "$?" "$LINENO"' ERR

apply_files() {
  local tmp d
  create_backup
  tmp=$(mktemp "$DATA/private/etc/.douglax-mdm-hosts.XXXXXX")
  cp -p "$DATA/private/etc/hosts" "$tmp"
  # 仅剔除目标域名的旧映射；同一行的其他别名、其他记录和注释保留。
  awk '
    BEGIN { target["deviceenrollment.apple.com"]=1; target["mdmenrollment.apple.com"]=1; target["iprofiles.apple.com"]=1 }
    {
      original=$0; body=$0; comment=""; p=index(body,"#")
      if (p) { comment=substr(body,p); body=substr(body,1,p-1) }
      n=split(body,a,/[ \t]+/); first=1
      while (first<=n && a[first]=="") first++
      changed=0; kept=0; out=a[first]
      for (i=first+1; i<=n; i++) {
        if (a[i]=="") continue
        if (tolower(a[i]) in target) { changed=1; continue }
        out=out "\t" a[i]; kept++
      }
      if (!changed) { print original; next }
      if (kept) { if (comment!="") out=out " " comment; print out }
      else if (comment!="") print comment
    }
    END {
      print "0.0.0.0 deviceenrollment.apple.com"
      print "0.0.0.0 mdmenrollment.apple.com"
      print "0.0.0.0 iprofiles.apple.com"
    }
  ' "$DATA/private/etc/hosts" > "$tmp"
  mv -f "$tmp" "$DATA/private/etc/hosts"
  rm -f "$DATA/${REL[1]}" "$DATA/${REL[2]}"
  # 已存在的标记保持原样；不存在时以普通 root:wheel 文件创建。
  local i
  for i in 3 4; do
    if [[ ! -e "$DATA/${REL[$i]}" ]]; then
      touch "$DATA/${REL[$i]}"
      chmod 644 "$DATA/${REL[$i]}"
      chown root:wheel "$DATA/${REL[$i]}"
    fi
  done
  for d in "${DOMAINS[@]}"; do domain_ok "$d"; done
  [[ ! -e "$DATA/${REL[1]}" && ! -e "$DATA/${REL[2]}" ]]
  [[ -f "$DATA/${REL[3]}" && -f "$DATA/${REL[4]}" ]]
  log '指定的本地文件修改及检查完成；账户未修改。'
  log '尚未验证重新启动后的注册行为；不能据此宣称已绕过 macOS 27。'
  log "回滚方式：在恢复环境运行本脚本 restore \"$BACKUP\""
}

case "$ACTION" in
  -h|--help|help) usage; exit 0 ;;
  check|apply) [[ $# -le 1 ]] || die '参数过多。' ;;
  restore) [[ $# -eq 2 && -n "$BACKUP_ARG" ]] || die 'restore 需要一个完整备份目录路径。' ;;
  *) usage; die '未知操作。' ;;
esac
# 参数只包含非凭据的卷 UUID 与现有账户短名称；不会读取账户口令。
if [[ -z "$EXPECTED_UUID" ]]; then
  [[ -t 0 ]] || die '请设置 MDM_DATA_UUID，或在交互式终端输入原 Data 卷 UUID。'
  read -r -p '原 Data 卷 UUID：' EXPECTED_UUID
fi
if [[ -z "$EXPECTED_USER" ]]; then
  [[ -t 0 ]] || die '请设置 MDM_ACCOUNT，或在交互式终端输入现有账户短名称。'
  read -r -p '现有账户短名称：' EXPECTED_USER
fi
[[ -n "$EXPECTED_UUID" && -n "$EXPECTED_USER" ]] || die '卷 UUID 与账户短名称不能为空。'
locate_data
if [[ "$ACTION" == check ]]; then report; exit 0; fi
require_recovery
report
if [[ "$ACTION" == apply ]]; then
  confirm APPLY
  apply_files
else
  BACKUP=$BACKUP_ARG
  validate_backup || die '备份不完整或 Data 卷 UUID 不匹配。'
  confirm RESTORE
  LOG="$BACKUP/operations.log"
  if restore_files; then log '已恢复该备份中的 hosts 和四个标记；账户未修改。'; else die "恢复未完成，请保留备份：$BACKUP"; fi
fi
