FROM public.ecr.aws/lambda/microvms:al2023-minimal

RUN dnf install -y --setopt=install_weak_deps=0 bash unzip tar gzip git bubblewrap socat shadow-utils && \
    (command -v curl >/dev/null 2>&1 || dnf install -y curl) && \
    dnf install -y --setopt=install_weak_deps=0 nodejs24 nodejs24-npm && \
    node --version && \
    dnf clean all

RUN npm install -g @anthropic-ai/claude-code

RUN useradd -m -d /home/agent agent && \
    mkdir -p /workspace /home/agent/.claude /mnt/session/outputs && \
    chown agent:agent /workspace /home/agent/.claude /mnt/session/outputs

COPY --chown=agent:agent settings.json /home/agent/.claude/settings.json
COPY package.json /opt/worker/package.json
RUN cd /opt/worker && npm install --omit=dev && npm cache clean --force
COPY worker.mjs index.html /opt/worker/

ENV CLAUDE_CODE_USE_BEDROCK=1
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV AWS_REGION=us-east-2
ENV GH_TOKEN_SECRET=cloud-agent/github-token
ENV SESSION_OUTPUTS=/mnt/session/outputs

WORKDIR /workspace

VOLUME /mnt/session/outputs

EXPOSE 8080

ENTRYPOINT ["node", "/opt/worker/worker.mjs"]
