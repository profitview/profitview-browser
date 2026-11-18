# ProfitView browser edition: Chromium + web desktop (linuxserver) with the extension preloaded
# CHECK(docker): pin BASE_TAG to a tested linuxserver/chromium tag before publishing, verify CHROME_CLI handling + policy path [P2]
ARG BASE_TAG=latest
FROM lscr.io/linuxserver/chromium:${BASE_TAG}

COPY policies/profitview.json /etc/chromium/policies/managed/profitview.json
COPY ext/ /opt/profitview/ext/

# Chromium flags + profile preparation before every start (Debian's launcher sources /etc/chromium.d/*)
# CHECK(docker): prefs.py relies on linuxserver's /lsiopy python3, verify after base image updates [P3]
COPY chromium.d/profitview /etc/chromium.d/profitview
COPY prefs.py /opt/profitview/prefs.py

ENV TITLE="ProfitView"
# base image watchdog (svc-watchdog): restarts Chromium within ~1 s whenever it exits or crashes
ENV RESTART_APP=true

LABEL org.opencontainers.image.source="https://github.com/profitview/profitview-browser"
LABEL org.opencontainers.image.description="ProfitView browser edition: Chromium with the extension preloaded"
