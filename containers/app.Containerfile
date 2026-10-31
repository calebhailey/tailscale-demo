FROM golang:1.27-bookworm AS build
WORKDIR /src
COPY app/go.mod ./
RUN go mod download
COPY app/ ./
RUN CGO_ENABLED=0 go build -buildvcs=false -trimpath -ldflags='-s -w' -o /out/tailscale-demo .

FROM debian:latest
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/tailscale-demo /usr/local/bin/tailscale-demo
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/tailscale-demo"]
CMD ["--host", "0.0.0.0", "--port", "8080"]
