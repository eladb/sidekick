# Debian (not Ubuntu) deliberately: Debian's `chromium` apt package is a
# real build, whereas Ubuntu's `chromium-browser` is a snap wrapper that
# doesn't work in a container (no snapd). Bare-VM installs via provision.sh
# should target Debian 12 for the same reason.
FROM debian:bookworm-slim

COPY provision.sh Caddyfile.tmpl supervisord.sidekick.conf.tmpl configure-and-start.sh /opt/sidekick-src/
COPY scripts/tunnel-watcher.sh /opt/sidekick-src/scripts/tunnel-watcher.sh
COPY services/execd/execd.py /opt/sidekick-src/services/execd/execd.py

RUN chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh \
  && /opt/sidekick-src/provision.sh

ENV SIDEKICK_INIT=container
EXPOSE 80

ENTRYPOINT ["/usr/local/bin/sidekick-configure-and-start"]
