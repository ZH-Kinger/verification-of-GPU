#!/bin/bash
# 长稳看护：每 10 分钟进容器看一次。任一节点出现以下情况立即输出一行并退出（触发提醒）：
#   任务不再 Running / gpu_burn 报 errors 非 0 / NCCL 有失败轮次 / GPU 利用率掉到 90% 以下
# 两台都正常跑完时也退出。
# 注意：循环体从 ids 文件读行，里面的 ssh/jobctl 必须断开 stdin（ssh -n、</dev/null），
# 否则第一条 ssh 会把剩余行读走，只有第一台被检查。
# 用法: SOAK_IDS=<文件，每行 "标签 JobId"> LOGD_a=<日志目录名> LOGD_b=... SSH_USER_FMT='%s.<用户>+root.<项目>.pod' bash watch.sh
cd "$(dirname "$0")/../../jobctl" && set -a && . ~/.yicloud/env && set +a
: "${SOAK_IDS:?}" "${SSH_USER_FMT:?}"
SSH="ssh -n -o BatchMode=yes -i $HOME/.ssh/id_ed25519 -o IdentitiesOnly=yes -p 2202"
while true; do
  done_n=0
  while read tag j; do
    ph=$(./jobctl get "$j" </dev/null 2>/dev/null | grep -oE 'phase=[A-Za-z]+')
    if [ "$ph" != "phase=Running" ]; then
      echo "[$(date -u +%FT%TZ)] soak-$tag $j $ph"; done_n=$((done_n+1)); continue
    fi
    R=$(./jobctl replicas "$j" </dev/null | awk '{print $1}' | head -1)
    ld=LOGD_$tag
    st=$(timeout 60 $SSH "$(printf "$SSH_USER_FMT" "$R")@ssh.gate.${YC_DOMAIN:-yicloud.com.cn}" "S=/mnt/acceptance/GPU_Offline_Acceptance/logs/${!ld}/soak"'
      b=$(tail -c 3000 $S/gpu_burn.txt | tr "\r" "\n" | grep -E "errors:" | tail -1)
      e=$(echo "$b" | grep -oE "errors: [0-9 -]+" | grep -oE "[0-9]+" | awk "{s+=\$1} END{print s+0}")
      u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | sort -n | head -1)
      echo "$(echo "$b" | grep -oE "^ *[0-9.]+%" | tr -d " ") err=${e:-?} nccl=$(cat $S/nccl_ok_iterations.txt)/$(cat $S/nccl_iterations.txt) minutil=$u"' 2>/dev/null)
    [ -z "$st" ] && continue   # SSH 偶发失败，下一轮再看
    err=$(echo "$st" | grep -oE 'err=[0-9?]+' | cut -d= -f2)
    ok=$(echo "$st" | grep -oE 'nccl=[0-9]+/[0-9]+' | cut -d= -f2)
    mu=$(echo "$st" | grep -oE 'minutil=[0-9]+' | cut -d= -f2)
    if { [ -n "$err" ] && [ "$err" != "0" ] && [ "$err" != "?" ]; } || [ "${ok%/*}" != "${ok#*/}" ] || [ "${mu:-100}" -lt 90 ]; then
      echo "[$(date -u +%FT%TZ)] soak-$tag 异常: $st"; exit 1
    fi
  done < "$SOAK_IDS"
  [ "$done_n" -ge 2 ] && { echo "[$(date -u +%FT%TZ)] 两台长稳均已结束"; exit 0; }
  [ "$done_n" -eq 1 ] && { echo "[$(date -u +%FT%TZ)] 有一台提前结束"; exit 1; }
  sleep 600
done
