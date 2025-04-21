# Builder stage - using latest Caddy builder
FROM caddy:builder AS builder

# Build Caddy with the Cloudflare DNS module
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

# Final stage - using latest Caddy runtime image
FROM caddy:latest

# Copy the custom Caddy binary from the builder stage
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
