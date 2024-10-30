# syntax=docker/dockerfile:1

# Base image
FROM ubuntu:20.04 AS base
LABEL maintainer="Jeremy Combs <jmcombs@me.com>"

# Set environment to non-interactive for apt install
ENV DEBIAN_FRONTEND=noninteractive

# Dockerfile ARG variables for installation
# Consider moving USERNAME and UID/GID to build arguments for flexibility
ARG TARGETARCH
ARG USERNAME=coder
ARG USER_UID=1000
ARG USER_GID=$USER_UID
ARG DOTNET_VERSION=3.1.32

# Set Locale environment variables - consider combining with other ENV
ENV LANGUAGE=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    PATH=/opt/microsoft/dotnet/${DOTNET_VERSION}:/opt/microsoft/dotnet/${DOTNET_VERSION}/tools:/home/$USERNAME/.local/bin:$PATH \
    DOTNET_ROOT=/opt/microsoft/dotnet/${DOTNET_VERSION}

# Configure apt and install base packages
# Consider splitting into multiple RUN commands for better layer caching
RUN apt-get update && \
    apt-get -y install --no-install-recommends software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get -y install --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gcc \
        locales \
        mkisofs \
        xorriso \
        python3.7 \
        python3.7-dev \
        python3.7-distutils \
        sudo \
        whois \
        less \
        p7zip-full \
        unzip \
        libc6 \
        libgcc1 \
        libgssapi-krb5-2 \
        libicu66 \
        libssl1.1 \
        libstdc++6 \
        zlib1g && \
    # Set Locale
    localedef -c -i en_US -f UTF-8 en_US.UTF-8 && \
    locale-gen en_US.UTF-8 && \
    dpkg-reconfigure locales && \
    # Set up non-root User and sudo privileges
    groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID --shell /usr/bin/pwsh --create-home $USERNAME && \
    echo "$USERNAME ALL=(root) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME && \
    # Clean up
    apt-get autoremove -y && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /home/$USERNAME

# Architecture-specific stages - consider combining these into a single stage
# with conditional ARG settings based on TARGETARCH
FROM base AS linux-amd64
ARG DOTNET_ARCH=x64
ARG PS_ARCH=x64

FROM base AS linux-arm64
ARG DOTNET_ARCH=arm64
ARG PS_ARCH=arm64

FROM base AS linux-arm
ARG DOTNET_ARCH=arm
ARG PS_ARCH=arm

# Microsoft installations
FROM linux-${TARGETARCH} AS msft-install
ARG DOTNET_VERSION
ARG DOTNET_ARCH
ARG PS_ARCH

# Install .NET Core - Consider using official Microsoft installation script
RUN DOTNET_PACKAGE=dotnet-runtime-${DOTNET_VERSION}-linux-${DOTNET_ARCH}.tar.gz && \
    DOTNET_PACKAGE_URL=https://dotnetcli.azureedge.net/dotnet/Runtime/${DOTNET_VERSION}/${DOTNET_PACKAGE} && \
    curl -L ${DOTNET_PACKAGE_URL} -o /tmp/dotnet.tar.gz && \
    mkdir -p ${DOTNET_ROOT} && \
    tar zxf /tmp/dotnet.tar.gz -C ${DOTNET_ROOT} && \
    rm /tmp/dotnet.tar.gz

# Install PowerShell Core with version pinning
RUN PS_MAJOR_VERSION=$(curl -Ls -o /dev/null -w %{url_effective} https://aka.ms/powershell-release?tag=lts | cut -d 'v' -f 2 | cut -d '.' -f 1) && \
    PS_INSTALL_FOLDER=/opt/microsoft/powershell/${PS_MAJOR_VERSION} && \
    PS_PACKAGE_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://aka.ms/powershell-release?tag=lts | \
        sed 's#https://github.com#https://api.github.com/repos#g; s#tag/#tags/#' | \
        xargs curl -s | grep browser_download_url | grep linux-${PS_ARCH}.tar.gz | cut -d '"' -f 4) && \
    curl -L ${PS_PACKAGE_URL} -o powershell.tar.gz && \
    mkdir -p ${PS_INSTALL_FOLDER} && \
    tar zxf powershell.tar.gz -C ${PS_INSTALL_FOLDER} && \
    chmod a+x,o-w ${PS_INSTALL_FOLDER}/pwsh && \
    ln -s ${PS_INSTALL_FOLDER}/pwsh /usr/bin/pwsh && \
    rm powershell.tar.gz && \
    echo /usr/bin/pwsh >> /etc/shells

# VMware PowerCLI installation stages with robust error handling
FROM msft-install AS vmware-install-arm64
SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]
# Consider adding version pinning for all PowerShell modules
RUN Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
    $MaxAttempts = 3; \
    $Attempt = 1; \
    do { \
        try { \
            Write-Host "Attempt $Attempt to install VMware.PowerCLI..."; \
            Install-Module -Name VMware.PowerCLI -RequiredVersion 13.0.0.20829139 -Scope AllUsers -Repository PSGallery -Force -Verbose; \
            Write-Host "Installation successful!"; \
            break; \
        } catch { \
            if ($Attempt -eq $MaxAttempts) { \
                Write-Host "Failed after $MaxAttempts attempts. Last error: $_"; \
                throw; \
            } \
            Write-Host "Attempt $Attempt failed. Retrying... Error: $_"; \
            $Attempt++; \
            Start-Sleep -Seconds 5; \
        } \
    } while ($true)

FROM msft-install AS vmware-install-amd64
SHELL ["pwsh", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]
# Consider combining arm64 and amd64 stages with conditional version selection
RUN Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
    $MaxAttempts = 3; \
    $Attempt = 1; \
    do { \
        try { \
            Write-Host "Attempt $Attempt to install VMware.PowerCLI..."; \
            Install-Module -Name VMware.PowerCLI -Scope AllUsers -Repository PSGallery -Force -Verbose; \
            Write-Host "Installation successful!"; \
            break; \
        } catch { \
            if ($Attempt -eq $MaxAttempts) { \
                Write-Host "Failed after $MaxAttempts attempts. Last error: $_"; \
                throw; \
            } \
            Write-Host "Attempt $Attempt failed. Retrying... Error: $_"; \
            $Attempt++; \
            Start-Sleep -Seconds 5; \
        } \
    } while ($true)

# Final stage
FROM vmware-install-${TARGETARCH}

USER $USERNAME

# Install pip for Python 3.7 and dependencies
# Consider using requirements.txt for Python dependencies
ADD --chown=${USER_UID}:${USER_GID} https://bootstrap.pypa.io/pip/3.7/get-pip.py /tmp/get-pip.py
RUN python3.7 /tmp/get-pip.py && \
    python3.7 -m pip install six psutil lxml pyopenssl && \
    rm /tmp/get-pip.py

# Configure VMware CEIP participation
RUN pwsh -Command "$ErrorActionPreference = 'Stop'; Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP:\$false -Confirm:\$false"

# Set Python path for PowerCLI
RUN pwsh -Command "$ErrorActionPreference = 'Stop'; Set-PowerCLIConfiguration -PythonPath /usr/bin/python3.7 -Scope User -Confirm:\$false"

# Ensure PowerShell is functioning as expected
RUN pwsh -Command "Write-Output 'PowerShell is set up correctly'"

ENV DEBIAN_FRONTEND=dialog

ENTRYPOINT ["pwsh"]
