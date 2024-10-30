# syntax=docker/dockerfile:1

FROM ubuntu:20.04 AS base
LABEL Maintainer = "Jeremy Combs <jmcombs@me.com>"

# Passer en mode non interactif pour la construction du conteneur
ENV DEBIAN_FRONTEND=noninteractive

# Variables d'ARG Dockerfile définies automatiquement pour faciliter l'installation des logiciels
ARG TARGETARCH

# Configurer apt et installer les paquets
RUN apt-get update \
    && apt-get -y install software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get -y install --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gcc \
        locales \
        mkisofs \
        xorriso \
        p7zip-full \
        python3.7 \
        python3.7-dev \
        python3.7-distutils \
        sudo \
        whois \
        less \
        libc6 \
        libgcc1 \
        libgssapi-krb5-2 \
        libicu66 \
        libssl1.1 \
        libstdc++6 \
        zlib1g

# Configurer la locale en_US.UTF-8
## Paquet apt : locales
ENV LANGUAGE=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8
RUN localedef -c -i en_US -f UTF-8 en_US.UTF-8 \
    && locale-gen en_US.UTF-8 \
    && dpkg-reconfigure locales

# Définir l'utilisateur non-root
ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=$USER_UID

# Configurer l'utilisateur non-root et accorder des privilèges sudo
# Paquet apt : sudo
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID --shell /usr/bin/pwsh --create-home $USERNAME \
    && echo $USERNAME ALL=\(root\) NOPASSWD:ALL >> /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME
WORKDIR /home/$USERNAME

# Nettoyer
RUN apt-get autoremove -y \
    && apt-get clean -y \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

FROM base AS linux-amd64
ARG DOTNET_ARCH=x64
ARG PS_ARCH=x64

FROM base AS linux-arm64
ARG DOTNET_ARCH=arm64
ARG PS_ARCH=arm64

FROM base AS linux-arm
ARG DOTNET_ARCH=arm
ARG PS_ARCH=arm32

FROM linux-${TARGETARCH} AS msft-install

# .NET Core 3.1 Runtime pour VMware PowerCLI
# Paquets apt : libc6m, libgcc1, libgssapi-krb5-2, libicu66, libssl1.1, libstdc++6, unzip, wget, zlib1g
ARG DOTNET_VERSION=3.1.32
ARG DOTNET_PACKAGE=dotnet-runtime-${DOTNET_VERSION}-linux-${DOTNET_ARCH}.tar.gz
ARG DOTNET_PACKAGE_URL=https://dotnetcli.azureedge.net/dotnet/Runtime/${DOTNET_VERSION}/${DOTNET_PACKAGE}
ENV DOTNET_ROOT=/opt/microsoft/dotnet/${DOTNET_VERSION}
ENV PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools
ADD ${DOTNET_PACKAGE_URL} /tmp/${DOTNET_PACKAGE}
RUN mkdir -p ${DOTNET_ROOT} \
    && tar zxf /tmp/${DOTNET_PACKAGE} -C ${DOTNET_ROOT} \
    && rm /tmp/${DOTNET_PACKAGE}

# PowerShell Core 7.2 (LTS)
# Paquets apt : ca-certificates, less, libssl1.1, libicu66, wget, unzip
RUN PS_MAJOR_VERSION=$(curl -Ls -o /dev/null -w %{url_effective} https://aka.ms/powershell-release\?tag\=lts | cut -d 'v' -f 2 | cut -d '.' -f 1) \
    && PS_INSTALL_FOLDER=/opt/microsoft/powershell/${PS_MAJOR_VERSION} \
    && PS_PACKAGE=$(curl -Ls -o /dev/null -w %{url_effective} https://aka.ms/powershell-release\?tag\=lts | sed 's#https://github.com#https://api.github.com/repos#g; s#tag/#tags/#' | xargs curl -s | grep browser_download_url | grep linux-${PS_ARCH}.tar.gz | cut -d '"' -f 4 | xargs basename) \
    && PS_PACKAGE_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://aka.ms/powershell-release\?tag\=lts | sed 's#https://github.com#https://api.github.com/repos#g; s#tag/#tags/#' | xargs curl -s | grep browser_download_url | grep linux-${PS_ARCH}.tar.gz | cut -d '"' -f 4) \
    && curl -LO ${PS_PACKAGE_URL} \
    && mkdir -p ${PS_INSTALL_FOLDER} \
    && tar zxf ${PS_PACKAGE} -C ${PS_INSTALL_FOLDER} \
    && chmod a+x,o-w ${PS_INSTALL_FOLDER}/pwsh \
    && ln -s ${PS_INSTALL_FOLDER}/pwsh /usr/bin/pwsh \
    && rm ${PS_PACKAGE} \
    && echo /usr/bin/pwsh >> /etc/shells

FROM msft-install as vmware-install-arm64

ARG POWERCLIURL=https://vdc-download.vmware.com/vmwb-repository/dcr-public/02830330-d306-4111-9360-be16afb1d284/c7b98bc2-fcce-44f0-8700-efed2b6275aa/VMware-PowerCLI-13.0.0-20829139.zip

ADD ${POWERCLIURL} /tmp/vmware-powercli.zip

RUN apt-get update && \
    apt-get install -y unzip && \
    mkdir -p /usr/local/share/powershell/Modules && \
    unzip -l /tmp/vmware-powercli.zip && \
    unzip /tmp/vmware-powercli.zip -d /usr/local/share/powershell/Modules && \
    rm /tmp/vmware-powercli.zip
    
FROM msft-install as vmware-install-amd64

RUN pwsh -Command Install-Module -Name VMware.PowerCLI -Scope AllUsers -Repository PSGallery -Force -Verbose

FROM vmware-install-${TARGETARCH} as vmware-install-common

ARG VMWARECEIP=false

USER $USERNAME

ADD --chown=${USER_UID}:${USER_GID} https://bootstrap.pypa.io/pip/3.7/get-pip.py /tmp/
ENV PATH=${PATH}:/home/$USERNAME/.local/bin
RUN python3.7 /tmp/get-pip.py \
    && python3.7 -m pip install six psutil lxml pyopenssl \
    && rm /tmp/get-pip.py
RUN pwsh -Command Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP \$${VMWARECEIP} -Confirm:\$false \
    && pwsh -Command Set-PowerCLIConfiguration -PythonPath /usr/bin/python3.7 -Scope User -Confirm:\$false

ENV DEBIAN_FRONTEND=dialog
ENTRYPOINT ["pwsh"]
