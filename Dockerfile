# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Stirling PDF – company image
# Builds from the official image so we can pin a digest and add customisations
# without forking the upstream project.
# ---------------------------------------------------------------------------
FROM stirlingtools/stirling-pdf:latest

# Expose the Spring Boot port (matches container app ingress config)
EXPOSE 8080

# Default health-check for local docker-compose usage
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:8080/actuator/health || exit 1
