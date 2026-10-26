"""scan_test.py - connect to the RAC database through SCAN from outside the cluster, 6 times,
and show which instance each connection lands on. Needs: pip install oracledb (thin mode, no
Oracle client). The password is asked once and never stored.

  python scan_test.py                                   # 127.0.0.1:30200/ORCLPDBSVC
  python scan_test.py 127.0.0.1:30200/ORCLPDBSVC 10     # other address / number of connections
"""
import getpass
import sys

import oracledb

dsn = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:30200/ORCLPDBSVC"
count = int(sys.argv[2]) if len(sys.argv) > 2 else 6
pw = getpass.getpass("SYSTEM password: ")
sql = ("select sys_context('USERENV','INSTANCE_NAME'), sys_context('USERENV','SERVER_HOST'),"
       " sys_context('USERENV','CON_NAME') from dual")
failed = 0
for i in range(1, count + 1):
    try:
        with oracledb.connect(user="system", password=pw, dsn=dsn, tcp_connect_timeout=10) as conn:
            inst, host, con = conn.cursor().execute(sql).fetchone()
            print(f"connection {i}: {inst} on {host} in {con}")
    except oracledb.Error as e:
        failed += 1
        print(f"connection {i}: FAILED {e}")
sys.exit(1 if failed else 0)
