FROM archlinux:base-20260111.0.480139

RUN pacman -Syu --noconfirm \
    cloc \
    cocogitto \
    curl \
    git \
    jq \
    make \
    neovim \
    nodejs \
    npm \
    python-pip \
    sudo \
    which

RUN pip install --break-system-packages zuban

RUN npm install --global \
    bash-language-server \
    language-server-bitbake \
    pyright

COPY plenary-patches /plenary-patches

RUN mkdir -p /usr/local/share/nvim/site/pack/plenary/start && \
    cd /usr/local/share/nvim/site/pack/plenary/start && \
    git clone --depth 1 https://github.com/nvim-lua/plenary.nvim.git && \
    git -C plenary.nvim apply /plenary-patches/*.patch
