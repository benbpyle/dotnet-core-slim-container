# Enable the Datadog APM bits
ARG ENABLE_DATADOG_APM=false 

# Base Docker Image that the output will run on
FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS base
# Sets the exposed port
EXPOSE $EXPOSED_PORT
WORKDIR /app

# Builder Docker Image that is alpine based but contains the .NET SDK
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
# Allows for debug building if needed
ARG PUBLISH_CONFIGURATION=release

WORKDIR /src
COPY ["ReferenceWebApi/ReferenceWebApi.csproj", "ReferenceWebApi/"]
RUN dotnet restore "ReferenceWebApi/ReferenceWebApi.csproj"

COPY . .

WORKDIR "/src/ReferenceWebApi"
RUN dotnet build "ReferenceWebApi.csproj" -c $PUBLISH_CONFIGURATION -o /app/build

# Publish Docker Image that is built on the build image for publishing the application
FROM build AS publish
ARG PUBLISH_CONFIGURATION=release
RUN dotnet publish "ReferenceWebApi.csproj" -c $PUBLISH_CONFIGURATION -o /app/publish /p:UseAppHost=false

# apm-false is the final image when there is no need for the APM tracer
FROM base as apm-false

FROM base as apm-true
# Enable the Datadog Continuous Profiler
ARG ENABLE_DATADOG_PROFILER=0
# Download the latest version of the tracer 
# Since this is a musl based container, it only comes in a tarball that must be extracted
RUN apk add curl \
    && TRACER_VERSION=$(curl -s \https://api.github.com/repos/DataDog/dd-trace-dotnet/releases/latest | grep tag_name | cut -d '"' -f 4 | cut -c2-)  \
    && curl -Lo /tmp/datadog-dotnet-apm.tar.gz https://github.com/DataDog/dd-trace-dotnet/releases/download/v${TRACER_VERSION}/datadog-dotnet-apm-${TRACER_VERSION}-musl.tar.gz  \
    && mkdir -p /opt/datadog \
    && mkdir -p /var/log/datadog \
    && mv /tmp/datadog-dotnet-apm.tar.gz /opt/datadog/datadog-dotnet-apm.tar.gz

RUN cd /opt/datadog \
    && tar -xvf datadog-dotnet-apm.tar.gz \
    && sh /opt/datadog/createLogPath.sh \
    && rm -f datadog-dotnet-apm.tar.gz \
    && apk add icu-dev

# APM Tracer Variables
ENV CORECLR_ENABLE_PROFILING=1
ENV CORECLR_PROFILER={846F5F1C-F9AE-4B07-969E-05C26BC060D8}
ENV CORECLR_PROFILER_PATH=/opt/datadog/linux-musl-x64/Datadog.Trace.ClrProfiler.Native.so
ENV DD_DOTNET_TRACER_HOME=/opt/datadog
# These two lines enable the continuous profiler.  
# If DD_PROFILING_ENABLED=1 (which is defaulted to 0), the profiler will be turned on 
ENV LD_PRELOAD=/opt/datadog/continuousprofiler/Datadog.Linux.ApiWrapper.x64.so
ENV DD_PROFILING_ENABLED=$ENABLE_DATADOG_PROFILER  

# The last image, built from the Datadog APM branching that either adds the tracer or does not
FROM apm-${ENABLE_DATADOG_APM} AS final

WORKDIR /app
# Application User and Group so not to run as root
ARG APP_USER=aspnet_user
ARG APP_GROUP=aspnet_group
# Port to exose to the container host
ARG EXPOSED_PORT=8080

RUN addgroup -S ${APP_GROUP} && \
    adduser -S ${APP_USER}

# Copy the output of publish into this image and give ownership to the user and group created
COPY --from=publish --chown=$APP_USER:$APP_GROUP /app/publish .

# Sets the container User
USER $APP_USER

ENTRYPOINT ["dotnet", "ReferenceWebApi.dll"]
