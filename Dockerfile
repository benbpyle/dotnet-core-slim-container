# Enable the Datadog APM bits
ARG ENABLE_DATADOG_APM=false 

# Base Docker Image that the output will run on - Debian Slim
FROM mcr.microsoft.com/dotnet/aspnet:8.0-bookworm-slim AS base
# Sets the exposed port
EXPOSE $EXPOSED_PORT
WORKDIR /app

# Builder Docker Image that contains the .NET SDK
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
# Allows for debug building if needed
ARG PUBLISH_CONFIGURATION=release
# Datdog package by Architect
ARG APM_ARCHITECTURE=amd64

WORKDIR /src
COPY ["ReferenceWebApi/ReferenceWebApi.csproj", "ReferenceWebApi/"]
RUN dotnet restore "ReferenceWebApi/ReferenceWebApi.csproj"

COPY . .

WORKDIR "/src/ReferenceWebApi"
RUN dotnet build "ReferenceWebApi.csproj" -c $PUBLISH_CONFIGURATION -o /app/build

# Download the latest version of the tracer 
RUN TRACER_VERSION=$(curl -s \https://api.github.com/repos/DataDog/dd-trace-dotnet/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c2-) \
    && curl -Lo /tmp/datadog-dotnet-apm.deb https://github.com/DataDog/dd-trace-dotnet/releases/download/v${TRACER_VERSION}/datadog-dotnet-apm_${TRACER_VERSION}_${APM_ARCHITECTURE}.deb


# Publish Docker Image that is built on the build image for publishing the application
FROM build AS publish
ARG PUBLISH_CONFIGURATION=release
RUN dotnet publish "ReferenceWebApi.csproj" -c $PUBLISH_CONFIGURATION -o /app/publish /p:UseAppHost=false

# apm-false is the final image when there is no need for the APM tracer
FROM base as apm-false

FROM base as apm-true
# Install the Datadog APM tracer
COPY --from=build /tmp/datadog-dotnet-apm.deb /tmp/datadog-dotnet-apm.deb
# Install the tracer
RUN mkdir -p /opt/datadog \
    && mkdir -p /var/log/datadog \
    && dpkg -i /tmp/datadog-dotnet-apm.deb \
    && rm /tmp/datadog-dotnet-apm.deb

# APM Tracer Variables
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8}
ENV CORECLR_PROFILER_PATH=/opt/datadog/Datadog.Trace.ClrProfiler.Native.so
ENV DD_DOTNET_TRACER_HOME=/opt/datadog
ENV DD_INTEGRATIONS=/opt/datadog/integrations.json

# The last image, built from the Datadog APM branching that either adds the tracer or does not
FROM apm-${ENABLE_DATADOG_APM} AS final

WORKDIR /app
# Application User and Group so not to run as root
ARG APP_USER=aspnet_user
# Port to exose to the container host
ARG EXPOSED_PORT=8080

RUN adduser --system --no-create-home $APP_USER
# Copy the output of publish into this image and give ownership to the user and group created
COPY --from=publish /app/publish .

# Sets the container User
USER $APP_USER

ENTRYPOINT ["dotnet", "ReferenceWebApi.dll"]
