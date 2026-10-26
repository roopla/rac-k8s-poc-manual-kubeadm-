#!/bin/bash
# scan-test.sh - runs in the dbclient pod: asks for the SYSTEM password once, then opens N separate
# connections through SCAN and shows which instance each lands on. The password goes to SQL*Plus on
# stdin, never on a command line or in a file.   bash /root/scan-test.sh [count]
read -rsp "SYSTEM password: " PW; echo
for i in $(seq 1 "${1:-6}"); do
  sqlplus -s /nolog <<EOF | grep -v -e '^$' -e '^Connected'
set head off feed off
connect system/"$PW"@//racnode-scan.rac.svc.cluster.local:1521/ORCLPDBSVC
select 'connection $i: '||sys_context('USERENV','INSTANCE_NAME')||' on '||sys_context('USERENV','SERVER_HOST')||' in '||sys_context('USERENV','CON_NAME') from dual;
exit
EOF
done
