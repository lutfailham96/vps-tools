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

dropbear_pids=$(grep 'Password auth succeeded' /var/log/messages | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
#dropbear_pids=$(journalctl -u dropbear.service | grep 'Password auth succeeded' | awk '{print $6","$14}' | sed "s/'//g;s/\[//g;s/]//g")
dropbear_active_users=""
dropbear_pcs=$(pidof dropbear)

while IFS= read -r dropbear_pid; do
  pid=$(echo "${dropbear_pid}" | awk -F ',' '{print $1}')
  user=$(echo "${dropbear_pid}" | awk -F ',' '{print $2}')
  ps=$(echo "${dropbear_pcs}" | grep "${pid}" | grep -v grep)
  if [[ ! -z "${ps}" ]]; then
    dropbear_active_users+="${user}"$'\t\t'"${pid}"$'\n'
  fi
done <<< "${dropbear_pids}"

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
  for login in "${login_users[@]}"; do
    login_user=$(echo "${login}" | awk '{print $2}')
    login_count=$(echo "${login}" | awk '{print $1}')
    #login_user=$(echo "${logins}" |  | awk '{print $2}')
    if [[ ${login_count} > ${max_multi_login} ]]; then
      echo "Multiple login detected from user: ${login_user}"
      dropbear_kill_user "${login_user}" "${max_multi_login}"
    fi
  done
fi

dropbear_active_users=$(echo "${dropbear_active_users}" | sed '/^[[:space:]]*$/d' | sort)
cat <<EOF
########################################
#               Dropbear               #
########################################
Username	PID
----------------------------------------
${dropbear_active_users}
----------------------------------------
Active user:	$(echo "${dropbear_active_users}" | wc -l)
EOF

