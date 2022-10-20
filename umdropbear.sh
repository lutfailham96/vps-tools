#!/bin/bash

lock_file="/tmp/umdropbear.lock"

if [[ -f "${lock_file}" ]]; then
  echo "Unable to lock (${lock_file}), is another process using it?"
  exit 1
fi

touch "${lock_file}"

parse_args() {
  #kill_users="${kill_users}"
  #max_multi_login=${max_multi_login}
  #kill_multi_login=${kill_multi_login}

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
}

telegram_send_notification() {
  #bot_token="${bot_token}"
  #group_id="${group_id}"
  #message_text="${message_text}"

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

dropbear_generate_active_users() {
  #dropbear_pids="${dropbear_pids}"
  #dropbear_active_users="${dropbear_active_users}"
  #dropbear_pid="${dropbear_pid}"
  #dropbear_pcs="${dropbear_pcs}"

  while IFS= read -r dropbear_pid; do
    pid=$(echo "${dropbear_pid}" | awk -F ',' '{print $1}')
    user=$(echo "${dropbear_pid}" | awk -F ',' '{print $2}')
    ip=$(echo "${dropbear_pid}" | awk -F ',' '{print $3}')
    ps=$(echo "${dropbear_pcs}" | grep "${pid}" | grep -v grep)
    if [[ ! -z "${ps}" ]]; then
      dropbear_active_users+="${user}"$'\t\t'"${pid}"$'\t'"${ip}"$'\n'
    fi
  done <<< "${dropbear_pids}"
}

dropbear_kill_user_sessions() {
  #user="${user}"
  #login_limit=${login_limit}
  #dropbear_active_users="${dropbear_active_users}"

  user_pid=$(echo "${dropbear_active_users}" | grep "${user}	" | awk '{print $2}')

  # This will makes latest connections still remains based on login_limit count
  if [[ ! -z ${login_limit} && ${login_limit} > 0 ]]; then
    reserved_pids=$(echo "${user_pid}" | tail -n ${login_limit})
    while IFS= read -r reserved_pid; do
      user_pid=$(echo "${user_pid}" | sed "/${reserved_pid}/d")
    done <<< "${reserved_pids}"
  fi

  # Kill active Dropbear user's session
  echo "Disconnecting Dropbear user: ${user} ..."
  for pid in ${user_pid[@]}; do
    kill ${pid} 2> /dev/null &
    dropbear_active_users=$(echo "${dropbear_active_users}" | sed "/	${pid}/d")
  done
}

dropbear_kill_active_users() {
  #kill_users="${kill_users}"

  # Triggered when command arg '-k' is specified
  if [[ ! -z "${kill_users}" ]]; then
    while IFS=',' read -ra users; do
      for user in "${users[@]}"; do
        user="${user}"
        dropbear_kill_user_sessions
      done
    done <<< "${kill_users}"
  fi
}

dropbear_kill_multiple_logins() {
  #kill_multi_login="${kill_multi_login}"
  #dropbear_active_users="${dropbear_active_users}"
  #telegram_bot_token="${telegram_bot_token}"
  #telegram_group_id="${telegram_group_id}"

  # Triggered when command arg '-z' is specified
  if ${kill_multi_login}; then
    echo "Removing multiple login ..."
    logins=$(echo "${dropbear_active_users}")
    login_users=$(echo "${logins}" | awk '{print $1}' | uniq -c)
    multiple_detected_count=0
    multiple_detected_users=""
    while IFS= read -r login; do
      login_user=$(echo "${login}" | awk '{print $2}')
      login_count=$(echo "${login}" | awk '{print $1}')
      if [[ ${login_count} > ${max_multi_login} ]]; then
        echo "Multiple Dropbear login detected from user: ${login_user}"

        user="${login_user}"
        login_limit="${max_multi_login}"
        dropbear_kill_user_sessions

        multiple_detected_count=$((${multiple_detected_count}+1))
        multiple_detected_users+="${multiple_detected_count}. ${login_user}	\[${login_count} login\]"
      fi
    done <<< "${login_users}"

    # Report multiple login to Telegram group
    if [[ ! -z "${telegram_bot_token}" && ! -z "${telegram_group_id}" && ! -z "${multiple_detected_users}" ]]; then
      echo "Report multiple Dropbear login user notification to Telegram ..."
      machine_name=$(hostname)
      bot_token="${telegram_bot_token}"
      group_id="${telegram_group_id}"
      message_text="Multiple Dropbear login user \[${machine_name}\]:\n${multiple_detected_users}"
      telegram_send_notification 2>&1 > /dev/null &
    else
      echo "Cannot send to Telegram, please check Telegram setting"
    fi
  fi
}

dropbear_print_active_users() {
  #dropbear_active_users="${dropbear_active_users}"

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
}

dropbear_main() {
  kill_users=""
  max_multi_login=1
  kill_multi_login=false
  parse_args "${@}"

  dropbear_pids=$(grep 'Password auth succeeded' /var/log/messages | sed "s/'//g;s/\[//g;s/]//g" | awk '{print $6","$14","$16}')
  #dropbear_pids=$(journalctl -u dropbear.service | grep 'Password auth succeeded' | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
  dropbear_active_users=""
  dropbear_pcs=$(pidof dropbear)
  dropbear_generate_active_users

  dropbear_kill_active_users

  # Telegram bot settings
  telegram_bot_token=""
  telegram_group_id=""
  dropbear_kill_multiple_logins

  dropbear_print_active_users
}

dropbear_main "${@}"

rm -f "${lock_file}"

