FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV FORCE_UNSAFE_CONFIGURE=1

# 依存パッケージと 32bitアーキテクチャ(armhf)の追加
RUN apt-get update && apt-get install -y \
    build-essential clang flex bison g++ gawk gettext git \
    libncurses-dev libssl-dev python3-distutils python3-setuptools \
    python3-dev python-is-python3 rsync swig unzip zlib1g-dev \
    file wget sudo vim libslang2-dev systemtap-sdt-dev ca-certificates \
    && dpkg --add-architecture armhf \
    && apt-get update \
    && apt-get install -y libc6:armhf \
    && apt-get clean

# ホスト用 Go 1.24.6 のインストール
RUN wget https://go.dev/dl/go1.24.6.linux-arm64.tar.gz && \
    tar -C /usr/local -xzf go1.24.6.linux-arm64.tar.gz && \
    rm go1.24.6.linux-arm64.tar.gz

ENV PATH=$PATH:/usr/local/go/bin

# ユーザー作成とクローン
RUN useradd -m builduser && echo "builduser ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER builduser
WORKDIR /home/builduser

RUN git clone https://github.com/BPI-SINOVOIP/BPI-R4PRO-8X-OPENWRT-V24.10.0-Master-Devel.git bpi

WORKDIR /home/builduser/bpi

CMD ["/bin/bash"]