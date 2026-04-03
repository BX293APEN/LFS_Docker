# =============================================================================
# Dockerfile  ―  LFS rootfs ビルド環境
# Ubuntu 24.04 LTS ベース
# =============================================================================

FROM ubuntu:24.04

ARG WS
ARG ENTRY_DIR
ARG ENTRY_POINT
ARG LANG

ENV DEBIAN_FRONTEND=noninteractive

# LFS Book が要求するホストツールを一括インストール
# https://www.linuxfromscratch.org/lfs/view/stable/chapter02/hostreqs.html
RUN apt update && \
    apt upgrade -y && \
    apt install -y \
        bash \
        binutils \
        bison \
        bzip2 \
        coreutils \
        diffutils \
        findutils \
        gawk \
        gcc \
        g++ \
        gzip \
        m4 \
        make \
        patch \
        perl \
        python3 \
        sed \
        tar \
        texinfo \
        xz-utils \
        wget \
        curl \
        ca-certificates \
        autoconf \
        automake \
        libtool \
        pkg-config \
        gettext \
        flex \
        bc \
        libssl-dev \
        libelf-dev \
        libncurses-dev \
        file \
        git \
        rsync \
        unzip \
        language-pack-ja \
        locales && \
    # /bin/sh を bash にする (LFS 要件)
    ln -sf bash /bin/sh && \
    locale-gen ${LANG} && \
    update-locale LANG=${LANG} && \
    mkdir -p /${WS} /${ENTRY_DIR} && \
    chmod 777 /${WS} && \
    chmod 777 /${ENTRY_DIR}

COPY ${ENTRY_POINT} /${ENTRY_DIR}/${ENTRY_POINT}
RUN chmod +x /${ENTRY_DIR}/${ENTRY_POINT}

WORKDIR /${WS}
