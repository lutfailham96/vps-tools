#!/bin/bash

lock_file="/tmp/umdropbear.lock"

if [[ -f "${lock_file}" ]]; then
  echo "Unable to lock (${lock_file}), is another process using it?"
  exit 1
fi

touch "${lock_file}"

kill_users=""
max_multi_login=1
kill_multi_login=false

while getopts ":k:l:z" o; do
  case "${o}" in
    k)
      kill_users=${OPTARG}
      ;;
    z)
      kill_multi_login=true
      ;;
    l)
      max_multi_login=${OPTARG}
      ;;
    #*)
    #  usage
    #  ;;
  esac
done

dropbear_pids=$(grep 'Password auth succeeded' /var/log/messages | sed "s/'//g;s/\[//g;s/]//g" | awk '{print $6","$14","$16}')
#dropbear_pids=$(journalctl -u dropbear.service | grep 'Password auth succeeded' | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
dropbear_active_users=""
dropbear_pcs=$(pidof dropbear)

telegram_bot_token=""
telegram_group_id=""

while IFS= read -r dropbear_pid; do
  pid=$(echo "${dropbear_pid}" | awk -F ',' '{print $1}')
  user=$(echo "${dropbear_pid}" | awk -F ',' '{print $2}')
  ip=$(echo "${dropbear_pid}" | awk -F ',' '{print $3}')
  ps=$(echo "${dropbear_pcs}" | grep "${pid}" | grep -v grep)
  if [[ ! -z "${ps}" ]]; then
    dropbear_active_users+="${user}"$'\t\t'"${pid}"$'\t'"${ip}"$'\n'
  fi
done <<< "${dropbear_pids}"

telegram_send_notification() {
  bot_token="${1}"
  group_id="${2}"
  message_text="${3}"
  json_body=$(cat <<EOF
{
  "chat_id": "${group_id}",
  "text": "${message_text}"
}
EOF
)
  curl -sl -X POST \
    -H 'Content-Type: application/json' \
    -d "${json_body}" \
    "https://api.telegram.org/bot${telegram_bot_token}/sendMessage"
}

dropbear_kill_user() {
  user="${1}"
  login_limit="${2}"
  echo "Disconnecting Dropbear user: ${user} ..."
  user_pid=$(echo "${dropbear_active_users}" | grep "${user}	" | awk '{print $2}')
  if [[ ! -z ${login_limit} && ${login_limit} > 0 ]]; then
    reserved_pids=$(echo "${user_pid}" | tail -n ${login_limit})
    while IFS= read -r reserved_pid; do
      user_pid=$(echo "${user_pid}" | sed "/${reserved_pid}/d")
    done <<< "${reserved_pids}"
  fi
  for pid in ${user_pid[@]}; do
    kill ${pid} 2> /dev/null &
    dropbear_active_users=$(echo "${dropbear_active_users}" | sed "/	${pid}/d")
  done
}

if [[ ! -z "${kill_users}" ]]; then
  while IFS=',' read -ra users; do
    for user in "${users[@]}"; do
      dropbear_kill_user "${user}"
    done
  done <<< "${kill_users}"
fi

if "${kill_multi_login}"; then
  echo "Removing multiple login ..."
  logins=$(echo "${dropbear_active_users}")
  login_users=$(echo "${logins}" | awk '{print $1}' | uniq -c)
  multiple_detected_count=0
  multiple_detected_users=""
  while IFS= read -r login; do
    login_user=$(echo "${login}" | awk '{print $2}')
    login_count=$(echo "${login}" | awk '{print $1}')
    if [[ ${login_count} > ${max_multi_login} ]]; then
      echo "Multiple login detected from user: ${login_user}"
      dropbear_kill_user "${login_user}" "${max_multi_login}"
      multiple_detected_count=$((${multiple_detected_count}+1))
      multiple_detected_users+="${multiple_detected_count}. ${login_user}	\[${login_count} login\]"
    fi
  done <<< "${login_users}"
  if [[ ! -z "${telegram_bot_token}" && ! -z "${telegram_group_id}" && ! -z "${multiple_detected_users}" ]]; then
    echo "Report multiple login user notification to Telegram ..."
    machine_name=$(hostname)
    telegram_send_notification "${telegram_bot_token}" "${telegram_group_id}" "Multiple login user \[${machine_name}\]:\n${multiple_detected_users}" 2>&1 > /dev/null &
  else
    echo "Cannot send to Telegram, please check Telegram setting"
  fi
fi

dropbear_active_users=$(echo "${dropbear_active_users}" | sed '/^[[:space:]]*$/d' | sort)
cat <<EOF
########################################
#               Dropbear               #
########################################
Username	PID	IP
----------------------------------------
${dropbear_active_users}
----------------------------------------
Active user:	$(echo "${dropbear_active_users}" | wc -l)
EOF

rm -f "${lock_file}"

