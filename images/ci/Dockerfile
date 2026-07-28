FROM registry.access.redhat.com/ubi9/go-toolset:latest

USER root

# System packages
RUN dnf -y install \
    git gpgme make openssl python3 python3-pip \
    skopeo unzip vim wget \
    && dnf clean all && rm -rf /var/cache/dnf

# Python packages
RUN pip3 install --no-cache-dir pyyaml reportportal-client

RUN wget https://certs.corp.redhat.com/certs/Current-IT-Root-CAs.pem \
    -O /etc/pki/ca-trust/source/anchors/Current-IT-Root-CAs.pem && \
    update-ca-trust extract

# Architecture-aware binary downloads (TARGETARCH set by buildx/podman --platform)
ARG TARGETARCH

# yq
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
    -o /usr/bin/yq && chmod +x /usr/bin/yq

# cosign (latest from sigstore)
RUN COSIGN_TAG=$(curl -sk https://api.github.com/repos/sigstore/cosign/releases/latest | \
    sed -n 's/.*"tag_name".*"\(v[^"]*\)".*/\1/p') && \
    curl -fsSL "https://github.com/sigstore/cosign/releases/download/${COSIGN_TAG}/cosign-linux-${TARGETARCH}" \
    -o /usr/bin/cosign && chmod +x /usr/bin/cosign

# rekor-cli (latest from sigstore)
RUN REKOR_TAG=$(curl -sk https://api.github.com/repos/sigstore/rekor/releases/latest | \
    sed -n 's/.*"tag_name".*"\(v[^"]*\)".*/\1/p') && \
    curl -fsSL "https://github.com/sigstore/rekor/releases/download/${REKOR_TAG}/rekor-cli-linux-${TARGETARCH}" \
    -o /usr/bin/rekor-cli && chmod +x /usr/bin/rekor-cli

# jq (latest)
RUN JQ_ARCH="${TARGETARCH}" && \
    [ "$JQ_ARCH" = "ppc64le" ] && JQ_ARCH="ppc64el" || true && \
    curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-linux-${JQ_ARCH}" \
    -o /usr/bin/jq && chmod +x /usr/bin/jq

# golangci-lint (latest)
RUN LINT_TAG=$(curl -sk https://api.github.com/repos/golangci/golangci-lint/releases/latest | \
    sed -n 's/.*"tag_name".*"\(v[^"]*\)".*/\1/p') && \
    curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/${LINT_TAG}/golangci-lint-${LINT_TAG#v}-linux-${TARGETARCH}.tar.gz" \
    | tar xz -C /usr/bin --strip-components=1 "golangci-lint-${LINT_TAG#v}-linux-${TARGETARCH}/golangci-lint"

# Gauge (latest)
RUN go install github.com/getgauge/gauge@latest && \
    mv "$(go env GOPATH)/bin/gauge" /usr/local/bin/gauge

# Ginkgo (latest)
RUN go install github.com/onsi/ginkgo/v2/ginkgo@latest && \
    mv "$(go env GOPATH)/bin/ginkgo" /usr/local/bin/ginkgo

# MinIO mc client (latest stable)
RUN curl -fsSL "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/mc" \
    -o /usr/local/bin/mc && chmod +x /usr/local/bin/mc

# ROSA CLI (latest)
RUN git clone --depth 1 https://github.com/openshift/rosa.git /tmp/rosa && \
    cd /tmp/rosa && go build -o /usr/local/bin/rosa ./cmd/rosa && \
    rm -rf /tmp/rosa

# Google Cloud CLI (only amd64/arm64 — not available for ppc64le/s390x)
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
      GCLOUD_ARCH="x86_64" && \
      [ "$TARGETARCH" = "arm64" ] && GCLOUD_ARCH="arm" ; \
      curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-${GCLOUD_ARCH}.tar.gz" \
        | tar xz -C /opt && \
      /opt/google-cloud-sdk/install.sh --quiet --usage-reporting=false --path-update=false && \
      ln -s /opt/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud && \
      ln -s /opt/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil ; \
    fi

# Azure CLI (only for amd64/arm64 — no prebuilt wheels for ppc64le/s390x)
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
      pip3 install --no-cache-dir azure-cli; \
    fi

# Alias python
RUN ln -fs /usr/bin/python3 /usr/bin/python

# Drop back to non-root (UID 1001 from ubi9/go-toolset base)
USER 1001
