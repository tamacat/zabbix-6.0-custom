Zabbix agent 2 @ZABBIX_VERSION@ for Windows (64-bit) -- custom build @BUILD_DATE@
==============================================================================

A standalone zabbix_agent2.exe built from the Zabbix @ZABBIX_VERSION@ source by the
tamacat/zabbix-6.0-custom project (https://github.com/tamacat/zabbix-6.0-custom).
Zabbix 6.0 no longer receives upstream updates; this build is re-built and re-scanned
by that project. The same agent also ships as the tamacat/zabbix-agent2 container image.

Contents
--------
  bin\zabbix_agent2.exe              the agent (statically linked, no extra DLLs needed)
  conf\zabbix_agent2.win.conf        default configuration
  conf\zabbix_agent2.d\plugins.d\    per-plugin configuration, included by the file above
  COPYING                            license of the agent (GNU GPL)
  THIRD-PARTY-NOTICES.txt, licenses\ licenses of the libraries linked into the exe

Quick start
-----------
Edit conf\zabbix_agent2.win.conf (at least Server=, ServerActive= and Hostname=), then
in an elevated (administrator) prompt, using ABSOLUTE paths:

  C:\zabbix\bin\zabbix_agent2.exe -c C:\zabbix\conf\zabbix_agent2.win.conf --install
  C:\zabbix\bin\zabbix_agent2.exe -c C:\zabbix\conf\zabbix_agent2.win.conf --start

Test a single item without installing the service:

  bin\zabbix_agent2.exe -c conf\zabbix_agent2.win.conf -t agent.ping

Build information
-----------------
  Zabbix version : @ZABBIX_VERSION@
  Build date     : @BUILD_DATE@
  Source revision: @SOURCE_REVISION@
  Statically linked: OpenSSL @OPENSSL_VERSION@, PCRE2 @PCRE2_VERSION@, GNU libiconv @LIBICONV_VERSION@

This executable is not code-signed, so Windows SmartScreen may warn when it is first
run. Verify the download against the SHA256SUMS file (and its cosign signature) published
with the release before installing.
