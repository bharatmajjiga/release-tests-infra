ARG GO_TOOLSET_VERSION=1.26
FROM registry.access.redhat.com/ubi9/go-toolset:${GO_TOOLSET_VERSION}

USER root

RUN dnf -y install \
    git gpgme make openssl python3 python3-pip \
    skopeo unzip vim wget \
    && dnf clean all && rm -rf /var/cache/dnf

ARG PYYAML_VERSION=6.0.3
ARG REPORTPORTAL_CLIENT_VERSION=5.7.10
RUN pip3 install --no-cache-dir \
    pyyaml==${PYYAML_VERSION} \
    reportportal-client==${REPORTPORTAL_CLIENT_VERSION}

RUN wget https://certs.corp.redhat.com/certs/Current-IT-Root-CAs.pem \
    -O /etc/pki/ca-trust/source/anchors/Current-IT-Root-CAs.pem && \
    update-ca-trust extract

# Architecture-aware binary downloads (TARGETARCH set by buildx/podman --platform)
ARG TARGETARCH

ARG YQ_VERSION=v4.53.6
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
    -o /usr/bin/yq && chmod +x /usr/bin/yq

ARG COSIGN_VERSION=v3.1.3
RUN curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
    -o /usr/bin/cosign && chmod +x /usr/bin/cosign

# rekor-cli
ARG REKOR_VERSION=v1.5.4
RUN curl -fsSL "https://github.com/sigstore/rekor/releases/download/${REKOR_VERSION}/rekor-cli-linux-${TARGETARCH}" \
    -o /usr/bin/rekor-cli && chmod +x /usr/bin/rekor-cli

ARG JQ_VERSION=1.8.2
RUN JQ_ARCH="${TARGETARCH}" && \
    [ "$JQ_ARCH" = "ppc64le" ] && JQ_ARCH="ppc64el" || true && \
    curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-${JQ_ARCH}" \
    -o /usr/bin/jq && chmod +x /usr/bin/jq

ARG GOLANGCI_LINT_VERSION=v2.13.1
RUN curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-${TARGETARCH}.tar.gz" \
    | tar xz -C /usr/bin --strip-components=1 "golangci-lint-${GOLANGCI_LINT_VERSION#v}-linux-${TARGETARCH}/golangci-lint"

ARG GAUGE_VERSION=v1.6.36
RUN go install github.com/getgauge/gauge@${GAUGE_VERSION} && \
    mv "$(go env GOPATH)/bin/gauge" /usr/local/bin/gauge

ARG GINKGO_VERSION=v2.32.1
RUN go install github.com/onsi/ginkgo/v2/ginkgo@${GINKGO_VERSION} && \
    mv "$(go env GOPATH)/bin/ginkgo" /usr/local/bin/ginkgo

ARG MC_VERSION=RELEASE.2025-08-13T08-35-41Z
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.${MC_VERSION}" \
    -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc

ARG ROSA_VERSION=v1.2.64
RUN git clone --depth 1 --branch "${ROSA_VERSION}" https://github.com/openshift/rosa.git /tmp/rosa && \
    cd /tmp/rosa && go build -o /usr/local/bin/rosa ./cmd/rosa && \
    rm -rf /tmp/rosa

# Azure CLI (only for amd64/arm64 — no prebuilt wheels for ppc64le/s390x)
ARG AZURE_CLI_VERSION=2.89.1
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
      pip3 install --no-cache-dir azure-cli==${AZURE_CLI_VERSION}; \
    fi

RUN ln -fs /usr/bin/python3 /usr/bin/python

USER 1001
