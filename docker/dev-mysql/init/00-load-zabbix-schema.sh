#!/bin/sh
# Loads the existing, unmodified Zabbix 6.0.48 MySQL schema/data into the verification/dev database
# [FR4.1][FR4.2].
#
# This does NOT duplicate sources/zabbix-6.0.48/database/mysql/*.sql into docker/ — compose.yml
# bind-mounts that directory read-only into this dev-mysql container at /zabbix-schema-src, and this
# script (itself picked up by the official mysql image's /docker-entrypoint-initdb.d/ convention, which
# runs *.sh files it finds there) applies the files in the exact order Zabbix's own install docs
# require: schema.sql (DDL) must run before images.sql/data.sql (they INSERT into those tables).
# Alphabetical order would run data.sql before schema.sql and break the load, which is exactly why this
# script exists instead of relying on the init mechanism's default filename-sort behavior for the three
# files directly. (database/mysql/option-patches/double.sql is a genuinely optional migration for
# pre-existing installs predating the IEEE754 numeric-range change and is not applied here — a fresh
# 6.0.48 schema.sql already defines columns in the modern format.)
#
# MySQL 8.x's default binary logging requires either the SUPER privilege or
# log_bin_trust_function_creators=1 to create the stored functions/triggers schema.sql defines; this
# container sets the latter globally before loading (harmless for a throwaway dev database).

set -eu

SRC_DIR="/zabbix-schema-src"

echo "**** Allowing function/trigger creation without SUPER (binary logging is on by default in MySQL 8.x)..."
mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" -e "SET GLOBAL log_bin_trust_function_creators=1;"

echo "**** Loading Zabbix 6.0.48 MySQL schema into '${MYSQL_DATABASE}' (dev/verification database)..."

for f in schema.sql images.sql data.sql; do
	if [ ! -f "${SRC_DIR}/${f}" ]; then
		echo "**** ERROR: ${SRC_DIR}/${f} not found (expected the sources/zabbix-6.0.48/database/mysql/ bind mount)." >&2
		exit 1
	fi

	echo "**** Applying ${f}..."
	mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "${SRC_DIR}/${f}"
done

# data.sql's pre-seeded "Zabbix server" host's agent interface points at DNS name "zabbix-server" —
# correct for the traditional same-host server+agent deployment schema.sql/data.sql assume, but wrong
# for this project's split-container topology, where the agent actually runs in the separate
# zabbix-agent2 container. Without this, the server tries to poll itself for the agent check and the
# Web UI shows "Zabbix agent is not available" indefinitely (confirmed against a real fresh load).
# Real production MySQL needs this same one-time fix (or the operator's own equivalent) for whatever
# their actual agent host/interface topology is — this script only handles the dev/verification database.
echo "**** Pointing the built-in 'Zabbix server' host's agent interface at the zabbix-agent2 container..."
mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" <<'SQL'
UPDATE interface i JOIN hosts h ON h.hostid = i.hostid
SET i.dns = 'zabbix-agent2'
WHERE h.host = 'Zabbix server' AND i.type = 1;
SQL

echo "**** Zabbix schema load complete."
