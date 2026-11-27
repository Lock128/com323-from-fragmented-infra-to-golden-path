# Build the function-observability runtime binary.
# The build.sh then wraps this runtime image into a Crossplane xpkg (Function
# package) with `crossplane xpkg build` and pushes it to the in-cluster registry.
#
# Base must satisfy go.mod's `go 1.24.x` directive (the SDK's transitive deps
# require it). GOTOOLCHAIN=auto lets it fetch a newer patch toolchain if go.mod
# ever bumps past the base image.
# Cross-compile on the build platform for the target platform (TARGETARCH), so
# `docker build --platform linux/amd64` on an arm64 Mac does not emulate the Go toolchain.
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ARG TARGETARCH
ENV GOTOOLCHAIN=auto
WORKDIR /src
# Build from the VENDORED modules so the image build needs NO network — this
# sidesteps the corporate-proxy TLS issue (go mod download can't verify
# proxy.golang.org behind Zscaler inside the build container). build.sh runs
# `go mod vendor` on the host first.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -mod=vendor -o /function .

FROM gcr.io/distroless/static-debian12
WORKDIR /
COPY --from=build /function /function
EXPOSE 9443
ENTRYPOINT ["/function"]
