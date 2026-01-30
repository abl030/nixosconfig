FROM docker.io/golang:1.22-alpine AS build
ENV GOTOOLCHAIN=auto
RUN apk add --no-cache git
RUN git clone --depth 1 https://github.com/grafana/loki-mcp /src
WORKDIR /src
RUN go build -o /loki-mcp-server ./cmd/server

FROM docker.io/alpine:3.20
RUN adduser -D -u 10001 app
USER app
COPY --from=build /loki-mcp-server /usr/local/bin/loki-mcp-server
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/loki-mcp-server"]
