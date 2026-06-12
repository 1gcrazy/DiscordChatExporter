# Scheduled, self-hosted Discord server backup.
#
# Stage 1 builds the CLI from THIS fork (mirrors DiscordChatExporter.Cli.dockerfile),
# so any changes you make to the exporter are included.
# Stage 2 adds a cron scheduler + the incremental backup driver + rclone.
#
# Build context MUST be the repository root, e.g.:
#   docker build -f backup/docker/Dockerfile -t dce-backup .
# (docker-compose.yml in this folder already sets the context correctly.)

# -- Build the CLI from source
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0-alpine AS build
ARG TARGETARCH
ARG VERSION=0.0.0
WORKDIR /tmp/app

COPY favicon.ico .
COPY NuGet.config .
COPY Directory.Build.props .
COPY Directory.Packages.props .
COPY DiscordChatExporter.Core DiscordChatExporter.Core
COPY DiscordChatExporter.Cli DiscordChatExporter.Cli

RUN dotnet publish DiscordChatExporter.Cli \
    -p:Version=$VERSION \
    -p:CSharpier_Bypass=true \
    --configuration Release \
    --self-contained \
    --use-current-runtime \
    --arch $TARGETARCH \
    --output /opt/app/

# -- Runtime + scheduler
FROM --platform=$TARGETPLATFORM mcr.microsoft.com/dotnet/runtime-deps:10.0-alpine AS run

# ICU (locales) + tz, plus the tools the backup driver needs.
RUN apk add --no-cache icu-libs icu-data-full tzdata bash jq rclone dcron
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8

COPY --from=build /opt/app /opt/app
COPY backup/scripts/backup.sh        /opt/backup/backup.sh
COPY backup/docker/entrypoint.sh     /opt/backup/entrypoint.sh
RUN chmod +x /opt/backup/backup.sh /opt/backup/entrypoint.sh

# Defaults — override via docker-compose / -e
ENV DCE_CLI=/opt/app/DiscordChatExporter.Cli \
    DCE_CONFIG=/data/config.json \
    DCE_OUTPUT_ROOT=/data/exports \
    DCE_STATE_DIR=/data/state \
    DCE_LOG_DIR=/data/logs \
    CRON_SCHEDULE="0 * * * *" \
    RUN_ON_START=true \
    TZ=UTC

WORKDIR /data
ENTRYPOINT ["/opt/backup/entrypoint.sh"]
