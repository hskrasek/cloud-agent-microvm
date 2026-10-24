FROM public.ecr.aws/lambda/microvms:al2023-minimal

RUN dnf install -y --setopt=install_weak_deps=0 bash unzip tar gzip && \
    (command -v curl >/dev/null 2>&1 || dnf install -y curl) && \
    dnf install -y nodejs npm && \
    node --version && \
    dnf clean all

RUN npm install -g @anthropic-ai/claude-code

ENV CLAUDE_CODE_USE_BEDROCK=1
ENV CLAUDE_CODE_USE_MANTLE=1

WORKDIR /workspace
