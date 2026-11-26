FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git python3 python3-venv ripgrep ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/swarm
COPY guest_pimono/package.json /opt/swarm/package.json
RUN npm install --omit=dev && ln -sf /opt/swarm/node_modules/.bin/pi /usr/local/bin/pi

COPY guest_pimono/guest-runnerd.mjs /opt/swarm/guest-runnerd.mjs
COPY guest_pimono/extensions/ /opt/swarm/extensions/
COPY meta_loop/harness_bundle_v1/ /opt/swarm/bundle/
RUN chmod -R a-w /opt/swarm/bundle && chmod -R a+rx /opt/swarm/bundle/scripts

RUN mkdir -p /workspace /run/ate/info
EXPOSE 80

CMD ["node", "/opt/swarm/guest-runnerd.mjs"]
