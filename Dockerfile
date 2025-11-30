# Base image: Alpine Linux (lightweight)
FROM alpine:3

# Install runtime dependencies
# - curl: for downloading mods
# - jq: for parsing Modrinth API JSON
# - ca-certificates: for SSL verification
RUN apk add --no-cache curl jq ca-certificates

# Create a working directory
WORKDIR /app

# Copy the script into the container
COPY update-optional-mods.sh /app/update-optional-mods.sh

# Ensure the script is executable
RUN chmod +x /app/update-optional-mods.sh

# Set the script as the entrypoint
# This allows running the container like an executable
ENTRYPOINT ["/app/update-optional-mods.sh"]
