Zabbix agent 2 @ZABBIX_VERSION@ for Linux (x86_64) -- custom build @BUILD_DATE@
===============================================================================

A standalone zabbix_agent2 built from the Zabbix @ZABBIX_VERSION@ source by the
tamacat/zabbix-6.0-custom project (https://github.com/tamacat/zabbix-6.0-custom).
Zabbix 6.0 no longer receives upstream updates; this build is re-built and re-scanned
by that project. The same agent also ships as the tamacat/zabbix-agent2 container image.

The binary is fully statically linked (musl libc), so it runs on any x86_64 Linux
distribution without installing shared libraries. Limitation of a static binary: user
and group names are resolved from /etc/passwd and /etc/group, because musl libc does not
load NSS modules such as LDAP or SSSD.

Contents
--------
  sbin/zabbix_agent2                 the agent
  conf/zabbix_agent2.conf            default configuration
  conf/zabbix_agent2.d/plugins.d/    per-plugin configuration, included by the file above
  COPYING                            license of the agent (GNU GPL)
  THIRD-PARTY-NOTICES.txt, licenses/ licenses of the libraries linked into the binary

Quick start
-----------
Edit conf/zabbix_agent2.conf (at least Server=, ServerActive= and Hostname=; the default
ControlSocket= is /tmp/agent.sock, and PidFile= / LogFile= default to /tmp as well, so
point them at paths the agent user can write if you do not want that), then run it as an
unprivileged user:

  sbin/zabbix_agent2 -c conf/zabbix_agent2.conf

Test a single item without starting the agent:

  sbin/zabbix_agent2 -c conf/zabbix_agent2.conf -t agent.ping

This archive does not include a systemd unit or a distribution package; write a unit for
your layout that runs the command above as a non-root user.

Build information
-----------------
  Zabbix version : @ZABBIX_VERSION@
  Build date     : @BUILD_DATE@
  Source revision: @SOURCE_REVISION@

Verify the download against the SHA256SUMS file (and its cosign signature) published
with the release before installing.
