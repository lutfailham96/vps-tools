#!/bin/bash

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

openssh_pids=$(grep 'Accepted password for' /var/log/secure | sed "s/sshd//g;s/://g;s/'//g;s/\[//g;s/]//g" | awk '{print $5","$9","$11":"$13}')
#openssh_pids=$(journalctl -u sshd.service | grep 'Accepted password for' | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
openssh_active_users=""
openssh_pcs=$(pidof sshd)

while IFS= read -r openssh_pid; do
  pid=$(echo "${openssh_pid}" | awk -F ',' '{print $1}')
  user=$(echo "${openssh_pid}" | awk -F ',' '{print $2}')
  ip=$(echo "${openssh_pid}" | awk -F ',' '{print $3}')
  ps=$(echo "${openssh_pcs}" | grep "${pid}" | grep -v grep)
  if [[ ! -z "${ps}" ]]; then
    openssh_active_users+="${user}"$'\t\t'"${pid}"$'\t'"${ip}"$'\n'
  fi
done <<< "${openssh_pids}"

openssh_kill_user() {
  user="${1}"
  login_limit="${2}"
  echo "Disconnecting openssh user: ${user} ..."
  user_pid=$(echo "${openssh_active_users}" | grep "${user}	" | awk '{print $2}')
  if [[ ! -z ${login_limit} && ${login_limit} > 0 ]]; then
    reserved_pids=$(echo "${user_pid}" | tail -n ${login_limit})
    while IFS= read -r reserved_pid; do
      user_pid=$(echo "${user_pid}" | sed "/${reserved_pid}/d")
    done <<< "${reserved_pids}"
  fi
  for pid in ${user_pid[@]}; do
    kill ${pid} 2> /dev/null &
    openssh_active_users=$(echo "${openssh_active_users}" | sed "/	${pid}/d")
  done
}

if [[ ! -z "${kill_users}" ]]; then
  while IFS=',' read -ra users; do
    for user in "${users[@]}"; do
      openssh_kill_user "${user}"
    done
  done <<< "${kill_users}"
fi

if "${kill_multi_login}"; then
  echo "Removing multiple login ..."
  logins=$(echo "${openssh_active_users}")
  login_users=$(echo "${logins}" | awk '{print $1}' | uniq -c)
  for login in "${login_users[@]}"; do
    login_user=$(echo "${login}" | awk '{print $2}')
    login_count=$(echo "${login}" | awk '{print $1}')
    #login_user=$(echo "${logins}" |  | awk '{print $2}')
    if [[ ${login_count} > ${max_multi_login} ]]; then
      echo "Multiple login detected from user: ${login_user}"
      openssh_kill_user "${login_user}" "${max_multi_login}"
    fi
  done
fi

openssh_active_users=$(echo "${openssh_active_users}" | sed '/^[[:space:]]*$/d' | sort)
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

