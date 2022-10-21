#!/bin/bash

lock_file="/tmp/umopenssh.lock"

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

openssh_generate_active_users() {
  #openssh_pids="${openssh_pids}"
  #openssh_active_users="${openssh_active_users}"
  #openssh_pid="${openssh_pid}"
  #openssh_pcs="${openssh_pcs}"

  os_id=$(grep '^ID=' /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
  os_version=$(grep '^VERSION_ID=' /etc/os-release | awk -F '=' '{print $2}' | sed 's/"//g')
  case "${os_id}" in
    "debian" | "ubuntu")
      log_file="/var/log/auth.log"
      log_filter="Accepted keyboard-interactive/pam"
      log_sub_cmd='sed "s/sshd//g;s/://g;s/'\''//g;s/\[//g;s/]//g" | awk '\''{print $5","$9","$11":"$13}'\'''
      ;;
    "almalinux" | "centos" | "fedora")
      log_file="/var/log/secure"
      log_filter="Accepted password for"
      log_sub_cmd='sed "s/sshd//g;s/://g;s/'\''//g;s/\[//g;s/]//g" | awk '\''{print $5","$9","$11":"$13}'\'''
      ;;
  esac
  while IFS= read -r openssh_pid; do
    filter_cmd="grep \"${log_filter}\" \"${log_file}\" | grep \"\[${openssh_pid}\]\" | ${log_sub_cmd}"
    openssh_pid=$(eval "${filter_cmd}")
    pid=$(echo "${openssh_pid}" | awk -F ',' '{print $1}')
    user=$(echo "${openssh_pid}" | awk -F ',' '{print $2}')
    ip=$(echo "${openssh_pid}" | awk -F ',' '{print $3}')
    ps=$(echo "${openssh_pcs}" | grep "${pid}" | grep -v grep)
    if [[ ! -z "${ps}" ]]; then
      openssh_active_users+="${user}"$'\t\t'"${pid}"$'\t'"${ip}"$'\n'
    fi
  done <<< "${openssh_pids}"
  openssh_active_users=$(echo "${openssh_active_users}" | sed '/^[[:space:]]*$/d')
}

openssh_kill_user_sessions() {
  #user="${user}"
  #login_limit=${login_limit}
  #openssh_active_users="${openssh_active_users}"

  user_pid=$(echo "${openssh_active_users}" | grep "${user}	" | awk '{print $2}')

  # This will makes latest connections still remains based on login_limit count
  if [[ ! -z ${login_limit} && ${login_limit} > 0 ]]; then
    reserved_pids=$(echo "${user_pid}" | tail -n ${login_limit})
    while IFS= read -r reserved_pid; do
      user_pid=$(echo "${user_pid}" | sed "/${reserved_pid}/d")
    done <<< "${reserved_pids}"
  fi

  # Kill active OpenSSH user's session
  echo "Disconnecting OpenSSH user: ${user} ..."
  for pid in ${user_pid[@]}; do
    kill ${pid} 2> /dev/null &
    openssh_active_users=$(echo "${openssh_active_users}" | sed "/	${pid}/d")
  done
}

openssh_kill_active_users() {
  #kill_users="${kill_users}"

  # Triggered when command arg '-k' is specified
  if [[ ! -z "${kill_users}" ]]; then
    while IFS=',' read -ra users; do
      for user in "${users[@]}"; do
        user="${user}"
        openssh_kill_user_sessions
      done
    done <<< "${kill_users}"
  fi
}

openssh_kill_multiple_logins() {
  #kill_multi_login="${kill_multi_login}"
  #openssh_active_users="${openssh_active_users}"
  #telegram_bot_token="${telegram_bot_token}"
  #telegram_group_id="${telegram_group_id}"

  # Triggered when command arg '-z' is specified
  if ${kill_multi_login}; then
    echo "Removing multiple login ..."
    logins=$(echo "${openssh_active_users}")
    login_users=$(echo "${logins}" | awk '{print $1}' | uniq -c)
    multiple_detected_count=0
    multiple_detected_users=""
    while IFS= read -r login; do
      login_user=$(echo "${login}" | awk '{print $2}')
      login_count=$(echo "${login}" | awk '{print $1}')
      if [[ ${login_count} > ${max_multi_login} ]]; then
        echo "Multiple OpenSSH login detected from user: ${login_user}"

        user="${login_user}"
        login_limit="${max_multi_login}"
        openssh_kill_user_sessions

        multiple_detected_count=$((${multiple_detected_count}+1))
        multiple_detected_users+="${multiple_detected_count}. ${login_user}	\[${login_count} login\]"
      fi
    done <<< "${login_users}"

    # Report multiple login to Telegram group
    if [[ ! -z "${telegram_bot_token}" && ! -z "${telegram_group_id}" && ! -z "${multiple_detected_users}" ]]; then
      echo "Report multiple OpenSSH login user notification to Telegram ..."
      machine_name=$(hostname)
      bot_token="${telegram_bot_token}"
      group_id="${telegram_group_id}"
      message_text="Multiple OpenSSH login user \[${machine_name}\]:\n${multiple_detected_users}"
      telegram_send_notification 2>&1 > /dev/null &
    elif [[ -z "${multiple_detected_users}" ]]; then
      echo "No multiple OpenSSH login found"
    else
      echo "Cannot send to Telegram, please check Telegram setting"
    fi
  fi
}

openssh_print_active_users() {
  #openssh_active_users="${openssh_active_users}"

  openssh_active_users=$(echo "${openssh_active_users}" | sort)
  cat <<EOF
########################################
#                OpenSSH               #
########################################
Username	PID	IP
----------------------------------------
${openssh_active_users}
----------------------------------------
Active user:	$(echo "${openssh_active_users}" | wc -l)
EOF
}

openssh_main() {
  kill_users=""
  max_multi_login=1
  kill_multi_login=false
  parse_args "${@}"

  openssh_pids=$(pidof sshd | sed 's/ /\n/g' | sort | sed '1d')
  #openssh_pids=$(journalctl -u sshd.service | grep 'Accepted password for' | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
  openssh_active_users=""
  openssh_pcs=$(pidof sshd)
  openssh_generate_active_users

  openssh_kill_active_users

  # Telegram bot settings
  telegram_bot_token=""
  telegram_group_id=""
  openssh_kill_multiple_logins

  openssh_print_active_users
}

openssh_main "${@}"

rm -f "${lock_file}"

